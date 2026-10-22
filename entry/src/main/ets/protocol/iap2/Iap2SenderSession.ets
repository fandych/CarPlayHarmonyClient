import cryptoFramework from '@ohos.security.cryptoFramework';
import { Iap2Csm, Iap2CsmFrame, Iap2Param, Iap2CsmParser } from './Iap2Csm';
import { CarPlayInviteProtocol } from '../airplay/CarPlayInviteProtocol';
import { MfiVerifier, ValidatedMfiCertificate } from './MfiVerifier';

export interface AccessoryWifiConfiguration {
  ssid: string;
  passphrase: string;
  securityType: number;
  channel: number;
}

export interface CarPlayStartSessionEndpoint {
  ssid: string;
  passphrase: string;
  securityType: number;
  channel: number;
  airPlayPort: number;
  deviceIdentifier: string;
  publicKey: string;
  sourceVersion: string;
  ipAddresses: string[];
}

type SessionLogger = (message: string) => void;
type SendControl = (bytes: Uint8Array) => void;
type WifiConfigurationListener = (configuration: AccessoryWifiConfiguration) => void;
type EndpointListener = (endpoint: CarPlayStartSessionEndpoint) => void;
type MfiStageListener = (stage: 'authenticating' | 'authenticated') => void;
type SecureRandomBytes = (length: number) => Promise<Uint8Array>;

function concatenateParameters(parameters: Uint8Array[]): Uint8Array {
  let length = 0;
  parameters.forEach((parameter: Uint8Array) => length += parameter.length);
  const output = new Uint8Array(length);
  let offset = 0;
  parameters.forEach((parameter: Uint8Array) => {
    output.set(parameter, offset);
    offset += parameter.length;
  });
  return output;
}

const MFI_REQUEST_CERTIFICATE = 0xAA00;
const MFI_CERTIFICATE = 0xAA01;
const MFI_REQUEST_CHALLENGE = 0xAA02;
const MFI_RESPONSE = 0xAA03;
const MFI_AUTHENTICATION_FAILED = 0xAA04;
const MFI_AUTHENTICATION_SUCCEEDED = 0xAA05;
const REQUEST_ACCESSORY_WIFI_CONFIGURATION = 0x5702;
const ACCESSORY_WIFI_CONFIGURATION = 0x5703;
const START_HID = 0x6800;
const DEVICE_HID_REPORT = 0x6801;
const CARPLAY_AVAILABILITY = 0x4300;
const CARPLAY_START_SESSION = 0x4301;

export class Iap2SenderSession {
  private readonly parser: Iap2CsmParser = new Iap2CsmParser();
  private active: boolean = true;
  private authenticationSent: boolean = false;
  private authenticated: boolean = false;
  private challengeStarted: boolean = false;
  private mfiFailed: boolean = false;
  private identificationReceived: boolean = false;
  private challengeTimer: number = -1;
  private challengeLengths: number[] = [];
  private challengeAttemptIndex: number = 0;
  private prefer20ByteChallenge: boolean = true;
  private validatedAccessoryCertificate: ValidatedMfiCertificate | undefined = undefined;
  private pendingMfiChallenge: Uint8Array | undefined = undefined;
  private receiveQueue: Promise<void> = Promise.resolve();
  private readonly sendControl: SendControl;
  private readonly log: SessionLogger;
  private readonly onWifiConfiguration: WifiConfigurationListener;
  private readonly onEndpoint: EndpointListener | undefined;
  private readonly onBlocked: ((reason: string) => void) | undefined;
  private readonly realBluetoothAddress: string | undefined;
  private readonly deviceName: string;
  private readonly onWifiPending: (() => void) | undefined;
  private readonly mfiVerifier: MfiVerifier;
  private readonly onFailure: (reason: string) => void;
  private readonly onMfiStage: MfiStageListener;
  private readonly secureRandomBytes: SecureRandomBytes;
  private availabilitySent: boolean = false;
  private accessorySendMessageIds: Set<number> | undefined = undefined;
  private accessoryReceiveMessageIds: Set<number> | undefined = undefined;

