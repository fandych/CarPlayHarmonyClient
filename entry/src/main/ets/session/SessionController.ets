import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { AirPlayPairingClient } from '../airplay/AirPlayPairingClient';
import { AirPlayMediaSessionInfo } from '../airplay/AirPlayMediaSession';
import { EncodedH264Event } from '../airplay/AirPlayVideoStream';
import { MfiTrustPromptInfo } from '../iap2/MfiVerifier';
import { AirPlayMdnsDiscovery, AirPlayService } from '../network/AirPlayMdnsDiscovery';
import { CarPlayCtrlAdvertiser } from '../network/CarPlayCtrlAdvertiser';
import { WifiCarPlayConnector } from '../network/WifiCarPlayConnector';
import { BluetoothIap2Server } from '../transport/BluetoothIap2Server';
import { CarPlayVirtualDisplay } from '../video/CarPlayVirtualDisplay';
import { NativeH264VideoEncoder } from '../video/NativeH264VideoEncoder';
import { Iap2SenderSession, WifiCredentials } from './Iap2SenderSession';

export interface SessionEvents {
  onStatus: (status: string) => void;
  onLog: (message: string) => void;
  onWifiCredentials: (credentials: WifiCredentials) => void;
  onAirPlayService: (service: AirPlayService) => void;
  onAirPlayMediaSession: (info: AirPlayMediaSessionInfo) => void;
  onProjectionReady: (displayId: number, width: number, height: number) => Promise<void>;
  onProjectionStopped: () => void;
  requestMfiTrust: (info: MfiTrustPromptInfo) => Promise<boolean>;
  persistMfiFingerprint: (fingerprint: string) => Promise<void>;
}

export class SessionController {
  private readonly context: common.UIAbilityContext;
  private readonly events: SessionEvents;
  private readonly bluetooth: BluetoothIap2Server = new BluetoothIap2Server();
  private readonly wifi: WifiCarPlayConnector = new WifiCarPlayConnector();
  private readonly projectionDisplay: CarPlayVirtualDisplay = new CarPlayVirtualDisplay();
  private readonly videoEncoder: NativeH264VideoEncoder = new NativeH264VideoEncoder();
  private discovery?: AirPlayMdnsDiscovery;
  private ctrlAdvertiser?: CarPlayCtrlAdvertiser;
  private activePairing?: AirPlayPairingClient;
  private discoveredAirPlay?: AirPlayService;
  private iap2?: Iap2SenderSession;
  private credentials?: WifiCredentials;
  private running: boolean = false;
  private inviteReceived: boolean = false;
  private vehicleWifiConnected: boolean = false;
  private wifiJoinInProgress: boolean = false;
  private airPlayConnectInProgress: boolean = false;
  private airPlayConnectAttempted: boolean = false;
  private readonly deviceAddress: string;
  private readonly deviceName: string;
  private readonly deviceUuid: string;
  private readonly keepScreenOn: boolean;
  private readonly allowMfiIntermediateDownload: boolean;
  private readonly trustedMfiFingerprints: string[];

  constructor(
    context: common.UIAbilityContext,
    events: SessionEvents,
    deviceAddress: string,
    deviceName: string,
    deviceUuid: string,
    keepScreenOn: boolean,
    allowMfiIntermediateDownload: boolean = false,
    trustedMfiFingerprints: string[] = []
  ) {
    this.context = context;
    this.events = events;
    this.deviceAddress = deviceAddress;
    this.deviceName = deviceName;
    this.deviceUuid = deviceUuid;
    this.keepScreenOn = keepScreenOn;
    this.allowMfiIntermediateDownload = allowMfiIntermediateDownload;
    this.trustedMfiFingerprints = trustedMfiFingerprints.slice();
  }

