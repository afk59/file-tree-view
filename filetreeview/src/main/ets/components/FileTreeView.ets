import { KeyCode } from '@kit.InputKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileNode, FileTreeConfig, FileTreeLabels } from '../model/FileNode';
import { FileTreeDataSource } from '../datasource/FileTreeDataSource';
import { DefaultFileTreeDataSource } from '../datasource/DefaultFileTreeDataSource';
import { formatSize } from '../util/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTreeView';

/** Horizontal offset added per tree level. */
const INDENT_PER_LEVEL: number = 16;
/** Width reserved for the expander, whether or not a row has one — keeps names aligned. */
const TWISTY_SIZE: number = 16;
const ICON_SIZE: number = 20;
const ROW_HEIGHT: number = 40;
const EXPANDED_ANGLE: number = 90;
const COLLAPSED_ANGLE: number = 0;
/** 10% of the ArkUI brand blue: a row highlight, not a selection block. */
const SELECTED_BG: string = '#1A0A59F7';
/** 5% black. Pointer feedback for the row under the cursor. */
const HOVERED_BG: string = '#0D000000';
const TRANSPARENT_BG: string = '#00000000';
/** No row is focused. */
const NO_INDEX: number = -1;
/** No row is hovered. Row ids start at 1, so 0 is outside the range. */
const NO_ID: number = 0;

const DEFAULT_LOADING: string = 'Loading…';
const DEFAULT_NO_ROOTS: string = 'No folders available.';
const DEFAULT_EMPTY_FOLDER: string = 'empty';
const DEFAULT_ROW_LOADING: string = '…';

/**
 * The host's label overrides merged over the defaults, so the render path never has to branch on
 * `undefined`. Built once in `aboutToAppear`.
 */
class ResolvedLabels {
  loading: string = DEFAULT_LOADING;
  noRoots: string = DEFAULT_NO_ROOTS;
  emptyFolder: string = DEFAULT_EMPTY_FOLDER;
  rowLoading: string = DEFAULT_ROW_LOADING;

  constructor(overrides?: FileTreeLabels) {
    if (overrides !== undefined) {
      this.loading = overrides.loading ?? this.loading;
      this.noRoots = overrides.noRoots ?? this.noRoots;
      this.emptyFolder = overrides.emptyFolder ?? this.emptyFolder;
      this.rowLoading = overrides.rowLoading ?? this.rowLoading;
    }
  }
}

/**
 * Monotonic row id.
 *
 * `ForEach` keys cannot be built from the path alone: a picked folder added with `addRoot()` may
 * sit inside one of the pre-authorized roots, which puts the same path in the tree twice. So
 * every row gets an identity of its own.
 */
let nextRowId: number = 1;

/**
 * One row of the flattened tree: a `FileNode` plus the display state the model does not carry.
 *
 * A plain class, not `@Observed`: every change goes through `refresh()`, which rebuilds the
 * visible array and re-keys the rows, so there is only one update path.
 */
class TreeRow {
  readonly id: number;
  readonly node: FileNode;
  readonly depth: number;
  expanded: boolean = false;
  loading: boolean = false;
  /** Children once listed. `undefined` means never listed, which is not the same as empty. */
  children?: TreeRow[];

  constructor(node: FileNode, depth: number) {
    this.id = nextRowId;
    nextRowId++;
    this.node = node;
    this.depth = depth;
  }
}

/**
 * A lazy-loading, file-system-backed tree panel.
 *
 * ```ets
 * FileTreeView({
 *   dataSource: new DefaultFileTreeDataSource({ showHidden: false }),
 *   onFileSelected: (node: FileNode) => { this.selected = node; }
 * })
 * ```
 *
 * Roots are listed on `aboutToAppear`. A directory's children are fetched the first time it is
 * expanded and never again — `TreeRow.children` is the memo. Nothing recurses, and nothing is
 * fetched speculatively.
 *
 * The tree is a flat adapter (node + depth + expanded) over a plain `List` rather than the
 * `@kit.ArkUI` TreeView, which expects a tree that is fully known before it is built:
 * `TreeController.buildDone()` is a full rebuild, so publishing newly listed children collapses
 * every open directory and clears the selection; skipping it renders the new nodes in TreeView's
 * uncommitted editing state; and its expander arrow tracks children-present rather than
 * `isFolder`, so an unexplored folder is drawn exactly like a file. Owning the row means the
 * arrow appears on every directory from the moment it is created.
 */
