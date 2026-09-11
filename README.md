# FileTreeView

A lazy-loading file tree for HarmonyOS NEXT, bound to the real device file system.

[![ohpm](https://img.shields.io/badge/ohpm-file--tree--view-blue)](https://ohpm.openharmony.cn/#/en/detail/file-tree-view)

```bash
ohpm i file-tree-view
```

This repository holds the published library and a demo app that consumes it.

| Module | What it is |
|---|---|
| [`filetreeview/`](filetreeview) | The reusable HAR library — the component itself. Published to OHPM as `file-tree-view`. |
| [`entry/`](entry) | A demo app: a tree panel on the left, file details on the right, plus the buttons that exercise every access route. |

**The full API and permission documentation lives in
[`filetreeview/README.md`](filetreeview/README.md)** ([中文](filetreeview/readme_cn.md)). Read the
permission section before anything else — it is what decides whether the tree shows content at all.

## What it does

`FileTreeView` renders the user's storage as an expandable tree panel. A directory's children are
read the first time it is expanded and never again, so the component stays responsive on deep trees
and never walks the file system speculatively. It targets the PC / 2-in-1 form factor — pointer
hover, keyboard navigation, a persistent side panel — and works on tablets with whatever storage
access that device grants.

- No third-party runtime dependencies. System kits only.
- Every directory shows an expander arrow from the moment it appears, whether or not its children
  have been read.
- Pluggable data layer: implement a two-method interface to back the tree with something other than
  the device file system.
- Ships the permission and picker helpers the file system actually requires, including the
  restricted-permission cases that fail at install time rather than at runtime.

## Building

Open the project in DevEco Studio, or from the command line:

```bash
ohpm install

# the library
hvigorw --mode module -p product=default -p buildMode=release assembleHar

# the demo app
hvigorw --mode module -p product=default -p buildMode=debug assembleHap
```

The HAR lands in `filetreeview/build/default/outputs/default/`.

### Running the demo

`build-profile.json5` ships with `"signingConfigs": []`, so building a HAP works but installing one
does not. Create a debug signature first — *File → Project Structure → Signing Configs →
Automatically generate signature* — which also requests the restricted permission
`ohos.permission.READ_WRITE_DESKTOP_DIRECTORY` from AGC while signing. Without that ACL the install
is rejected outright with `code:9568289`, not merely the Desktop listing.

Then:

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

## Requirements

- HarmonyOS NEXT, API 24 (compatible/target SDK `6.1.1(24)`).
- Device types: `2in1`, `tablet`. PC / 2-in-1 is the primary target.

## License

Apache-2.0. See [LICENSE](LICENSE).
