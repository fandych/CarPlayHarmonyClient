import { carPlaySessionController, CarPlaySessionState, isCarPlaySessionActive } from '../app/session/CarPlaySessionController';
import { CarPlayTheme } from '../app/settings/CarPlaySettings';
import { carPlaySettings } from '../platform/settings/HarmonySettings';
import { showPageError } from '../components/PageHeader';
import { MfiTrustPromptInfo } from '../protocol/iap2/MfiVerifier';

@Entry
@Component
struct Index {
  @State private state: CarPlaySessionState = 'idle';
  @State private deviceName: string = '';
  @State private selectedDeviceName: string = '';
  @State private selectedDeviceId: string = '';
  @State private carPlayEnabled: boolean = false;
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private changingSwitch: boolean = false;
  @State private theme: CarPlayTheme = 'system';
  @State private settingsError: string = '';
  @State private blockedReason: string = '';
  private unsubscribeSession: (() => void) | undefined = undefined;
  private unsubscribeSettings: (() => void) | undefined = undefined;
  private presentedMfiTrustFingerprint: string = '';

  aboutToAppear(): void {
    this.unsubscribeSession = carPlaySessionController.subscribe((snapshot) => {
      this.state = snapshot.state;
      this.deviceName = snapshot.connectedDeviceName;
      this.blockedReason = snapshot.blockedReason;
      const trustRequest = snapshot.mfiTrustRequest;
      if (trustRequest !== undefined && trustRequest.fingerprint !== this.presentedMfiTrustFingerprint) {
        this.presentedMfiTrustFingerprint = trustRequest.fingerprint;
        void this.presentMfiTrustRequest(trustRequest);
      }
    });
    this.unsubscribeSettings = carPlaySettings.subscribe((snapshot) => {
      this.carPlayEnabled = snapshot.settings.enabled;
      this.selectedDeviceName = snapshot.settings.targetDeviceName;
      this.selectedDeviceId = snapshot.settings.targetDeviceId;
      this.ready = snapshot.ready;
      this.busy = snapshot.busy;
      this.theme = snapshot.settings.theme;
      this.settingsError = snapshot.error;
    });
  }

  aboutToDisappear(): void {
    if (this.presentedMfiTrustFingerprint.length > 0) {
      carPlaySessionController.approveMfiTrust(this.presentedMfiTrustFingerprint, false);
      this.presentedMfiTrustFingerprint = '';
    }
    this.unsubscribeSession?.();
    this.unsubscribeSettings?.();
    this.unsubscribeSession = undefined;
    this.unsubscribeSettings = undefined;
  }

  private async presentMfiTrustRequest(info: MfiTrustPromptInfo): Promise<void> {
    try {
      const response = await this.getUIContext().getPromptAction().showDialog({
        title: '确认车机 MFi 证书信任',
        message: `系统无法验证此证书的颁发链。只有在你确认正在连接自己的车机/DiPlay 时才信任。\n\n` +
          `主体：${info.subject}\n颁发者：${info.issuer}\nSHA-256：${info.fingerprint}\n\n` +
          `${info.pkixFailure}\n\n同意后仅在本机保存此指纹；仍会验证 MFi challenge 签名。`,
        buttons: [
          { text: '拒绝', color: '#666666' },
          { text: '信任此证书', color: '#007DFF' }
        ]
      });
      carPlaySessionController.approveMfiTrust(info.fingerprint, response.index === 1);
    } catch (error) {
      carPlaySessionController.approveMfiTrust(info.fingerprint, false);
      showPageError(this.getUIContext(), 'MFi 证书信任确认', error);
    } finally {
      if (this.presentedMfiTrustFingerprint === info.fingerprint) {
        this.presentedMfiTrustFingerprint = '';
      }
    }
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

  private connectOrChooseDevice(): void {
    if (!this.ready || this.busy) {
      return;
    }
    if (this.selectedDeviceId.length === 0 || this.selectedDeviceName.length === 0) {
      this.openDevicePicker();
      return;
    }
    if (isCarPlaySessionActive(this.state)) {
      return;
    }
    if (this.carPlayEnabled) {
      void carPlaySessionController.start().catch((error: Error) => {
        showPageError(this.getUIContext(), '连接接收端', error);
      });
    } else {
      void carPlaySessionController.setEnabled(true).catch((error: Error) => {
        showPageError(this.getUIContext(), '连接接收端', error);
      });
    }
  }

  private openDevicePicker(): void {
    void this.getUIContext().getRouter().pushUrl({ url: 'pages/DevicePicker' }).catch((error: Error) => {
      showPageError(this.getUIContext(), '选择接收端', error);
    });
  }

  private statusDetail(): string {
    switch (this.state) {
      case 'connecting': return '正在连接所选接收端，或等待接收端回连';
      case 'bluetooth-connected': return '蓝牙通道已连接，CarPlay 尚未建立';
      case 'iap2-negotiating': return '正在协商 iAP2 链路，CarPlay 尚未建立';
      case 'iap2-ready': return 'iAP2 已就绪，等待车机网络信息';
      case 'mfi-authenticating': return '已读取车机身份，正在验证 MFi 证书与 challenge 签名';
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
          Text('CarPlayer')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
          Text('Harmony 无线 CarPlay 发送端')
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
          Divider().color($r('app.color.divider'))
          Row({ space: 12 }) {
            Row({ space: 12 }) {
              Text('设备')
                .fontSize(18)
                .fontColor($r('app.color.primary_text'))
              Text(this.selectedDeviceName.length > 0 ? this.selectedDeviceName : '选择接收端')
                .fontSize(15)
                .fontColor($r('app.color.secondary_text'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .layoutWeight(1)
            .height('100%')
            .accessibilityText('设备，点击选择接收端')
            .onClick(() => this.openDevicePicker())
            Button(this.selectedDeviceId.length === 0 ? '选择' :
              isCarPlaySessionActive(this.state) ? '已连接' : '连接')
              .enabled(this.ready && !this.busy && !isCarPlaySessionActive(this.state))
              .onClick(() => this.connectOrChooseDevice())
          }
          .width('100%')
          .height(48)
          if (this.state === 'waiting-video') {
            Text('开始后仅投送 CarPlayer 的虚拟屏界面；不会采集手机物理屏幕或其他应用内容。')
              .fontSize(12)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
            Button('开始投屏')
              .enabled(!this.busy)
              .width('100%')
              .onClick(() => {
                void carPlaySessionController.startProjection().catch((error: Error) => {
                  showPageError(this.getUIContext(), '开始投屏', error);
                });
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
