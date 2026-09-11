import { Environment, fileIo, ListFileOptions } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileNode, FileTreeConfig, FileTreeSort } from '../model/FileNode';
import { FileTreeDataSource } from './FileTreeDataSource';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTreeView';

/** `Stat.mtime` is in seconds; `FileNode.mtime` is in milliseconds. */
const SECONDS_TO_MILLIS: number = 1000;

/** How many `stat` calls may be in flight at once. See `listChildren`. */
const STAT_BATCH: number = 64;

/** Error code 801: the API is not supported on this device. */
const ERR_CAPABILITY_NOT_SUPPORTED: number = 801;

/**
 * Error code 13900001 (EPERM). The pre-authorized user directories return this until the
 * matching `user_grant` permission is granted — see `permission/UserDirPermissions.ets`. The
 * raw message, "Operation not permitted", says nothing about permissions.
 */
const ERR_OPERATION_NOT_PERMITTED: number = 13900001;

/**
 * The system capability behind the three `Environment` getters.
 *
 * Every call to them sits lexically inside a `canIUse(ENVIRONMENT_SYSCAP)` block: the ArkTS
 * compiler raises "not supported on all devices" for any call it cannot see guarded, and it
 * only recognises the guard when the call is inside the `if`. That is why the three getters are
 * written out longhand in `getRoots()` rather than looped over.
 */
const ENVIRONMENT_SYSCAP: string = 'SystemCapability.FileManagement.File.Environment.FolderObtain';

/**
 * The default `FileTreeDataSource`: the device file system, one level at a time.
 *
 * Roots come from `Environment`, plus anything the host adds with `addRoot()` — that is how a
 * picked folder joins the same tree. Children come from `fileIo.listFile` + `fileIo.stat`.
 */
export class DefaultFileTreeDataSource implements FileTreeDataSource {
  private config: FileTreeConfig;
  private extraRoots: FileNode[] = [];

  constructor(config?: FileTreeConfig) {
    this.config = config ?? {};
  }

  /** Replace the filtering/ordering config. The caller re-lists to see the effect. */
  setConfig(config: FileTreeConfig): void {
    this.config = config;
  }

  /**
   * Add a root beyond the pre-authorized ones, e.g. a folder the user picked.
   * Ignored if a root with the same path is already present.
   */
  addRoot(node: FileNode): void {
    for (const existing of this.extraRoots) {
      if (existing.path === node.path) {
        return;
      }
    }
    this.extraRoots.push(node);
  }

  /**
   * Drop a host-added root by path. No-op if it is not there.
   * Never touches the `Environment` roots.
   */
  removeRoot(path: string): boolean {
    const before: number = this.extraRoots.length;
    this.extraRoots = this.extraRoots.filter((n: FileNode) => n.path !== path);
    return this.extraRoots.length !== before;
  }

  /** The host-added roots, as a copy. Useful for persisting them. */
  listExtraRoots(): FileNode[] {
    return this.extraRoots.slice();
  }

  /**
   * The pre-authorized user directories, then any host-added roots.
   *
   * Never rejects: each `Environment` getter is wrapped on its own, so a directory that is
   * unavailable on this device cannot take the others down with it. An empty result means no
   * reachable storage yet, which is a state to render rather than an error.
   *
   * These are paths, not access: listing them still needs the matching `user_grant` permission,
   * so `getRoots()` succeeding says nothing about `listChildren()` succeeding.
   */
  async getRoots(): Promise<FileNode[]> {
    const roots: FileNode[] = [];

    // Positive `if`, not an early return on the negation: the compiler only accepts the guard
    // when the calls are lexically inside the `canIUse` block.
    if (canIUse(ENVIRONMENT_SYSCAP)) {
      try {
        DefaultFileTreeDataSource.pushRoot(roots, 'Documents', Environment.getUserDocumentDir());
      } catch (e) {
        DefaultFileTreeDataSource.logRootFailure('Documents', e);
      }
      try {
        DefaultFileTreeDataSource.pushRoot(roots, 'Download', Environment.getUserDownloadDir());
      } catch (e) {
        DefaultFileTreeDataSource.logRootFailure('Download', e);
      }
      try {
        DefaultFileTreeDataSource.pushRoot(roots, 'Desktop', Environment.getUserDesktopDir());
      } catch (e) {
        DefaultFileTreeDataSource.logRootFailure('Desktop', e);
      }
    } else {
      // Without the capability every getter would throw 801. Skip them and let host-added roots
      // stand on their own.
      hilog.warn(DOMAIN, TAG,
        'Environment capability absent; the pre-authorized user directories are unavailable.');
    }

    for (const extra of this.extraRoots) {
      roots.push(extra);
    }
    return roots;
  }

