import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { HarmonySppClient, PairedAccessory, SppConnection } from '../../platform/bluetooth/HarmonySppClient';
import { HarmonyBluetoothIdentityProvider } from '../../platform/bluetooth/HarmonyBluetoothIdentityProvider';
import { carPlayDiagnostics } from '../../platform/diagnostics/CarPlayDiagnostics';
import { describeFailure } from '../../platform/diagnostics/DiagnosticFormat';
import { Iap2LinkEngine, Iap2LinkState } from '../../protocol/iap2/Iap2LinkEngine';
import {
  AccessoryWifiConfiguration,
  CarPlayStartSessionEndpoint,
  Iap2SenderSession
} from '../../protocol/iap2/Iap2SenderSession';
import { HarmonyWifiClient } from '../../platform/network/HarmonyWifiClient';
import { AirPlayServiceEndpoint, HarmonyMdnsBrowser } from '../../platform/network/HarmonyMdnsBrowser';
import { HarmonyAirPlayClient } from '../../platform/network/HarmonyAirPlayClient';
import {
  CarPlayInviteServer
} from '../../platform/network/HarmonyCarPlayInviteServer';
import { CarPlayInviteRequest } from '../../protocol/airplay/CarPlayInviteProtocol';

export type CarPlaySessionState =
  'idle' | 'connecting' | 'bluetooth-connected' | 'iap2-negotiating' | 'iap2-ready' |
  'wifi-pending' | 'wifi-connected' | 'airplay-found' | 'blocked' | 'error';

export function isCarPlaySessionActive(state: CarPlaySessionState): boolean {
  return state !== 'idle' && state !== 'error' && state !== 'blocked';
}

export interface CarPlaySessionSnapshot {
  state: CarPlaySessionState;
  logs: string[];
  devices: PairedAccessory[];
  selectedDeviceId: string;
  logSession: string;
  logFailure: string;
  blockedReason: string;
}

type SessionListener = (snapshot: CarPlaySessionSnapshot) => void;

class CarPlaySessionController {
  private static readonly MAX_LOG_LINES = 250;
  private readonly sppClient: HarmonySppClient = new HarmonySppClient();
  private readonly listeners: Set<SessionListener> = new Set<SessionListener>();
  private logs: string[] = [];
  private devices: PairedAccessory[] = [];
  private selectedDeviceId: string = '';
  private settings: preferences.Preferences | undefined = undefined;
  private blockedReason: string = '';
  private identityProvider: HarmonyBluetoothIdentityProvider | undefined = undefined;
  private realBluetoothAddress: string | undefined = undefined;
  private iap2Timer: number | undefined = undefined;
  private state: CarPlaySessionState = 'idle';
  private abilityContext: common.UIAbilityContext | undefined = undefined;
  private generation: number = 0;
  private connection: SppConnection | undefined = undefined;
  private linkEngine: Iap2LinkEngine | undefined = undefined;
  private senderSession: Iap2SenderSession | undefined = undefined;
  private wifiClient: HarmonyWifiClient | undefined = undefined;
  private mdnsBrowser: HarmonyMdnsBrowser | undefined = undefined;
  private inviteServer: CarPlayInviteServer | undefined = undefined;
  private pendingStartSession: CarPlayStartSessionEndpoint | undefined = undefined;
  private latestAirPlayEndpoint: AirPlayServiceEndpoint | undefined = undefined;
  private readonly airPlayProbeKeys: Set<string> = new Set<string>();
  private cleanupPromise: Promise<void> | undefined = undefined;
  private identificationStarted: boolean = false;
  private wifiConnectionStarted: boolean = false;
  private receivedCarPlayInvite: boolean = false;
  private pairingStarted: boolean = false;
  constructor() {
    carPlayDiagnostics.subscribe((line: string) => {
      this.logs.push(line);
      if (this.logs.length > CarPlaySessionController.MAX_LOG_LINES) {
        this.logs.splice(0, this.logs.length - CarPlaySessionController.MAX_LOG_LINES);
      }
      this.notify();
    });
  }

