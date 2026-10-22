import { PageHeader, showPageError } from '../components/PageHeader';
import { CarPlaySettings } from '../app/settings/CarPlaySettings';
import { carPlaySettings } from '../platform/settings/HarmonySettings';
import { carPlaySessionController, isCarPlaySessionActive } from '../app/session/CarPlaySessionController';
import { PairedAccessory } from '../platform/bluetooth/HarmonySppClient';

@Entry
@Component
struct Settings {
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private active: boolean = false;
  @State private fileBusy: boolean = false;
  @State private pinBusy: boolean = false;
  @State private trustedMfiFingerprints: string[] = [];
  @State private error: string = '';
  @State private localAddress: string = '';
  @State private deviceName: string = '';
  @State private targetId: string = '';
  @State private targetName: string = '';
  @State private systemAddress: string = '';
  @State private identitySource: string = 'unavailable';
  @State private ssid: string = '';
  @State private password: string = '';
  @State private security: number = 2;
  @State private channel: string = '0';
  @State private host: string = '';
  @State private port: string = '7000';
  @State private targetOptions: SelectOption[] = [];
  @State private targetIndex: number = -1;
  private devices: PairedAccessory[] = [];
  private draftLoaded: boolean = false;
  private unsubscribeSettings: (() => void) | undefined = undefined;
  private unsubscribeSession: (() => void) | undefined = undefined;
  private readonly securityOptions: SelectOption[] = [{ value: 'WPA/WPA2 PSK' }, { value: 'WPA3 SAE' }, { value: '开放网络' }];

  aboutToAppear(): void {
    this.draftLoaded = false;
    this.unsubscribeSettings = carPlaySettings.subscribe((snapshot) => {
      this.ready = snapshot.ready;
      this.busy = snapshot.busy;
      this.error = snapshot.error;
      this.trustedMfiFingerprints = snapshot.trustedMfiFingerprints;
      if (snapshot.ready && !this.draftLoaded) {
        this.loadDraft(snapshot.settings);
      }
    });
    this.unsubscribeSession = carPlaySessionController.subscribe((snapshot) => {
      this.active = isCarPlaySessionActive(snapshot.state);
      this.systemAddress = snapshot.systemBluetoothAddress;
      this.identitySource = snapshot.identitySource;
      this.devices = snapshot.devices;
      this.targetOptions = this.devices.map((device: PairedAccessory): SelectOption => { return { value: device.name }; });
      this.targetIndex = this.devices.findIndex((device: PairedAccessory) => device.deviceId === this.targetId);
    });
  }
  aboutToDisappear(): void {
    this.unsubscribeSettings?.();
    this.unsubscribeSession?.();
    this.unsubscribeSettings = undefined;
    this.unsubscribeSession = undefined;
  }

  private loadDraft(settings: CarPlaySettings): void {
    this.localAddress = settings.localBluetoothAddress;
    this.deviceName = settings.deviceName;
    this.targetId = settings.targetDeviceId;
    this.targetName = settings.targetDeviceName;
    this.ssid = settings.wifi.ssid;
    this.password = carPlaySettings.password();
    this.security = settings.wifi.securityType;
    this.channel = `${settings.wifi.channel}`;
    this.host = settings.airplay.host;
    this.port = `${settings.airplay.port}`;
    this.targetIndex = this.devices.findIndex((device: PairedAccessory) => device.deviceId === this.targetId);
    this.draftLoaded = true;
  }