  constructor(
    sendControl: SendControl,
    log: SessionLogger,
    onWifiConfiguration: WifiConfigurationListener,
    onEndpoint?: EndpointListener,
    onBlocked?: (reason: string) => void,
    realBluetoothAddress?: string,
    deviceName: string = 'Harmony CarPlay',
    onWifiPending?: () => void,
    mfiVerifier?: MfiVerifier,
    onFailure: (reason: string) => void = () => {},
    onMfiStage: MfiStageListener = () => {},
    secureRandomBytes?: SecureRandomBytes
  ) {
    this.sendControl = sendControl;
    this.log = log;
    this.onWifiConfiguration = onWifiConfiguration;
    this.onEndpoint = onEndpoint;
    this.onBlocked = onBlocked;
    this.realBluetoothAddress = realBluetoothAddress === undefined ? undefined :
      CarPlayInviteProtocol.createTxtIdentity(realBluetoothAddress).toUpperCase();
    if (deviceName.trim().length === 0 || /[\x00-\x1F]/.test(deviceName)) {
      throw new Error('iAP2 设备名不能为空或包含控制字符。');
    }
    this.deviceName = deviceName;
    this.onWifiPending = onWifiPending;
    this.mfiVerifier = mfiVerifier ?? new MfiVerifier(log);
    this.onFailure = onFailure;
    this.onMfiStage = onMfiStage;
    this.secureRandomBytes = secureRandomBytes ?? (async (length: number): Promise<Uint8Array> =>
      (await cryptoFramework.createRandom().generateRandom(length)).data);
  }

  start(): void {
    this.sendMessage(0x1D00);
    this.log('已发送 iAP2 设备识别请求。');
  }

  receive(bytes: Uint8Array): void {
    if (!this.active) {
      return;
    }
    const frames = this.parser.offer(bytes);
    for (let index = 0; index < frames.length; index++) {
      if (!this.active) {
        break;
      }
      const frame = frames[index];
      this.receiveQueue = this.receiveQueue.then(async (): Promise<void> => {
        if (this.active) {
          await this.handleFrame(frame);
        }
      }).catch((error: Error) => {
        this.failAuthentication(error instanceof Error ? error.message : String(error));
      });
    }
  }

  close(): void {
    this.active = false;
    this.clearChallengeTimer();
    this.clearPendingChallenge();
  }

  async whenIdle(): Promise<void> {
    await this.receiveQueue;
  }

  private async handleFrame(frame: Iap2CsmFrame): Promise<void> {
    this.log(`iAP2 rx type=0x${frame.messageId.toString(16).padStart(4, '0')}; bodyBytes=${frame.body.length}。`);
    switch (frame.messageId) {
      case 0x1D01:
        await this.handleIdentification(frame);
        break;
      case MFI_CERTIFICATE:
        await this.beginMfiChallenge(frame);
        break;
      case MFI_RESPONSE:
        await this.completeMfiAuthentication(frame);
        break;
      case MFI_AUTHENTICATION_FAILED:
        await this.retryMfiChallenge('车机拒绝了当前长度的 MFi challenge。');
        break;
      case ACCESSORY_WIFI_CONFIGURATION:
        if (this.authenticated) {
          this.handleWifiConfiguration(frame);
        } else {
          this.log('认证完成前收到 Wi-Fi 配置；已忽略。');
        }
        break;
      case CARPLAY_START_SESSION:
        if (this.authenticated) {
          this.handleStartSession(frame);
        } else {
          this.log('认证完成前收到 CarPlayStartSession；已忽略。');
        }
        break;
      case START_HID:
        if (this.authenticated) {
          this.sendMessage(
            DEVICE_HID_REPORT,
            concatenateParameters([
              Iap2Csm.u16(0, 0),
              Iap2Csm.param(1, new Uint8Array([0]))
            ])
          );
          this.log('已响应车机 StartHID 请求。');
        } else {
          this.log('认证完成前收到 StartHID；已忽略。');
        }
        break;
      default:
        this.log(`收到 iAP2 消息 0x${frame.messageId.toString(16).padStart(4, '0')}。`);
        break;
    }
  }

  private async handleIdentification(frame: Iap2CsmFrame): Promise<void> {
    if (this.identificationReceived || this.authenticationSent || this.mfiFailed) {
      this.log('忽略重复或过期的 iAP2 设备身份消息。');
      return;
    }
    this.identificationReceived = true;
    const params = Iap2Csm.parseParams(frame.body);
    const name = this.stringParam(params, 0);
    const model = this.stringParam(params, 1);
    const manufacturer = this.stringParam(params, 2);
    this.accessorySendMessageIds = this.parseDeclaredMessageIds(params, 6, '发送');
    this.accessoryReceiveMessageIds = this.parseDeclaredMessageIds(params, 7, '接收');
    const identity = `${name} ${model} ${manufacturer}`.toLowerCase();
    this.prefer20ByteChallenge = identity.indexOf('audi') >= 0 || identity.indexOf('mib') >= 0 ||
      identity.indexOf('delphi') >= 0 || identity.indexOf('harman') >= 0 || identity.indexOf('porsche') >= 0;
    this.log(`车机身份已解析；hasName=${name.length > 0}; hasModel=${model.length > 0}; ` +
      `hasManufacturer=${manufacturer.length > 0}; prefer20ByteChallenge=${this.prefer20ByteChallenge}。`);
    this.sendMessage(0x1D02);
    this.sendMessage(MFI_REQUEST_CERTIFICATE);
    this.onMfiStage('authenticating');
    this.log('已回送 IDENTIFICATION_ACCEPTED，并请求 MFi 证书；等待 AA01。');
  }

