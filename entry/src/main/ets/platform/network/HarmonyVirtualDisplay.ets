import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import display from '@ohos.display';
import { window } from '@kit.ArkUI';
import { describeFailure } from '../diagnostics/DiagnosticFormat';

const PROJECTION_WIDTH = 1280;
const PROJECTION_HEIGHT = 720;

export class HarmonyVirtualDisplay {
  readonly displayId: number;
  readonly width: number = PROJECTION_WIDTH;
  readonly height: number = PROJECTION_HEIGHT;
  private readonly screenId: number;
  private readonly projectionWindow: window.Window;
  private closed: boolean = false;

  private constructor(screenId: number, projectionWindow: window.Window) {
    this.screenId = screenId;
    this.displayId = display.getDisplayByIdSync(screenId).id;
    this.projectionWindow = projectionWindow;
  }

  static async create(
    context: common.UIAbilityContext,
    log: (message: string, error?: boolean) => void
  ): Promise<HarmonyVirtualDisplay> {
    const surfaceId = `CarPlayerProjection-${util.generateRandomUUID()}`;
    let screenId: number | undefined = undefined;
    let projectionWindow: window.Window | undefined = undefined;
    try {
      screenId = await display.createVirtualScreen({
        name: `CarPlayer-${util.generateRandomUUID()}`,
        width: PROJECTION_WIDTH,
        height: PROJECTION_HEIGHT,
        density: 160,
        surfaceId,
        supportsFocus: false
      });
      const virtualDisplay = display.getDisplayByIdSync(screenId);
      if (!virtualDisplay.alive || virtualDisplay.width < 2 || virtualDisplay.height < 2) {
        throw new Error('系统创建了虚拟屏，但返回的显示器不可用或尺寸无效。');
      }
      projectionWindow = await window.createWindow({
        name: `CarPlayerProjectionWindow-${screenId}`,
        windowType: window.WindowType.TYPE_FLOAT,
        ctx: context,
        displayId: virtualDisplay.id
      });
      await projectionWindow.setUIContent('pages/Projection');
      await projectionWindow.resize(PROJECTION_WIDTH, PROJECTION_HEIGHT);
      await projectionWindow.showWindow();
      log(`CarPlayer 虚拟显示已创建：screen=${screenId}，display=${virtualDisplay.id}，` +
        `size=${PROJECTION_WIDTH}x${PROJECTION_HEIGHT}，surfaceId 已省略。`);
      return new HarmonyVirtualDisplay(screenId, projectionWindow);
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(describeFailure(error));
      if (projectionWindow !== undefined) {
        try {
          await projectionWindow.destroyWindow();
        } catch (cleanupError) {
          log(`虚拟屏初始化失败后销毁窗口也失败：${describeFailure(cleanupError)}`, true);
        }
      }
      if (screenId !== undefined) {
        try {
          await display.destroyVirtualScreen(screenId);
        } catch (cleanupError) {
          log(`虚拟屏初始化失败后销毁显示器也失败：${describeFailure(cleanupError)}`, true);
        }
      }
      log(`CarPlayer 虚拟显示初始化失败：${describeFailure(failure)}`, true);
      throw failure;
    }
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    const failures: string[] = [];
    try {
      await this.projectionWindow.destroyWindow();
    } catch (error) {
      failures.push(`销毁虚拟屏窗口失败：${describeFailure(error)}`);
    }
    try {
      await display.destroyVirtualScreen(this.screenId);
    } catch (error) {
      failures.push(`销毁虚拟显示失败：${describeFailure(error)}`);
    }
    if (failures.length > 0) {
      throw new Error(failures.join('；'));
    }
  }
}
