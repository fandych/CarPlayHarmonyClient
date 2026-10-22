import display from '@ohos.display';

export interface CarPlayDisplaySize {
  width: number;
  height: number;
}

export class CarPlayVirtualDisplay {
  private screenId: number = -1;

  get id(): number {
    return this.screenId;
  }

  async create(surfaceId: string, size: CarPlayDisplaySize): Promise<number> {
    if (this.screenId >= 0) {
      throw new Error('CarPlay virtual display is already active');
    }
    if (!surfaceId || !Number.isInteger(size.width) || !Number.isInteger(size.height) ||
      size.width < 320 || size.height < 240 || size.width > 1920 || size.height > 1200 ||
      size.width % 2 !== 0 || size.height % 2 !== 0) {
      throw new Error('Invalid CarPlay virtual display parameters');
    }
    try {
      const density = display.getDefaultDisplaySync().densityPixels;
      if (!Number.isFinite(density) || density < 0.5 || density > 4) {
        throw new Error(`Primary display density is out of range: ${density}`);
      }
      this.screenId = await display.createVirtualScreen({
        name: 'Harmony CarPlay',
        width: size.width,
        height: size.height,
        density,
        surfaceId,
        supportsFocus: true
      });
      if (!Number.isInteger(this.screenId) || this.screenId <= 0) {
        this.screenId = -1;
        throw new Error('HarmonyOS returned an invalid virtual display ID');
      }
      return this.screenId;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`创建 CarPlay 虚拟屏失败：${message}`);
    }
  }

  async destroy(): Promise<void> {
    const screenId = this.screenId;
    this.screenId = -1;
    if (screenId < 0) {
      return;
    }
    try {
      await display.destroyVirtualScreen(screenId);
      this.screenId = -1;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.screenId = screenId;
      throw new Error(`销毁 CarPlay 虚拟屏失败：${message}`);
    }
  }
}
