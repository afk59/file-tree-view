import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { Environment, fileShare, fileUri, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileNode } from '../model/FileNode';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTreeView';

/** Read-only is all this component needs. `OperationMode.READ_MODE` is `0b1`. */
const READ_ONLY_MODE: number = fileShare.OperationMode.READ_MODE;

/** The syscap behind `fileShare.persistPermission` / `activatePermission`. */
const FOLDER_AUTH_SYSCAP: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
/** The syscap behind `DocumentSelectMode.FOLDER`. Folder picking is not universal. */
const FOLDER_SELECT_SYSCAP: string = 'SystemCapability.FileManagement.UserFileService.FolderSelection';
/** The syscap behind the `Environment` getters. */
const ENVIRONMENT_SYSCAP: string = 'SystemCapability.FileManagement.File.Environment.FolderObtain';

/**
 * Full-disk access. Read the caveats before declaring it:
 *
 * - `system_basic`, i.e. restricted: it must be listed in the signing profile's `allowed-acls`
 *   or the app will not install (`code:9568289`). Declare it in `module.json5` first, then
 *   re-generate the signature so the restricted permission is requested during signing.
 * - Authorization mode is `manual_settings`: there is no runtime dialog and
 *   `requestPermissionsFromUser` will not help. The user turns it on in Settings.
 * - PC/2-in-1 only; supported devices do not include tablets or phones.
 * - Since API 22.
 */
export const FULL_DISK_PERMISSION: Permissions = 'ohos.permission.ACCESS_USER_FULL_DISK';

/** A folder the user granted access to, in both the forms a host needs. */
export interface PickedRoot {
  /**
   * The `file://` URI the picker returned. This is the value to persist — a plain path cannot be
   * re-activated on the next launch, only a URI can.
   */
  uri: string;
  /** The same folder as a tree root, ready for `DefaultFileTreeDataSource.addRoot()`. */
  node: FileNode;
}

/** Whether persistent folder grants work at all on this device. */
export function isFolderAuthorizationSupported(): boolean {
  return canIUse(FOLDER_AUTH_SYSCAP);
}

/**
 * Whether the user can be asked to pick a folder at all.
 *
 * Check this before offering an "add folder" affordance: where it is false, `pickFolders()` can
 * only fail. It is false more often than the picker docs suggest — a device can carry
 * `SystemCapability.FileManagement.UserFileService` without
 * `...UserFileService.FolderSelection`, so files can be picked there and folders cannot. Since a
 * file grant does not make its parent directory listable, there is no useful fallback.
 */
export function isFolderSelectionSupported(): boolean {
  return canIUse(FOLDER_SELECT_SYSCAP);
}

/**
 * Does the app currently hold full-disk access?
 *
 * Synchronous and silent. `false` covers every reason equally — not declared, not granted, wrong
 * device — because the only remedy for any of them is the user enabling it in Settings.
 */
export function hasFullDisk(): boolean {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    return atManager.getSelfPermissionStatus(FULL_DISK_PERMISSION) ===
      abilityAccessCtrl.PermissionStatus.GRANTED;
  } catch (e) {
    const err = e as BusinessError;
    hilog.warn(DOMAIN, TAG, 'Full-disk status unavailable. Code: %{public}d, message: %{public}s',
      err.code, err.message);
    return false;
  }
}

/**
 * Send the user to the Settings page where full-disk access is turned on.
 *
 * `ACCESS_USER_FULL_DISK` is a `manual_settings` permission, so `requestPermissionsFromUser`
 * cannot grant it and will not show a dialog. `openPermissionOnSetting` (API 22+) is the only
 * route.
 *
 * Returns true when the permission is already granted or the user agreed to go to Settings. The
 * grant itself lands later, so re-check `hasFullDisk()` when the app returns to the foreground
 * rather than immediately after this resolves.
 *
 * Throws nothing. `12100014` means the permission is not `manual_settings` and `12100001` means
 * it is not declared in `module.json5`; both are build faults, so they are logged.
 */
