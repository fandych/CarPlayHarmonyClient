import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { carPlaySessionController } from '../app/session/CarPlaySessionController';
import { carPlayDiagnostics } from '../platform/diagnostics/CarPlayDiagnostics';
import { describeFailure } from '../platform/diagnostics/DiagnosticFormat';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private initialization: Promise<void> = Promise.resolve();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.initialization = carPlaySessionController.setContext(this.context);
    void this.initialization.catch((error: Error) => {
      carPlayDiagnostics.log('ability', `配置初始化失败：${describeFailure(error)}`, true);
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    void carPlaySessionController.shutdown();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        carPlayDiagnostics.log('ability', `loadContent failed: ${describeFailure(err)}`, true);
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      void this.initialization.then(() => carPlaySessionController.restoreEnabledOnce()).catch((error: Error) => {
        carPlayDiagnostics.log('ability', `恢复开启状态失败：${describeFailure(error)}`, true);
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    carPlayDiagnostics.log('ability', 'onForeground');
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    carPlayDiagnostics.log('ability', 'onBackground');
    try {
      carPlayDiagnostics.flush();
    } catch (error) {
      carPlayDiagnostics.log('ability', `日志刷盘失败：${describeFailure(error)}`, true);
    }
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}