import common from '@ohos.app.ability.common';
import { AppSettingsStore } from '../settings/AppSettingsStore';

@Entry
@Component
struct ProjectionHome {
  @State backgroundUri: string = '';
  @State appCount: number = 0;
  @State loadStatus: string = 'CarPlay';
  private readonly settingsStore: AppSettingsStore = new AppSettingsStore();

  aboutToAppear(): void {
    void this.loadProjectionSettings();
  }

  build() {
    Stack() {
      if (this.backgroundUri.length > 0) {
        Image(this.backgroundUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#101B2D')
      }
      Column({ space: 12 }) {
        Text('CarPlay')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text(this.loadStatus)
          .fontSize(14)
          .fontColor('#E2EAF5')
        Text(this.appCount > 0 ? `${this.appCount} 个应用可从手机端选择投放` : '请从手机端选择要投放的应用')
          .fontSize(12)
          .fontColor('#D0DAE8')
      }
      .padding(24)
      .backgroundColor('#AA101B2D')
      .borderRadius(20)
      .align(Alignment.Center)
    }
    .width('100%')
    .height('100%')
  }

  private async loadProjectionSettings(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const settings = await this.settingsStore.load(context);
      this.backgroundUri = settings.backgroundPhotoUri;
      this.appCount = settings.favoriteBundles.length;
      this.loadStatus = '应用已投放至 CarPlay 虚拟屏';
    } catch (error) {
      this.loadStatus = `读取投屏设置失败：${error instanceof Error ? error.message : String(error)}`;
    }
  }
}
