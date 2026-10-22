import cryptoFramework from '@ohos.security.cryptoFramework';
import { Iap2Csm, Iap2CsmFrame, Iap2Param, Iap2CsmParser } from './Iap2Csm';
import { CarPlayInviteProtocol } from '../airplay/CarPlayInviteProtocol';

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
  private challengeStarted: boolean = false;
  private challengeTimer: number = -1;
  private challengeLengths: number[] = [];
  private challengeAttemptIndex: number = 0;
  private prefer20ByteChallenge: boolean = true;
  private readonly sendControl: SendControl;
  private readonly log: SessionLogger;
  private readonly onWifiConfiguration: WifiConfigurationListener;
  private readonly onEndpoint: EndpointListener | undefined;
  private readonly onBlocked: ((reason: string) => void) | undefined;
  private readonly realBluetoothAddress: string | undefined;
  private readonly deviceName: string;
  private readonly onWifiPending: (() => void) | undefined;
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
    onWifiPending?: () => void
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
      this.handleFrame(frames[index]);
    }
  }

  close(): void {
    this.active = false;
    if (this.challengeTimer >= 0) {
      clearTimeout(this.challengeTimer);
      this.challengeTimer = -1;
    }
  }

  private handleFrame(frame: Iap2CsmFrame): void {
    this.log(`iAP2 rx type=0x${frame.messageId.toString(16).padStart(4, '0')}; bodyBytes=${frame.body.length}。`);
    switch (frame.messageId) {
      case 0x1D01:
        this.handleIdentification(frame);
        break;
      case MFI_CERTIFICATE:
        this.beginMfiChallenge(frame);
        break;
      case MFI_RESPONSE:
        this.completeAuthentication(`收到 MFi 挑战响应（${frame.body.length} 字节）；兼容流程跳过签名校验。`);
        break;
      case MFI_AUTHENTICATION_FAILED:
        this.retryMfiChallenge('车机拒绝了当前长度的 MFi 挑战。');
        break;
      case ACCESSORY_WIFI_CONFIGURATION:
        this.handleWifiConfiguration(frame);
        break;
      case CARPLAY_START_SESSION:
        this.handleStartSession(frame);
        break;
      case START_HID:
        this.sendMessage(
          DEVICE_HID_REPORT,
          concatenateParameters([
            Iap2Csm.u16(0, 0),
            Iap2Csm.param(1, new Uint8Array([0]))
          ])
        );
        this.log('已响应车机 StartHID 请求。');
        break;
      default:
        this.log(`收到 iAP2 消息 0x${frame.messageId.toString(16).padStart(4, '0')}。`);
        break;
    }
  }

  private handleIdentification(frame: Iap2CsmFrame): void {
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
    this.log('已接受车机身份并请求 MFi 证书。');
  }

  private beginMfiChallenge(frame: Iap2CsmFrame): void {
    if (this.challengeStarted || this.authenticationSent) {
      return;
    }
    this.challengeStarted = true;
    this.log(`已收到 MFi 证书（${frame.body.length} 字节）；正在生成一次性挑战。`);
    this.challengeLengths = this.prefer20ByteChallenge ? [20, 32, 16] : [32, 20, 16];
    this.challengeAttemptIndex = 0;
    this.sendMfiChallenge();
  }

  private sendMfiChallenge(): void {
    if (!this.active || this.authenticationSent) {
      return;
    }
    if (this.challengeAttemptIndex >= this.challengeLengths.length) {
      this.completeAuthentication('MFi 挑战档位均无应答或被拒；按发送端兼容流程继续。');
      return;
    }

    const attemptIndex = this.challengeAttemptIndex;
    const length = this.challengeLengths[attemptIndex];
    try {
      cryptoFramework.createRandom().generateRandom(length).then((random) => {
        if (!this.active || this.authenticationSent || attemptIndex !== this.challengeAttemptIndex) {
          return;
        }
        this.sendMessage(MFI_REQUEST_CHALLENGE, Iap2Csm.param(0, random.data));
        this.log(`已发送 ${length} 字节 MFi 挑战（${attemptIndex + 1}/${this.challengeLengths.length}），等待车机响应。`);
        this.challengeTimer = setTimeout(() => {
          this.challengeTimer = -1;
          this.retryMfiChallenge(`MFi ${length} 字节挑战超时。`);
        }, length === 20 ? 6000 : 3000);
      }, (error: Error) => {
        if (this.active) {
          this.log(`安全随机数生成失败，无法继续 MFi 挑战：${error.message}`);
        }
      });
    } catch (error) {
      if (this.active) {
        this.log(`安全随机数服务不可用，无法继续 MFi 挑战：${error instanceof Error ? error.message : '未知错误'}`);
      }
    }
  }

  private retryMfiChallenge(reason: string): void {
    if (!this.active || this.authenticationSent || !this.challengeStarted) {
      return;
    }
    if (this.challengeTimer >= 0) {
      clearTimeout(this.challengeTimer);
      this.challengeTimer = -1;
    }
    this.log(reason);
    this.challengeAttemptIndex++;
    this.sendMfiChallenge();
  }

  private completeAuthentication(reason: string): void {
    if (!this.active || this.authenticationSent) {
      return;
    }
    this.authenticationSent = true;
    if (this.challengeTimer >= 0) {
      clearTimeout(this.challengeTimer);
      this.challengeTimer = -1;
    }
    this.log(reason);
    this.sendMessage(MFI_AUTHENTICATION_SUCCEEDED);
    this.log('已发送 MFi 发送端成功标记。');
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
