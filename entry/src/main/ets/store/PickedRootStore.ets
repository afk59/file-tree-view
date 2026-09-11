import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTreeDemo';

const STORE_NAME: string = 'filetree_roots';
const KEY_URIS: string = 'picked_uris';
const EMPTY_JSON_ARRAY: string = '[]';

/**
 * Remembers the URIs of folders the user picked, so they can be re-activated next launch.
 *
 * This lives in the app rather than in `filetreeview`, which deliberately persists nothing: a
 * library that creates a preferences file inside its host's data directory is a surprise, and
 * most apps already have somewhere they keep settings. The library hands back URIs
 * (`pickFolders` → `PickedRoot.uri`) and takes them again on the next launch
 * (`activatePersistedRoots`); where they live in between is the app's choice. This class is one
 * answer, not the only one.
 *
 * The stored value is a JSON array of URI strings under a single key.
 */
export class PickedRootStore {
  private context: common.UIAbilityContext;
  private store?: preferences.Preferences;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** The saved URIs, oldest first. Returns `[]` on failure — this is a cache, not a source. */
  async load(): Promise<string[]> {
    try {
      const store: preferences.Preferences = await this.open();
      const raw: string = store.getSync(KEY_URIS, EMPTY_JSON_ARRAY) as string;
      const parsed: string[] = JSON.parse(raw) as string[];
      return parsed;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'Reading saved roots failed. Code: %{public}d, message: %{public}s',
        err.code, err.message);
      return [];
    }
  }

  /**
   * Replace the saved list.
   *
   * Callers pass the URIs that are currently valid, so a grant that failed to re-activate stops
   * being retried on every launch. Hence a whole-list write rather than an append.
   */
  async save(uris: string[]): Promise<void> {
    try {
      const store: preferences.Preferences = await this.open();
      store.putSync(KEY_URIS, JSON.stringify(uris));
      await store.flush();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'Saving roots failed. Code: %{public}d, message: %{public}s',
        err.code, err.message);
    }
  }

  /**
   * Open the store once and remember it. `getPreferences` is declared as throwing, and ArkTS
   * wants that handled at the call site; rethrowing with the store name attached beats a bare
   * 15500000.
   */
  private async open(): Promise<preferences.Preferences> {
    const cached: preferences.Preferences | undefined = this.store;
    if (cached !== undefined) {
      return cached;
    }
    try {
      const opened: preferences.Preferences =
        await preferences.getPreferences(this.context, STORE_NAME);
      this.store = opened;
      return opened;
    } catch (e) {
      const err = e as BusinessError;
      throw new Error(`Cannot open the "${STORE_NAME}" store (code ${err.code}): ${err.message}`);
    }
  }
}
