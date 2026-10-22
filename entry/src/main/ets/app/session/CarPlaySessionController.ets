import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import display from '@ohos.display';
import { HarmonySppClient, PairedAccessory, SppConnection } from '../../platform/bluetooth/HarmonySppClient';
import { HarmonyBluetoothIdentityProvider } from '../../platform/bluetooth/HarmonyBluetoothIdentityProvider';
import {
  BluetoothIdentitySource, ConfiguredBluetoothIdentityProvider
} from '../../platform/bluetooth/ConfiguredBluetoothIdentityProvider';
import { carPlaySettings } from '../../platform/settings/HarmonySettings';
import { chooseAirPlayEndpoint, configuredAirPlay, resolveSessionWifi } from '../settings/SettingsFallbacks';
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
import { HarmonyAirPlayMediaSession } from '../../platform/network/HarmonyAirPlayMediaSession';
import {
  CarPlayInviteServer
} from '../../platform/network/HarmonyCarPlayInviteServer';
import { CarPlayInviteRequest } from '../../protocol/airplay/CarPlayInviteProtocol';

export type CarPlaySessionState =
  'idle' | 'connecting' | 'bluetooth-connected' | 'iap2-negotiating' | 'iap2-ready' |
  'wifi-pending' | 'wifi-connected' | 'airplay-found' | 'media-negotiating' |
  'waiting-video' | 'screen-capture-pending' | 'streaming' | 'blocked' | 'error';

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
  connectedDeviceName: string;
  identitySource: BluetoothIdentitySource;
  systemBluetoothAddress: string;
}

type SessionListener = (snapshot: CarPlaySessionSnapshot) => void;