  setContext(context: common.UIAbilityContext): void {
    this.abilityContext = context;
    carPlayDiagnostics.initialize(context.filesDir);
    this.appendLog(`phone=${deviceInfo.productModel}; osBuild=${deviceInfo.osFullName.replace(/\./g, '_')}; sdk=${deviceInfo.sdkApiVersion}`);
    this.blockedReason = '本机蓝牙身份尚未检测；需要系统接口 access.getLocalAddress 及 GET_BLUETOOTH_LOCAL_MAC 系统权限。';
    this.appendLog(this.blockedReason);
    try {
      this.settings = preferences.getPreferencesSync(context, { name: 'carplay-settings' });
      const selected = this.settings.getSync('targetDeviceId', '');
      this.selectedDeviceId = typeof selected === 'string' ? selected : '';
    } catch (error) {
      this.appendLog(`读取接收端设置失败：${describeFailure(error)}`, true);
    }
    this.notify();
  }

  subscribe(listener: SessionListener): () => void {
    this.listeners.add(listener);
    listener(this.snapshot());
    return () => {
      this.listeners.delete(listener);
    };
  }

  snapshot(): CarPlaySessionSnapshot {
    return {
      state: this.state,
      logs: this.logs.slice(),
      devices: this.devices.slice(),
      selectedDeviceId: this.selectedDeviceId,
      logSession: carPlayDiagnostics.currentSession(),
      logFailure: carPlayDiagnostics.failure(),
      blockedReason: this.blockedReason
    };
  }