  /** Turn a resolved user-directory path into a root node. Empty paths are dropped. */
  private static pushRoot(roots: FileNode[], label: string, path: string): void {
    if (path.length === 0) {
      hilog.warn(DOMAIN, TAG, 'Root %{public}s resolved to an empty path; skipping.', label);
      return;
    }
    roots.push({ name: label, path: path, isDirectory: true, loaded: false });
  }

  /** Report a root that could not be resolved. Never rethrows. */
  private static logRootFailure(label: string, e: Object): void {
    const err = e as BusinessError;
    if (err.code === ERR_CAPABILITY_NOT_SUPPORTED) {
      // The syscap guard should have caught this; otherwise the device lacks the directory.
      hilog.warn(DOMAIN, TAG, 'Root %{public}s unavailable on this device (801).', label);
    } else {
      hilog.error(DOMAIN, TAG, 'Root %{public}s failed. Code: %{public}d, message: %{public}s',
        label, err.code, err.message);
    }
  }

  /**
   * The immediate children of `node` — one level, no recursion.
   *
   * `recursion: false` is passed explicitly even though it is the default, since that one flag
   * is what keeps the tree lazy. `listNum` is left at its default of 0, meaning all names.
   *
   * Rejects if the directory itself cannot be listed. An entry whose `stat` fails is returned
   * as a node carrying `error`, so one unreadable file does not blank out its siblings.
   */
  async listChildren(node: FileNode): Promise<FileNode[]> {
    if (!node.isDirectory) {
      return [];
    }

    const dirPath: string = node.path;
    const options: ListFileOptions = { recursion: false };

    let names: string[] = [];
    try {
      names = await fileIo.listFile(dirPath, options);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'listFile failed for %{public}s. Code: %{public}d, message: %{public}s',
        dirPath, err.code, err.message);
      if (err.code === ERR_OPERATION_NOT_PERMITTED) {
        // The system message alone sends people hunting for a bad path when only the grant is
        // missing, so name the actual cause.
        throw new Error(
          `Cannot list "${node.name}": permission not granted (code ${err.code}). ` +
          'Request the user-directory permission first — see USER_DIR_PERMISSIONS.');
      }
      throw new Error(`Cannot list "${node.name}" (code ${err.code}): ${err.message}`);
    }