export async function openFullDiskSetting(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const result: abilityAccessCtrl.SelectedResult =
      await atManager.openPermissionOnSetting(context, FULL_DISK_PERMISSION);
    return result === abilityAccessCtrl.SelectedResult.GRANTED ||
      result === abilityAccessCtrl.SelectedResult.OPENED;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG,
      'openPermissionOnSetting failed. Code: %{public}d, message: %{public}s. 12100001 = not ' +
      'declared in module.json5; 12100014 = not a manual_settings permission.',
      err.code, err.message);
    return false;
  }
}

/**
 * Whether full disk is worth offering at all: declared, and not already granted.
 *
 * `INVALID` means the HAP never declared it, in which case a button pointing at Settings would
 * send the user somewhere with nothing to toggle.
 */
export function canRequestFullDisk(): boolean {
  try {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const status: abilityAccessCtrl.PermissionStatus =
      atManager.getSelfPermissionStatus(FULL_DISK_PERMISSION);
    return status !== abilityAccessCtrl.PermissionStatus.GRANTED &&
      status !== abilityAccessCtrl.PermissionStatus.INVALID;
  } catch (e) {
    return false;
  }
}

/**
 * The whole user storage area as one root — the parent of Documents / Download / Desktop.
 *
 * Only meaningful when `hasFullDisk()` is true; adding it without the permission produces a root
 * that fails 13900001 as soon as it is opened. Kept out of `getRoots()` so the data layer stays
 * free of permission logic.
 *
 * The path is derived as the parent of `getUserDocumentDir()` rather than hard-coded, since its
 * actual value is a platform detail.
 */
export function fullDiskRoot(label: string = 'All files'): FileNode | undefined {
  let documents: string = '';
  if (canIUse(ENVIRONMENT_SYSCAP)) {
    try {
      documents = Environment.getUserDocumentDir();
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Cannot derive the full-disk root. Code: %{public}d', err.code);
    }
  }
  const cut: number = documents.lastIndexOf('/');
  if (cut <= 0) {
    return undefined;
  }
  return { name: label, path: documents.substring(0, cut), isDirectory: true };
}

/**
 * Ask the user to pick one or more folders, and keep the grant across launches.
 *
 * This is the only way to widen access on a device where full disk is unavailable. It needs no
 * `user_grant` permission and shows no permission dialog: the user's pick is the grant.
 *
 * The returned `uri`s must be stored by the host and handed back to `activatePersistedRoots()`
 * on the next launch; persisting a grant and forgetting its URI leaves an access right nothing
 * can use. Resolves to `[]` when the user cancels.
 *
 * @param context the UIAbility context. From a page:
 *   `this.getUIContext().getHostContext() as common.UIAbilityContext`.
 */
export async function pickFolders(context: common.UIAbilityContext): Promise<PickedRoot[]> {
  // Built inside a positive `canIUse` block: `selectMode` and `DocumentSelectMode` are gated on
  // their own syscap, and the compiler only accepts the guard when the reference is lexically
  // inside the `if`.
  let options: picker.DocumentSelectOptions | undefined = undefined;
  if (canIUse(FOLDER_SELECT_SYSCAP)) {
    // Folders, not files. `DocumentSelectMode.FILE` is the default and would give us leaves.
    options = { selectMode: picker.DocumentSelectMode.FOLDER };
  }
  if (options === undefined) {
    // Hosts should have checked `isFolderSelectionSupported()` and not offered the action.
    hilog.warn(DOMAIN, TAG,
      'Folder selection is unsupported on this device (no ...UserFileService.FolderSelection); ' +
      'a root cannot be added by picking.');
    return [];
  }

  let uris: string[] = [];
  try {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    uris = await documentPicker.select(options);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'Folder picker failed. Code: %{public}d, message: %{public}s',
      err.code, err.message);
    return [];
  }
  if (uris.length === 0) {
    hilog.info(DOMAIN, TAG, 'Folder picker cancelled.');
    return [];
  }

  // Persist before returning: a grant that is not persisted dies with the process, and the host
  // would not notice until the next launch.
  const persisted: string[] = await persistUris(uris);
  return persisted.map((uri: string) => toPickedRoot(uri));
}