  async refreshAccessories(): Promise<void> {
    const context = this.abilityContext;
    if (context === undefined) {
      throw new Error('应用上下文尚未准备就绪。');
    }
    if (isCarPlaySessionActive(this.state)) {
      throw new Error('请先停止连接，再刷新接收端。');
    }
    const generation = this.generation;
    const result = await abilityAccessCtrl.createAtManager()
      .requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
    if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
      throw new Error('蓝牙权限未获授权。');
    }
    if (!this.isCurrent(generation) || isCarPlaySessionActive(this.state)) {
      throw new Error('配对设备刷新已取消；会话状态已变化。');
    }
    this.loadAccessories();
    await this.detectBluetoothIdentity(generation);
  }

  async checkBluetoothIdentity(): Promise<void> {
    const context = this.abilityContext;
    if (context === undefined || isCarPlaySessionActive(this.state)) {
      throw new Error('请在应用就绪且停止连接后检测蓝牙身份。');
    }
    const generation = this.generation;
    const result = await abilityAccessCtrl.createAtManager()
      .requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
    if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
      throw new Error('蓝牙权限未获授权。');
    }
    if (!this.isCurrent(generation) || isCarPlaySessionActive(this.state)) {
      throw new Error('蓝牙身份检测已取消；会话状态已变化。');
    }
    await this.detectBluetoothIdentity(generation);
  }

  private async detectBluetoothIdentity(generation?: number): Promise<void> {
    const context = this.abilityContext;
    if (context === undefined) {
      throw new Error('应用上下文尚未准备就绪。');
    }
    const provider = new HarmonyBluetoothIdentityProvider(context.applicationInfo.accessTokenId);
    try {
      const address = await provider.getStableBluetoothAddress();
      if (generation !== undefined && !this.isCurrent(generation)) {
        return;
      }
      this.identityProvider = provider;
      this.realBluetoothAddress = address;
      this.blockedReason = '';
      this.appendLog('本机真实蓝牙身份已由 access.getLocalAddress 读取并校验；不将地址写入日志。');
    } catch (error) {
      if (generation !== undefined && !this.isCurrent(generation)) {
        return;
      }
      this.identityProvider = undefined;
      this.realBluetoothAddress = undefined;
      this.blockedReason = `本机蓝牙身份不可用：${describeFailure(error)}`;
      this.appendLog(this.blockedReason, true);
    }
    this.notify();
  }

  selectAccessory(deviceId: string): void {
    if (isCarPlaySessionActive(this.state) || !this.devices.some((device: PairedAccessory) => device.deviceId === deviceId)) {
      throw new Error('不能在连接过程中选择接收端，或设备已不在配对列表中。');
    }
    this.selectedDeviceId = deviceId;
    try {
      if (this.settings === undefined) {
        throw new Error('接收端设置存储不可用。');
      }
      this.settings.putSync('targetDeviceId', deviceId);
      this.settings.flushSync();
    } catch (error) {
      this.appendLog(`接收端选择仅本次有效，持久化失败：${describeFailure(error)}`, true);
    }
    this.appendLog(`已选择接收端 ${carPlayDiagnostics.identifier(deviceId)}。`);
    this.notify();
  }

  logSessions(): string[] {
    return carPlayDiagnostics.sessionNames();
  }

  async exportLogs(name: string): Promise<boolean> {
    const context = this.abilityContext;
    if (context === undefined) {
      throw new Error('应用上下文尚未准备就绪。');
    }
    try {
      return await carPlayDiagnostics.exportSession(context, name);
    } catch (error) {
      this.appendLog(`日志导出失败：${describeFailure(error)}`, true);
      throw error instanceof Error ? error : new Error(describeFailure(error));
    }
  }

  reportActionFailure(stage: string, error: Error): void {
    this.appendLog(`${stage}失败：${describeFailure(error)}`, true);
  }

  private loadAccessories(): void {
    this.devices = this.sppClient.pairedAccessories();
    if (!this.devices.some((device: PairedAccessory) => device.deviceId === this.selectedDeviceId)) {
      this.selectedDeviceId = '';
    }
    this.appendLog(`读取到 ${this.devices.length} 个已配对设备；只连接用户选定的接收端。`);
    this.notify();
  }

  async start(): Promise<void> {
    if (this.cleanupPromise !== undefined) {
      await this.cleanupPromise;
      this.cleanupPromise = undefined;
    }
    if (isCarPlaySessionActive(this.state)) {
      return;
    }
    const context = this.abilityContext;
    if (context === undefined) {
      this.setState('error');
      this.appendLog('应用上下文尚未准备就绪，无法启动连接。');
      return;
    }

    const generation = ++this.generation;
    this.logs = [];
    carPlayDiagnostics.beginSession();
    this.setState('connecting');
    this.appendLog(`phone=${deviceInfo.productModel}; osBuild=${deviceInfo.osFullName.replace(/\./g, '_')}; sdk=${deviceInfo.sdkApiVersion}`);
    this.appendLog('本次先核验蓝牙身份；身份不可用仍可诊断 RFCOMM/iAP2，但不表示已具备投屏能力。');
    this.appendLog('正在请求蓝牙权限并检查已配对车机。');
    let stage = '蓝牙权限请求';
    try {
      const permissions: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
      const permissionResult = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, permissions);
      if (!this.isCurrent(generation)) {
        return;
      }
      if (permissionResult.authResults.length === 0 || permissionResult.authResults[0] !== 0) {
        this.failSession('蓝牙权限未获授权。');
        return;
      }

      stage = '本机蓝牙身份检测';
      await this.detectBluetoothIdentity(generation);
      if (!this.isCurrent(generation)) {
        return;
      }
      this.loadAccessories();
      const target = this.devices.find((device: PairedAccessory) => device.deviceId === this.selectedDeviceId);
      if (target === undefined) {
        this.failSession('尚未选择接收端；请刷新已配对设备并选择车机或 DiPlay，再开启连接。');
        return;
      }
      stage = 'iAP2 RFCOMM 服务连接';
      const connection = await this.sppClient.connectToAccessory(
        target,
        () => this.isCurrent(generation),
        (message: string) => this.appendLog(message)
      );
      if (!this.isCurrent(generation)) {
        connection.close();
        return;
      }
      this.connection = connection;
      this.setState('bluetooth-connected');
      this.identificationStarted = false;
      const link = new Iap2LinkEngine((bytes: Uint8Array) => {
        connection.write(bytes).then(() => {
        }, (error: Error) => {
          if (this.isCurrent(generation)) {
            this.failSession(`iAP2 RFCOMM 写入失败：${describeFailure(error)}`);
          }
        });
      });
      this.linkEngine = link;
      link.onStateChanged = (state: Iap2LinkState) => this.onLinkState(state, generation);
      link.onControl = (bytes: Uint8Array) => this.onControlBytes(bytes, generation);
      connection.onData((data: ArrayBuffer) => {
        if (this.isCurrent(generation)) {
          try {
            link.feed(new Uint8Array(data));
          } catch (error) {
            this.failSession(`iAP2 链路解析失败：${describeFailure(error)}`);
          }
        }
      });
      connection.onClosed((reason: string) => {
        if (this.isCurrent(generation)) {
          this.failSession(reason);
        }
      });
      this.appendLog('RFCOMM 通道已就绪，开始 iAP2 链路协商。');
      this.iap2Timer = setTimeout(() => {
        this.iap2Timer = undefined;
        if (this.isCurrent(generation)) {
          this.failSession('RFCOMM 已连接，但 iAP2 链路协商超时；请结合 first-rx 和接收端日志确认协议收发。');
        }
      }, 15000);
      link.start();
    } catch (error) {
      if (!this.isCurrent(generation)) {
        return;
      }
      this.failSession(`${stage}失败：${describeFailure(error)}`);
    }
  }

  stop(): void {
    this.generation++;
    this.sppClient.stop();
    this.identityProvider = undefined;
    this.realBluetoothAddress = undefined;
    if (this.iap2Timer !== undefined) {
      clearTimeout(this.iap2Timer);
      this.iap2Timer = undefined;
    }
    const cleanupTasks: Promise<void>[] = [];
    if (this.cleanupPromise !== undefined) {
      cleanupTasks.push(this.cleanupPromise);
    }
    if (this.linkEngine !== undefined) {
      this.linkEngine.close();
      this.linkEngine = undefined;
    }
    if (this.senderSession !== undefined) {
      this.senderSession.close();
      this.senderSession = undefined;
    }
    if (this.inviteServer !== undefined) {
      const inviteServer = this.inviteServer;
      this.inviteServer = undefined;
      cleanupTasks.push(inviteServer.stop().catch((error: Error) => {
        this.appendLog(`停止 CarPlay 邀请服务失败：${error.message}`);
      }));
    }
    if (this.mdnsBrowser !== undefined) {
      this.mdnsBrowser.stop((message: string) => this.appendLog(message));
      this.mdnsBrowser = undefined;
    }
    this.pendingStartSession = undefined;
    this.latestAirPlayEndpoint = undefined;
    this.receivedCarPlayInvite = false;
    this.pairingStarted = false;
    this.wifiConnectionStarted = false;
    this.airPlayProbeKeys.clear();
    if (this.wifiClient !== undefined) {
      const client = this.wifiClient;
      this.wifiClient = undefined;
      cleanupTasks.push(client.stop().catch((error: Error) => {
        this.appendLog(`断开时清理车机 Wi-Fi/恢复应用网络失败：${describeFailure(error)}`, true);
      }));
    }
    if (this.connection !== undefined) {
      try {
        this.connection.close();
        this.appendLog(`已关闭 ${this.connection.deviceName} 的 RFCOMM 通道。`);
      } catch (error) {
        this.appendLog(`关闭 RFCOMM 通道失败：${describeFailure(error)}`, true);
      }
      this.connection = undefined;
    }
    this.setState('idle');
    const cleanup = Promise.all(cleanupTasks).then(() => {
      carPlayDiagnostics.flush();
    }).catch((error: Error) => {
      this.appendLog(`会话清理/日志刷盘失败：${describeFailure(error)}`, true);
    });
    this.cleanupPromise = cleanup;
    void cleanup.then(() => {
      if (this.cleanupPromise === cleanup) {
        this.cleanupPromise = undefined;
      }
    });
  }

  async shutdown(): Promise<void> {
    this.stop();
    if (this.cleanupPromise !== undefined) {
      await this.cleanupPromise;
    }
    carPlayDiagnostics.log('ability', 'onDestroy cleanup complete');
    carPlayDiagnostics.close();
  }

  private onLinkState(state: Iap2LinkState, generation: number): void {
    if (!this.isCurrent(generation)) {
      return;
    }
    this.appendLog(`iAP2 link state=${state}。`);
    if (state === 'normal' && !this.identificationStarted) {
      if (this.iap2Timer !== undefined) {
        clearTimeout(this.iap2Timer);
        this.iap2Timer = undefined;
      }
      this.identificationStarted = true;
      this.wifiConnectionStarted = false;
      this.pendingStartSession = undefined;
      this.airPlayProbeKeys.clear();
      this.setState('iap2-ready');
      this.appendLog('iAP2 链路协商完成；开始设备身份识别与 Wi-Fi 配置交换。');
      this.senderSession = new Iap2SenderSession(
        (bytes: Uint8Array) => this.sendControl(bytes, generation),
        (message: string) => this.appendLog(message),
        (configuration: AccessoryWifiConfiguration) => {
          this.beginWifiConnection(configuration, generation);
        },
        (endpoint: CarPlayStartSessionEndpoint) => this.onCarPlayStartSession(endpoint, generation),
        (reason: string) => this.blockSession(reason),
        this.realBluetoothAddress
      );
      this.senderSession.start();
    } else if (state === 'negotiating') {
      this.setState('iap2-negotiating');
    } else if (state === 'dead') {
      this.failSession('iAP2 链路已终止。');
    }
  }

  private onControlBytes(bytes: Uint8Array, generation: number): void {
    if (this.isCurrent(generation)) {
      try {
        this.senderSession?.receive(bytes);
      } catch (error) {
        this.failSession(`iAP2 控制消息处理失败：${describeFailure(error)}`);
      }
    }
  }

  private sendControl(bytes: Uint8Array, generation: number): void {
    if (!this.isCurrent(generation) || this.linkEngine === undefined) {
      return;
    }
    try {
      this.linkEngine.sendControl(bytes);
    } catch (error) {
      this.failSession(`iAP2 控制消息发送失败：${describeFailure(error)}`);
    }
  }

  private async connectToAccessoryWifi(configuration: AccessoryWifiConfiguration, generation: number): Promise<void> {
    const context = this.abilityContext;
    if (context === undefined || !this.isCurrent(generation)) {
      return;
    }
    this.setState('wifi-pending');
    this.appendLog('正在请求 Wi-Fi 网络权限。');
    try {
      const permissions: Permissions[] = [
        'ohos.permission.SET_WIFI_INFO',
        'ohos.permission.GET_WIFI_INFO',
        'ohos.permission.GET_NETWORK_INFO',
        'ohos.permission.INTERNET'
      ];
      const permissionResult = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, permissions);
      if (!this.isCurrent(generation)) {
        return;
      }
      if (permissionResult.authResults.length !== permissions.length ||
        permissionResult.authResults.some((result: number) => result !== 0)) {
        this.failSession('Wi-Fi 权限未全部获授权，无法安全加入车机热点。');
        return;
      }

      const client = new HarmonyWifiClient();
      this.wifiClient = client;
      await client.connectToAccessory(
        configuration,
        () => this.isCurrent(generation),
        (message: string) => this.appendLog(message)
      );
      if (!this.isCurrent(generation)) {
        return;
      }
      this.setState('wifi-connected');
      this.appendLog('已连接车机热点并验证 WLAN 绑定。');
      const identityProvider = this.identityProvider;
      if (identityProvider === undefined) {
        this.blockSession(this.blockedReason || '本机蓝牙身份尚未通过系统接口与权限检查。');
        return;
      }
      const identity = await identityProvider.getStableBluetoothAddress();
      if (!this.isCurrent(generation)) {
        return;
      }
      if (identity !== this.realBluetoothAddress) {
        this.blockSession('本机蓝牙身份与 iAP2 使用的身份不一致，已停止发布邀请服务。');
        return;
      }
      this.appendLog('开始发现 AirPlay 服务。');
      this.tryPairAfterInvite(generation);
      const inviteServer = new CarPlayInviteServer(
        identityProvider,
        (request: CarPlayInviteRequest) => this.onCarPlayInvite(request, generation),
        (message: string) => this.appendLog(message)
      );
      this.inviteServer = inviteServer;
      void inviteServer.start(context).catch((error: Error) => {
        if (this.isCurrent(generation)) {
          this.appendLog(`CarPlay 邀请服务不可用：${error.message}`);
        }
      });
      const browser = new HarmonyMdnsBrowser();
      this.mdnsBrowser = browser;
      browser.start(
        context,
        (message: string) => this.appendLog(message),
        (endpoint: AirPlayServiceEndpoint) => this.onAirPlayEndpoint(endpoint, generation)
      );
      this.probePendingStartSession(generation);
    } catch (error) {
      if (this.isCurrent(generation)) {
        this.failSession(`车机热点连接失败：${describeFailure(error)}`);
      }
    }
  }

  private onAirPlayEndpoint(endpoint: AirPlayServiceEndpoint, generation: number): void {
    if (!this.isCurrent(generation)) {
      return;
    }
    this.setState('airplay-found');
    const pairingSupport = endpoint.homeKitPairingSupported === undefined ? '未知' :
      endpoint.homeKitPairingSupported ? '支持' : '不支持';
    this.appendLog(`已发现车机 AirPlay 端点 ${endpoint.name}；HomeKit 配对声明：${pairingSupport}。` +
      'RTSP 配对等待车机邀请触发；媒体流和触摸回控尚未接入。');
    this.latestAirPlayEndpoint = endpoint;
    this.tryPairAfterInvite(generation);
    this.probeAirPlayEndpoint(endpoint, generation);
  }

  private onCarPlayStartSession(endpoint: CarPlayStartSessionEndpoint, generation: number): void {
    if (!this.isCurrent(generation)) {
      return;
    }
    this.pendingStartSession = endpoint;
    this.tryPairAfterInvite(generation);
    if (endpoint.ssid.length > 0) {
      this.beginWifiConnection({
        ssid: endpoint.ssid,
        passphrase: endpoint.passphrase,
        securityType: endpoint.securityType,
        channel: endpoint.channel
      }, generation);
    }
    if (this.state === 'wifi-connected' || this.state === 'airplay-found') {
      this.probePendingStartSession(generation);
    }
  }

  private beginWifiConnection(configuration: AccessoryWifiConfiguration, generation: number): void {
    if (!this.isCurrent(generation) || this.wifiConnectionStarted) {
      return;
    }
    this.wifiConnectionStarted = true;
    void this.connectToAccessoryWifi(configuration, generation);
  }

  private probePendingStartSession(generation: number): void {
    const endpoint = this.pendingStartSession;
    if (endpoint === undefined || endpoint.airPlayPort <= 0) {
      return;
    }
    endpoint.ipAddresses.forEach((host: string) => {
      this.probeAirPlayEndpoint({
        name: 'iAP2 CarPlayStartSession',
        host,
        port: endpoint.airPlayPort,
        features: undefined,
        homeKitPairingSupported: undefined
      }, generation);
    });
  }

  private onCarPlayInvite(_request: CarPlayInviteRequest, generation: number): void {
    if (!this.isCurrent(generation)) {
      return;
    }
    this.receivedCarPlayInvite = true;
    this.tryPairAfterInvite(generation);
  }

  private tryPairAfterInvite(generation: number): void {
    if (!this.receivedCarPlayInvite || this.pairingStarted || !this.isCurrent(generation) ||
      (this.state !== 'wifi-connected' && this.state !== 'airplay-found')) {
      return;
    }
    const startSession = this.pendingStartSession;
    const directHost = startSession?.ipAddresses.find((host: string) => host.length > 0);
    const endpoint: AirPlayServiceEndpoint | undefined = directHost !== undefined && startSession !== undefined
      ? {
        name: 'iAP2 CarPlayStartSession',
        host: directHost,
        port: startSession.airPlayPort,
        features: undefined,
        homeKitPairingSupported: undefined
      }
      : this.latestAirPlayEndpoint;
    if (endpoint === undefined || endpoint.port < 1 || endpoint.port > 65535) {
      this.appendLog('已收到 CarPlay 邀请，但尚无可用 AirPlay RTSP 端点；等待 iAP2/mDNS 端点。');
      return;
    }
    this.pairingStarted = true;
    this.appendLog(`收到车机邀请，开始 AirPlay HomeKit 配对与验证：${endpoint.host}:${endpoint.port}。`);
    const context = this.abilityContext;
    if (context === undefined) {
      this.pairingStarted = false;
      this.appendLog('无法启动 AirPlay 配对：应用上下文不可用。');
      return;
    }
    void new HarmonyAirPlayClient().pairAndVerify(
      context,
      endpoint,
      (message: string) => this.appendLog(message)
    ).then(() => {
      if (this.isCurrent(generation)) {
        this.appendLog('AirPlay pair-setup/pair-verify 已完成；媒体 SETUP/RECORD 与帧源仍未建立。');
      }
    }).catch((error: Error) => {
      if (this.isCurrent(generation)) {
        this.pairingStarted = false;
        this.appendLog(`AirPlay 配对失败：${error.message}`);
      }
    });
  }

  private probeAirPlayEndpoint(endpoint: AirPlayServiceEndpoint, generation: number): void {
    const key = `${endpoint.host}:${endpoint.port}`;
    if (!this.isCurrent(generation) || this.airPlayProbeKeys.has(key)) {
      return;
    }
    this.airPlayProbeKeys.add(key);
    const client = new HarmonyAirPlayClient();
    void client.inspect(endpoint, (message: string) => this.appendLog(message)).then((response) => {
      if (this.isCurrent(generation)) {
        this.appendLog(HarmonyAirPlayClient.describeInfo(response));
      }
    }, (error: Error) => {
      if (this.isCurrent(generation)) {
        this.appendLog(`无法连接 AirPlay RTSP 端点：${error.message}`);
      }
    });
  }

  private failSession(message: string): void {
    this.appendLog(message, true);
    this.stop();
    this.setState('error');
  }

  private blockSession(reason: string): void {
    this.blockedReason = reason;
    this.appendLog(`BLOCKED: ${reason}`, true);
    this.stop();
    this.setState('blocked');
  }

  private isCurrent(generation: number): boolean {
    return this.generation === generation;
  }

  private appendLog(message: string, error: boolean = false): void {
    carPlayDiagnostics.log('session', message, error);
  }

  private setState(state: CarPlaySessionState): void {
    if (this.state !== state) {
      carPlayDiagnostics.log('state', `${this.state} -> ${state}`);
    }
    this.state = state;
    this.notify();
  }

  private notify(): void {
    const snapshot = this.snapshot();
    this.listeners.forEach((listener: SessionListener) => listener(snapshot));
  }
}

export const carPlaySessionController = new CarPlaySessionController();
