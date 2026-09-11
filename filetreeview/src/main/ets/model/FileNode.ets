/**
 * Data model for the file tree. No UI and no file-system calls, so it can be referenced from
 * either side of the component.
 */

/** One entry in the tree: a file or a directory. */
export interface FileNode {
  /** Base name, e.g. `report.pdf`. Never a path. */
  name: string;
  /** Absolute sandbox path, e.g. `/storage/Users/currentUser/Documents/report.pdf`. */
  path: string;
  /** True for a directory. Resolved with `Stat.isDirectory()`, not from the name. */
  isDirectory: boolean;
  /** Size in bytes. Files only — `Stat.size` is valid only for regular files. */
  size?: number;
  /**
   * Last modified, in milliseconds since the epoch, ready for `new Date(...)`.
   * `Stat.mtime` is in seconds; the conversion happens only in
   * `DefaultFileTreeDataSource.toFileNode()`.
   */
  mtime?: number;
  /** Set when access came from a picker grant rather than a pre-authorized directory. */
  uri?: string;
  /** True once `listChildren()` has run for this node, so re-expanding does not refetch. */
  loaded?: boolean;
  /**
   * Set when this node could not be read, e.g. `stat` returned 13900012 Permission denied.
   * The node is still listed; the UI renders the reason instead of dropping the entry.
   */
  error?: string;
}

/** Ordering applied within the directory group and within the file group. */
export type FileTreeSort =
  'name-asc' | 'name-desc' | 'size-asc' | 'size-desc' | 'date-asc' | 'date-desc';

/**
 * The text the tree draws itself. Defaults are English; override whichever ones your app
 * localises, and leave the rest undefined.
 */
export interface FileTreeLabels {
  /** Shown while the roots are being read. Default `'Loading…'`. */
  loading?: string;
  /** Shown when there are no roots at all. Default `'No folders available.'`. */
  noRoots?: string;
  /** Trailing text on a directory that was listed and had nothing in it. Default `'empty'`. */
  emptyFolder?: string;
  /** Trailing text on a directory whose listing is in flight. Default `'…'`. */
  rowLoading?: string;
}

/** Host-supplied filtering, ordering and labels. Every field is optional. */
export interface FileTreeConfig {
  /** Show dot-files. Default `false`. Applies to directories as well as files. */
  showHidden?: boolean;
  /**
   * If set and non-empty, only files with these extensions are listed. Extensions are compared
   * case-insensitively, without the dot: `['key', 'pem', 'xsh']`. Directories are never filtered
   * by this, since that would hide the whole subtree behind them.
   */
  extWhitelist?: string[];
  /** Files with these extensions are hidden. Takes precedence over `extWhitelist`. */
  extBlacklist?: string[];
  /** Default `'name-asc'`. */
  sort?: FileTreeSort;
  /**
   * Overrides for the component's built-in text. Unlike the fields above, these are read by
   * `FileTreeView` itself, so they apply whatever `FileTreeDataSource` is in use.
   */
  labels?: FileTreeLabels;
}
