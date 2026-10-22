import common from '@ohos.app.ability.common';
import image from '@ohos.multimedia.image';
import promptAction from '@ohos.promptAction';
import { AudioRtpSender, AudioRtpSession } from '../audio/AudioRtpSender';
import { PlaybackAudioCapture } from '../audio/PlaybackAudioCapture';
import { AirPlayMediaSessionInfo } from '../airplay/AirPlayMediaSession';
import { MfiTrustPromptInfo } from '../iap2/MfiVerifier';
import { AppLaunchTarget, AppLauncher } from '../launcher/AppLauncher';
import { AirPlayService } from '../network/AirPlayMdnsDiscovery';
import { SessionController, SessionEvents } from '../session/SessionController';
import { appendConnectionLog } from '../session/ConnectionLogBuffer';
import { WifiCredentials } from '../session/Iap2SenderSession';
import { AppSettingsStore, CarDeckAppSettings } from '../settings/AppSettingsStore';
import { BackgroundPhotoPicker } from '../settings/BackgroundPhotoPicker';
import { VirtualScreenPermissionProbe } from '../settings/VirtualScreenPermissionProbe';

const DISCLAIMER_VERSION = '1';

interface MapAppCandidate {
  bundleName: string;
  name: string;
}

const DEFAULT_MAP_APPS: MapAppCandidate[] = [
  { bundleName: 'com.autonavi.amapauto', name: '高德地图车机版' },
  { bundleName: 'com.autonavi.minimap', name: '高德地图' },
  { bundleName: 'com.baidu.BaiduMap', name: '百度地图' },
  { bundleName: 'com.tencent.map', name: '腾讯地图' }
];

@Entry
@Component
struct Index {
  @State status: string = '未连接';
  @State isStarting: boolean = false;
  @State isStopping: boolean = false;
  @State isJoiningWifi: boolean = false;
  @State settingsReady: boolean = false;
  @State settingsError: string = '';
  @State disclaimerAccepted: boolean = false;
  @State disclaimerRemaining: number = 10;
  @State activeTab: string = 'connect';
  @State isSessionActive: boolean = false;
  @State keepScreenOn: boolean = true;
  @State allowMfiIntermediateDownload: boolean = false;
  @State trustedMfiFingerprints: string[] = [];
  @State isAudioCaptureRequesting: boolean = false;
  @State isAudioCapturing: boolean = false;
  @State audioCaptureStatus: string = '未请求系统播放音频捕获';
  @State audioBytesCaptured: number = 0;
  @State bluetoothAddress: string = '02:00:00:00:00:00';
  @State deviceName: string = 'Harmony CarPlay';
  @State deviceUuid: string = '';
  @State wifiSsid: string = '';
  @State wifiPassword: string = '';
  @State bundleNameInput: string = '';
  @State favoriteBundles: string[] = [];
  @State favoriteTargets: AppLaunchTarget[] = [];
  @State mapDiscoveryStatus: string = '地图快捷方式尚未扫描';
  @State isDiscoveringMapApps: boolean = false;
  @State backgroundPhotoUri: string = '';
  @State backgroundPhotoThumbnail: image.PixelMap | undefined = undefined;
  @State backgroundPhotoStatus: string = '未选择背景图';
  @State virtualScreenPermissionStatus: string = '尚未检测';
  @State projectionDisplayId: number = -1;
  @State settingsMessage: string = '';
  @State logs: string[] = [];
  @State logAtBottom: boolean = true;
  private readonly logScroller: Scroller = new Scroller();
  private controller?: SessionController;
  private readonly settingsStore: AppSettingsStore = new AppSettingsStore();
  private readonly appLauncher: AppLauncher = new AppLauncher();
  private readonly backgroundPhotoPicker: BackgroundPhotoPicker = new BackgroundPhotoPicker();
  private readonly virtualScreenPermissionProbe: VirtualScreenPermissionProbe =
    new VirtualScreenPermissionProbe();
  private playbackCapture?: PlaybackAudioCapture;
  private audioRtpSender?: AudioRtpSender;
  private audioRtpSession?: AudioRtpSession;
  private disclaimerTimer: number = -1;
  private audioStatsTimer: number = -1;
  private pendingAudioBytes: number = 0;
  private mapDiscoveryDone: boolean = false;

  aboutToAppear(): void {
    void this.loadSettings().catch((error: Error): void => {
      this.settingsError = error.message;
      this.settingsReady = true;
    });
  }

