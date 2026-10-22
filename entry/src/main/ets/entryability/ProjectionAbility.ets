import { UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { describeFailure } from '../platform/diagnostics/DiagnosticFormat';

const DOMAIN = 0x0000;
const CLOSE_PROJECTION_ACTION = 'close';

export default class ProjectionAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Projection', (error) => {
      if (error.code !== 0) {
        hilog.error(DOMAIN, 'CarPlayerProjection', 'Unable to load projection UI: %{public}s',
          describeFailure(error));
      }
    });
  }

  onNewWant(want: Want): void {
    if (want.parameters?.['carplayerProjectionAction'] === CLOSE_PROJECTION_ACTION) {
      void this.context.terminateSelf().catch((error: Error) => {
        hilog.error(DOMAIN, 'CarPlayerProjection', 'Unable to terminate projection ability: %{public}s',
          describeFailure(error));
      });
    }
  }
}
