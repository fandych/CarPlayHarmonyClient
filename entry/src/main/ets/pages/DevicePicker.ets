import { PageHeader, showPageError } from '../components/PageHeader';
import { isCarPlaySessionActive, carPlaySessionController } from '../app/session/CarPlaySessionController';
import { PairedAccessory } from '../platform/bluetooth/HarmonySppClient';
import { carPlaySettings } from '../platform/settings/HarmonySettings';

@Entry
@Component
struct DevicePicker {
  @State private devices: PairedAccessory[] = [];
  @State private selectedDeviceId: string = '';
  @State private active: boolean = false;
  @State private busy: boolean = false;
  @State private refreshing: boolean = false;
  @State private error: string = '';
  private unsubscribeSession: (() => void) | undefined = undefined;
  private unsubscribeSettings: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.unsubscribeSession = carPlaySessionController.subscribe((snapshot) => {
      this.devices = snapshot.devices;
      this.active = isCarPlaySessionActive(snapshot.state);
    });
    this.unsubscribeSettings = carPlaySettings.subscribe((snapshot) => {
      this.selectedDeviceId = snapshot.settings.targetDeviceId;
      this.busy = snapshot.busy;
    });
    if (!this.active) {
      this.refreshDevices();
    }
  }

  aboutToDisappear(): void {
    this.unsubscribeSession?.();
    this.unsubscribeSettings?.();
    this.unsubscribeSession = undefined;
    this.unsubscribeSettings = undefined;
  }

  private refreshDevices(): void {
    if (this.active || this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.error = '';
    void carPlaySessionController.refreshAccessories().catch((error: Error) => {
      this.error = error.message;
      showPageError(this.getUIContext(), '刷新配对设备', error);
    }).finally(() => {
      this.refreshing = false;
    });
  }

  private async chooseDevice(device: PairedAccessory): Promise<void> {
    if (this.active || this.busy) {
      return;
    }
    try {
      const settings = carPlaySettings.snapshot().settings;
      settings.targetDeviceId = device.deviceId;
      settings.targetDeviceName = device.name;
      await carPlaySettings.save(settings, carPlaySettings.password());
      this.getUIContext().getPromptAction().showToast({ message: `已选择 ${device.name}` });
      this.getUIContext().getRouter().back();
    } catch (error) {
      showPageError(this.getUIContext(), '保存接收端', error);
    }
  }

  build() {
    Column({ space: 12 }) {
      PageHeader({ title: '选择设备' })
      Text('只显示系统中已配对的设备。选择车机或 DiPlay 后，返回主页可点击设备名称连接。')
        .fontSize(13)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
      if (this.active) {
        Text('连接期间不能更换设备，请先关闭主页 CarPlay 开关。')
          .fontSize(13)
          .fontColor($r('app.color.warning'))
          .width('100%')
      }
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(13)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
      Button(this.refreshing ? '正在刷新…' : '刷新已配对设备')
        .enabled(!this.active && !this.refreshing && !this.busy)
        .width('100%')
        .onClick(() => this.refreshDevices())
      Scroll() {
        Column() {
          if (this.devices.length === 0) {
            Text(this.refreshing ? '正在读取设备…' : '未找到已配对设备。请先在系统蓝牙设置中配对车机或 DiPlay，再刷新。')
              .fontSize(14)
              .fontColor($r('app.color.secondary_text'))
              .width('100%')
              .padding(16)
          }
          ForEach(this.devices, (device: PairedAccessory) => {
            Column() {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text(device.name)
                    .fontSize(16)
                    .fontColor($r('app.color.primary_text'))
                  Text(device.deviceId)
                    .fontSize(11)
                    .fontColor($r('app.color.secondary_text'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(device.deviceId === this.selectedDeviceId ? '已选择' : '选择')
                  .fontSize(14)
                  .fontColor(device.deviceId === this.selectedDeviceId ?
                    $r('app.color.accent') : $r('app.color.secondary_text'))
              }
              .width('100%')
              .padding(16)
              .onClick(() => { void this.chooseDevice(device); })
              Divider().color($r('app.color.divider'))
            }
          }, (device: PairedAccessory) => device.deviceId)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
      }
      .layoutWeight(1)
      .width('100%')
    }
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
