import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';

type ProjectionPermission =
  'ohos.permission.ACCESS_VIRTUAL_SCREEN' |
  'ohos.permission.CONTROL_DEVICE';

export class VirtualScreenPermissionProbe {
  hasAccess(): boolean {
    return this.hasPermission('ohos.permission.ACCESS_VIRTUAL_SCREEN');
  }

  hasTouchControl(): boolean {
    return this.hasPermission('ohos.permission.CONTROL_DEVICE');
  }

  private hasPermission(permission: ProjectionPermission): boolean {
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
    );
    const result = abilityAccessCtrl.createAtManager().checkAccessTokenSync(
      bundleInfo.appInfo.accessTokenId,
      permission
    );
    return result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }
}