/**
 * Re-activate grants persisted in an earlier session and return them as roots.
 *
 * Call this once at startup with whatever `pickFolders()` returned last time. URIs that can no
 * longer be activated — the folder was deleted, the grant was revoked in Settings — are dropped
 * with a warning rather than failing the batch, so a host should treat "absent from the result"
 * as "stop storing this URI".
 */
export async function activatePersistedRoots(uris: string[]): Promise<PickedRoot[]> {
  if (uris.length === 0) {
    return [];
  }
  if (!isFolderAuthorizationSupported()) {
    hilog.warn(DOMAIN, TAG, 'Folder authorization unsupported here; persisted roots unavailable.');
    return [];
  }

  const policies: fileShare.PolicyInfo[] = uris.map((uri: string) => {
    const policy: fileShare.PolicyInfo = { uri: uri, operationMode: READ_ONLY_MODE };
    return policy;
  });

  const failed: Set<string> = new Set<string>();
  try {
    await fileShare.activatePermission(policies);
  } catch (e) {
    collectPolicyFailures(e, 'activatePermission', failed);
  }
  return uris.filter((uri: string) => !failed.has(uri)).map((uri: string) => toPickedRoot(uri));
}

/** Persist read access to each URI. Returns the ones that are usable. */
async function persistUris(uris: string[]): Promise<string[]> {
  if (!isFolderAuthorizationSupported()) {
    // Without persistence the grant still works for this session, so return the URIs rather than
    // pretending the pick failed.
    hilog.warn(DOMAIN, TAG,
      'Folder authorization unsupported here; the grant will not survive a restart.');
    return uris;
  }

  const policies: fileShare.PolicyInfo[] = uris.map((uri: string) => {
    const policy: fileShare.PolicyInfo = { uri: uri, operationMode: READ_ONLY_MODE };
    return policy;
  });

  const failed: Set<string> = new Set<string>();
  try {
    await fileShare.persistPermission(policies);
  } catch (e) {
    collectPolicyFailures(e, 'persistPermission', failed);
  }
  // A URI that could not be persisted is still usable now, since the pick granted it. Keep it
  // and let it lapse at the next launch.
  for (const uri of failed) {
    hilog.warn(DOMAIN, TAG, 'Grant for %{public}s is session-only; it was not persisted.', uri);
  }
  return uris;
}

/**
 * Pull the per-URI failures out of a `fileShare` rejection.
 *
 * These APIs report partial failure in `BusinessError.data` as `PolicyErrorResult[]`, one entry
 * per URI that did not take. A rejection with no `data` is a whole-call failure (401 bad
 * parameter, 201 missing `FILE_ACCESS_PERSIST`, 801 unsupported).
 */
function collectPolicyFailures(e: Object, api: string, failed: Set<string>): void {
  const err = e as BusinessError<fileShare.PolicyErrorResult[]>;
  hilog.error(DOMAIN, TAG, '%{public}s failed. Code: %{public}d, message: %{public}s',
    api, err.code, err.message);
  const results: fileShare.PolicyErrorResult[] | undefined = err.data;
  if (results === undefined) {
    return;
  }
  for (const result of results) {
    hilog.error(DOMAIN, TAG, '  %{public}s: policy code %{public}d, %{public}s',
      result.uri, result.code, result.message);
    failed.add(result.uri);
  }
}

/**
 * Turn a picker URI into a root node.
 *
 * `FileUri` extends `uri.URI`, so `.path` is the sandbox path `fileIo` wants and `.name` is the
 * last segment. Both are carried: `path` is what the data layer lists, `uri` is what a later
 * `activatePermission` needs.
 */
function toPickedRoot(uri: string): PickedRoot {
  const parsed: fileUri.FileUri = new fileUri.FileUri(uri);
  const node: FileNode = {
    name: parsed.name,
    path: parsed.path,
    isDirectory: true,
    uri: uri
  };
  return { uri: uri, node: node };
}
