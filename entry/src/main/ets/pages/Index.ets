import { carPlaySessionController, CarPlaySessionState, isCarPlaySessionActive } from '../app/session/CarPlaySessionController';
import { CarPlayTheme } from '../app/settings/CarPlaySettings';
import { carPlaySettings } from '../platform/settings/HarmonySettings';
import { showPageError } from '../components/PageHeader';

@Entry
@Component
struct Index {
  @State private state: CarPlaySessionState = 'idle';
  @State private deviceName: string = '';
  @State private carPlayEnabled: boolean = false;
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private changingSwitch: boolean = false;
  @State private theme: CarPlayTheme = 'system';
  @State private settingsError: string = '';
  @State private blockedReason: string = '';
  private unsubscribeSession: (() => void) | undefined = undefined;
  private unsubscribeSettings: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribeSession = carPlaySessionController.subscribe((snapshot) => {
      this.state = snapshot.state;
      this.deviceName = snapshot.connectedDeviceName;
      this.blockedReason = snapshot.blockedReason;
    });
    this.unsubscribeSettings = carPlaySettings.subscribe((snapshot) => {
      this.carPlayEnabled = snapshot.settings.enabled;
      this.ready = snapshot.ready;
      this.busy = snapshot.busy;
      this.theme = snapshot.settings.theme;
      this.settingsError = snapshot.error;
    });
  }

  aboutToDisappear(): void {
    this.unsubscribeSession?.();
    this.unsubscribeSettings?.();
    this.unsubscribeSession = undefined;
    this.unsubscribeSettings = undefined;
  }

  private async changeEnabled(value: boolean): Promise<void> {
    if (value === this.carPlayEnabled || this.changingSwitch) {
      return;
    }
    this.changingSwitch = true;
    try {
      await carPlaySessionController.setEnabled(value);
    } catch (error) {
      showPageError(this.getUIContext(), '保存 CarPlay 开关', error);
    } finally {
      this.changingSwitch = false;
    }
  }

  private statusDetail(): string {
    switch (this.state) {
      case 'connecting': return '正在连接所选接收端，或等待接收端回连';
      case 'bluetooth-connected': return '蓝牙通道已连接，CarPlay 尚未建立';
      case 'iap2-negotiating': return '正在协商 iAP2 链路，CarPlay 尚未建立';
      case 'iap2-ready': return 'iAP2 已就绪，等待车机网络信息';
      case 'wifi-pending': return '正在确认并加入车机 Wi-Fi';
      case 'wifi-connected': return '车机 Wi-Fi 已连接，等待邀请/端点';
      case 'airplay-found': return '已发现 AirPlay 服务，尚未开始视频投屏';
      case 'media-negotiating': return '正在进行 AirPlay 配对与媒体通道协商';
      case 'waiting-video': return '媒体通道已建立，等待视频源；尚未投屏';
      case 'screen-capture-pending': return '正在等待系统屏幕采集授权或首个 H.264 视频帧';
      case 'streaming': return '屏幕采集已授权，正在向接收端发送视频帧';
      case 'blocked': return this.blockedReason;
      case 'error': return '连接失败，开启意图已保留；请查看日志或修改设置后重试';
      default: return this.carPlayEnabled ? '已记住开启状态，当前未连接' : '开启后连接已保存的接收端';
    }
  }

  @Builder
  private menuRow(title: string, url: string, detail: string = '') {
    Row({ space: 12 }) {
      Text(title)
        .fontSize(18)
        .fontColor($r('app.color.primary_text'))
      Blank()
      if (detail.length > 0) {
        Text(detail)
          .fontSize(14)
          .fontColor($r('app.color.secondary_text'))
      }
      Text('>')
        .fontSize(20)
        .fontColor($r('app.color.secondary_text'))
    }
    .width('100%')
    .height(64)
    .padding({ left: 20, right: 20 })
    .backgroundColor($r('app.color.card_background'))
    .accessibilityText(title)
    .onClick(() => {
      void this.getUIContext().getRouter().pushUrl({ url }).catch((error: Error) => {
        showPageError(this.getUIContext(), '打开页面', error);
      });
    })
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Column({ space: 5 }) {
          Text('CarPlay')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text('Harmony 无线发送端')
            .fontSize(14)
            .fontColor($r('app.color.secondary_text'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Text('状态')
              .fontSize(18)
              .fontColor($r('app.color.primary_text'))
            Blank()
            Text(this.deviceName.length > 0 ? `${this.deviceName}（蓝牙已连接）` : '未连接')
              .fontSize(15)
              .fontColor($r('app.color.secondary_text'))
              .maxLines(2)
              .textAlign(TextAlign.End)
              .layoutWeight(1)
          }
          Text(this.statusDetail())
            .fontSize(13)
            .fontColor(this.state === 'error' || this.state === 'blocked' ? $r('app.color.warning') : $r('app.color.secondary_text'))
            .width('100%')
          Divider().color($r('app.color.divider'))
          Row() {
            Column({ space: 5 }) {
              Text('CarPlay')
                .fontSize(18)
                .fontColor($r('app.color.primary_text'))
              Text('记住开关，重新打开应用时尝试恢复一次')
                .fontSize(12)
                .fontColor($r('app.color.secondary_text'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.carPlayEnabled })
              .accessibilityText('CarPlay 开关')
              .enabled(this.ready && !this.busy && !this.changingSwitch)
              .onChange((value: boolean) => { void this.changeEnabled(value); })
          }
          if (this.carPlayEnabled && !isCarPlaySessionActive(this.state)) {
            Button('重试连接')
              .enabled(this.ready && !this.busy)
              .onClick(() => {
                void carPlaySessionController.start().catch((error: Error) => {
                  showPageError(this.getUIContext(), '重试连接', error);
                });
              })
          }
          if (this.state === 'waiting-video') {
            Text('开始后将投送手机当前屏幕（可能包含其他应用的可见内容）。系统会先请求授权；可随时停止。')
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
            Button('开始投屏')
              .enabled(!this.busy)
              .width('100%')
              .onClick(() => {
                try {
                  carPlaySessionController.startProjection();
                } catch (error) {
                  showPageError(this.getUIContext(), '开始投屏', error);
                }
              })
          }
          if (this.state === 'screen-capture-pending' || this.state === 'streaming') {
            Button(this.state === 'streaming' ? '停止投屏' : '取消屏幕采集')
              .enabled(!this.busy)
              .width('100%')
              .onClick(() => {
                void carPlaySessionController.stopProjection().catch((error: Error) => {
                  showPageError(this.getUIContext(), '停止投屏', error);
                });
              })
          }
        }
        .padding(20)
        .borderRadius(18)
        .backgroundColor($r('app.color.card_background'))
        .width('100%')

        Column() {
          this.menuRow('主题', 'pages/Theme', this.theme === 'system' ? '跟随系统' : this.theme === 'dark' ? '深色' : '浅色')
          Divider().color($r('app.color.divider'))
          this.menuRow('设置', 'pages/Settings')
          Divider().color($r('app.color.divider'))
          this.menuRow('日志', 'pages/Logs')
          Divider().color($r('app.color.divider'))
          this.menuRow('关于', 'pages/About')
        }
        .borderRadius(18)
        .clip(true)
        .width('100%')

        if (!this.ready) {
          Text(this.settingsError || '正在载入配置…')
            .fontSize(13)
            .fontColor($r('app.color.danger'))
          if (this.settingsError.length > 0) {
            Button('重新载入配置').onClick(() => {
              void carPlaySettings.retryInitialization().catch((error: Error) => {
                showPageError(this.getUIContext(), '载入配置', error);
              });
            })
          }
        } else if (this.settingsError.length > 0) {
          Text(this.settingsError).fontColor($r('app.color.danger')).fontSize(13)
        }
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 28, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
