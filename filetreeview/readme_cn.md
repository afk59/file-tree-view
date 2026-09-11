# @afk35/filetreeview

鸿蒙 NEXT 的懒加载文件树组件，直接绑定设备真实文件系统。

源码：https://github.com/afk59/file-tree-view

`FileTreeView` 把用户存储渲染成可展开的树形面板。目录的子项只在第一次展开时读取，之后不再重复读取，
因此在层级很深的目录下依然流畅，也不会提前遍历文件系统。它面向 PC / 2in1 形态设计——指针悬停、键盘导航、
常驻侧边面板——在平板上也能使用该设备所允许的存储访问能力。

- 无第三方运行时依赖，只使用系统 Kit：`@kit.ArkUI`、`@kit.CoreFileKit`、`@kit.AbilityKit`、
  `@kit.InputKit`、`@kit.BasicServicesKit`、`@kit.PerformanceAnalysisKit`。
- 目录从出现的那一刻就带展开箭头，无论其子项是否已经读取。
- 数据层可替换：实现一个只有两个方法的接口，就能用设备文件系统以外的数据源。
- 附带文件系统实际需要的权限与选择器辅助函数，包括那些在安装阶段而非运行阶段失败的受限权限场景。

## 安装

```bash
ohpm i @afk35/filetreeview
```

## 快速开始

```ets
import { FileTreeView, FileNode } from '@afk35/filetreeview';

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

不传任何参数时，组件读取设备文件系统并列出预授权的用户目录。但仅此还不够——请先阅读下面的**权限**一节，
否则树只会显示 `No folders available.`。

## 权限

这一节决定组件到底能不能显示内容，在提交「树是空的」这类问题之前请先读完。

**HAR 无法替宿主声明权限。** 库的 `module.json5` 中的 `requestPermissions` 不会合并进使用它的应用，
因此下面所有权限都必须由你自己的 HAP 声明。

### 读取预授权的用户目录

`Environment.getUserDocumentDir()` 及其同类函数不需要任何权限就能返回路径。但这不等于允许读取：
在该路径上调用 `fileIo.listFile()` 会一直失败并返回 **13900001 `Operation not permitted`**，
直到对应的 `user_grant` 权限被声明**并且**被授予。

在你的 HAP 的 `module.json5` 中声明：

```json5
"requestPermissions": [
  { "name": "ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY", "reason": "$string:reason_documents",
    "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" } },
  { "name": "ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY", "reason": "$string:reason_download",
    "usedScene": { "abilities": ["EntryAbility"], "when": "inuse" } }
]
```

然后在构建树之前于运行时申请：

```ets
import { requestUserDirPermissions, UserDirPermissionResult } from '@afk35/filetreeview';

const result: UserDirPermissionResult =
  await requestUserDirPermissions(this.getUIContext().getHostContext() as common.UIAbilityContext);
if (result.granted.length > 0) {
  // 此时再挂载 FileTreeView
}
```

请在拿到访问权限之后再挂载组件。`FileTreeView` 在 `aboutToAppear` 中读取根节点，
在授权之前构建的树会一直是空的，直到页面被重建。

`UserDirPermissionResult.unusable` 把「任何弹窗都无法解决」的权限——未声明，或已声明但签名缺少 ACL——
与用户单纯拒绝的权限区分开。两者的处理方式相反：前者要改构建配置，后者给一个重试按钮即可。

### Desktop 及其他受限权限

`ohos.permission.READ_WRITE_DESKTOP_DIRECTORY` 是 `system_basic` 级别，属于**受限权限**。
它必须出现在你的 profile 的 `allowed-acls` 中，否则**安装会直接被拒绝**，而不是列目录失败：

```
code:9568289 install failed due to grant request permissions failed.
PermissionName: ohos.permission.READ_WRITE_DESKTOP_DIRECTORY
```

声明必须在签名**之前**就存在，因为签名生成器会读取 `requestPermissions` 并在那一刻申请受限权限。
先声明，然后重新执行 *File → Project Structure → Signing Configs → Automatically generate signature*。

拿到 ACL 之后使用 `ALL_USER_DIR_PERMISSIONS`；没有 ACL 时使用 `USER_DIR_PERMISSIONS`
（Documents + Download，均为 `normal` 级别）。没有 ACL 时申请完整集合也是安全的：
Desktop 会出现在 `unusable` 中，另外两个照常弹窗。

### 用户选择的文件夹

当预授权目录不够用时，用户可以直接授权某个文件夹。这不需要 `user_grant` 权限，也不会弹出权限对话框——
用户的选择本身就是授权。

```ets
import { isFolderSelectionSupported, pickFolders, PickedRoot } from '@afk35/filetreeview';

