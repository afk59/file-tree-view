/** Public surface of the `filetreeview` HAR. Anything not re-exported here is internal. */

// Data model
export { FileNode, FileTreeConfig, FileTreeLabels, FileTreeSort } from './src/main/ets/model/FileNode';

// Data layer
export { FileTreeDataSource } from './src/main/ets/datasource/FileTreeDataSource';
export { DefaultFileTreeDataSource } from './src/main/ets/datasource/DefaultFileTreeDataSource';

// UI layer
export { FileTreeView } from './src/main/ets/components/FileTreeView';

// Permissions — the user directories are path-authorized, not read-authorized
export {
  USER_DIR_PERMISSIONS,
  ALL_USER_DIR_PERMISSIONS,
  DESKTOP_DIR_PERMISSION,
  UserDirPermissionResult,
  checkUserDirPermissions,
  requestUserDirPermissions
} from './src/main/ets/permission/UserDirPermissions';

// Access layer — picker grants and full-disk access
export {
  FULL_DISK_PERMISSION,
  PickedRoot,
  isFolderAuthorizationSupported,
  isFolderSelectionSupported,
  hasFullDisk,
  canRequestFullDisk,
  openFullDiskSetting,
  fullDiskRoot,
  pickFolders,
  activatePersistedRoots
} from './src/main/ets/access/StorageAccess';
