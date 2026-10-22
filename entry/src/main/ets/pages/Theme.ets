import { PageHeader, showPageError } from '../components/PageHeader';
import { CarPlayTheme } from '../app/settings/CarPlaySettings';
import { carPlaySettings } from '../platform/settings/HarmonySettings';

@Entry
@Component
struct Theme {
  @State private theme: CarPlayTheme = 'system';
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private error: string = '';
  private unsubscribe: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribe = carPlaySettings.subscribe((snapshot) => {
      this.theme = snapshot.settings.theme;
      this.ready = snapshot.ready;
      this.busy = snapshot.busy;
      this.error = snapshot.error;
    });
  }
  aboutToDisappear(): void { this.unsubscribe?.(); this.unsubscribe = undefined; }

  @Builder
  private option(label: string, value: CarPlayTheme) {
    Button() {
      Row() {
        Text(label).fontSize(18).fontColor($r('app.color.primary_text'))
        Blank()
        Text(this.theme === value ? '已选择' : '')
          .fontSize(14)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .padding(20)
    }
    .type(ButtonType.Normal)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(14)
    .width('100%')
    .enabled(this.ready && !this.busy)
    .onClick(() => {
      if (this.theme !== value) {
        void carPlaySettings.setTheme(value).catch((error: Error) => {
          showPageError(this.getUIContext(), '保存主题', error);
        });
      }
    })
  }

  build() {
    Column({ space: 16 }) {
      PageHeader({ title: '主题' })
      this.option('跟随系统', 'system')
      this.option('浅色', 'light')
      this.option('深色', 'dark')
      Text('立即应用并保存；“跟随系统”会随系统外观变化。')
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
      if (this.error.length > 0) {
        Text(this.error).fontSize(13).fontColor($r('app.color.danger'))
      }
    }
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
