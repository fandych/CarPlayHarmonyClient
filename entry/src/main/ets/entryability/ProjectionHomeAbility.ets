import { UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class ProjectionHomeAbility extends UIAbility {
  onCreate(_want: Want): void {
    hilog.info(DOMAIN, 'CarPlayProjection', 'Projection home ability created');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/ProjectionHome', (error) => {
      if (error.code) {
        hilog.error(
          DOMAIN,
          'CarPlayProjection',
          'Projection home failed to load: %{public}s',
          JSON.stringify(error)
        );
      }
    });
  }
}
