import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'FileTreeView';

/**
 * The user-directory permissions this component needs, and how to obtain them.
 *
 * `Environment.getUserDocumentDir()` and its siblings return the path to a pre-authorized
 * directory and need no permission to do so. That is not the same as being allowed to read it:
 * `fileIo.listFile()` on that path fails with 13900001 "Operation not permitted" until the
 * matching `user_grant` permission has been declared and granted.
 *
 * The permission is per-directory; there is no single "read the user dirs" permission below
 * `ACCESS_USER_FULL_DISK` (system_basic, manual_settings, API 22+, PC/2-in-1 only).
 */

/**
 * Documents and Download. Both are `normal` level since API 12, so an ordinary debug signature
 * carries them — no ACL entry in the provisioning profile is required.
 *
 * Does not include Desktop: see `DESKTOP_DIR_PERMISSION`.
 */
export const USER_DIR_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
];

/**
 * All three user directories, Desktop included.
 *
 * Requires the profile ACL — see `DESKTOP_DIR_PERMISSION`. Safe to request even without it:
 * `requestUserDirPermissions()` reports Desktop as `unusable` and still prompts for the other
 * two, so an app without the ACL degrades to Documents + Download rather than to nothing.
 */
export const ALL_USER_DIR_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY'
];

/**
 * Desktop, kept apart on purpose.
 *
 * It is `system_basic` level, which makes it a restricted permission: it must appear in the
 * `allowed-acls` of the provisioning profile or installation fails outright — not the listing,
 * the install:
 * ```
 * code:9568289 install failed due to grant request permissions failed.
 * PermissionName: ohos.permission.READ_WRITE_DESKTOP_DIRECTORY
 * ```
 * Obtaining the ACL is a one-time step: declare the permission in the HAP's `module.json5`
 * first, then re-run *File → Project Structure → Signing Configs → Automatically generate
 * signature*, which requests the restricted permission while signing. It stays out of
 * `USER_DIR_PERMISSIONS` because a consuming app may not have done that, and one unobtainable
 * permission must not be the default.
 *
 * Use `ALL_USER_DIR_PERMISSIONS` once your app has the ACL.
 */
export const DESKTOP_DIR_PERMISSION: Permissions = 'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY';

/** Outcome of a check or a request. Always lists every permission that was asked about. */
export interface UserDirPermissionResult {
  /** Permissions confirmed granted. */
  granted: Permissions[];
  /** Permissions not granted — denied, undeclared, or never decided. */
  denied: Permissions[];
  /** True only when `denied` is empty. */
  allGranted: boolean;
  /**
   * The subset of `denied` that no dialog can fix: status `INVALID` (not declared in the HAP's
   * `module.json5`) or `RESTRICTED` (declared, but the signature carries no ACL for it).
   *
   * Kept separate because the two need opposite handling — one is a build-configuration fix, the
   * other is a user tap.
   */
  unusable: Permissions[];
  /** Convenience for `unusable.length > 0`. */
  needsConfigFix: boolean;
}

/** `PermissionRequestResult.authResults`: 0 means granted. */
const AUTH_RESULT_GRANTED: number = 0;

/**
 * What the app is currently allowed to do, without showing anything to the user.
 *
 * Synchronous and side-effect free, so it is safe to call before every listing.
 * `getSelfPermissionStatus` is API 20+.
 */
export function checkUserDirPermissions(
  permissions: Permissions[] = USER_DIR_PERMISSIONS): UserDirPermissionResult {
  const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
  const granted: Permissions[] = [];
  const denied: Permissions[] = [];
  const unusable: Permissions[] = [];

  for (const permission of permissions) {
    try {
      const status: abilityAccessCtrl.PermissionStatus = atManager.getSelfPermissionStatus(permission);
      if (status === abilityAccessCtrl.PermissionStatus.GRANTED) {
        granted.push(permission);
      } else {
        denied.push(permission);
        // INVALID = not declared in module.json5. RESTRICTED = declared but the app may not even
        // ask (no ACL). Neither is fixable by prompting.
        if (status === abilityAccessCtrl.PermissionStatus.INVALID ||
          status === abilityAccessCtrl.PermissionStatus.RESTRICTED) {
          unusable.push(permission);
          hilog.error(DOMAIN, TAG,
            'Permission %{public}s is unusable (status %{public}d). Check requestPermissions in ' +
            'module.json5, and the profile ACL for system_basic permissions.',
            permission, status);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG,
        'getSelfPermissionStatus failed for %{public}s. Code: %{public}d, message: %{public}s',
        permission, err.code, err.message);
      denied.push(permission);
    }
  }
  return {
    granted: granted,
    denied: denied,
    allGranted: denied.length === 0,
    unusable: unusable,
    needsConfigFix: unusable.length > 0
  };
}

/**
 * Show the system authorization dialog for whatever is still missing, and report the outcome.
 *
 * Anything already granted is not re-requested. If the user has already refused once the system
 * will not show the dialog again; the promise still resolves, with the permission in `denied`,
 * rather than rejecting, so callers should route that case to Settings instead of looping.
 *
 * @param context the UIAbility context. From a page:
 *   `this.getUIContext().getHostContext() as common.UIAbilityContext`.
 */
export async function requestUserDirPermissions(
  context: common.UIAbilityContext,
  permissions: Permissions[] = USER_DIR_PERMISSIONS): Promise<UserDirPermissionResult> {
  const current: UserDirPermissionResult = checkUserDirPermissions(permissions);
  // Ask only for what a dialog can actually grant. An undeclared or ACL-less permission in the
  // list must not suppress the prompt for its neighbours.
  const askable: Permissions[] =
    current.denied.filter((p: Permissions) => !current.unusable.includes(p));
  if (askable.length === 0) {
    return current;
  }

  const granted: Permissions[] = current.granted.slice();
  const denied: Permissions[] = current.unusable.slice();
  const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();

  try {
    const data: PermissionRequestResult =
      await atManager.requestPermissionsFromUser(context, askable);
    for (let i: number = 0; i < data.permissions.length; i++) {
      const permission: Permissions = data.permissions[i] as Permissions;
      if (data.authResults[i] === AUTH_RESULT_GRANTED) {
        granted.push(permission);
      } else {
        denied.push(permission);
        hilog.warn(DOMAIN, TAG, 'Permission %{public}s not granted (authResult %{public}d).',
          permission, data.authResults[i]);
      }
    }
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG,
      'requestPermissionsFromUser failed. Code: %{public}d, message: %{public}s', err.code, err.message);
    // The dialog itself broke (12100009): treat every outstanding permission as still missing.
    for (const permission of askable) {
      denied.push(permission);
    }
  }

  return {
    granted: granted,
    denied: denied,
    allGranted: denied.length === 0,
    unusable: current.unusable,
    needsConfigFix: current.needsConfigFix
  };
}
