# Changelog

## 1.0.0

First release.

### Component

- `FileTreeView`: a lazy-loading tree panel over the device file system. A directory's children are
  read the first time it is expanded and memoised; nothing recurses and nothing is fetched
  speculatively.
- Every directory draws an expander arrow from the moment it appears, whether or not its children
  have been read.
- Keyboard navigation: Up/Down move the cursor, Right opens a folder or steps into an open one,
  Left closes it or steps out to the parent, Enter/Space activates.
- Pointer hover feedback and a selection highlight, for PC / 2-in-1 use.
- `rootsVersion` makes a mounted tree re-read its roots without collapsing the directories the user
  has already opened.
- Host callbacks (`onFileSelected`, `onDirExpanded`, `onError`) are invoked defensively: one that
  throws is logged, not propagated.
- Text is overridable through `FileTreeConfig.labels`, so the built-in English strings can be
  localised without forking the component.

### Data layer

- `FileTreeDataSource`: a two-method interface, both calls returning one level only.
- `DefaultFileTreeDataSource`: the device file system, with `addRoot` / `removeRoot` /
  `listExtraRoots` so picked folders join the same tree. Entries are `stat`ed in bounded batches
  rather than all at once.
- `FileTreeConfig`: hidden-file, extension whitelist/blacklist and sort options. Directories are
  never removed by an extension rule and always sort before files.
- `FileNode.mtime` is published in milliseconds; the conversion from `Stat.mtime` seconds happens
  in exactly one place.
- An entry whose `stat` fails is returned as a node carrying `error` instead of failing the whole
  listing.

### Permissions and access

- `checkUserDirPermissions` / `requestUserDirPermissions`, which separate the permissions no dialog
  can fix (undeclared, or declared without the signature ACL) from the ones the user refused.
- `USER_DIR_PERMISSIONS`, `ALL_USER_DIR_PERMISSIONS`, `DESKTOP_DIR_PERMISSION`.
- `pickFolders` / `activatePersistedRoots` for folder grants that survive a restart, guarded by
  `isFolderSelectionSupported()` and `isFolderAuthorizationSupported()`.
- `hasFullDisk`, `canRequestFullDisk`, `openFullDiskSetting`, `fullDiskRoot` for
  `ACCESS_USER_FULL_DISK` on PC / 2-in-1, including the `manual_settings` route to the Settings
  page since no runtime dialog exists for it.

### Notes

- No third-party runtime dependencies; system kits only.
- Supported device types: `2in1`, `tablet`.
- The library persists nothing. Picked-folder URIs are returned to the host to store.
