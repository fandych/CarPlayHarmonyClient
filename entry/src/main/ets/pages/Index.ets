import { carPlaySessionController, CarPlaySessionState, isCarPlaySessionActive } from '../app/session/CarPlaySessionController';
import { PairedAccessory } from '../platform/bluetooth/HarmonySppClient';
import { describeFailure } from '../platform/diagnostics/DiagnosticFormat';

@Entry
@Component
struct Index {
  @State private isCarPlayEnabled: boolean = false;
  @State private sessionState: CarPlaySessionState = 'idle';
  @State private logs: string[] = [];
  @State private deviceOptions: SelectOption[] = [];
  @State private selectedDeviceIndex: number = -1;
  @State private blockedReason: string = '';
  @State private logFailure: string = '';
  @State private logOptions: SelectOption[] = [];
  @State private selectedLogIndex: number = 0;
  @State private exporting: boolean = false;
  private devices: PairedAccessory[] = [];
  private logNames: string[] = [];
  private logSession: string = '';
  private unsubscribe: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribe = carPlaySessionController.subscribe((snapshot) => {
      this.sessionState = snapshot.state;
      this.isCarPlayEnabled = isCarPlaySessionActive(snapshot.state);
      this.logs = snapshot.logs;
      this.devices = snapshot.devices;
      this.deviceOptions = snapshot.devices.map((device: PairedAccessory): SelectOption => {
        return { value: device.name };
      });
      this.selectedDeviceIndex = snapshot.devices.findIndex((device: PairedAccessory) =>
        device.deviceId === snapshot.selectedDeviceId);
      this.blockedReason = snapshot.blockedReason;
      this.logFailure = snapshot.logFailure;
      if (this.logSession !== snapshot.logSession) {
        this.logSession = snapshot.logSession;
        this.refreshLogSessions();
      }
    });
  }

  private showFailure(stage: string, error: Error): void {
    carPlaySessionController.reportActionFailure(stage, error);
    this.getUIContext().getPromptAction().showToast({ message: `${stage}失败：${describeFailure(error)}` });
  }

  private refreshLogSessions(): void {
    try {
      this.logNames = carPlaySessionController.logSessions();
      this.logOptions = this.logNames.map((name: string): SelectOption => {
        return { value: `${name === this.logSession ? '当前 · ' : ''}${name}` };
      });
      this.selectedLogIndex = 0;
    } catch (error) {
      this.showFailure('读取日志列表', error);
    }
  }

  private async refreshAccessories(): Promise<void> {
    try {
      await carPlaySessionController.refreshAccessories();
    } catch (error) {
      this.showFailure('刷新配对设备', error);
    }
  }

  private async exportLog(): Promise<void> {
    const name = this.logNames[this.selectedLogIndex];
    if (name === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: '暂无可导出的日志文件。' });
      return;
    }
    this.exporting = true;
    try {
      const saved = await carPlaySessionController.exportLogs(name);
      this.getUIContext().getPromptAction().showToast({
        message: saved ? '日志已保存；如有持久化错误，请检查不完整提示。' : '已取消保存日志。'
      });
    } catch (error) {
      this.showFailure('导出日志', error);
    } finally {
      this.exporting = false;
    }
  }

  aboutToDisappear(): void {
    if (this.unsubscribe !== undefined) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
  }

  private onSwitchChanged(enabled: boolean): void {
    if (enabled === isCarPlaySessionActive(this.sessionState)) {
      return;
    }
    this.isCarPlayEnabled = enabled;
    if (enabled) {
      void carPlaySessionController.start();
    } else {
      carPlaySessionController.stop();
    }
  }

  private statusLabel(): string {
    switch (this.sessionState) {
      case 'connecting':
        return '正在连接所选接收端／等待回连';
      case 'bluetooth-connected':
        return '蓝牙通道已连接';
      case 'iap2-negotiating':
        return 'iAP2 链路协商中';
      case 'iap2-ready':
        return 'iAP2 链路已就绪 · CarPlay 尚未建立';
      case 'wifi-pending':
        return 'Wi-Fi 配置已收到 · CarPlay 尚未建立';
      case 'wifi-connected':
        return '车机热点已连接 · AirPlay 尚未建立';
      case 'airplay-found':
        return 'AirPlay 服务已发现 · CarPlay 尚未建立';
      case 'error':
        return '连接失败';
      case 'blocked':
        return '能力受限 · 无线 CarPlay 被阻塞';
      default:
        return '未连接';
    }
  }

  private statusColor(): string {
    switch (this.sessionState) {
      case 'bluetooth-connected':
        return '#F3B75F';
      case 'connecting':
        return '#77A9FF';
      case 'error':
        return '#FF7777';
      case 'blocked':
        return '#F3B75F';
      default:
        return '#8994A8';
    }
  }

  build() {
    Column({ space: 18 }) {
      Column({ space: 8 }) {
        Text('CARPLAY')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#8FAEFF')
          .letterSpacing(2)
        Text('Harmony Client')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F4F6FB')
        Text('无线连接控制台')
          .fontSize(14)
          .fontColor('#919CB0')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 8 }) {
        Row() {
          Text('已配对的接收端')
            .fontSize(14)
            .fontColor('#C2CBD9')
          Blank()
          Button('检测身份')
            .fontSize(12)
            .enabled(!this.isCarPlayEnabled)
            .onClick(() => {
              void carPlaySessionController.checkBluetoothIdentity().catch((error: Error) => {
                this.showFailure('检测蓝牙身份', error);
              });
            })
          Button('刷新')
            .fontSize(12)
            .enabled(!this.isCarPlayEnabled)
            .onClick(() => { void this.refreshAccessories(); })
        }
        Select(this.deviceOptions)
          .selected(this.selectedDeviceIndex)
          .value(this.selectedDeviceIndex >= 0 ? this.deviceOptions[this.selectedDeviceIndex].value : '请刷新并选择车机或 DiPlay')
          .fontColor('#C2CBD9')
          .width('100%')
          .enabled(!this.isCarPlayEnabled)
          .onSelect((index: number) => {
            try {
              carPlaySessionController.selectAccessory(this.devices[index].deviceId);
            } catch (error) {
              this.showFailure('选择接收端', error);
            }
          })
      }
      .width('100%')

      Row() {
        Column({ space: 6 }) {
          Text('CarPlay 连接')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F4F6FB')
          Text('只连接所选设备，同时支持接收端回连')
            .fontSize(13)
            .fontColor('#919CB0')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.isCarPlayEnabled })
          .accessibilityText('CarPlay 连接开关')
          .onChange((value: boolean) => this.onSwitchChanged(value))
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#151E2D')
      .borderRadius(18)

      Column({ space: 12 }) {
        Text('连接状态')
          .fontSize(13)
          .fontColor('#919CB0')
        Row({ space: 9 }) {
          Circle()
            .width(9)
            .height(9)
            .fill(this.statusColor())
          Text(this.statusLabel())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.statusColor())
        }
        .width('100%')
        if (this.blockedReason.length > 0) {
          Text(this.blockedReason)
            .fontSize(12)
            .fontColor('#F3B75F')
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(18)
      .backgroundColor('#151E2D')
      .borderRadius(18)

      Column({ space: 12 }) {
        Row() {
          Text('运行日志')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#F4F6FB')
          Blank()
          Text(`${this.logs.length} 条`)
            .fontSize(12)
            .fontColor('#8994A8')
        }
        .width('100%')

        Row({ space: 8 }) {
          Select(this.logOptions)
            .selected(this.selectedLogIndex)
            .value(this.logOptions[this.selectedLogIndex]?.value ?? '暂无日志')
            .font({ size: 11 })
            .fontColor('#C2CBD9')
            .layoutWeight(1)
            .enabled(!this.exporting)
            .onSelect((index: number) => { this.selectedLogIndex = index; })
          Button(this.exporting ? '保存中' : '导出')
            .fontSize(12)
            .enabled(!this.exporting && this.logNames.length > 0)
            .onClick(() => { void this.exportLog(); })
          Button('刷新')
            .fontSize(12)
            .enabled(!this.exporting)
            .onClick(() => this.refreshLogSessions())
        }
        .width('100%')
        Text('界面仅显示最近 250 条；导出读取完整文件，保留最近 10 次会话。')
          .fontSize(11)
          .fontColor('#8994A8')
        if (this.logFailure.length > 0) {
          Text(`日志存储失败，文件可能不完整：${this.logFailure}`)
            .fontSize(12)
            .fontColor('#FF7777')
        }

        Scroll() {
          Column({ space: 8 }) {
            if (this.logs.length === 0) {
              Text('开启连接后，运行状态和错误信息会显示在这里。')
                .fontSize(13)
                .fontColor('#8994A8')
                .width('100%')
            } else {
              ForEach(this.logs, (line: string, index: number) => {
                Text(line)
                  .fontSize(12)
                  .fontColor('#C2CBD9')
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }, (line: string, index: number) => `${index}-${line}`)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .layoutWeight(1)
      .width('100%')
      .padding(18)
      .backgroundColor('#151E2D')
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 22, right: 22, top: 28, bottom: 20 })
    .backgroundColor('#0B111C')
  }
}
