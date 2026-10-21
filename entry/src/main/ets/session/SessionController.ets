import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { AirPlayMdnsDiscovery, AirPlayService } from '../network/AirPlayMdnsDiscovery';
import { AirPlayRtspProbe } from '../network/AirPlayRtspProbe';
import { CarPlayCtrlAdvertiser } from '../network/CarPlayCtrlAdvertiser';
import { WifiCarPlayConnector } from '../network/WifiCarPlayConnector';
import { BluetoothIap2Server } from '../transport/BluetoothIap2Server';
import { Iap2SenderSession, WifiCredentials } from './Iap2SenderSession';

export interface SessionEvents {
  onStatus: (status: string) => void;
  onLog: (message: string) => void;
  onWifiCredentials: (credentials: WifiCredentials) => void;
  onAirPlayService: (service: AirPlayService) => void;
}

export class SessionController {
  private readonly context: common.UIAbilityContext;
  private readonly events: SessionEvents;
  private readonly bluetooth: BluetoothIap2Server = new BluetoothIap2Server();
  private readonly wifi: WifiCarPlayConnector = new WifiCarPlayConnector();
  private readonly rtspProbe: AirPlayRtspProbe = new AirPlayRtspProbe();
  private discovery?: AirPlayMdnsDiscovery;
  private ctrlAdvertiser?: CarPlayCtrlAdvertiser;
  private discoveredAirPlay?: AirPlayService;
  private iap2?: Iap2SenderSession;
  private credentials?: WifiCredentials;
  private running: boolean = false;
  private inviteReceived: boolean = false;
  private readonly deviceAddress: string;
  private readonly deviceName: string;
  private readonly deviceUuid: string;
  private readonly keepScreenOn: boolean;
  private readonly allowMfiIntermediateDownload: boolean;

  constructor(
    context: common.UIAbilityContext,
    events: SessionEvents,
    deviceAddress: string,
    deviceName: string,
    deviceUuid: string,
    keepScreenOn: boolean,
    allowMfiIntermediateDownload: boolean = false
  ) {
    this.context = context;
    this.events = events;
    this.deviceAddress = deviceAddress;
    this.deviceName = deviceName;
    this.deviceUuid = deviceUuid;
    this.keepScreenOn = keepScreenOn;
    this.allowMfiIntermediateDownload = allowMfiIntermediateDownload;
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    await this.requestPermissions(['ohos.permission.ACCESS_BLUETOOTH']);
    await this.bluetooth.start(
      () => this.handleBluetoothConnected(),
      (bytes: Uint8Array) => this.handleBluetoothData(bytes),
      (message: string) => this.reportError(message)
    );
    this.running = true;
    await this.setKeepScreenOn(true);
    this.events.onStatus('蓝牙 RFCOMM 监听中，等待已配对车机连接');
    this.events.onLog('蓝牙监听已启动；请在车机侧发起无线 CarPlay 连接');
  }

  async stop(): Promise<void> {
    this.running = false;
    const failures: string[] = [];
    try {
      this.discovery?.stop();
    } catch (error) {
      failures.push(`mDNS 停止失败：${error instanceof Error ? error.message : String(error)}`);
    }
    this.discovery = undefined;
    if (this.ctrlAdvertiser) {
      try {
        await this.ctrlAdvertiser.stop();
      } catch (error) {
        failures.push(`控制广播停止失败：${error instanceof Error ? error.message : String(error)}`);
      }
      this.ctrlAdvertiser = undefined;
    }
    this.iap2?.cancel();
    try {
      this.bluetooth.stop();
    } catch (error) {
      failures.push(`蓝牙监听停止失败：${error instanceof Error ? error.message : String(error)}`);
    }
    this.iap2 = undefined;
    this.credentials = undefined;
    this.discoveredAirPlay = undefined;
    this.inviteReceived = false;
    await this.setKeepScreenOn(false);
    this.events.onStatus(failures.length > 0 ? '已停止，但部分资源清理失败' : '已停止');
    this.events.onLog(failures.length > 0 ? `会话停止时出现错误：${failures.join('；')}` : '会话已停止');
    if (failures.length > 0) {
      throw new Error(failures.join('；'));
    }
  }

  setManualWifi(ssid: string, password: string): void {
    if (!ssid.trim()) {
      throw new Error('请输入车机热点名称');
    }
    const normalizedSsid = ssid.trim();
    if (this.credentials && this.credentials.ssid === normalizedSsid) {
      this.credentials.password = password;
      return;
    }
    this.credentials = { ssid: normalizedSsid, password, securityType: 2, channel: 0 };
  }

  async joinVehicleWifi(): Promise<void> {
    if (!this.credentials) {
      throw new Error('尚未收到车机热点配置，请填写热点名称和密码');
    }
    await this.requestPermissions([
      'ohos.permission.SET_WIFI_INFO',
      'ohos.permission.GET_WIFI_INFO'
    ]);
    this.events.onStatus(`正在请求加入车机热点 ${this.credentials.ssid}`);
    const result = await this.wifi.connect(this.credentials);
    this.events.onStatus(`已连接车机热点 ${result.ssid} (${result.ipAddress})`);
    this.events.onLog(`Wi-Fi 已连接，本机地址 ${result.ipAddress}`);
    if (this.iap2?.isAccessoryVerified) {
      await this.iap2.onWifiConnected();
    } else if (this.iap2) {
      this.events.onLog('Wi-Fi 已连接，但车机 MFi 验证未完成；未发送 CarPlay 会话启动消息');
    }
    await this.startControlAdvertisement();
    this.startAirPlayDiscovery();
  }

