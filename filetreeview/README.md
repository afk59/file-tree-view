# file-tree-view

A lazy-loading file tree for HarmonyOS NEXT, bound to the real device file system.

Source: https://github.com/afk59/file-tree-view

`FileTreeView` renders the user's storage as an expandable tree panel. A directory's children are
read the first time it is expanded and never again, so the component stays responsive on deep
trees and never walks the file system speculatively. It is built for the PC / 2-in-1 form factor —
pointer hover, keyboard navigation, a persistent side panel — and works on tablets with whatever
storage access that device grants.

- No third-party runtime dependencies. System kits only: `@kit.ArkUI`, `@kit.CoreFileKit`,
  `@kit.AbilityKit`, `@kit.InputKit`, `@kit.BasicServicesKit`, `@kit.PerformanceAnalysisKit`.
- Every directory shows an expander arrow from the moment it appears, whether or not its children
  have been read.
- Pluggable data layer: back the tree with something other than the device file system by
  implementing one two-method interface.
- Ships the permission and picker helpers the file system actually requires, including the
  restricted-permission cases that fail at install time rather than at runtime.

## Installation

```bash
ohpm i file-tree-view
```

## Quick start

```ets
import { FileTreeView, FileNode } from 'file-tree-view';

@Entry
@Component
struct Index {
  @State selected: string = '';

  build() {
    Column() {
      FileTreeView({
        onFileSelected: (node: FileNode) => { this.selected = node.path; }
      })
    }
    .width('100%')
    .height('100%')
  }
}
```

With no arguments the tree reads the device file system and lists the pre-authorized user
directories. That is not enough on its own — see **Permissions** below, or the tree will show
`No folders available.`

## Permissions

This is the part that decides whether the component shows anything at all, so read it before
filing a bug about an empty tree.

**A HAR cannot declare permissions for its host.** `requestPermissions` in a library's
`module.json5` is not merged into the consuming app, so your own HAP has to declare every
permission below.

### Reading the pre-authorized user directories

`Environment.getUserDocumentDir()` and its siblings return a path without any permission. That is
not the same as being allowed to read it: `fileIo.listFile()` on that path fails with **13900001
`Operation not permitted`** until the matching `user_grant` permission is declared *and* granted.

Declare in your HAP's `module.json5`:

```json5
"requestPermissions": [
  { "name": "ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY", "reason": "$string:reason_documents",
    "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" } },
  { "name": "ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY", "reason": "$string:reason_download",
    "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" } }
]
```

Then request them at runtime before the tree is built:

```ets
import { requestUserDirPermissions, UserDirPermissionResult } from 'file-tree-view';

const result: UserDirPermissionResult =
  await requestUserDirPermissions(this.getUIContext().getHostContext() as common.UIAbilityContext);
if (result.granted.length > 0) {
  // mount FileTreeView now
}
```

Mount the component only once access exists. `FileTreeView` reads its roots in `aboutToAppear`,
so a tree built before the grant lists nothing until the page is rebuilt.

`UserDirPermissionResult.unusable` separates the permissions no dialog can fix — undeclared, or
declared without the ACL the signature needs — from the ones the user merely refused. The two need
opposite handling: one is a build-configuration fix, the other is a retry button.

### Desktop, and other restricted permissions

`ohos.permission.READ_WRITE_DESKTOP_DIRECTORY` is `system_basic`, which makes it **restricted**. It
must appear in the `allowed-acls` of your provisioning profile or **installation is rejected**, not
the listing:

```
code:9568289 install failed due to grant request permissions failed.
PermissionName: ohos.permission.READ_WRITE_DESKTOP_DIRECTORY
```

The declaration has to exist *before* signing, because the signature generator reads
`requestPermissions` and requests the restricted permissions at that moment. Declare it, then
re-run *File → Project Structure → Signing Configs → Automatically generate signature*.

Use `ALL_USER_DIR_PERMISSIONS` once you have the ACL, `USER_DIR_PERMISSIONS` (Documents + Download,
both `normal` level) if you do not. Requesting the full set without the ACL is safe: Desktop comes
back in `unusable` and the other two are still prompted for.

### Folders the user picks

Where the pre-authorized directories are not enough, the user can grant a folder directly. This
needs no `user_grant` permission and shows no permission dialog — the pick *is* the grant.

```ets
import { isFolderSelectionSupported, pickFolders, PickedRoot } from 'file-tree-view';

if (isFolderSelectionSupported()) {
  const picked: PickedRoot[] = await pickFolders(context);
  for (const root of picked) {
    dataSource.addRoot(root.node);
  }
  this.rootsVersion++;          // makes the mounted tree re-read its roots
  await saveSomewhere(picked.map((p: PickedRoot) => p.uri));
}
```

Check `isFolderSelectionSupported()` first. It is false more often than the picker documentation
suggests — a device can carry `SystemCapability.FileManagement.UserFileService` without
`...UserFileService.FolderSelection`, so files can be picked there and folders cannot. There is no
useful fallback, because a file grant does not make its parent directory listable.

To keep a grant across restarts, declare `ohos.permission.FILE_ACCESS_PERSIST` (`normal`,
`system_grant` — no ACL, no review, no dialog), store the URIs yourself, and hand them back on the
next launch:

```ets
const restored: PickedRoot[] = await activatePersistedRoots(savedUris);
```