  private editable(): boolean { return this.ready && !this.busy && !this.active && !this.fileBusy; }
  private number(value: string, field: string): number {
    if (!/^\d+$/.test(value)) {
      throw new Error(`${field} 必须填写整数。`);
    }
    return Number(value);
  }
  private async save(): Promise<void> {
    try {
      const settings = carPlaySettings.snapshot().settings;
      settings.localBluetoothAddress = this.localAddress;
      settings.deviceName = this.deviceName;
      settings.targetDeviceId = this.targetId;
      settings.targetDeviceName = this.targetName;
      settings.wifi = { ssid: this.ssid, securityType: this.security, channel: this.number(this.channel, '信道') };
      settings.airplay = { host: this.host, port: this.number(this.port, '端口') };
      await carPlaySettings.save(settings, this.password);
      this.loadDraft(carPlaySettings.snapshot().settings);
      const warning = carPlaySettings.snapshot().error;
      this.getUIContext().getPromptAction().showToast({ message: warning || '设置已保存，下次连接生效。' });
    } catch (error) {
      showPageError(this.getUIContext(), '保存设置', error);
    }
  }
  private async importConfiguration(): Promise<void> {
    this.fileBusy = true;
    try {
      const imported = await carPlaySettings.importConfiguration();
      if (imported) {
        this.loadDraft(carPlaySettings.snapshot().settings);
      }
      this.getUIContext().getPromptAction().showToast({
        message: imported ? '导入成功，CarPlay 开关已关闭；新网络的密码需另行填写。' : '已取消导入。'
      });
    } catch (error) {
      showPageError(this.getUIContext(), '导入配置', error);
    } finally {
      this.fileBusy = false;
    }
  }
  private async exportConfiguration(): Promise<void> {
    this.fileBusy = true;
    try {
      const exported = await carPlaySettings.exportConfiguration();
      this.getUIContext().getPromptAction().showToast({ message: exported ? '配置已导出，不含密码。' : '已取消导出。' });
    } catch (error) {
      showPageError(this.getUIContext(), '导出配置', error);
    } finally {
      this.fileBusy = false;
    }
  }
  private async revokeMfiFingerprint(fingerprint: string): Promise<void> {
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '撤销 MFi 证书信任',
        message: `撤销指纹 ${fingerprint} 后，下次连接该证书时需要重新验证或确认信任。`,
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '撤销信任', color: '#D32F2F' }
        ]
      });
      if (result.index !== 1) {
        return;
      }
      this.pinBusy = true;
      await carPlaySettings.removeTrustedMfiFingerprint(fingerprint);
      this.getUIContext().getPromptAction().showToast({ message: '已撤销 MFi 证书信任。' });
    } catch (error) {
      showPageError(this.getUIContext(), '撤销 MFi 信任', error);
    } finally {
      this.pinBusy = false;
    }
  }
  private refreshDevices(): void {
    void carPlaySessionController.refreshAccessories().catch((error: Error) => {
      showPageError(this.getUIContext(), '刷新配对设备', error);
    });
  }

  @Builder
  private section(title: string, hint: string) {
    Text(title).fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.primary_text'))
      .width('100%').margin({ top: 18 })
    Text(hint).fontSize(12).fontColor($r('app.color.secondary_text')).width('100%')
  }
  @Builder
  private label(title: string) {
    Text(title).fontSize(14).fontColor($r('app.color.primary_text')).width('100%')
  }

  build() {
    Column({ space: 8 }) {
      PageHeader({ title: '设置' })
      Scroll() {
        Column({ space: 12 }) {
          if (this.active) {
            Text('连接中仅可查看。请先关闭主页 CarPlay 开关再修改配置。')
              .fontSize(13).fontColor($r('app.color.warning'))
          }
          if (this.error.length > 0) {
            Text(this.error).fontSize(13).fontColor($r('app.color.danger'))
          }
          this.section('本机身份', '自动获取优先。手动地址必须是本人手机的真实蓝牙地址，不是车机地址；普通权限无法自动核实该地址是否属于本机。')
          if (this.systemAddress.length > 0) {
            Text(`已自动读取：${this.systemAddress}`).fontSize(14).fontColor($r('app.color.accent'))
          } else {
            Text(this.identitySource === 'manual' ? '当前使用已保存的手动备用地址。' : '尚未自动获取本机地址，可填写备用地址。')
              .fontSize(13).fontColor($r('app.color.secondary_text'))
          }
          this.label('本机蓝牙地址（备用）')
          TextInput({ text: this.localAddress, placeholder: '例如 10:20:30:AA:BB:CC' })
            .enabled(this.editable() && this.systemAddress.length === 0)
            .maxLength(32)
            .onChange((value: string) => { this.localAddress = value; })
          Button('检测已保存的身份')
            .enabled(this.editable())
            .onClick(() => {
              void carPlaySessionController.checkBluetoothIdentity().catch((error: Error) => {
                showPageError(this.getUIContext(), '检测身份', error);
              });
            })
          this.label('发送端设备名')
          TextInput({ text: this.deviceName, placeholder: 'Harmony CarPlay' })
            .enabled(this.editable()).maxLength(64)
            .onChange((value: string) => { this.deviceName = value; })

          this.section('目标接收端', '先在系统设置配对，刷新后选择车机或 DiPlay，并保存设置。不会自动连接其他已配对设备。')
          Button('刷新已配对设备').enabled(this.editable()).onClick(() => this.refreshDevices())
          Select(this.targetOptions)
            .selected(this.targetIndex)
            .value(this.targetIndex >= 0 ? this.targetOptions[this.targetIndex].value :
              this.targetName || (this.targetId.length > 0 ? '已保存目标（当前未出现在配对列表）' : '请选择接收端'))
            .enabled(this.editable())
            .width('100%')
            .onSelect((index: number) => {
              const target = this.devices[index];
              if (target === undefined) {
                showPageError(this.getUIContext(), '选择接收端', new Error('配对设备列表已变化，请重新刷新。'));
                return;
              }
              this.targetId = target.deviceId;
              this.targetName = target.name;
              this.targetIndex = index;
            })

          this.section('备用车机 Wi-Fi', 'SSID 留空则不启用。仅在 iAP2 网络信息缺失或等待超时后使用；不绕过蓝牙协商。密码单独存入系统安全存储。')
          this.label('SSID')
          TextInput({ text: this.ssid, placeholder: '车机热点名称' }).enabled(this.editable())
            .onChange((value: string) => { this.ssid = value; })
          this.label('安全类型')
          Select(this.securityOptions)
            .selected(this.security === 4 ? 1 : this.security === 0 ? 2 : 0)
            .value(this.security === 4 ? 'WPA3 SAE' : this.security === 0 ? '开放网络' : 'WPA/WPA2 PSK')
            .width('100%').enabled(this.editable())
            .onSelect((index: number) => { this.security = index === 0 ? 2 : index === 1 ? 4 : 0; })
          this.label('Wi-Fi 密码（留空会清除已保存密码）')
          TextInput({ text: this.password, placeholder: '不写入日志或配置导出文件' })
            .type(InputType.Password).enabled(this.editable()).maxLength(64)
            .onChange((value: string) => { this.password = value; })
          this.label('信道（0 表示自动）')
          TextInput({ text: this.channel }).type(InputType.Number).enabled(this.editable())
            .onChange((value: string) => { this.channel = value; })

          this.section('备用 AirPlay 端点', 'IP 留空则不启用。有效的 iAP2/mDNS 结果优先；备用端点也必须等待真实车机邀请，不会跳过配对。')
          this.label('IP 地址')
          TextInput({ text: this.host, placeholder: 'IPv4 或 IPv6，可带 %wlan0 scope' }).enabled(this.editable())
            .onChange((value: string) => { this.host = value; })
          this.label('端口')
          TextInput({ text: this.port }).type(InputType.Number).enabled(this.editable())
            .onChange((value: string) => { this.port = value; })
          Button(this.busy ? '保存中' : '保存设置')
            .enabled(this.editable()).width('100%').onClick(() => { void this.save(); })

          this.section('配置 JSON', '导出只包含已保存的非密码配置，包括蓝牙地址和设备/网络信息，请谨慎分享。导入严格校验，失败不会覆盖原配置；导入成功后关闭开关，新网络密码需另填。')
          Row({ space: 12 }) {
            Button(this.ready ? '导入配置' : '导入配置恢复')
              .enabled(!this.busy && !this.active && !this.fileBusy)
              .onClick(() => { void this.importConfiguration(); })
            Button('导出配置').enabled(this.ready && !this.busy && !this.fileBusy)
              .onClick(() => { void this.exportConfiguration(); })
          }
          .width('100%')
          Text('私钥、证书、配对证明和系统权限不属于可手填配置。')
            .fontSize(12).fontColor($r('app.color.secondary_text')).width('100%')

          this.section('MFi 证书信任', '仅对你确认过 SHA-256 指纹的车机证书保存本机信任。指纹不会随设置 JSON 导出。')
          if (this.trustedMfiFingerprints.length === 0) {
            Text('尚无已确认的 MFi 证书指纹。')
              .fontSize(13).fontColor($r('app.color.secondary_text')).width('100%')
          }
          ForEach(this.trustedMfiFingerprints, (fingerprint: string) => {
            Column({ space: 8 }) {
              Text(fingerprint).fontSize(12).fontColor($r('app.color.primary_text')).width('100%')
              Button('撤销此证书信任')
                .enabled(!this.active && !this.busy && !this.pinBusy && !this.fileBusy)
                .onClick(() => { void this.revokeMfiFingerprint(fingerprint); })
            }
            .width('100%')
            .padding(12)
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(10)
          }, (fingerprint: string) => fingerprint)
        }
        .width('100%')
        .padding({ bottom: 32 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .padding({ left: 24, right: 24, top: 20, bottom: 16 })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