  private async beginMfiChallenge(frame: Iap2CsmFrame): Promise<void> {
    if (!this.identificationReceived || this.challengeStarted || this.authenticationSent || this.mfiFailed) {
      this.log('忽略握手阶段不匹配或重复的 MFi 证书消息。');
      return;
    }
    this.challengeStarted = true;
    const certificate = Iap2Csm.parseParams(frame.body).find((parameter: Iap2Param) => parameter.id === 0)?.value;
    if (certificate === undefined || certificate.length === 0) {
      throw new Error('车机 AA01 消息缺少 MFi 证书参数。');
    }
    this.log(`已收到 MFi 证书数据（${certificate.length} 字节）；正在验证证书链。`);
    this.validatedAccessoryCertificate = await this.mfiVerifier.validateAccessoryCertificate(certificate);
    if (!this.active) {
      return;
    }
    this.challengeLengths = this.prefer20ByteChallenge ? [20, 32, 16] : [32, 20, 16];
    this.challengeAttemptIndex = 0;
    await this.sendMfiChallenge();
  }

  private async sendMfiChallenge(): Promise<void> {
    if (!this.active || this.authenticationSent || this.mfiFailed) {
      return;
    }
    if (this.challengeAttemptIndex >= this.challengeLengths.length) {
      this.failAuthentication('所有兼容 MFi challenge 长度均失败；不会发送认证成功标记。');
      return;
    }

    const attemptIndex = this.challengeAttemptIndex;
    const length = this.challengeLengths[attemptIndex];
    try {
      const random = await this.secureRandomBytes(length);
      if (!this.active || this.authenticationSent || attemptIndex !== this.challengeAttemptIndex) {
        random.fill(0);
        return;
      }
      this.clearPendingChallenge();
      if (random.length !== length) {
        random.fill(0);
        throw new Error(`secure random provider returned ${random.length} bytes; expected ${length}`);
      }
      this.pendingMfiChallenge = random.slice();
      random.fill(0);
      this.sendMessage(MFI_REQUEST_CHALLENGE, Iap2Csm.param(0, this.pendingMfiChallenge));
      this.log(`已发送 ${length} 字节 MFi challenge（${attemptIndex + 1}/${this.challengeLengths.length}），等待签名响应。`);
      this.challengeTimer = setTimeout(() => {
        this.challengeTimer = -1;
        void this.retryMfiChallenge(`MFi ${length} 字节 challenge 超时。`);
      }, length === 20 ? 6000 : 3000);
    } catch (error) {
      throw new Error(`安全随机数生成 MFi challenge 失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private async retryMfiChallenge(reason: string): Promise<void> {
    if (!this.active || this.authenticationSent || this.mfiFailed || !this.challengeStarted) {
      return;
    }
    this.clearChallengeTimer();
    this.clearPendingChallenge();
    this.log(reason);
    this.challengeAttemptIndex++;
    await this.sendMfiChallenge();
  }

  private async completeMfiAuthentication(frame: Iap2CsmFrame): Promise<void> {
    if (!this.active || this.authenticationSent || this.mfiFailed) {
      return;
    }
    const certificate = this.validatedAccessoryCertificate;
    const challenge = this.pendingMfiChallenge;
    const responseParameters = Iap2Csm.parseParams(frame.body);
    const signature = responseParameters.find((parameter: Iap2Param) => parameter.id === 0)?.value;
    if (certificate === undefined || challenge === undefined || signature === undefined || signature.length === 0) {
      throw new Error(
        `MFi AA03 响应缺少必需数据 (certificate=${certificate !== undefined}, ` +
          `challenge=${challenge !== undefined}, signature=${signature !== undefined && signature.length > 0}, ` +
          `parameterIds=${responseParameters.map((parameter: Iap2Param) => parameter.id).join(',')})。`
      );
    }
    this.clearChallengeTimer();
    await this.mfiVerifier.verifyChallenge(certificate, challenge, signature);
    if (!this.active) {
      return;
    }
    this.clearPendingChallenge();
    this.validatedAccessoryCertificate = undefined;
    this.authenticationSent = true;
    this.authenticated = true;
    this.onMfiStage('authenticated');
    this.log('MFi 证书链信任与 challenge 签名验证成功。');
    this.sendMessage(MFI_AUTHENTICATION_SUCCEEDED);
    this.log('已发送 MFi 认证成功标记。');
    this.beginPostAuthentication();
  }

  private beginPostAuthentication(): void {
    this.onWifiPending?.();
    const canReceiveWifiRequest = this.accessoryReceiveMessageIds?.has(REQUEST_ACCESSORY_WIFI_CONFIGURATION);
    const canSendWifiConfiguration = this.accessorySendMessageIds?.has(ACCESSORY_WIFI_CONFIGURATION);
    if (canReceiveWifiRequest !== false && canSendWifiConfiguration !== false) {
      this.sendMessage(REQUEST_ACCESSORY_WIFI_CONFIGURATION);
      this.log('已请求车机 Wi-Fi 配置。');
      return;
    }
    this.log('车机能力清单不支持旧版 Wi-Fi 配置交换，改用新版 0x4300 身份交换。');
    this.sendCarPlayAvailability();
  }

  private failAuthentication(reason: string): void {
    if (this.mfiFailed || this.authenticationSent) {
      return;
    }
    this.mfiFailed = true;
    this.clearChallengeTimer();
    this.clearPendingChallenge();
    this.validatedAccessoryCertificate = undefined;
    this.active = false;
    this.log(`MFi 认证失败：${reason}`);
    this.onFailure(reason);
  }

  private clearChallengeTimer(): void {
    if (this.challengeTimer >= 0) {
      clearTimeout(this.challengeTimer);
      this.challengeTimer = -1;
    }
  }

  private clearPendingChallenge(): void {
    this.pendingMfiChallenge?.fill(0);
    this.pendingMfiChallenge = undefined;
  }

  private sendCarPlayAvailability(): void {
    if (!this.active || this.availabilitySent) {
      return;
    }
    const address = this.realBluetoothAddress;
    if (address === undefined) {
      const reason = '新版 0x4300/邀请服务需要本机真实蓝牙身份；自动读取不可用且尚未配置合法的手动备用地址。';
      this.log(reason);
      this.onBlocked?.(reason);
      return;
    }
    this.availabilitySent = true;
    if (this.accessoryReceiveMessageIds?.has(0x4E09) !== false) {
      this.sendMessage(0x4E09, Iap2Csm.string(0, this.deviceName));
    }
    if (this.accessoryReceiveMessageIds?.has(CARPLAY_AVAILABILITY) === false) {
      this.log('车机能力清单排除了 0x4300；不发送未声明支持的新版请求，端点等待 iAP2/mDNS。');
      return;
    }
    this.sendMessage(CARPLAY_AVAILABILITY, Iap2Csm.group(
      1, Iap2Csm.u8(0, 1), Iap2Csm.string(1, address)
    ));
    this.log('已发送 CarPlayAvailability；使用系统验证的本机蓝牙身份。');
  }

  private handleWifiConfiguration(frame: Iap2CsmFrame): void {
    const params = Iap2Csm.parseParams(frame.body);
    const configuration: AccessoryWifiConfiguration = {
      ssid: this.stringParam(params, 1),
      passphrase: this.stringParam(params, 2),
      securityType: this.byteParam(params, 3),
      channel: this.byteParam(params, 4)
    };
    if (configuration.ssid.length === 0) {
      this.log('车机返回的 Wi-Fi 配置缺少 SSID，已拒绝继续。');
      return;
    }
    this.log(`收到车机 Wi-Fi 配置：hasSsid=true，信道=${configuration.channel}，安全类型=${configuration.securityType}。`);
    if (this.realBluetoothAddress === undefined) {
      this.sendCarPlayAvailability();
      return;
    }
    this.onWifiConfiguration(configuration);
    this.sendCarPlayAvailability();
  }

  private handleStartSession(frame: Iap2CsmFrame): void {
    const endpoint = parseCarPlayStartSession(frame);
    this.log(
      `收到 CarPlayStartSession：AirPlay=${endpoint.ipAddresses.join(',') || '未提供'}:${endpoint.airPlayPort}，` +
      `hasSsid=${endpoint.ssid.length > 0}，版本=${endpoint.sourceVersion || '未知'}。`
    );
    if (this.realBluetoothAddress !== undefined &&
      this.accessoryReceiveMessageIds?.has(0x4E0E) !== false) {
      this.sendMessage(0x4E0E, Iap2Csm.string(0, this.realBluetoothAddress));
      this.log('已发送 DeviceTransportIdentifier；与 0x4300/邀请服务使用同一本机身份。');
    }
    this.onEndpoint?.(endpoint);
  }

  private stringParam(params: Iap2Param[], id: number): string {
    const param = params.find((item) => item.id === id);
    return param === undefined ? '' : Iap2Csm.asString(param) ?? '';
  }

  private byteParam(params: Iap2Param[], id: number): number {
    const param = params.find((item) => item.id === id);
    return param === undefined || param.value.length === 0 ? 0 : param.value[0];
  }

  private parseDeclaredMessageIds(
    params: Iap2Param[],
    parameterId: number,
    direction: string
  ): Set<number> | undefined {
    const parameter = params.find((item) => item.id === parameterId);
    if (parameter === undefined) {
      return undefined;
    }
    try {
      const messageIds = Iap2Csm.asU16List(parameter);
      this.log(`车机声明可${direction} ${messageIds.length} 种 iAP2 消息。`);
      return new Set<number>(messageIds);
    } catch {
      this.log(`车机 iAP2 ${direction}消息清单格式无效；按能力未知处理。`);
      return undefined;
    }
  }

  private sendMessage(messageId: number, body: Uint8Array = new Uint8Array(0)): void {
    if (this.active) {
      this.log(`iAP2 tx type=0x${messageId.toString(16).padStart(4, '0')}; bodyBytes=${body.length}。`);
      this.sendControl(Iap2Csm.encode(messageId, body));
    }
  }
}

export function parseCarPlayStartSession(frame: Iap2CsmFrame): CarPlayStartSessionEndpoint {
  const parameters = Iap2Csm.parseParams(frame.body);
  const getParameter = (id: number): Iap2Param | undefined =>
    parameters.find((parameter: Iap2Param) => parameter.id === id);
  const wirelessParameter = getParameter(1);
  const wireless = wirelessParameter === undefined ? [] : Iap2Csm.parseParams(wirelessParameter.value);
  const strings: string[] = wireless
    .map((parameter: Iap2Param) => cString(parameter))
    .filter((value: string) => value.length > 0);
  const ipAddresses = strings.filter((value: string) => isIpAddress(value));
  const accessPointStrings = strings.filter((value: string) => !isIpAddress(value));
  const ssid = accessPointStrings[0] ?? '';
  const passphrase = accessPointStrings[1] ?? '';
  const singleByteValues = new Map<number, number>();
  wireless.forEach((parameter: Iap2Param) => {
    if (parameter.value.length === 1) {
      singleByteValues.set(parameter.id, parameter.value[0]);
    }
  });
  const securityType = [singleByteValues.get(4), singleByteValues.get(3)]
    .find((value: number | undefined) => value !== undefined && value >= 0 && value <= 4) ?? 0;
  const channel = [singleByteValues.get(2), singleByteValues.get(4), singleByteValues.get(3)]
    .find((value: number | undefined) =>
      value !== undefined && value >= 1 && value <= 196 && value !== securityType) ?? 0;

  return {
    ssid: ssid.length <= 32 ? ssid : '',
    passphrase,
    securityType,
    channel,
    airPlayPort: readUnsigned(getParameter(2)),
    deviceIdentifier: cString(getParameter(3)),
    publicKey: cString(getParameter(4)),
    sourceVersion: cString(getParameter(5)),
    ipAddresses
  };
}

function cString(parameter: Iap2Param | undefined): string {
  if (parameter === undefined || parameter.value.length === 0) {
    return '';
  }
  let length = parameter.value.length;
  while (length > 0 && parameter.value[length - 1] === 0) {
    length--;
  }
  const value = new Uint8Array(length + 1);
  value.set(parameter.value.slice(0, length));
  const stringParameter: Iap2Param = { id: parameter.id, value };
  return Iap2Csm.asString(stringParameter) ?? '';
}

function readUnsigned(parameter: Iap2Param | undefined): number {
  if (parameter === undefined || parameter.value.length === 0 || parameter.value.length > 4) {
    return 0;
  }
  let value = 0;
  for (let index = 0; index < parameter.value.length; index++) {
    value = (value * 256) + parameter.value[index];
  }
  return value;
}

function isIpAddress(value: string): boolean {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(value) || value.indexOf(':') >= 0;
}
