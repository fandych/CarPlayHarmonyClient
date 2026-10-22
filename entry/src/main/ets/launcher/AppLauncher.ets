import bundleManager from '@ohos.bundle.bundleManager';
import common from '@ohos.app.ability.common';
import { Want } from '@kit.AbilityKit';

export interface AppLaunchTarget {
  bundleName: string;
  abilityName: string;
  label: string;
}

export class AppLauncher {
  async resolve(bundleName: string): Promise<AppLaunchTarget> {
    const normalized = bundleName.trim();
    if (!normalized || normalized.length > 255 || normalized.includes('\n')) {
      throw new Error('应用包名无效');
    }
    let bundleInfo: bundleManager.BundleInfo;
    try {
      bundleInfo = await bundleManager.getBundleInfo(
        normalized,
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_ABILITY |
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_HAP_MODULE
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`读取应用信息失败 (${normalized})：${message}`);
    }

    for (const moduleInfo of bundleInfo.hapModulesInfo) {
      for (const abilityInfo of moduleInfo.abilitiesInfo) {
        if (abilityInfo.enabled && abilityInfo.exported) {
          const target: AppLaunchTarget = {
            bundleName: normalized,
            abilityName: abilityInfo.name,
            label: abilityInfo.label.length > 0 ? abilityInfo.label : normalized
          };
          return target;
        }
      }
    }
    throw new Error(`应用 ${normalized} 没有可由其他应用启动的 UIAbility`);
  }

  async launch(
    context: common.UIAbilityContext,
    target: AppLaunchTarget,
    displayId?: number
  ): Promise<void> {
    const want: Want = new Want();
    want.bundleName = target.bundleName;
    want.abilityName = target.abilityName;
    if (displayId !== undefined && (!Number.isInteger(displayId) || displayId <= 0)) {
      throw new Error(`虚拟屏 ID 无效：${displayId}`);
    }
    try {
      if (displayId === undefined) {
        await context.startAbility(want);
      } else {
        await context.startAbility(want, { displayId });
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const destination = displayId === undefined ? '手机' : `CarPlay 屏幕 ${displayId}`;
      throw new Error(`在${destination}启动应用 ${target.label} 失败：${message}`);
    }
  }

  async launchProjectionHome(context: common.UIAbilityContext, displayId: number): Promise<void> {
    if (!Number.isInteger(displayId) || displayId <= 0) {
      throw new Error(`虚拟屏 ID 无效：${displayId}`);
    }
    const bundleName = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
    ).name;
    const want: Want = new Want();
    want.bundleName = bundleName;
    want.abilityName = 'ProjectionHomeAbility';
    try {
      await context.startAbility(want, { displayId });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`启动 CarPlay 投屏桌面失败：${message}`);
    }
  }
}