  aboutToDisappear(): void {
    this.stopDisclaimerCountdown();
    void this.stopAudioCapture();
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        if (!this.settingsReady) {
          this.loadingPanel()
        } else if (this.settingsError.length > 0) {
          this.settingsErrorPanel()
        } else if (!this.disclaimerAccepted) {
          this.disclaimerPanel()
        } else {
          this.header()
          this.navigationBar()
          if (this.activeTab === 'connect') {
            this.connectionCard()
            this.logCard()
          } else if (this.activeTab === 'apps') {
            this.appsPage()
          } else if (this.activeTab === 'settings') {
            this.identityCard()
            this.wifiCard()
            this.keepScreenCard()
            this.mfiTrustCard()
            this.virtualScreenPermissionCard()
            this.backgroundPhotoCard()
            this.audioCaptureCard()
          } else {
            this.aboutPage()
          }
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 24, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F4F8')
  }

  @Builder
  private loadingPanel() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(32)
        .height(32)
      Text('正在读取本机设置…')
        .fontSize(14)
        .fontColor('#536279')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private settingsErrorPanel() {
    Column({ space: 14 }) {
      Text('设置读取失败')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text(this.settingsError)
        .fontSize(13)
        .fontColor('#69788E')
        .width('100%')
      Button('重试')
        .width('100%')
        .onClick(() => this.retrySettingsLoad())
    }
    .width('100%')
    .padding(20)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private disclaimerPanel() {
    Column({ space: 14 }) {
      Text('首次使用说明')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Scroll() {
        Column({ space: 12 }) {
          Text('CarPlay 发送端是未获 Apple 或车厂授权的实验性项目，不是 MFi 认证产品；CarPlay、AirPlay 均为各自权利人的商标。')
            .fontSize(14)
            .fontColor('#31435C')
            .width('100%')
          Text('无线协议实现仍在开发。连接、配对、画面、触摸或声音可能失败或中断；本应用不能替代车机原厂导航、车辆仪表或安全关键系统。')
            .fontSize(14)
            .fontColor('#31435C')
            .width('100%')
          Text('仅在停车时设置和测试。行驶时驾驶员不得操作手机；如由乘客操作，也要以原厂导航作为安全冗余。')
            .fontSize(14)
            .fontColor('#9B4B00')
            .width('100%')
          Text('蓝牙设备信息、用户设置、AirPlay 配对身份和应用收藏保存在本机且不会进入系统备份。本版本不会保存车机 Wi-Fi 密码到偏好设置。')
            .fontSize(14)
            .fontColor('#31435C')
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .height(260)
      .width('100%')
      .backgroundColor('#FFFFFF')
      .borderRadius(14)
      .padding(14)
      Text(this.disclaimerRemaining > 0 ? `请阅读后继续（${this.disclaimerRemaining} 秒）` : '请确认已阅读以上说明')
        .fontSize(12)
        .fontColor('#69788E')
      Button(this.disclaimerRemaining > 0 ? `请稍候 ${this.disclaimerRemaining} 秒` : '我已阅读并同意，继续')
        .width('100%')
        .height(48)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .backgroundColor('#1769E0')
        .enabled(this.disclaimerRemaining === 0)
        .onClick(() => this.acceptDisclaimer())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 28, bottom: 28 })
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private navigationBar() {
    Row({ space: 7 }) {
      this.navButton('连接', 'connect')
      this.navButton('应用', 'apps')
      this.navButton('设置', 'settings')
      this.navButton('关于', 'about')
    }
    .width('100%')
    .padding(5)
    .backgroundColor('#E6EBF2')
    .borderRadius(14)
  }

  @Builder
  private navButton(label: string, tab: string) {
    Button(label)
      .layoutWeight(1)
      .height(38)
      .fontSize(13)
      .fontColor(this.activeTab === tab ? '#FFFFFF' : '#536279')
      .backgroundColor(this.activeTab === tab ? '#1769E0' : '#E6EBF2')
      .onClick(() => this.selectTab(tab))
  }

  @Builder
  private appsPage() {
    Column({ space: 14 }) {
      Text('本机应用')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text(this.projectionDisplayId > 0
        ? '已建立 CarPlay 虚拟屏；启动应用会投放到车机。'
        : '添加应用快捷方式。未连接 CarPlay 时会在手机打开；已连接时可投放到车机。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      if (this.projectionDisplayId > 0) {
        Button('显示 CarPlay 桌面 / 背景图')
          .width('100%')
          .height(40)
          .backgroundColor('#EAF2FF')
          .fontColor('#1769E0')
          .onClick(() => this.showProjectionHome())
      }
      Button('扫描常见地图应用')
        .width('100%')
        .height(42)
        .backgroundColor('#EAF2FF')
        .fontColor('#1769E0')
        .enabled(!this.isDiscoveringMapApps)
        .onClick(() => this.discoverMapApps(true))
      Text(this.mapDiscoveryStatus)
        .fontSize(11)
        .fontColor('#69788E')
        .width('100%')
      TextInput({ text: this.bundleNameInput, placeholder: '应用 bundle name，例如 com.example.maps' })
        .fontSize(14)
        .height(46)
        .backgroundColor('#F4F6F9')
        .borderRadius(10)
        .onChange((value: string) => this.bundleNameInput = value.trim())
      Button('验证并添加应用')
        .width('100%')
        .height(44)
        .fontSize(14)
        .backgroundColor('#172F56')
        .onClick(() => this.addFavoriteBundle())
      if (this.favoriteTargets.length === 0) {
        Text('尚未添加应用')
          .fontSize(13)
          .fontColor('#8B98A9')
      }
      ForEach(this.favoriteTargets, (target: AppLaunchTarget) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(target.label)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#17243A')
            Text(target.bundleName)
              .fontSize(10)
              .fontColor('#69788E')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button(this.projectionDisplayId >= 0 ? '投放' : '手机打开')
            .fontSize(12)
            .onClick(() => this.launchFavorite(target))
          Button('移除')
            .fontSize(12)
            .onClick(() => this.removeFavorite(target.bundleName))
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#F4F6F9')
        .borderRadius(10)
      }, (target: AppLaunchTarget) => target.bundleName)
      Text(this.settingsMessage)
        .fontSize(12)
        .fontColor('#536279')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private keepScreenCard() {
    Column({ space: 12 }) {
      Text('会话与显示')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text('常亮只作用于本应用窗口。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      Row({ space: 8 }) {
        Text(this.keepScreenOn ? '会话期间保持本应用窗口常亮：开' : '会话期间保持本应用窗口常亮：关')
          .fontSize(13)
          .fontColor('#31435C')
          .layoutWeight(1)
        Button(this.keepScreenOn ? '关闭' : '开启')
          .fontSize(12)
          .onClick(() => this.keepScreenOn = !this.keepScreenOn)
      }
      .width('100%')
      Row({ space: 8 }) {
        Text(this.allowMfiIntermediateDownload ? 'MFi 中间证书 AIA 下载：开' : 'MFi 中间证书 AIA 下载：关')
          .fontSize(12)
          .fontColor('#31435C')
          .layoutWeight(1)
        Button(this.allowMfiIntermediateDownload ? '关闭' : '开启')
          .fontSize(12)
          .enabled(!this.isSessionActive)
          .onClick(() => this.allowMfiIntermediateDownload = !this.allowMfiIntermediateDownload)
      }
      .width('100%')
      Text('默认关闭。开启后系统会请求接收端证书 AIA 中的 HTTP 中间证书地址；只对可信车机启用，PKIX 仍要求系统 CA 信任根。')
        .fontSize(11)
        .fontColor('#9B4B00')
        .width('100%')
      Button(this.isSessionActive ? '请先停止蓝牙监听再保存设置' : '保存设置')
        .width('100%')
        .height(44)
        .enabled(!this.isSessionActive)
        .backgroundColor('#1769E0')
        .fontColor('#FFFFFF')
        .onClick(() => this.saveSettings())
      Text(this.settingsMessage)
        .fontSize(12)
        .fontColor('#536279')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private mfiTrustCard() {
    Column({ space: 10 }) {
      Text('MFi 证书指纹信任')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text(this.trustedMfiFingerprints.length === 0
        ? '尚无人工固定的证书'
        : `已固定 ${this.trustedMfiFingerprints.length} 个证书指纹`)
        .fontSize(12)
        .fontColor('#69788E')
      ForEach(this.trustedMfiFingerprints, (fingerprint: string) => {
        Row({ space: 8 }) {
          Text(fingerprint)
            .fontSize(9)
            .fontColor('#31435C')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('撤销')
            .fontSize(11)
            .enabled(!this.isSessionActive)
            .onClick(() => this.revokeMfiFingerprint(fingerprint))
        }
        .width('100%')
        .padding(8)
        .backgroundColor('#F4F6F9')
        .borderRadius(8)
      }, (fingerprint: string) => fingerprint)
      Text('只固定完整 SHA-256 指纹。每次连接仍验证 challenge 签名；人工固定不代表 Apple/MFi 官方认证。')
        .fontSize(11)
        .fontColor('#9B4B00')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private audioCaptureCard() {
    Column({ space: 10 }) {
      Text('播放音频捕获')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text('已协商音频流后，授权捕获可向车机发送播放音频。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      Text(this.audioCaptureStatus)
        .fontSize(13)
        .fontColor('#31435C')
        .width('100%')
      Text(`本地捕获 ${this.audioBytesCaptured} 字节`)
        .fontSize(12)
        .fontColor('#69788E')
      Button(this.isAudioCapturing || this.isAudioCaptureRequesting ? '停止/取消捕获' : '请求播放音频捕获')
        .width('100%')
        .height(44)
        .backgroundColor('#172F56')
        .fontColor('#FFFFFF')
        .onClick(() => {
          if (this.isAudioCapturing || this.isAudioCaptureRequesting) {
            void this.stopAudioCapture();
          } else {
            void this.startAudioCapture();
          }
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private backgroundPhotoCard() {
    Column({ space: 10 }) {
      Text('CarPlay 背景图')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      if (this.backgroundPhotoThumbnail !== undefined) {
        Image(this.backgroundPhotoThumbnail)
          .width('100%')
          .height(180)
          .objectFit(ImageFit.Cover)
          .borderRadius(12)
      } else {
        Row() {
          Text('选择一张图片')
            .fontSize(14)
            .fontColor('#8B98A9')
        }
        .width('100%')
        .height(120)
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#F4F6F9')
        .borderRadius(12)
      }
      Text(this.backgroundPhotoStatus)
        .fontSize(12)
        .fontColor('#69788E')
      Row({ space: 8 }) {
        Button('选择图片')
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#1769E0')
          .fontColor('#FFFFFF')
          .onClick(() => this.chooseBackgroundPhoto())
        Button('清除')
          .width(72)
          .height(42)
          .enabled(this.backgroundPhotoUri.length > 0)
          .onClick(() => this.clearBackgroundPhoto())
      }
      .width('100%')
      Text('仅本机预览，暂不发送到车机。')
        .fontSize(11)
        .fontColor('#9B4B00')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private virtualScreenPermissionCard() {
    Column({ space: 10 }) {
      Text('虚拟屏权限')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text(this.virtualScreenPermissionStatus)
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      Button('检测系统授权')
        .width('100%')
        .height(42)
        .backgroundColor('#172F56')
        .fontColor('#FFFFFF')
        .onClick(() => this.checkVirtualScreenPermission())
      Text('只检测授权，不创建屏幕。需设备系统签名/白名单；触摸回注还需授权输入服务。')
        .fontSize(11)
        .fontColor('#9B4B00')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private aboutPage() {
    Column({ space: 10 }) {
      Text('功能与平台边界')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text('已实现：iAP2/MFi 校验、AirPlay RTSP 会话、授权 PCM 音频通路和常见地图快捷方式。')
        .fontSize(13)
        .fontColor('#31435C')
        .width('100%')
      Text('未完成：H.264 视频编码/画面源、AAC 和触控回传。')
        .fontSize(13)
        .fontColor('#9B4B00')
        .width('100%')
      Text('普通应用无法申请受信虚拟屏、全局屏幕采集和跨应用触控；地图快捷方式只在手机启动。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      Text('所有车辆测试必须在停车状态下进行。本项目为非官方实验实现，未经车厂或 Apple 认证。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private header() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Text('CP')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .width(48)
          .height(48)
          .textAlign(TextAlign.Center)
          .backgroundColor('#1769E0')
          .borderRadius(14)
        Column({ space: 3 }) {
          Text('CarPlay 发送端')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#17243A')
          Text('HarmonyOS API 26 · 无线连接')
            .fontSize(13)
            .fontColor('#69788E')
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private connectionCard() {
    Column({ space: 16 }) {
      Row({ space: 14 }) {
        Column({ space: 5 }) {
          Text('CarPlay')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#17243A')
          Text(this.isStarting ? '正在启动…' : this.status)
            .fontSize(13)
            .fontColor('#536279')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.isSessionActive })
          .enabled(!this.isStarting && !this.isStopping)
          .onChange((enabled: boolean): void => {
            if (enabled) {
              void this.startSession();
            } else {
              void this.stopSession();
            }
          })
      }
      .width('100%')
      Text(this.isSessionActive
        ? 'iAP2 → MFi → Wi-Fi 确认 → AirPlay'
        : '开启后等待车机蓝牙 iAP2 握手')
        .fontSize(11)
        .fontColor('#69788E')
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
  }

  @Builder
  private identityCard() {
    Column({ space: 12 }) {
      Text('发送端身份')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17243A')
      Text('系统不向普通应用提供通用蓝牙 MAC；车机要求时请手动填写。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      TextInput({ text: this.bluetoothAddress, placeholder: '本机蓝牙 MAC，例如 AA:BB:CC:DD:EE:FF' })
        .fontSize(14)
        .height(44)
        .backgroundColor('#F4F6F9')
        .borderRadius(10)
        .onChange((value: string) => this.bluetoothAddress = value.trim())
      TextInput({ text: this.deviceName, placeholder: '设备名称' })
        .fontSize(14)
        .height(44)
        .backgroundColor('#F4F6F9')
        .borderRadius(10)
        .onChange((value: string) => this.deviceName = value)
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private wifiCard() {
    Column({ space: 12 }) {
      Row() {
        Text('车机热点')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17243A')
        Blank()
        Text('iAP2 0x5703')
          .fontSize(11)
          .fontColor('#69788E')
      }
      .width('100%')
      Text('可自动填入或手动输入；加入网络需系统确认。')
        .fontSize(12)
        .fontColor('#69788E')
        .width('100%')
      TextInput({ text: this.wifiSsid, placeholder: '热点名称（SSID）' })
        .fontSize(14)
        .height(44)
        .backgroundColor('#F4F6F9')
        .borderRadius(10)
        .onChange((value: string) => this.wifiSsid = value)
      TextInput({ text: this.wifiPassword, placeholder: '热点密码' })
        .fontSize(14)
        .height(44)
        .type(InputType.Password)
        .backgroundColor('#F4F6F9')
        .borderRadius(10)
        .onChange((value: string) => this.wifiPassword = value)
      Button(this.isJoiningWifi ? '正在等待系统连接…' : '加入车机热点')
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .backgroundColor('#172F56')
        .enabled(!this.isJoiningWifi)
        .onClick(() => this.joinWifi())
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private logCard() {
    Column({ space: 8 }) {
      Row() {
        Text('连接日志')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17243A')
        Blank()
        Button('到底部')
          .fontSize(11)
          .height(30)
          .onClick(() => this.scrollLogsToBottom())
      }
      .width('100%')
      Scroll(this.logScroller) {
        Column({ space: 5 }) {
          if (this.logs.length === 0) {
            Text('开启 CarPlay 后，握手与连接进度会显示在这里')
              .fontSize(12)
              .fontColor('#8B98A9')
              .width('100%')
          }
          ForEach(this.logs, (entry: string) => {
            Text(entry)
              .fontSize(11)
              .fontColor('#536279')
              .width('100%')
          }, (entry: string) => entry)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(360)
      .scrollBar(BarState.Auto)
      .backgroundColor('#F7F8FA')
      .borderRadius(10)
      .padding(10)
      .onScroll((_xOffset: number, yOffset: number): void => {
        const contentHeight = this.logScroller.contentSize().height;
        this.logAtBottom = contentHeight - yOffset <= 400;
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .borderRadius(18)
    .alignItems(HorizontalAlign.Start)
  }

  private async loadSettings(): Promise<void> {
    const settings = await this.settingsStore.load(this.getAppContext());
    this.disclaimerAccepted = settings.disclaimerAccepted && settings.disclaimerVersion === DISCLAIMER_VERSION;
    this.deviceName = settings.deviceName;
    this.bluetoothAddress = settings.bluetoothAddress;
    this.deviceUuid = settings.deviceUuid || this.createDeviceUuid();
    this.wifiSsid = settings.lastSsid;
    this.keepScreenOn = settings.keepScreenOn;
    this.allowMfiIntermediateDownload = settings.allowMfiIntermediateDownload;
    this.trustedMfiFingerprints = settings.trustedMfiFingerprints;
    this.favoriteBundles = settings.favoriteBundles;
    this.backgroundPhotoUri = settings.backgroundPhotoUri;
    if (this.backgroundPhotoUri.length > 0) {
      try {
        this.backgroundPhotoThumbnail = await this.backgroundPhotoPicker.loadThumbnail(
          this.getAppContext(),
          this.backgroundPhotoUri
        );
        this.backgroundPhotoStatus = '背景图已保存';
      } catch (error) {
        this.backgroundPhotoStatus = `图片不可用：${error instanceof Error ? error.message : String(error)}`;
        this.addLog(this.backgroundPhotoStatus);
      }
    }
    this.settingsReady = true;
    if (!this.disclaimerAccepted) {
      this.startDisclaimerCountdown();
    }
    if (!settings.deviceUuid) {
      await this.persistSettings();
    }
  }

  private getAppContext(): common.UIAbilityContext {
    const hostContext = this.getUIContext().getHostContext();
    if (!hostContext) {
      throw new Error('无法获取应用上下文');
    }
    return hostContext as common.UIAbilityContext;
  }

  private collectSettings(disclaimerAccepted: boolean = this.disclaimerAccepted): CarDeckAppSettings {
    const settings: CarDeckAppSettings = {
      disclaimerAccepted,
      disclaimerVersion: DISCLAIMER_VERSION,
      deviceName: this.deviceName.trim() || 'Harmony CarPlay',
      bluetoothAddress: this.bluetoothAddress.trim(),
      deviceUuid: this.deviceUuid,
      lastSsid: this.wifiSsid.trim(),
      keepScreenOn: this.keepScreenOn,
      allowMfiIntermediateDownload: this.allowMfiIntermediateDownload,
      trustedMfiFingerprints: this.trustedMfiFingerprints.slice(),
      favoriteBundles: this.favoriteBundles.slice(),
      backgroundPhotoUri: this.backgroundPhotoUri
    };
    return settings;
  }

  private async persistSettings(disclaimerAccepted: boolean = this.disclaimerAccepted): Promise<void> {
    const settings = this.collectSettings(disclaimerAccepted);
    await this.settingsStore.save(this.getAppContext(), settings);
  }

  private async acceptDisclaimer(): Promise<void> {
    try {
      await this.persistSettings(true);
      this.disclaimerAccepted = true;
      this.stopDisclaimerCountdown();
      this.settingsMessage = '';
    } catch (error) {
      this.showError(error);
    }
  }

  private startDisclaimerCountdown(): void {
    if (this.disclaimerTimer >= 0 || this.disclaimerRemaining === 0) {
      return;
    }
    this.disclaimerTimer = setInterval((): void => {
      if (this.disclaimerRemaining > 0) {
        this.disclaimerRemaining--;
      }
      if (this.disclaimerRemaining === 0) {
        this.stopDisclaimerCountdown();
      }
    }, 1000);
  }

  private stopDisclaimerCountdown(): void {
    if (this.disclaimerTimer >= 0) {
      clearInterval(this.disclaimerTimer);
      this.disclaimerTimer = -1;
    }
  }

  private async retrySettingsLoad(): Promise<void> {
    this.settingsError = '';
    this.settingsReady = false;
    try {
      await this.loadSettings();
    } catch (error) {
      this.settingsError = error instanceof Error ? error.message : String(error);
      this.settingsReady = true;
    }
  }

  private async saveSettings(): Promise<void> {
    try {
      if (this.isSessionActive) {
        throw new Error('请先停止蓝牙监听，再修改发送端身份设置');
      }
      await this.persistSettings();
      this.controller = undefined;
      this.settingsMessage = '设置已保存在本机；Wi-Fi 密码不会被保存。';
    } catch (error) {
      this.showError(error);
    }
  }

  private async confirmMfiFingerprintTrust(info: MfiTrustPromptInfo): Promise<boolean> {
    const options: promptAction.ShowDialogOptions = {
      title: '是否固定并信任此证书？',
      message:
        '确认后仅在本应用中固定这个确切的叶证书 SHA-256 指纹，不会写入系统证书库。' +
        '人工固定会覆盖系统对证书链、KeyUsage 和未知 critical extension 的验证；应用仍会检查证书有效期，' +
        '且每次连接都必须通过 iAP2 challenge 签名验证。人工固定不代表 Apple/MFi 官方认证。\n\n' +
        `Subject: ${info.subject}\nIssuer: ${info.issuer}\nSHA-256: ${info.fingerprint}\n\n` +
        `PKIX: ${info.pkixFailure}`,
      buttons: [
        { text: '拒绝', color: '#69788E' },
        { text: '信任并固定指纹', color: '#B15B00' }
      ]
    };
    try {
      const response = await promptAction.showDialog(options);
      const approved = response.index === 1;
      this.addLog(`MFi 证书信任决策：${approved ? '用户同意' : '用户拒绝'} ${info.fingerprint}`);
      return approved;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.addLog(`MFi 信任确认窗口未完成，按拒绝处理：${message}`);
      return false;
    }
  }

  private async persistMfiFingerprint(fingerprint: string): Promise<void> {
    const normalized = fingerprint.toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(normalized)) {
      throw new Error('MFi 指纹不是有效 SHA-256，拒绝保存');
    }
    if (this.trustedMfiFingerprints.includes(normalized)) {
      return;
    }
    const previous = this.trustedMfiFingerprints;
    this.trustedMfiFingerprints = [...previous, normalized];
    try {
      await this.persistSettings();
      this.addLog(`MFi 指纹已在 challenge 签名验证成功后保存：${normalized}`);
    } catch (error) {
      this.trustedMfiFingerprints = previous;
      throw new Error(`保存 MFi 指纹失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private async revokeMfiFingerprint(fingerprint: string): Promise<void> {
    const previous = this.trustedMfiFingerprints;
    this.trustedMfiFingerprints = previous.filter((item: string) => item !== fingerprint);
    try {
      await this.persistSettings();
      this.settingsMessage = '已撤销 MFi 指纹信任';
      this.addLog(`已撤销 MFi 指纹：${fingerprint}`);
    } catch (error) {
      this.trustedMfiFingerprints = previous;
      this.showError(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private async chooseBackgroundPhoto(): Promise<void> {
    try {
      const selected = await this.backgroundPhotoPicker.pick(this.getAppContext());
      if (!selected) {
        return;
      }
      const previousUri = this.backgroundPhotoUri;
      const previousThumbnail = this.backgroundPhotoThumbnail;
      this.backgroundPhotoUri = selected.uri;
      this.backgroundPhotoThumbnail = selected.thumbnail;
      this.backgroundPhotoStatus = '正在保存背景图…';
      try {
        await this.persistSettings();
        this.backgroundPhotoStatus = '背景图已保存';
      } catch (error) {
        this.backgroundPhotoUri = previousUri;
        this.backgroundPhotoThumbnail = previousThumbnail;
        throw new Error(error instanceof Error ? error.message : String(error));
      }
    } catch (error) {
      this.showError(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private async clearBackgroundPhoto(): Promise<void> {
    const previousUri = this.backgroundPhotoUri;
    const previousThumbnail = this.backgroundPhotoThumbnail;
    this.backgroundPhotoUri = '';
    this.backgroundPhotoThumbnail = undefined;
    this.backgroundPhotoStatus = '未选择背景图';
    try {
      await this.persistSettings();
    } catch (error) {
      this.backgroundPhotoUri = previousUri;
      this.backgroundPhotoThumbnail = previousThumbnail;
      this.backgroundPhotoStatus = '清除失败，已恢复原背景图';
      this.showError(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private checkVirtualScreenPermission(): void {
    try {
      const virtualScreen = this.virtualScreenPermissionProbe.hasAccess();
      const inputInjection = this.virtualScreenPermissionProbe.hasTouchControl();
      this.virtualScreenPermissionStatus =
        `虚拟屏 ${virtualScreen ? '已授予' : '未授予'}；` +
        `跨应用输入 ${inputInjection ? '已授予' : '未授予'}`;
    } catch (error) {
      this.virtualScreenPermissionStatus =
        `检测失败：${error instanceof Error ? error.message : String(error)}`;
      this.addLog(this.virtualScreenPermissionStatus);
    }
  }

  private selectTab(tab: string): void {
    this.activeTab = tab;
    if (tab === 'connect') {
      this.scrollLogsToBottom();
    }
    if (tab === 'apps' && !this.mapDiscoveryDone) {
      void this.discoverMapApps();
    }
    if (tab === 'apps' && this.favoriteTargets.length === 0 && this.favoriteBundles.length > 0) {
      void this.loadFavoriteTargets();
    }
  }

  private async discoverMapApps(force: boolean = false): Promise<void> {
    if (this.mapDiscoveryDone && !force || this.isDiscoveringMapApps) {
      return;
    }
    this.isDiscoveringMapApps = true;
    const available: AppLaunchTarget[] = [];
    const unresolved: string[] = [];
    for (const candidate of DEFAULT_MAP_APPS) {
      try {
        available.push(await this.appLauncher.resolve(candidate.bundleName));
      } catch (error) {
        unresolved.push(
          `${candidate.name}: ${error instanceof Error ? error.message : String(error)}`
        );
      }
    }
    this.mapDiscoveryDone = true;
    if (available.length === 0) {
      this.mapDiscoveryStatus = unresolved.length > 0
        ? `未找到常见地图；可手动添加。${unresolved.length} 个包未能解析。`
        : '未发现常见地图；可手动填写 bundle name。';
      for (const error of unresolved) {
        this.addLog(error);
      }
      this.isDiscoveringMapApps = false;
      return;
    }
    const existingBundles = new Set<string>(this.favoriteBundles);
    const newTargets = available.filter((target: AppLaunchTarget): boolean =>
      !existingBundles.has(target.bundleName)
    );
    this.favoriteBundles = [...this.favoriteBundles, ...newTargets.map((target: AppLaunchTarget): string =>
      target.bundleName
    )];
    const currentTargets = new Map<string, AppLaunchTarget>();
    for (const target of this.favoriteTargets) {
      currentTargets.set(target.bundleName, target);
    }
    for (const target of available) {
      currentTargets.set(target.bundleName, target);
    }
    this.favoriteTargets = Array.from(currentTargets.values());
    this.mapDiscoveryStatus =
      `找到 ${available.length} 个常见地图快捷方式；仅在手机启动。未解析 ${unresolved.length} 个。`;
    for (const error of unresolved) {
      this.addLog(error);
    }
    if (newTargets.length > 0) {
      try {
        await this.persistSettings();
      } catch (error) {
        this.showError(error instanceof Error ? error : new Error(String(error)));
      }
    }
    this.isDiscoveringMapApps = false;
  }

  private async loadFavoriteTargets(): Promise<void> {
    const targets: AppLaunchTarget[] = [];
    for (const bundleName of this.favoriteBundles) {
      try {
        targets.push(await this.appLauncher.resolve(bundleName));
      } catch (error) {
        this.addLog(error instanceof Error ? error.message : String(error));
      }
    }
    this.favoriteTargets = targets;
  }

  private async addFavoriteBundle(): Promise<void> {
    const bundleName = this.bundleNameInput.trim();
    if (!bundleName) {
      this.showError(new Error('请输入 bundle name'));
      return;
    }
    try {
      const target = await this.appLauncher.resolve(bundleName);
      if (!this.favoriteBundles.includes(target.bundleName)) {
        this.favoriteBundles = [...this.favoriteBundles, target.bundleName];
        this.favoriteTargets = [...this.favoriteTargets, target];
        await this.persistSettings();
      }
      this.bundleNameInput = '';
      this.settingsMessage = `已添加 ${target.label}`;
    } catch (error) {
      this.showError(error);
    }
  }

  private async removeFavorite(bundleName: string): Promise<void> {
    this.favoriteBundles = this.favoriteBundles.filter((item: string) => item !== bundleName);
    this.favoriteTargets = this.favoriteTargets.filter((item: AppLaunchTarget) => item.bundleName !== bundleName);
    try {
      await this.persistSettings();
      this.settingsMessage = '应用已从收藏移除';
    } catch (error) {
      this.showError(error);
    }
  }

  private async launchFavorite(target: AppLaunchTarget): Promise<void> {
    try {
      if (this.projectionDisplayId > 0) {
        await this.appLauncher.launch(this.getAppContext(), target, this.projectionDisplayId);
        this.status = `已请求将 ${target.label} 投放到 CarPlay`;
      } else {
        await this.appLauncher.launch(this.getAppContext(), target);
        this.status = `已请求在手机启动 ${target.label}`;
      }
    } catch (error) {
      this.showError(error);
    }
  }

  private async showProjectionHome(): Promise<void> {
    if (this.projectionDisplayId <= 0) {
      return;
    }
    try {
      await this.appLauncher.launchProjectionHome(this.getAppContext(), this.projectionDisplayId);
      this.settingsMessage = 'CarPlay 桌面和背景图已投放';
    } catch (error) {
      this.showError(error);
    }
  }

  private async startAudioCapture(): Promise<void> {
    if (this.playbackCapture) {
      this.showError(new Error('播放音频捕获正在运行'));
      return;
    }
    this.audioBytesCaptured = 0;
    this.isAudioCaptureRequesting = true;
    const audioSession = this.audioRtpSession;
    if (audioSession) {
      const sender = new AudioRtpSender(
        (message: string): void => this.addLog(message),
        (message: string): void => this.showError(new Error(message))
      );
      try {
        await sender.start(audioSession);
        this.audioRtpSender = sender;
      } catch (error) {
        this.isAudioCaptureRequesting = false;
        this.showError(error instanceof Error ? error : new Error(String(error)));
        return;
      }
    }
    const capture = new PlaybackAudioCapture(
      (data: Uint8Array): void => {
        const sender = this.audioRtpSender;
        if (sender) {
          try {
            sender.pushPcm(data);
          } catch (error) {
            this.showError(error instanceof Error ? error : new Error(String(error)));
          }
        }
        this.pendingAudioBytes += data.length;
        if (this.audioStatsTimer < 0) {
          this.audioStatsTimer = setInterval((): void => {
            this.audioBytesCaptured += this.pendingAudioBytes;
            this.pendingAudioBytes = 0;
          }, 1000);
        }
      },
      (status: string): void => {
        this.audioCaptureStatus = status.startsWith('已授权捕获') && this.audioRtpSender
          ? `已授权捕获并发送 AirPlay 音频（${audioSession?.sampleRate ?? 48000}Hz）`
          : status;
        this.isAudioCapturing = status.startsWith('已授权捕获');
        if (this.isAudioCapturing) {
          this.isAudioCaptureRequesting = false;
        }
        if (status.includes('未获用户授权') || status.includes('启动失败')) {
          this.isAudioCaptureRequesting = false;
          this.playbackCapture = undefined;
          void this.stopAudioRtpSender();
        }
        if (status === '播放音频捕获已停止') {
          if (this.audioStatsTimer >= 0) {
            clearInterval(this.audioStatsTimer);
            this.audioStatsTimer = -1;
          }
          this.audioBytesCaptured += this.pendingAudioBytes;
          this.pendingAudioBytes = 0;
          this.isAudioCaptureRequesting = false;
          this.isAudioCapturing = false;
          this.playbackCapture = undefined;
          void this.stopAudioRtpSender();
        }
      },
      audioSession?.sampleRate ?? 48000
    );
    this.playbackCapture = capture;
    try {
      await capture.requestStart();
    } catch (error) {
      this.playbackCapture = undefined;
      this.isAudioCaptureRequesting = false;
      await this.stopAudioRtpSender();
      this.showError(error);
    }
  }

  private async stopAudioCapture(): Promise<void> {
    this.isAudioCaptureRequesting = false;
    if (this.audioStatsTimer >= 0) {
      clearInterval(this.audioStatsTimer);
      this.audioStatsTimer = -1;
    }
    this.audioBytesCaptured += this.pendingAudioBytes;
    this.pendingAudioBytes = 0;
    const capture = this.playbackCapture;
    this.playbackCapture = undefined;
    if (capture) {
      try {
        await capture.stop();
      } catch (error) {
        this.showError(error instanceof Error ? error : new Error(String(error)));
      }
    }
    await this.stopAudioRtpSender();
    this.isAudioCapturing = false;
  }

  private async stopAudioRtpSender(): Promise<void> {
    const sender = this.audioRtpSender;
    this.audioRtpSender = undefined;
    if (!sender) {
      return;
    }
    try {
      await sender.stop();
    } catch (error) {
      this.showError(error instanceof Error ? error : new Error(String(error)));
    }
  }

  private ensureController(): SessionController {
    if (!this.controller) {
      const context = this.getAppContext();
      const events: SessionEvents = {
        onStatus: (status: string): void => {
          this.status = status;
        },
        onLog: (message: string): void => {
          this.addLog(message);
        },
        onWifiCredentials: (credentials: WifiCredentials): void => {
          this.wifiSsid = credentials.ssid;
          this.wifiPassword = credentials.password;
          this.addLog(`iAP2 收到热点凭据：${credentials.ssid}（密码不记录）`);
        },
        onAirPlayService: (service: AirPlayService): void => {
          this.addLog(`AirPlay 服务已解析：${service.name} · ${service.host}:${service.port}`);
        },
        onAirPlayMediaSession: (info: AirPlayMediaSessionInfo): void => {
          this.audioRtpSession = info.audioSession;
          this.status = `RTSP 会话已建立；音频${info.audioSession ? '可用' : '不可用'}；正在启动 H.264 视频`;
          this.addLog(`RTSP RECORD 已完成；screen=${info.videoDataPort}，audio=${info.audioSession?.dataPort ?? 0}`);
        },
        onProjectionReady: async (displayId: number, width: number, height: number): Promise<void> => {
          this.projectionDisplayId = displayId;
          this.addLog(`CarPlay 虚拟屏就绪：${displayId} (${width}x${height})`);
          try {
            if (this.favoriteTargets.length === 0 && this.favoriteBundles.length > 0) {
              await this.loadFavoriteTargets();
            }
            const target = this.favoriteTargets[0];
            if (target) {
              try {
                await this.appLauncher.launch(context, target, displayId);
                this.addLog(`默认应用已启动到 CarPlay：${target.label}`);
                return;
              } catch (error) {
                this.addLog(
                  `默认应用不能启动到 CarPlay 屏幕：${error instanceof Error ? error.message : String(error)}`
                );
              }
            }
            await this.appLauncher.launchProjectionHome(context, displayId);
            this.addLog('已启动 CarPlay 本地桌面');
          } catch (error) {
            this.addLog(`CarPlay 桌面启动失败：${error instanceof Error ? error.message : String(error)}`);
          }
        },
        onProjectionStopped: (): void => {
          this.projectionDisplayId = -1;
        },
        requestMfiTrust: (info: MfiTrustPromptInfo): Promise<boolean> =>
          this.confirmMfiFingerprintTrust(info),
        persistMfiFingerprint: (fingerprint: string): Promise<void> =>
          this.persistMfiFingerprint(fingerprint)
      };
      this.controller = new SessionController(
        context,
        events,
        this.bluetoothAddress,
        this.deviceName,
        this.deviceUuid || this.createDeviceUuid(),
        this.keepScreenOn,
        this.allowMfiIntermediateDownload,
        this.trustedMfiFingerprints
      );
    }
    return this.controller;
  }

  private async startSession(): Promise<void> {
    this.isStarting = true;
    this.isSessionActive = true;
    try {
      await this.ensureController().start();
    } catch (error) {
      this.isSessionActive = false;
      this.showError(error);
    } finally {
      this.isStarting = false;
    }
  }

  private async stopSession(): Promise<void> {
    if (this.isStopping) {
      return;
    }
    this.isStopping = true;
    this.isSessionActive = false;
    const failures: string[] = [];
    try {
      await this.stopAudioCapture();
    } catch (error) {
      failures.push(`音频清理：${error instanceof Error ? error.message : String(error)}`);
    }
    try {
      await this.controller?.stop();
    } catch (error) {
      failures.push(error instanceof Error ? error.message : String(error));
    }
    this.controller = undefined;
    this.audioRtpSession = undefined;
    if (failures.length > 0) {
      this.showError(new Error(`停止会话时清理失败：${failures.join('；')}`));
    } else {
      this.status = '已停止';
    }
    this.isStopping = false;
  }

  private async joinWifi(): Promise<void> {
    this.isJoiningWifi = true;
    try {
      const controller = this.ensureController();
      controller.setManualWifi(this.wifiSsid, this.wifiPassword);
      await controller.joinVehicleWifi();
      await this.persistSettings();
    } catch (error) {
      this.showError(error);
    } finally {
      this.isJoiningWifi = false;
    }
  }

  private addLog(message: string): void {
    const timestamp = new Date().toLocaleTimeString();
    const followTail = this.logAtBottom;
    this.logs = appendConnectionLog(this.logs, `${timestamp}  ${message}`);
    if (followTail && this.activeTab === 'connect') {
      setTimeout((): void => {
        if (this.logAtBottom && this.activeTab === 'connect') {
          this.scrollLogsToBottom();
        }
      }, 40);
    }
  }

  private scrollLogsToBottom(): void {
    if (this.activeTab !== 'connect') {
      return;
    }
    setTimeout((): void => {
      try {
        this.logScroller.scrollEdge(Edge.Bottom);
        this.logAtBottom = true;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.logs = [...this.logs, `${new Date().toLocaleTimeString()}  日志滚动失败：${message}`].slice(-300);
      }
    }, 40);
  }

  private showError(error: Error): void {
    const message = error instanceof Error ? error.message : String(error);
    this.status = `错误：${message}`;
    this.addLog(`错误：${message}`);
  }

  private createDeviceUuid(): string {
    const randomPart = Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, '0');
    return `HOS-${Date.now().toString(16)}-${randomPart}`;
  }
}