@Component
export struct FileTreeView {
  /**
   * Where nodes come from. Defaults to the device file system, so the component works with no
   * arguments; pass your own to back it with something else.
   */
  dataSource: FileTreeDataSource = new DefaultFileTreeDataSource();
  /**
   * Filtering, ordering and label overrides.
   *
   * The filtering and ordering fields are handed to `DefaultFileTreeDataSource`; a custom
   * `FileTreeDataSource` owns its own filtering, so with one of those they are ignored with a
   * warning. `labels` is read by this component and always applies.
   */
  config?: FileTreeConfig;
  /** Fired when a non-directory row is clicked. */
  onFileSelected?: (node: FileNode) => void;
  /** Fired after a directory has been expanded and its children are on screen. */
  onDirExpanded?: (node: FileNode) => void;
  /** Fired when a listing fails. The tree stays usable; the directory can be clicked again. */
  onError?: (err: Error) => void;
  /**
   * Bump this to make the tree re-read `dataSource.getRoots()`.
   *
   * A parent cannot call a method on a child `@Component`, so a watched counter is the handle: a
   * host that has just called `addRoot()` increments this and the new root appears. Open
   * directories stay open — a root whose path is unchanged keeps its existing row, with its
   * children and expansion intact, and only genuinely new roots are built fresh.
   */
  @Prop @Watch('onRootsVersionChanged') rootsVersion: number = 0;

  /** The flattened, currently visible rows. Rebuilt by `refresh()`; never mutated in place. */
  @State private rows: TreeRow[] = [];
  /** Path of the highlighted row. Path, not id — it survives a rebuild. */
  @State private selectedPath: string = '';
  /** True until `getRoots()` has come back, so an empty tree is not read as "no files". */
  @State private loadingRoots: boolean = true;
  /**
   * Index into `rows` of the keyboard cursor, or -1. An index rather than a path, because every
   * arrow key is a move to the row above or below. Re-derived after any structural change so a
   * collapse cannot leave it pointing at a row that no longer exists.
   */
  @State private focusedIndex: number = NO_INDEX;
  /** Row id under the pointer. Pointer devices only; touch never sets it. */
  @State private hoveredId: number = NO_ID;

  private roots: TreeRow[] = [];
  /** Needed to keep the keyboard cursor on screen; `List` cannot scroll itself to an index. */
  private listScroller: Scroller = new Scroller();
  /** Resolved in `aboutToAppear` from `config.labels`. */
  private labels: ResolvedLabels = new ResolvedLabels();

  onRootsVersionChanged(): void {
    this.loadRoots();
  }

  aboutToAppear(): void {
    if (this.config !== undefined) {
      this.labels = new ResolvedLabels(this.config.labels);
      if (this.dataSource instanceof DefaultFileTreeDataSource) {
        (this.dataSource as DefaultFileTreeDataSource).setConfig(this.config);
      } else if (FileTreeView.hasSourceOptions(this.config)) {
        hilog.warn(DOMAIN, TAG,
          'Filtering and ordering options were supplied but dataSource is not a ' +
          'DefaultFileTreeDataSource; ignoring them. Label overrides still apply.');
      }
    }
    this.loadRoots();
  }

  /** True when `config` carries options only `DefaultFileTreeDataSource` can act on. */
  private static hasSourceOptions(config: FileTreeConfig): boolean {
    return config.showHidden !== undefined || config.extWhitelist !== undefined ||
      config.extBlacklist !== undefined || config.sort !== undefined;
  }