class CarPlaySessionController {
  private static readonly MAX_LOG_LINES = 250;
  private readonly sppClient: HarmonySppClient = new HarmonySppClient();
  private readonly listeners: Set<SessionListener> = new Set<SessionListener>();
  private logs: string[] = [];
  private devices: PairedAccessory[] = [];
  private selectedDeviceId: string = '';
  private blockedReason: string = '';
  private identityProvider: ConfiguredBluetoothIdentityProvider | undefined = undefined;
  private realBluetoothAddress: string | undefined = undefined;
  private identitySource: BluetoothIdentitySource = 'unavailable';
  private systemBluetoothAddress: string = '';
  private connectedDeviceName: string = '';
  private restored: boolean = false;
  private iap2Timer: number | undefined = undefined;
  private wifiFallbackTimer: number | undefined = undefined;
  private airPlayFallbackTimer: number | undefined = undefined;
  private manualEndpointAllowed: boolean = false;
  private state: CarPlaySessionState = 'idle';
  private abilityContext: common.UIAbilityContext | undefined = undefined;
  private generation: number = 0;
  private connection: SppConnection | undefined = undefined;
  private linkEngine: Iap2LinkEngine | undefined = undefined;
  private senderSession: Iap2SenderSession | undefined = undefined;
  private wifiClient: HarmonyWifiClient | undefined = undefined;
  private mdnsBrowser: HarmonyMdnsBrowser | undefined = undefined;
  private inviteServer: CarPlayInviteServer | undefined = undefined;
  private airPlayMediaSession: HarmonyAirPlayMediaSession | undefined = undefined;
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
    carPlaySettings.subscribe((snapshot) => {
      if (snapshot.ready) {
        this.selectedDeviceId = snapshot.settings.targetDeviceId;
        if (!snapshot.settings.enabled && isCarPlaySessionActive(this.state)) {
          this.stop();
        }
        this.notify();
      }
    });
  }

  async setContext(context: common.UIAbilityContext): Promise<void> {
    this.abilityContext = context;
    this.restored = false;
    carPlayDiagnostics.initialize(context.filesDir);
    this.appendLog(`phone=${deviceInfo.productModel}; osBuild=${deviceInfo.osFullName.replace(/\./g, '_')}; sdk=${deviceInfo.sdkApiVersion}`);
    this.blockedReason = '本机身份尚未检测；自动读取不可用时，可在设置中填写本机真实蓝牙地址。';
    this.appendLog(this.blockedReason);
    await carPlaySettings.initialize(context);
    this.notify();
  }

  async setEnabled(enabled: boolean): Promise<void> {
    if (!enabled) {
      this.stop();
    }
    await carPlaySettings.setEnabled(enabled);
    if (enabled) {
      void this.start().catch((error: Error) => this.failSession(`连接启动异常：${describeFailure(error)}`));
    }
  }

  async restoreEnabledOnce(): Promise<void> {
    if (this.restored) {
      return;
    }
    this.restored = true;
    const snapshot = carPlaySettings.snapshot();
    if (!snapshot.ready || !snapshot.settings.enabled) {
      return;
    }
    const context = this.abilityContext;
    if (context === undefined) {
      return;
    }
    const accessManager = abilityAccessCtrl.createAtManager();
    const granted = accessManager.checkAccessTokenSync(context.applicationInfo.accessTokenId, 'ohos.permission.ACCESS_BLUETOOTH');
    if (snapshot.settings.targetDeviceId.length === 0 ||
      granted !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      this.blockSession('已记住 CarPlay 开启状态；请在设置选择接收端，并手动重试以完成蓝牙授权。');
      return;
    }
    if (snapshot.settings.localBluetoothAddress.length === 0 &&
      accessManager.checkAccessTokenSync(context.applicationInfo.accessTokenId,
        'ohos.permission.GET_BLUETOOTH_LOCAL_MAC') !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      this.blockSession('已记住 CarPlay 开启状态，但缺少可用的本机蓝牙地址；请在设置填写后重试。');
      return;
    }
    this.appendLog('恢复已保存的 CarPlay 开启意图；本次应用启动仅自动尝试一次。');
    await this.start();
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
      blockedReason: this.blockedReason,
      connectedDeviceName: this.connectedDeviceName,
      identitySource: this.identitySource,
      systemBluetoothAddress: this.systemBluetoothAddress
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
    const provider = new ConfiguredBluetoothIdentityProvider(
      new HarmonyBluetoothIdentityProvider(context.applicationInfo.accessTokenId),
      carPlaySettings.snapshot().settings.localBluetoothAddress,
      (message: string) => this.appendLog(message)
    );
    try {
      const address = await provider.getStableBluetoothAddress();
      if (generation !== undefined && !this.isCurrent(generation)) {
        return;
      }
      this.identityProvider = provider;
      this.realBluetoothAddress = address;
      this.identitySource = provider.identitySource();
      this.systemBluetoothAddress = this.identitySource === 'system' ? address : '';
      this.blockedReason = '';
      this.appendLog(`本机蓝牙身份格式已校验；source=${this.identitySource}，不将地址写入日志。` +
        (this.identitySource === 'manual' ? '手动地址由用户声明为本机真实地址，需接收端实测确认一致性。' : ''));
    } catch (error) {
      if (generation !== undefined && !this.isCurrent(generation)) {
        return;
      }
      this.identityProvider = undefined;
      this.realBluetoothAddress = undefined;
      this.identitySource = 'unavailable';
      this.systemBluetoothAddress = '';
      this.blockedReason = `本机蓝牙身份不可用：${describeFailure(error)}`;
      this.appendLog(this.blockedReason, true);
    }
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
    if (!carPlaySettings.snapshot().ready) {
      this.failSession('配置尚未成功载入，不能启动连接。');
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
      this.connectedDeviceName = target.name;
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

  startProjection(): void {
    if (this.state !== 'waiting-video') {
      throw new Error('Projection can start only after the AirPlay media channel is ready.');
    }
    const mediaSession = this.airPlayMediaSession;
    if (mediaSession === undefined) {
      throw new Error('The AirPlay media session is no longer available.');
    }
    const generation = this.generation;
    const screen = display.getDefaultDisplaySync();
    if (screen.width < 2 || screen.height < 2) {
      throw new Error('The system returned invalid screen dimensions.');
    }
    const scale = Math.min(1, 1280 / Math.max(screen.width, screen.height));
    const width = Math.max(2, Math.floor(screen.width * scale / 2) * 2);
    const height = Math.max(2, Math.floor(screen.height * scale / 2) * 2);
    this.setState('screen-capture-pending');
    try {
      mediaSession.startScreenCapture(
        width,
        height,
        screen.id,
        () => {
          if (this.isCurrent(generation) && this.airPlayMediaSession === mediaSession) {
            this.setState('streaming');
          }
        },
        (reason: string) => {
          if (this.isCurrent(generation) && this.airPlayMediaSession === mediaSession) {
            this.appendLog(`系统停止屏幕采集：${reason}`);
            this.setState('waiting-video');
          }
        }
      );
    } catch (error) {
      this.setState('waiting-video');
      const failure = error instanceof Error ? error : new Error(String(error));
      this.appendLog(`启动用户授权屏幕采集失败：${describeFailure(failure)}`, true);
      throw failure;
    }
  }

  async stopProjection(): Promise<void> {
    const mediaSession = this.airPlayMediaSession;
    if (mediaSession === undefined) {
      return;
    }
    await mediaSession.stopScreenCapture();
    if (this.airPlayMediaSession === mediaSession &&
      (this.state === 'screen-capture-pending' || this.state === 'streaming')) {
      this.setState('waiting-video');
    }
  }

  stop(): void {
    this.generation++;
    this.sppClient.stop();
    this.identityProvider = undefined;
    this.realBluetoothAddress = undefined;
    this.connectedDeviceName = '';
    this.manualEndpointAllowed = false;
    if (this.wifiFallbackTimer !== undefined) {
      clearTimeout(this.wifiFallbackTimer);
      this.wifiFallbackTimer = undefined;
    }
    if (this.airPlayFallbackTimer !== undefined) {
      clearTimeout(this.airPlayFallbackTimer);
      this.airPlayFallbackTimer = undefined;
    }
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
    if (this.airPlayMediaSession !== undefined) {
      const mediaSession = this.airPlayMediaSession;
      this.airPlayMediaSession = undefined;
      cleanupTasks.push(mediaSession.close().catch((error: Error) => {
        this.appendLog(`关闭 AirPlay 媒体会话失败：${describeFailure(error)}`, true);
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
        this.realBluetoothAddress,
        carPlaySettings.snapshot().settings.deviceName,
        () => this.armWifiFallback(generation)
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
      this.armAirPlayFallback(generation);
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
    if (this.state !== 'media-negotiating' && this.state !== 'waiting-video') {
      this.setState('airplay-found');
    }
    const pairingSupport = endpoint.homeKitPairingSupported === undefined ? '未知' :
      endpoint.homeKitPairingSupported ? '支持' : '不支持';
    this.appendLog(`已发现车机 AirPlay 端点 ${endpoint.name}；HomeKit 配对声明：${pairingSupport}。` +
      '媒体配对等待车机邀请触发；发现服务不代表视频投屏成功。');
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
    try {
      const resolved = resolveSessionWifi(configuration, carPlaySettings.snapshot().settings, carPlaySettings.password());
      if (resolved === undefined) {
        throw new Error('自动和备用 Wi-Fi 配置均不可用。');
      }
      if (this.wifiFallbackTimer !== undefined) {
        clearTimeout(this.wifiFallbackTimer);
        this.wifiFallbackTimer = undefined;
      }
      this.wifiConnectionStarted = true;
      void this.connectToAccessoryWifi(resolved, generation);
    } catch (error) {
      this.failSession(`Wi-Fi 配置不完整：${describeFailure(error)}`);
    }
  }

  private armWifiFallback(generation: number): void {
    if (!this.isCurrent(generation) || this.wifiConnectionStarted || this.wifiFallbackTimer !== undefined) {
      return;
    }
    this.wifiFallbackTimer = setTimeout(() => {
      this.wifiFallbackTimer = undefined;
      if (!this.isCurrent(generation) || this.wifiConnectionStarted) {
        return;
      }
      try {
        const manual = resolveSessionWifi(undefined, carPlaySettings.snapshot().settings, carPlaySettings.password());
        if (manual === undefined) {
          this.appendLog('自动 Wi-Fi 配置尚未到达，且没有备用 SSID；继续等待 iAP2，或关闭开关后到设置补全。');
          return;
        }
        this.appendLog('自动 Wi-Fi 信息等待超时；使用用户保存的备用网络配置，不跳过蓝牙/iAP2 协商。');
        this.beginWifiConnection(manual, generation);
      } catch (error) {
        this.failSession(`备用 Wi-Fi 配置不可用：${describeFailure(error)}`);
      }
    }, 8000);
  }

  private armAirPlayFallback(generation: number): void {
    this.airPlayFallbackTimer = setTimeout(() => {
      this.airPlayFallbackTimer = undefined;
      if (!this.isCurrent(generation) || this.selectAirPlayEndpoint(false) !== undefined) {
        return;
      }
      this.manualEndpointAllowed = true;
      const endpoint = this.selectAirPlayEndpoint(true);
      if (endpoint !== undefined) {
        this.appendLog('iAP2/mDNS 尚未提供有效端点；启用手动 AirPlay 备用地址，配对仍等待真实车机邀请。');
        this.probeAirPlayEndpoint(endpoint, generation);
        this.tryPairAfterInvite(generation);
      }
    }, 5000);
  }

  private selectAirPlayEndpoint(allowManual: boolean): AirPlayServiceEndpoint | undefined {
    const start = this.pendingStartSession;
    const host = start?.ipAddresses.find((value: string) => value.length > 0);
    const direct: AirPlayServiceEndpoint | undefined = start !== undefined && host !== undefined ? {
      name: 'iAP2 CarPlayStartSession', host, port: start.airPlayPort, features: undefined, homeKitPairingSupported: undefined
    } : undefined;
    return chooseAirPlayEndpoint(direct, this.latestAirPlayEndpoint,
      configuredAirPlay(carPlaySettings.snapshot().settings), allowManual);
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
    const endpoint = this.selectAirPlayEndpoint(this.manualEndpointAllowed);
    if (endpoint === undefined || endpoint.port < 1 || endpoint.port > 65535) {
      this.appendLog('已收到 CarPlay 邀请，但尚无可用 AirPlay RTSP 端点；等待 iAP2/mDNS 端点。');
      return;
    }
    this.pairingStarted = true;
    this.setState('media-negotiating');
    this.appendLog(`收到车机邀请，开始 AirPlay 配对、验证和媒体通道协商：${endpoint.host}:${endpoint.port}。`);
    const context = this.abilityContext;
    if (context === undefined) {
      this.pairingStarted = false;
      this.failSession('无法启动 AirPlay 媒体协商：应用上下文不可用。');
      return;
    }
    const identity = this.realBluetoothAddress;
    if (identity === undefined) {
      this.pairingStarted = false;
      this.blockSession('媒体 SETUP 需要稳定的本机蓝牙身份；当前会话没有可用身份。');
      return;
    }
    const settings = carPlaySettings.snapshot().settings;
    void HarmonyAirPlayMediaSession.establish(
      context,
      endpoint,
      identity,
      {
        name: settings.deviceName,
        model: deviceInfo.productModel,
        osName: 'HarmonyOS',
        osBuildVersion: deviceInfo.osFullName,
        osVersion: `${deviceInfo.sdkApiVersion}`,
        sourceVersion: 'CarPlayHarmonyClient/1.0'
      },
      (message: string) => this.appendLog(message),
      () => this.isCurrent(generation),
      (error: Error) => {
        if (this.isCurrent(generation)) {
          this.failSession(`AirPlay 媒体会话异常：${describeFailure(error)}`);
        }
      }
    ).then((mediaSession: HarmonyAirPlayMediaSession) => {
      if (!this.isCurrent(generation)) {
        void mediaSession.close().catch((error: Error) => {
          this.appendLog(`已取消媒体协商后的清理失败：${describeFailure(error)}`, true);
        });
        return;
      }
      this.airPlayMediaSession = mediaSession;
      this.setState('waiting-video');
      this.appendLog('AirPlay 配对、SETUP、RECORD 与视频数据通道已建立；尚未发送视频帧，当前不是投屏状态。');
    }, (error: Error) => {
      if (this.isCurrent(generation)) {
        this.pairingStarted = false;
        this.failSession(`AirPlay 媒体协商失败：${describeFailure(error)}`);
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
