import { hilog } from '@kit.PerformanceAnalysisKit';
import { DefaultFileTreeDataSource, FileNode } from '@afk35/filetreeview';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTreeProbe';

/**
 * Diagnostic: log the roots and one level of children, with dir/file flags. No UI, so the data
 * layer can be checked on its own. Filter logcat on `FileTreeProbe` to read it.
 */
export async function runDataSourceProbe(): Promise<void> {
  const ds = new DefaultFileTreeDataSource({ showHidden: false, sort: 'name-asc' });

  const roots: FileNode[] = await ds.getRoots();
  hilog.info(DOMAIN, TAG, '--- roots: %{public}d ---', roots.length);
  if (roots.length === 0) {
    // Expected where the Environment capability is absent: every getter throws 801 there.
    hilog.warn(DOMAIN, TAG, 'No roots. Without the Environment capability this is correct (801).');
    return;
  }
  for (const root of roots) {
    hilog.info(DOMAIN, TAG, 'root name=%{public}s path=%{public}s', root.name, root.path);
  }

  // One level under the first root only — walking the tree here would defeat the point.
  const first: FileNode = roots[0];
  try {
    const children: FileNode[] = await ds.listChildren(first);
    hilog.info(DOMAIN, TAG, '--- children of %{public}s: %{public}d ---', first.name, children.length);
    for (const child of children) {
      hilog.info(DOMAIN, TAG,
        '%{public}s name=%{public}s size=%{public}s mtime=%{public}s%{public}s',
        child.isDirectory ? '[DIR ]' : '[FILE]',
        child.name,
        child.size === undefined ? '-' : `${child.size}`,
        // mtime is milliseconds; a 1970 date here means the conversion regressed.
        child.mtime === undefined ? '-' : new Date(child.mtime).toISOString(),
        child.error === undefined ? '' : ` ERROR(${child.error})`);
    }
  } catch (e) {
    const err = e as Error;
    hilog.error(DOMAIN, TAG, 'listChildren failed: %{public}s', err.message);
  }
}