  /** Seed the tree with the roots. Never throws — `getRoots()` degrades per root by contract. */
  private async loadRoots(): Promise<void> {
    try {
      const roots: FileNode[] = await this.dataSource.getRoots();
      if (roots.length === 0) {
        hilog.warn(DOMAIN, TAG,
          'No roots. Either the Environment capability is missing, or nothing has been added.');
      }
      // Reuse the row for any root we already had, so a reload does not collapse the tree.
      const byPath: Map<string, TreeRow> = new Map<string, TreeRow>();
      for (const existing of this.roots) {
        byPath.set(existing.node.path, existing);
      }
      this.roots = roots.map((node: FileNode) => {
        const kept: TreeRow | undefined = byPath.get(node.path);
        return kept !== undefined ? kept : new TreeRow(node, 0);
      });
      hilog.info(DOMAIN, TAG, 'Roots: %{public}d.', roots.length);
    } catch (e) {
      this.reportError(e, 'loading roots');
    } finally {
      this.loadingRoots = false;
      this.refresh();
    }
  }

  /**
   * Recompute the visible rows. The only place `this.rows` is assigned, and the only thing that
   * makes the UI redraw — a new array, since mutating the old one in place would not.
   */
  private refresh(): void {
    const visible: TreeRow[] = [];
    FileTreeView.flatten(this.roots, visible);
    this.rows = visible;
    // A collapse removes rows, so an index taken before it can now point past the end or at an
    // unrelated row. Re-derive from the selected path, which survives a rebuild.
    if (this.focusedIndex !== NO_INDEX) {
      this.focusedIndex = visible.findIndex((row: TreeRow) => row.node.path === this.selectedPath);
    }
  }

  /** Depth-first walk of the open parts of the tree. Collapsed subtrees are skipped whole. */
  private static flatten(rows: TreeRow[], out: TreeRow[]): void {
    for (const row of rows) {
      out.push(row);
      if (row.expanded && row.children !== undefined) {
        FileTreeView.flatten(row.children, out);
      }
    }
  }

  private handleRowClick(row: TreeRow, index: number): void {
    this.selectedPath = row.node.path;
    // Clicking also places the keyboard cursor, otherwise the first arrow key after a click
    // would jump somewhere unrelated.
    this.focusedIndex = index;
    if (!row.node.isDirectory) {
      // Refresh first: the highlight must move even if the host's handler throws.
      this.refresh();
      this.emitFileSelected(row.node);
      return;
    }
    if (row.expanded) {
      row.expanded = false;
      this.refresh();
      return;
    }
    row.expanded = true;
    if (row.children !== undefined) {
      // Already listed once. Reopening must not touch the file system again.
      this.refresh();
      this.emitDirExpanded(row.node);
      return;
    }
    this.loadChildren(row);
  }

  /** List a directory once, and show the outcome — children, or the reason there are none. */
  private async loadChildren(row: TreeRow): Promise<void> {
    if (row.loading) {
      return;
    }
    row.loading = true;
    this.refresh();
    let expanded: boolean = false;
    try {
      const children: FileNode[] = await this.dataSource.listChildren(row.node);
      row.children = children.map((child: FileNode) => new TreeRow(child, row.depth + 1));
      row.node.loaded = true;
      hilog.info(DOMAIN, TAG, 'Listed %{public}s: %{public}d children.', row.node.name, children.length);
      expanded = true;
    } catch (e) {
      // Collapse again and leave `children` undefined, so the next click is a real retry once
      // the cause is gone (a permission granted, a device remounted).
      row.expanded = false;
      this.reportError(e, `expanding "${row.node.name}"`);
    } finally {
      row.loading = false;
      this.refresh();
    }
    // Outside the try: a host callback that throws must not be mistaken for a listing failure,
    // which would collapse the row it just filled.
    if (expanded) {
      this.emitDirExpanded(row.node);
    }
  }

  /** Trailing text: the failure reason if there is one, a file's size otherwise. */
  private trailingOf(row: TreeRow): string {
    if (row.loading) {
      return this.labels.rowLoading;
    }
    if (row.node.error !== undefined) {
      return row.node.error;
    }
    if (!row.node.isDirectory && row.node.size !== undefined) {
      return formatSize(row.node.size);
    }
    if (row.node.isDirectory && row.children !== undefined && row.children.length === 0) {
      // An empty directory and an unreadable one look identical without this.
      return this.labels.emptyFolder;
    }
    return '';
  }

  /** Selection wins over hover; a hovered row that is already selected must not get lighter. */
  private static rowBackground(selected: boolean, hovered: boolean): string {
    if (selected) {
      return SELECTED_BG;
    }
    return hovered ? HOVERED_BG : TRANSPARENT_BG;
  }

