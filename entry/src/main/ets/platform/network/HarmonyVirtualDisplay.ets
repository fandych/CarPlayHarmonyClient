import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import display from '@ohos.display';
import nativeScreenCapture from 'libentry.so';
import { describeFailure } from '../diagnostics/DiagnosticFormat';

const PROJECTION_WIDTH = 1280;
const PROJECTION_HEIGHT = 720;

export class HarmonyVirtualDisplay {
  readonly displayId: number;
  readonly width: number = PROJECTION_WIDTH;
  readonly height: number = PROJECTION_HEIGHT;
  private readonly screenId: number;
  private readonly context: common.UIAbilityContext;
  private closed: boolean = false;

  private constructor(screenId: number, context: common.UIAbilityContext) {
    this.screenId = screenId;
    this.displayId = display.getDisplayByIdSync(screenId).id;
    this.context = context;
  }

  static async create(
    context: common.UIAbilityContext,
    log: (message: string, error?: boolean) => void
  ): Promise<HarmonyVirtualDisplay> {
    let screenId: number | undefined = undefined;
    let surfaceCreated = false;
    try {
      const surfaceId: string =
        nativeScreenCapture.createVirtualSurface(PROJECTION_WIDTH, PROJECTION_HEIGHT);
      surfaceCreated = true;
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
      await context.startAbility({
        bundleName: context.abilityInfo.bundleName,
        abilityName: 'ProjectionAbility'
      }, {
        displayId: virtualDisplay.id
      });
      log(`CarPlayer 虚拟显示与投影 Ability 已启动：screen=${screenId}，display=${virtualDisplay.id}，` +
        `size=${PROJECTION_WIDTH}x${PROJECTION_HEIGHT}，surfaceId 已省略。`);
      return new HarmonyVirtualDisplay(screenId, context);
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(describeFailure(error));
      if (screenId !== undefined) {
        try {
          await display.destroyVirtualScreen(screenId);
        } catch (cleanupError) {
          log(`虚拟屏初始化失败后销毁显示器也失败：${describeFailure(cleanupError)}`, true);
        }
      }
      if (surfaceCreated) {
        try {
          nativeScreenCapture.destroyVirtualSurface();
        } catch (cleanupError) {
          log(`虚拟屏初始化失败后销毁输出 Surface 也失败：${describeFailure(cleanupError)}`, true);
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
      await this.context.startAbility({
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'ProjectionAbility',
        parameters: {
          carplayerProjectionAction: 'close'
        }
      }, {
        displayId: this.displayId
      });
    } catch (error) {
      failures.push(`关闭虚拟显示 Ability 失败：${describeFailure(error)}`);
    }
    try {
      await display.destroyVirtualScreen(this.screenId);
    } catch (error) {
      failures.push(`销毁虚拟显示失败：${describeFailure(error)}`);
    }
    try {
      nativeScreenCapture.destroyVirtualSurface();
    } catch (error) {
      failures.push(`销毁虚拟显示输出 Surface 失败：${describeFailure(error)}`);
    }
    if (failures.length > 0) {
      throw new Error(failures.join('；'));
    }
  }
}