The library deliberately persists nothing of its own: a component that writes a preferences file
into its host's data directory is a surprise, and most apps already have somewhere they keep
settings. URIs that no longer activate are dropped from the result — treat "absent" as "stop
storing this one".

### Full disk

`ohos.permission.ACCESS_USER_FULL_DISK` (API 22+) exposes the whole user storage area as one root.
Before you reach for it:

- It is `system_basic`, i.e. restricted, so it needs the profile ACL. Declared without one, the app
  installs **nowhere** — a failed ACL request costs the whole build, not one feature.
- Its authorization mode is `manual_settings`: there is no runtime dialog at all.
  `requestPermissionsFromUser` will not help. `openFullDiskSetting()` takes the user to the
  Settings page instead.
- Supported devices are PC / 2-in-1 only. Elsewhere expect `PermissionStatus.INVALID`, which
  `canRequestFullDisk()` reports as false so you can hide the button.

```ets
if (canRequestFullDisk()) {
  await openFullDiskSetting(context);
}
// The grant lands while the user is in Settings, so re-check on foreground, not here.
if (hasFullDisk()) {
  const root: FileNode | undefined = fullDiskRoot();
  if (root !== undefined) { dataSource.addRoot(root); }
}
```

## API

### `FileTreeView`

| Property | Type | Description |
|---|---|---|
| `dataSource` | `FileTreeDataSource` | Where nodes come from. Defaults to `new DefaultFileTreeDataSource()`. |
| `config` | `FileTreeConfig` | Filtering, ordering and label overrides. |
| `rootsVersion` | `number` | Increment to make the tree re-read `getRoots()`. Open directories stay open. |
| `onFileSelected` | `(node: FileNode) => void` | A non-directory row was activated. |
| `onDirExpanded` | `(node: FileNode) => void` | A directory's children are on screen. |
| `onError` | `(err: Error) => void` | A listing failed. The tree stays usable. |

A callback that throws is caught and logged; it cannot take the tree down.

### Keyboard

Up / Down move the cursor, Right opens a folder or steps into an open one, Left closes it or steps
out to the parent, Enter or Space activates. Arrowing onto a file fires `onFileSelected`, because
the cursor is also the selection — debounce on your side if that is expensive.

### `FileTreeConfig`

```ets
interface FileTreeConfig {
  showHidden?: boolean;        // dot-files. Default false
  extWhitelist?: string[];     // ['key', 'pem'] — no dot, case-insensitive
  extBlacklist?: string[];     // takes precedence over extWhitelist
  sort?: FileTreeSort;         // 'name-asc' | 'name-desc' | 'size-asc' | ... Default 'name-asc'
  labels?: FileTreeLabels;     // text overrides
}
```

Directories are never removed by an extension rule — that would hide the whole subtree behind
them — and they always sort before files; `sort` only orders within a group.

The filtering and ordering fields are handed to `DefaultFileTreeDataSource`. A custom
`FileTreeDataSource` owns its own filtering, so with one of those they are ignored with a warning.
`labels` is read by the component itself and always applies.

### `FileTreeLabels`

The component's built-in text is English. Override whichever strings your app localises:

```ets
FileTreeView({
  config: {
    labels: {
      loading: 'Yükleniyor…',
      noRoots: 'Klasör yok.',
      emptyFolder: 'boş',
      rowLoading: '…'
    }
  }
})
```

### `FileNode`

```ets
interface FileNode {
  name: string;          // base name, never a path
  path: string;          // absolute sandbox path
  isDirectory: boolean;  // from Stat.isDirectory(), not from the name
  size?: number;         // bytes; files only
  mtime?: number;        // MILLISECONDS since the epoch, ready for new Date(...)
  uri?: string;          // set when access came from a picker grant
  loaded?: boolean;      // true once listChildren() has run for this node
  error?: string;        // set when the node could not be read; it is still listed
}
```

`Stat.mtime` is in seconds. `FileNode.mtime` is in milliseconds, converted in exactly one place, so
you can hand it straight to `Date`.

### `FileTreeDataSource`

Two methods, both returning **one level only** — that contract is what keeps the tree lazy.

```ets
interface FileTreeDataSource {
  getRoots(): Promise<FileNode[]>;
  listChildren(node: FileNode): Promise<FileNode[]>;
}
```

Implement it to back the tree with a remote host, an archive, or a test double. `FileTreeView`
never calls `fileIo` directly.

`getRoots()` must not reject because one root is unavailable; return the ones that worked.
`listChildren()` may reject if the directory itself cannot be listed, but an individual entry that
fails should come back as a node carrying `error` — one unreadable file must not blank out its
siblings.

### `DefaultFileTreeDataSource`

The device file system, one level at a time.

| Method | Description |
|---|---|
| `setConfig(config)` | Replace filtering/ordering. The caller re-lists to see the effect. |
| `addRoot(node)` | Add a root beyond the pre-authorized ones. Ignored if the path is already there. |
| `removeRoot(path)` | Drop a host-added root. Never touches the `Environment` roots. |
| `listExtraRoots()` | The host-added roots, as a copy. Useful for persisting them. |

Entries are `stat`ed in bounded batches, so a directory with tens of thousands of files does not
open one file descriptor per entry at once.

## Supported devices

`2in1` and `tablet`. PC / 2-in-1 is the primary target.

## License

Apache-2.0. See [LICENSE](LICENSE).