  /**
   * Row identity for `ForEach`. The mutable display state is part of the key on purpose:
   * `ForEach` reuses an item whose key is unchanged, so a key of just `path` would leave a row's
   * arrow pointing the wrong way after it was expanded.
   */
  private static keyOf(row: TreeRow): string {
    const loaded: string = row.children === undefined ? 'u' : `${row.children.length}`;
    return `${row.id}|${row.expanded}|${row.loading}|${loaded}`;
  }

  /**
   * Keyboard navigation. Up/Down move the cursor, Right opens a folder or steps into an open
   * one, Left closes it or steps out to the parent, Enter/Space activates.
   *
   * Only `KeyType.Down` is handled; acting on both edges would fire every action twice.
   */
  private handleKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) {
      return;
    }
    const code: number = event.keyCode;
    if (code === KeyCode.KEYCODE_DPAD_DOWN) {
      this.moveFocus(1);
    } else if (code === KeyCode.KEYCODE_DPAD_UP) {
      this.moveFocus(-1);
    } else if (code === KeyCode.KEYCODE_DPAD_RIGHT) {
      this.openFocused();
    } else if (code === KeyCode.KEYCODE_DPAD_LEFT) {
      this.closeFocused();
    } else if (code === KeyCode.KEYCODE_ENTER || code === KeyCode.KEYCODE_NUMPAD_ENTER ||
      code === KeyCode.KEYCODE_SPACE) {
      const row: TreeRow | undefined = this.focusedRow();
      if (row !== undefined) {
        this.handleRowClick(row, this.focusedIndex);
      }
    }
  }

  private focusedRow(): TreeRow | undefined {
    if (this.focusedIndex < 0 || this.focusedIndex >= this.rows.length) {
      return undefined;
    }
    return this.rows[this.focusedIndex];
  }

  /** Move the cursor by `delta`, clamped, and keep it on screen. */
  private moveFocus(delta: number): void {
    if (this.rows.length === 0) {
      return;
    }
    // A first keypress with no cursor lands on the top row rather than nowhere.
    const from: number = this.focusedIndex < 0 ? (delta > 0 ? -1 : 0) : this.focusedIndex;
    let next: number = from + delta;
    if (next < 0) {
      next = 0;
    }
    if (next > this.rows.length - 1) {
      next = this.rows.length - 1;
    }
    this.setFocus(next);
  }

  /**
   * Move the cursor to `index`, highlight that row, and notify the host.
   *
   * `onFileSelected` fires here because the cursor sets `selectedPath`, which is what draws the
   * row as selected; staying silent would leave a row looking selected while the host still
   * showed the previous file. Arrowing through a directory therefore fires the callback once per
   * file, and hosts that find it expensive should debounce.
   *
   * Directories are not announced: focus is not expansion, and `onDirExpanded` means the
   * children are on screen.
   */
  private setFocus(index: number): void {
    this.focusedIndex = index;
    const row: TreeRow | undefined = this.focusedRow();
    if (row === undefined) {
      return;
    }
    this.selectedPath = row.node.path;
    this.listScroller.scrollToIndex(index);
    if (!row.node.isDirectory) {
      this.emitFileSelected(row.node);
    }
  }

  /** Right arrow: open a closed folder, or step into an open one. */
  private openFocused(): void {
    const row: TreeRow | undefined = this.focusedRow();
    if (row === undefined || !row.node.isDirectory) {
      return;
    }
    if (!row.expanded) {
      this.handleRowClick(row, this.focusedIndex);
      return;
    }
    if (row.children !== undefined && row.children.length > 0) {
      // The first child is always the next visible row, because `flatten` is depth-first.
      this.moveFocus(1);
    }
  }

  /** Left arrow: close an open folder, or step out to the parent. */
  private closeFocused(): void {
    const row: TreeRow | undefined = this.focusedRow();
    if (row === undefined) {
      return;
    }
    if (row.node.isDirectory && row.expanded) {
      row.expanded = false;
      this.refresh();
      return;
    }
    // Walk back to the nearest shallower row — that is this row's parent by construction.
    for (let i: number = this.focusedIndex - 1; i >= 0; i--) {
      if (this.rows[i].depth < row.depth) {
        this.setFocus(i);
        return;
      }
    }
  }

  private reportError(e: Object, whileDoing: string): void {
    const err: Error = e instanceof Error ? e as Error : new Error(`${e}`);
    hilog.error(DOMAIN, TAG, 'Failed while %{public}s: %{public}s', whileDoing, err.message);
    this.emit('onError', () => {
      if (this.onError !== undefined) {
        this.onError(err);
      }
    });
  }

  private emitFileSelected(node: FileNode): void {
    this.emit('onFileSelected', () => {
      if (this.onFileSelected !== undefined) {
        this.onFileSelected(node);
      }
    });
  }

  private emitDirExpanded(node: FileNode): void {
    this.emit('onDirExpanded', () => {
      if (this.onDirExpanded !== undefined) {
        this.onDirExpanded(node);
      }
    });
  }

  /**
   * Run a host callback without letting it take the tree down. These are arbitrary functions
   * from another codebase: a throw from inside a click handler would abort the handler
   * mid-update, and from inside an `async` method it would surface as an unhandled rejection.
   */
  private emit(name: string, call: () => void): void {
    try {
      call();
    } catch (e) {
      const err: Error = e instanceof Error ? e as Error : new Error(`${e}`);
      hilog.error(DOMAIN, TAG, 'Host %{public}s callback threw: %{public}s', name, err.message);
    }
  }

  build() {
    Column() {
      if (this.loadingRoots) {
        Text(this.labels.loading).fontSize(13).fontColor(Color.Gray).padding(12)
      } else if (this.rows.length === 0) {
        Text(this.labels.noRoots).fontSize(13).fontColor(Color.Gray).padding(12)
      } else {
        List({ scroller: this.listScroller }) {
          ForEach(this.rows, (row: TreeRow, index: number) => {
            ListItem() {
              this.NodeRow(row, index)
            }
          }, (row: TreeRow) => FileTreeView.keyOf(row))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        // The list takes focus, not the rows: one key handler for the whole tree is far less
        // state than a focus ring per row, and it is what makes Up/Down mean previous/next row
        // rather than previous/next focusable widget.
        .focusable(true)
        .defaultFocus(true)
        .onKeyEvent((event: KeyEvent) => {
          this.handleKey(event);
        })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** One file or directory row: indent, expander, icon, name, trailing detail. */
  @Builder
  NodeRow(row: TreeRow, index: number) {
    Row({ space: 6 }) {
      // The expander is drawn from `isDirectory`, so a directory has one from the moment it
      // appears, whether or not its children have been fetched.
      if (row.node.isDirectory) {
        Image($r('sys.media.ohos_ic_public_arrow_right'))
          .width(TWISTY_SIZE)
          .height(TWISTY_SIZE)
          .opacity(row.loading ? 0.3 : 0.6)
          .rotate({ angle: row.expanded ? EXPANDED_ANGLE : COLLAPSED_ANGLE })
      } else {
        // Reserve the same width so file names line up with directory names.
        Row().width(TWISTY_SIZE).height(TWISTY_SIZE)
      }

      Image(row.node.isDirectory
        ? $r('sys.media.ohos_ic_normal_white_grid_folder')
        : $r('sys.media.ohos_ic_normal_white_grid_doc'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)

      Text(row.node.name)
        .fontSize(14)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(this.trailingOf(row))
        .fontSize(11)
        .fontColor(Color.Gray)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '45%' })
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .padding({ left: 8 + row.depth * INDENT_PER_LEVEL, right: 8 })
    .borderRadius(8)
    .backgroundColor(FileTreeView.rowBackground(
      this.selectedPath === row.node.path, this.hoveredId === row.id))
    .onHover((isHover: boolean) => {
      // Clearing by id rather than unconditionally avoids a stale highlight when the pointer
      // leaves one row by entering the next.
      if (isHover) {
        this.hoveredId = row.id;
      } else if (this.hoveredId === row.id) {
        this.hoveredId = NO_ID;
      }
    })
    .onClick(() => {
      this.handleRowClick(row, index);
    })
  }
}