    // `stat` every entry, but only STAT_BATCH at a time. A single `Promise.all` over the whole
    // listing opens one file descriptor per entry at once, which a directory with tens of
    // thousands of files will not survive.
    const children: FileNode[] = [];
    for (let i: number = 0; i < names.length; i += STAT_BATCH) {
      const slice: string[] = names.slice(i, i + STAT_BATCH);
      const batch: FileNode[] = await Promise.all(
        slice.map((name: string) => this.statChild(dirPath, name))
      );
      for (const child of batch) {
        children.push(child);
      }
    }
    return this.applyConfig(children);
  }

  /** `stat` one listed entry, degrading to an error-marked node rather than throwing. */
  private async statChild(dirPath: string, name: string): Promise<FileNode> {
    const childPath: string = DefaultFileTreeDataSource.joinPath(dirPath, name);
    try {
      const stat: fileIo.Stat = await fileIo.stat(childPath);
      // `isDirectory()` is declared as throwing (13900005 I/O error, 13900042 unknown), so it is
      // called inside this guard: a throw degrades one entry instead of the whole listing.
      const isDirectory: boolean = stat.isDirectory();
      return DefaultFileTreeDataSource.toFileNode(name, childPath, stat, isDirectory);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'stat failed for %{public}s. Code: %{public}d, message: %{public}s',
        childPath, err.code, err.message);
      // `stat` is what would have told us whether this is a directory, so surface it as a
      // non-expandable leaf carrying the reason. Code 13900012 is "Permission denied".
      return {
        name: name,
        path: childPath,
        isDirectory: false,
        // Not `loaded: true` — nothing was loaded.
        error: `code ${err.code}: ${err.message}`
      };
    }
  }

  /**
   * The single `Stat` -> `FileNode` conversion point, and the only place a timestamp is scaled:
   * `Stat.mtime` is in seconds, `FileNode.mtime` in milliseconds.
   */
  private static toFileNode(
    name: string, path: string, stat: fileIo.Stat, isDirectory: boolean): FileNode {
    return {
      name: name,
      path: path,
      isDirectory: isDirectory,
      // `Stat.size` is valid only for regular files, so directories get no size.
      size: isDirectory ? undefined : stat.size,
      mtime: stat.mtime * SECONDS_TO_MILLIS,
      loaded: false
    };
  }

  /** Join a directory path and a base name without doubling the separator. */
  private static joinPath(dirPath: string, name: string): string {
    return dirPath.endsWith('/') ? `${dirPath}${name}` : `${dirPath}/${name}`;
  }

  /** Lower-cased extension without the dot; empty for dot-files and names with no extension. */
  private static extensionOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  /** Apply `FileTreeConfig`: filter first, then order. */
  private applyConfig(nodes: FileNode[]): FileNode[] {
    const showHidden: boolean = this.config.showHidden ?? false;
    const whitelist: string[] = this.config.extWhitelist ?? [];
    const blacklist: string[] = this.config.extBlacklist ?? [];

    const kept: FileNode[] = nodes.filter((n: FileNode) => {
      if (!showHidden && n.name.startsWith('.')) {
        return false;
      }
      // An extension rule never removes a directory; that would hide the subtree behind it.
      if (n.isDirectory) {
        return true;
      }
      // Nor a node we failed to `stat`: it is marked `isDirectory: false` only because nothing
      // told us otherwise, so filtering it could hide a subtree too.
      if (n.error !== undefined) {
        return true;
      }
      const ext: string = DefaultFileTreeDataSource.extensionOf(n.name);
      if (blacklist.length > 0 && blacklist.some((b: string) => b.toLowerCase() === ext)) {
        return false;
      }
      if (whitelist.length > 0 && !whitelist.some((w: string) => w.toLowerCase() === ext)) {
        return false;
      }
      return true;
    });

    const sort: FileTreeSort = this.config.sort ?? 'name-asc';
    kept.sort((a: FileNode, b: FileNode) => DefaultFileTreeDataSource.compare(a, b, sort));
    return kept;
  }

  /** Directories before files, always. `sort` only orders within a group. */
  private static compare(a: FileNode, b: FileNode, sort: FileTreeSort): number {
    if (a.isDirectory !== b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    const byName: number = a.name.localeCompare(b.name);
    switch (sort) {
      case 'name-asc':
        return byName;
      case 'name-desc':
        return -byName;
      case 'size-asc':
      case 'size-desc': {
        // Size is meaningless for a directory, so directories stay in name order.
        if (a.isDirectory) {
          return byName;
        }
        const diff: number = (a.size ?? 0) - (b.size ?? 0);
        if (diff === 0) {
          return byName;
        }
        return sort === 'size-asc' ? diff : -diff;
      }
      case 'date-asc':
      case 'date-desc': {
        const diff: number = (a.mtime ?? 0) - (b.mtime ?? 0);
        if (diff === 0) {
          return byName;
        }
        return sort === 'date-asc' ? diff : -diff;
      }
      default:
        return byName;
    }
  }
}