  async start(): Promise<void> {
    if (this.running) {
      return;
    }
    await this.requestPermissions(['ohos.permission.ACCESS_BLUETOOTH']);
    this.running = true;
    this.inviteReceived = false;
    this.wifiJoinInProgress = false;
    this.airPlayConnectInProgress = false;
    this.airPlayConnectAttempted = false;
    this.vehicleWifiConnected = false;
    try {
      await this.bluetooth.start(
        () => this.handleBluetoothConnected(),
        (bytes: Uint8Array) => this.handleBluetoothData(bytes),
        (message: string) => this.reportError(message)
      );
      await this.setKeepScreenOn(true);
      this.events.onStatus('等待车机 iAP2 握手');
      this.events.onLog('CarPlay 已开启：等待蓝牙 RFCOMM / iAP2 连接');
    } catch (error) {
      this.running = false;
      this.bluetooth.stop();
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async stop(): Promise<void> {
    this.running = false;
    this.airPlayConnectAttempted = false;
    this.wifiJoinInProgress = false;
    this.vehicleWifiConnected = false;
    const failures: string[] = [];
    try {
      await this.wifi.cancelPendingJoin();
    } catch (error) {
      failures.push(`取消 Wi-Fi 加入失败：${error instanceof Error ? error.message : String(error)}`);
    }
    try {
      await this.stopProjection();
    } catch (error) {
      failures.push(`投屏资源清理失败：${error instanceof Error ? error.message : String(error)}`);
    }
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
    const pairing = this.activePairing;
    this.activePairing = undefined;
    if (pairing) {
      try {
        await pairing.close();
      } catch (error) {
        failures.push(`AirPlay 会话清理失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
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
    if (this.vehicleWifiConnected) {
      this.events.onLog('车机 Wi-Fi 已连接，忽略重复加入请求');
      return;
    }
    if (this.wifiJoinInProgress) {
      this.events.onLog('车机 Wi-Fi 连接已在等待系统确认');
      return;
    }
    if (!this.running) {
      throw new Error('CarPlay 已关闭，不能加入车机热点');
    }
    if (!this.credentials) {
      throw new Error('尚未收到车机热点配置，请填写热点名称和密码');
    }
    const iap2 = this.iap2;
    if (!iap2?.isAccessoryVerified) {
      throw new Error('iAP2 MFi 验证尚未完成；拒绝启动车机 Wi-Fi/AirPlay 会话');
    }
    this.wifiJoinInProgress = true;
    const credentials: WifiCredentials = {
      ssid: this.credentials.ssid,
      password: this.credentials.password,
      securityType: this.credentials.securityType,
      channel: this.credentials.channel
    };
    try {
      await this.requestPermissions([
        'ohos.permission.SET_WIFI_INFO',
        'ohos.permission.GET_WIFI_INFO'
      ]);
      if (!this.running) {
        return;
      }
      this.events.onStatus(`等待系统确认连接 ${credentials.ssid}`);
      const result = await this.wifi.connect(credentials);
      if (!this.running) {
        return;
      }
      this.vehicleWifiConnected = true;
      this.events.onStatus(`已连接车机 Wi-Fi：${result.ssid}`);
      this.events.onLog(`车机 Wi-Fi 已连接，本机地址 ${result.ipAddress}`);
      if (!this.running || this.iap2 !== iap2) {
        return;
      }
      await iap2.onWifiConnected();
      if (!this.running) {
        return;
      }
      await this.startControlAdvertisement();
      if (!this.running) {
        return;
      }
      this.startAirPlayDiscovery();
    } finally {
      this.wifiJoinInProgress = false;
    }
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
    if (!this.running) {
      this.events.onLog('CarPlay 已关闭，忽略迟到的 Bluetooth RFCOMM 连接');
      this.bluetooth.stop();
      return;
    }
    this.events.onStatus('车机已连接，正在协商 iAP2');
    this.events.onLog('已接受 RFCOMM 连接');
    this.iap2?.cancel();
    this.iap2 = new Iap2SenderSession(
      (bytes: Uint8Array): Promise<void> => this.bluetooth.send(bytes),
      (message: string): void => this.events.onLog(message),
      (credentials: WifiCredentials): void => {
        this.credentials = credentials;
        this.events.onWifiCredentials(credentials);
        this.events.onStatus(`iAP2 已收到热点 ${credentials.ssid}，等待系统确认加入`);
        void this.joinVehicleWifi().catch((error: Error): void => {
          if (this.running) {
            this.reportError(error.message);
          } else {
            this.events.onLog(`CarPlay 已停止，取消 Wi-Fi 加入：${error.message}`);
          }
        });
      },
      (body: Uint8Array): void => {
        this.events.onLog(`收到 CarPlay 会话端点 (${body.length} 字节)，等待 mDNS 服务发现`);
      },
      this.deviceAddress,
      this.deviceName,
      this.deviceUuid,
      this.allowMfiIntermediateDownload,
      this.trustedMfiFingerprints,
      this.events.requestMfiTrust,
      this.events.persistMfiFingerprint
    );
    void this.iap2.start().catch((error: Error): void => this.reportError(error.message));
  }

  private handleBluetoothData(bytes: Uint8Array): void {
    if (!this.running || !this.iap2) {
      this.events.onLog('CarPlay 非活动状态，忽略 iAP2 数据');
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
        this.events.onLog(`发现 AirPlay ${service.name} · ${service.host}:${service.port}`);
        if (this.inviteReceived) {
          void this.connectAirPlay().catch((error: Error): void => this.reportError(error.message));
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
        this.events.onStatus('收到车机邀请，等待 AirPlay 接收端');
        if (this.discoveredAirPlay) {
          void this.connectAirPlay().catch((error: Error): void => this.reportError(error.message));
        }
      },
      (message: string): void => this.events.onLog(message)
    );
    this.ctrlAdvertiser = advertiser;
    await advertiser.start();
  }

  private async connectAirPlay(): Promise<void> {
    const service = this.discoveredAirPlay;
    if (!this.running || !service || !this.inviteReceived || this.airPlayConnectInProgress ||
      this.airPlayConnectAttempted) {
      return;
    }
    this.airPlayConnectInProgress = true;
    this.airPlayConnectAttempted = true;
    const pairing = new AirPlayPairingClient((message: string): void => this.events.onLog(message));
    this.activePairing = pairing;
    try {
      this.events.onStatus('车机邀请和 AirPlay 服务已就绪，正在安全配对');
      this.events.onLog(`开始 AirPlay Pair-Setup/Verify：${service.host}:${service.port}`);
      const result = await pairing.pair(this.context, service);
      if (!this.running) {
        await pairing.close();
        return;
      }
      this.events.onLog(`AirPlay 配对验证通过：${result.receiverId} · ${result.model}`);
      this.events.onStatus('AirPlay 配对通过，正在建立 RTSP 会话');
      const media = await pairing.startCarPlaySession(this.deviceAddress, this.deviceName);
      if (!this.running) {
        await pairing.close();
        return;
      }
      this.events.onAirPlayMediaSession(media);
      this.events.onLog(
        `AirPlay RTSP RECORD 已完成：screen=${media.videoDataPort}, audio=${media.audioSession?.dataPort ?? 0}`
      );
      try {
        await this.startProjection(media, pairing);
        if (!this.running) {
          return;
        }
        this.events.onStatus(`CarPlay 实时投屏已启动：${media.displayWidth}x${media.displayHeight}`);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.events.onStatus(`AirPlay 控制已连接；投屏不可用：${message}`);
        this.events.onLog(`CarPlay 视频源未能启动：${message}`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (!this.running) {
        try {
          await pairing.close();
        } catch (cleanupError) {
          this.events.onLog(`停止期间清理 AirPlay 会话失败：${cleanupError instanceof Error ?
            cleanupError.message : String(cleanupError)}`);
        }
        return;
      }
      this.events.onStatus(`AirPlay 连接失败：${message}`);
      this.events.onLog(`AirPlay 自动连接失败：${message}`);
      try {
        await pairing.close();
      } catch (cleanupError) {
        this.events.onLog(`AirPlay 失败清理异常：${cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError)}`);
      }
      this.activePairing = undefined;
    } finally {
      this.airPlayConnectInProgress = false;
    }
  }

  private async startProjection(media: AirPlayMediaSessionInfo, pairing: AirPlayPairingClient): Promise<void> {
    if (!this.running) {
      return;
    }
    const bitrate = Math.max(1_500_000, Math.min(10_000_000, media.displayWidth * media.displayHeight * 5));
    const surfaceId = this.videoEncoder.start({
      width: media.displayWidth,
      height: media.displayHeight,
      frameRate: media.maxFrameRate,
      bitrate
    }, (event: EncodedH264Event): void => {
      if (event.type === 'overflow') {
        const keyFrameRequested = this.videoEncoder.requestKeyFrame();
        this.events.onLog(
          `H.264 回调队列过载；请求关键帧${keyFrameRequested ? '成功' : '失败'}`
        );
        return;
      }
      void pairing.pushEncodedVideo(event).catch((error: Error): void => {
        this.reportError(`AirPlay H.264 帧发送失败：${error.message}`);
        void this.stopProjection().catch((cleanupError: Error): void => {
          this.reportError(`H.264 失败后清理投屏资源失败：${cleanupError.message}`);
        });
      });
    });
    try {
      const displayId = await this.projectionDisplay.create(surfaceId, {
        width: media.displayWidth,
        height: media.displayHeight
      });
      if (!this.running) {
        await this.stopProjection();
        return;
      }
      pairing.setForceKeyFrameHandler((): void => {
        const requested = this.videoEncoder.requestKeyFrame();
        this.events.onLog(`车机关键帧请求：${requested ? '已提交' : '编码器未就绪'}`);
      });
      await this.events.onProjectionReady(displayId, media.displayWidth, media.displayHeight);
      this.events.onLog(
        `CarPlay 虚拟屏已建立：id=${displayId}, ${media.displayWidth}x${media.displayHeight}, ` +
          `${media.maxFrameRate}fps`
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const failures: string[] = [];
      try {
        await this.projectionDisplay.destroy();
      } catch (cleanupError) {
        failures.push(cleanupError instanceof Error ? cleanupError.message : String(cleanupError));
      }
      this.videoEncoder.stop();
      pairing.setForceKeyFrameHandler(undefined);
      if (failures.length > 0) {
        throw new Error(`${message}; cleanup failed: ${failures.join('; ')}`);
      }
      throw error instanceof Error ? error : new Error(message);
    }
  }

  private async stopProjection(): Promise<void> {
    const displayId = this.projectionDisplay.id;
    const failures: string[] = [];
    try {
      await this.projectionDisplay.destroy();
    } catch (error) {
      failures.push(error instanceof Error ? error.message : String(error));
    }
    this.videoEncoder.stop();
    this.activePairing?.setForceKeyFrameHandler(undefined);
    if (displayId >= 0) {
      this.events.onProjectionStopped();
      this.events.onLog(`CarPlay 虚拟屏已停止：id=${displayId}`);
    }
    if (failures.length > 0) {
      throw new Error(failures.join('; '));
    }
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