  private async requestPermissions(permissions: Array<
    'ohos.permission.ACCESS_BLUETOOTH' | 'ohos.permission.SET_WIFI_INFO' | 'ohos.permission.GET_WIFI_INFO'
  >): Promise<void> {
    const manager = abilityAccessCtrl.createAtManager();
    await new Promise<void>((resolve, reject) => {
      manager.requestPermissionsFromUser(this.context, permissions, (error, result) => {
        if (error) {
          reject(new Error(`权限请求失败 (${error.code}): ${error.message}`));
          return;
        }
        const denied: string[] = [];
        for (let index = 0; index < result.permissions.length; index++) {
          if (result.authResults[index] !== 0) {
            denied.push(result.permissions[index]);
          }
        }
        if (denied.length > 0) {
          reject(new Error(`未获授权：${denied.join('、')}。请在系统设置中授予后重试`));
          return;
        }
        resolve();
      });
    });
  }

  private handleBluetoothConnected(): void {
    this.events.onStatus('车机已连接，正在协商 iAP2');
    this.events.onLog('已接受 RFCOMM 连接');
    this.iap2?.cancel();
    this.iap2 = new Iap2SenderSession(
      (bytes: Uint8Array): Promise<void> => this.bluetooth.send(bytes),
      (message: string): void => this.events.onLog(message),
      (credentials: WifiCredentials): void => {
        this.credentials = credentials;
        this.events.onWifiCredentials(credentials);
        this.events.onStatus(`已收到车机热点配置：${credentials.ssid}；点击“加入车机热点”继续`);
      },
      (body: Uint8Array): void => {
        this.events.onLog(`收到 CarPlay 会话端点 (${body.length} 字节)，等待 mDNS 服务发现`);
      },
      this.deviceAddress,
      this.deviceName,
      this.deviceUuid,
      this.allowMfiIntermediateDownload
    );
    void this.iap2.start().catch((error: Error): void => this.reportError(error.message));
  }

  private handleBluetoothData(bytes: Uint8Array): void {
    if (!this.iap2) {
      this.events.onLog('忽略会话初始化前到达的数据');
      return;
    }
    void this.iap2.receive(bytes).catch((error: Error): void => this.reportError(error.message));
  }

  private startAirPlayDiscovery(): void {
    if (this.discovery) {
      this.discovery.stop();
    }
    this.discovery = new AirPlayMdnsDiscovery(
      this.context,
      (service: AirPlayService): void => {
        this.discoveredAirPlay = service;
        this.events.onAirPlayService(service);
        this.events.onStatus(`发现 AirPlay 接收端 ${service.host}:${service.port}`);
        this.events.onLog(`发现 ${service.name}，TXT 项 ${Object.keys(service.txt).length} 个`);
        if (this.inviteReceived) {
          void this.probeAirPlay().catch((error: Error): void => this.reportError(error.message));
        }
      },
      (message: string): void => this.events.onLog(message)
    );
    this.discovery.start();
    this.events.onLog('正在发现 _airplay._tcp 服务');
  }

  private async startControlAdvertisement(): Promise<void> {
    if (this.ctrlAdvertiser) {
      await this.ctrlAdvertiser.stop();
    }
    this.inviteReceived = false;
    const advertiser = new CarPlayCtrlAdvertiser(
      this.context,
      this.deviceAddress,
      (): void => {
        this.inviteReceived = true;
        this.events.onStatus('车机已邀请控制连接，等待 AirPlay 接收端地址');
        if (this.discoveredAirPlay) {
          void this.probeAirPlay().catch((error: Error): void => this.reportError(error.message));
        }
      },
      (message: string): void => this.events.onLog(message)
    );
    this.ctrlAdvertiser = advertiser;
    await advertiser.start();
  }

  private async probeAirPlay(): Promise<void> {
    const service = this.discoveredAirPlay;
    if (!service || !this.inviteReceived) {
      return;
    }
    this.events.onStatus(`正在探测 AirPlay 控制端点 ${service.host}:${service.port}`);
    const statusLine = await this.rtspProbe.probe(service);
    this.events.onStatus(`AirPlay RTSP 可达：${statusLine}`);
    this.events.onLog(`AirPlay RTSP 探测结果：${statusLine}；尚未执行配对或流协商`);
  }

  private reportError(message: string): void {
    this.events.onStatus(`错误：${message}`);
    this.events.onLog(`错误：${message}`);
  }

  private async setKeepScreenOn(keepScreenOn: boolean): Promise<void> {
    if (!this.keepScreenOn) {
      return;
    }
    try {
      const appWindow = await window.getLastWindow(this.context);
      await appWindow.setWindowKeepScreenOn(keepScreenOn);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.events.onLog(`常亮设置失败：${message}`);
    }
  }
}
