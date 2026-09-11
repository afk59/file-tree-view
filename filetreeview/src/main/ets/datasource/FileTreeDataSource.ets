import { FileNode } from '../model/FileNode';

/**
 * The tree's source of data.
 *
 * Both calls return one level only — that single-level contract is what keeps the tree lazy.
 * Implement this to back the tree with something other than the device file system (a remote
 * host, a test double, an archive). `FileTreeView` never calls `fileIo` directly.
 */
export interface FileTreeDataSource {
  /**
   * The top-level nodes. Called once when the tree is built.
   *
   * Must not reject just because one root is unavailable — return the roots that worked.
   */
  getRoots(): Promise<FileNode[]>;

  /**
   * The immediate children of `node`. One level, no recursion.
   *
   * Rejects if the directory itself cannot be listed; individual unreadable entries should be
   * returned as nodes carrying `error`.
   */
  listChildren(node: FileNode): Promise<FileNode[]>;
}