if (isFolderSelectionSupported()) {
  const picked: PickedRoot[] = await pickFolders(context);
  for (const root of picked) {
    dataSource.addRoot(root.node);
  }
  this.rootsVersion++;          // 让已挂载的树重新读取根节点
  await saveSomewhere(picked.map((p: PickedRoot) => p.uri));
}
```

请先调用 `isFolderSelectionSupported()`。它返回 false 的情况比选择器文档所暗示的更常见——
设备可能带有 `SystemCapability.FileManagement.UserFileService` 却没有
`...UserFileService.FolderSelection`，即能选文件却不能选文件夹。这种情况没有可用的降级方案，
因为对文件的授权并不会让它的父目录变得可列举。

若要让授权在重启后依然有效，请声明 `ohos.permission.FILE_ACCESS_PERSIST`
（`normal`、`system_grant`——无需 ACL、无需审核、无弹窗），自行保存这些 URI，并在下次启动时交回：

```ets
const restored: PickedRoot[] = await activatePersistedRoots(savedUris);
```

本库刻意不做任何持久化：一个在宿主数据目录里偷偷写 preferences 文件的组件是个意外，
而且大多数应用本来就有存放设置的地方。无法再激活的 URI 会从结果中被剔除——
把「结果里没有」当作「不要再保存这个 URI」。

### 全盘访问

`ohos.permission.ACCESS_USER_FULL_DISK`（API 22+）把整个用户存储区域暴露为一个根节点。
在使用它之前请注意：

- 它是 `system_basic`，即受限权限，需要 profile ACL。没有 ACL 就声明它，应用将**无处可装**——
  一次失败的 ACL 申请代价是整个构建，而不是一个功能。
- 它的授权方式是 `manual_settings`：完全没有运行时弹窗，`requestPermissionsFromUser` 也无济于事。
  请改用 `openFullDiskSetting()` 把用户带到设置页。
- 支持的设备只有 PC / 2in1。其他设备上应预期 `PermissionStatus.INVALID`，
  `canRequestFullDisk()` 会返回 false，方便你隐藏按钮。

```ets
if (canRequestFullDisk()) {
  await openFullDiskSetting(context);
}
// 授权是在用户停留在设置页时生效的，所以要在回到前台时重新检查，而不是在这里。
if (hasFullDisk()) {
  const root: FileNode | undefined = fullDiskRoot();
  if (root !== undefined) { dataSource.addRoot(root); }
}
```

## API

### `FileTreeView`

| 属性 | 类型 | 说明 |
|---|---|---|
| `dataSource` | `FileTreeDataSource` | 节点来源。默认为 `new DefaultFileTreeDataSource()`。 |
| `config` | `FileTreeConfig` | 过滤、排序与文案覆盖。 |
| `rootsVersion` | `number` | 自增以让树重新读取 `getRoots()`。已展开的目录保持展开。 |
| `onFileSelected` | `(node: FileNode) => void` | 非目录行被激活。 |
| `onDirExpanded` | `(node: FileNode) => void` | 某个目录的子项已显示在界面上。 |
| `onError` | `(err: Error) => void` | 某次列目录失败。树仍然可用。 |

回调抛出的异常会被捕获并记录日志，不会让树崩溃。

### 键盘

上 / 下移动光标，右键展开目录或进入已展开的目录，左键收起目录或回到父级，Enter 或空格激活。
用方向键移动到文件上会触发 `onFileSelected`，因为光标同时就是选中项——如果这个回调开销较大，请自行做防抖。

### `FileTreeConfig`

```ets
interface FileTreeConfig {
  showHidden?: boolean;        // 是否显示点文件。默认 false
  extWhitelist?: string[];     // ['key', 'pem'] —— 不带点，不区分大小写
  extBlacklist?: string[];     // 优先级高于 extWhitelist
  sort?: FileTreeSort;         // 'name-asc' | 'name-desc' | 'size-asc' | ... 默认 'name-asc'
  labels?: FileTreeLabels;     // 文案覆盖
}
```

扩展名规则永远不会过滤掉目录——那会把整棵子树藏起来——并且目录始终排在文件之前；
`sort` 只在同一组内排序。

过滤与排序字段会交给 `DefaultFileTreeDataSource`。自定义的 `FileTreeDataSource` 自行负责过滤，
因此在使用自定义数据源时这些字段会被忽略并输出一条警告。`labels` 由组件自身读取，始终生效。

### `FileTreeLabels`

组件内置文案为英文。可以只覆盖你需要本地化的字符串：

```ets
FileTreeView({
  config: {
    labels: {
      loading: '加载中…',
      noRoots: '没有可用的文件夹。',
      emptyFolder: '空',
      rowLoading: '…'
    }
  }
})
```

### `FileNode`

```ets
interface FileNode {
  name: string;          // 基础名称，绝不是路径
  path: string;          // 绝对沙箱路径
  isDirectory: boolean;  // 来自 Stat.isDirectory()，而不是根据名称推断
  size?: number;         // 字节数；仅文件有效
  mtime?: number;        // 自纪元起的**毫秒**数，可直接传给 new Date(...)
  uri?: string;          // 当访问权限来自选择器授权时才有值
  loaded?: boolean;      // 该节点执行过 listChildren() 后为 true
  error?: string;        // 节点读取失败时设置；该节点仍会被列出
}
```

`Stat.mtime` 的单位是秒，`FileNode.mtime` 的单位是毫秒，转换只在一处完成，因此可以直接交给 `Date`。

### `FileTreeDataSource`

两个方法，都只返回**一层**——正是这个约定让树保持懒加载。

```ets
interface FileTreeDataSource {
  getRoots(): Promise<FileNode[]>;
  listChildren(node: FileNode): Promise<FileNode[]>;
}
```

实现它即可用远程主机、压缩包或测试替身作为数据源。`FileTreeView` 从不直接调用 `fileIo`。

`getRoots()` 不应因为某一个根不可用就 reject，而应返回可用的那些。
`listChildren()` 在目录本身无法列举时可以 reject，但单个失败的条目应作为带 `error` 的节点返回——
一个无法读取的文件不该让它的兄弟节点全部消失。

### `DefaultFileTreeDataSource`

设备文件系统，一次一层。

| 方法 | 说明 |
|---|---|
| `setConfig(config)` | 替换过滤/排序配置。调用方需重新列目录才能看到效果。 |
| `addRoot(node)` | 在预授权目录之外添加根节点。路径已存在时忽略。 |
| `removeRoot(path)` | 移除宿主添加的根节点。绝不会动 `Environment` 的根节点。 |
| `listExtraRoots()` | 返回宿主添加的根节点副本，便于持久化。 |

条目的 `stat` 调用是分批进行的，因此即使目录下有几万个文件，也不会同时打开同样数量的文件描述符。

## 支持设备

`2in1` 与 `tablet`，其中 PC / 2in1 是主要目标形态。

## 许可证

Apache-2.0，详见 [LICENSE](LICENSE)。
