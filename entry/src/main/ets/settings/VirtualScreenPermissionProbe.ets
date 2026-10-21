import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';

export class VirtualScreenPermissionProbe {
  hasAccess(): boolean {
    const bundleInfo = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
    );
    const result = abilityAccessCtrl.createAtManager().checkAccessTokenSync(
      bundleInfo.appInfo.accessTokenId,
      'ohos.permission.ACCESS_VIRTUAL_SCREEN'
    );
    return result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }
}
