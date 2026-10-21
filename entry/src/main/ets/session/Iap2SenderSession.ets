import {
  concatBytes,
  decodeIap2Parameters,
  decodeIap2String,
  encodeIap2Control,
  encodeIap2LinkFrame,
  encodeIap2SyncPayload,
  Iap2ControlDecoder,
  Iap2LinkDecoder,
  Iap2LinkFrame,
  numberParameter,
  stringParameter
} from '../protocol/Iap2Codec';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { MfiVerifier, ValidatedMfiCertificate } from '../iap2/MfiVerifier';

const LINK_MARKER: Uint8Array = new Uint8Array([0xff, 0x55, 0x02, 0x00, 0xee, 0x10]);
interface Iap2MessageIds {
  IDENTIFICATION_START: number;
  IDENTIFICATION_INFORMATION: number;
  IDENTIFICATION_ACCEPTED: number;
  WIFI_REQUEST: number;
  WIFI_CONFIGURATION: number;
  MFI_CERTIFICATE_REQUEST: number;
  MFI_CERTIFICATE: number;
  MFI_CHALLENGE: number;
  MFI_RESPONSE: number;
  MFI_AUTHENTICATION_SUCCEEDED: number;
  CARPLAY_AVAILABILITY: number;
  CARPLAY_START_SESSION: number;
  WIRELESS_UPDATE: number;
  TRANSPORT_IDENTIFIER: number;
  START_HID: number;
  DEVICE_HID_REPORT: number;
  DEVICE_INFORMATION_UPDATE: number;
  DEVICE_LANGUAGE_UPDATE: number;
  DEVICE_TIME_UPDATE: number;
  DEVICE_UUID_UPDATE: number;
}

const MESSAGE: Iap2MessageIds = {
  IDENTIFICATION_START: 0x1d00,
  IDENTIFICATION_INFORMATION: 0x1d01,
  IDENTIFICATION_ACCEPTED: 0x1d02,
  WIFI_REQUEST: 0x5702,
  WIFI_CONFIGURATION: 0x5703,
  MFI_CERTIFICATE_REQUEST: 0xaa00,
  MFI_CERTIFICATE: 0xaa01,
  MFI_CHALLENGE: 0xaa02,
  MFI_RESPONSE: 0xaa03,
  MFI_AUTHENTICATION_SUCCEEDED: 0xaa05,
  CARPLAY_AVAILABILITY: 0x4300,
  CARPLAY_START_SESSION: 0x4301,
  WIRELESS_UPDATE: 0x4e0d,
  TRANSPORT_IDENTIFIER: 0x4e0e,
  START_HID: 0x6800,
  DEVICE_HID_REPORT: 0x6801,
  DEVICE_INFORMATION_UPDATE: 0x4e09,
  DEVICE_LANGUAGE_UPDATE: 0x4e0a,
  DEVICE_TIME_UPDATE: 0x4e0b,
  DEVICE_UUID_UPDATE: 0x4e0c
};

export interface WifiCredentials {
  ssid: string;
  password: string;
  securityType: number;
  channel: number;
}

export class Iap2SenderSession {
  private readonly linkDecoder: Iap2LinkDecoder = new Iap2LinkDecoder();
  private readonly controlDecoder: Iap2ControlDecoder = new Iap2ControlDecoder();
  private readonly sendBytes: (bytes: Uint8Array) => Promise<void>;
  private readonly log: (message: string) => void;
  private readonly onWifi: (credentials: WifiCredentials) => void;
  private readonly onEndpoint: (body: Uint8Array) => void;
  private readonly mfiVerifier: MfiVerifier;
  private readonly deviceAddress: string;
  private readonly deviceName: string;
  private readonly deviceUuid: string;
  private nextSequence: number = 99;
  private lastReceivedSequence: number = 0;
  private controlSessionId: number = 10;
  private started: boolean = false;
  private authenticated: boolean = false;
  private identificationRequested: boolean = false;
  private challengeLength: number = 32;
  private readonly challengeLengths: number[] = [32, 20, 16];
  private challengeIndex: number = 0;
  private validatedAccessoryCertificate?: ValidatedMfiCertificate;
  private pendingMfiChallenge?: Uint8Array;
  private transportIdentifierSent: boolean = false;
  private transportIdentifierPending: boolean = false;
  private transportIdentifierTimer?: number;
  private identificationTimer?: number;

  constructor(
    sendBytes: (bytes: Uint8Array) => Promise<void>,
    log: (message: string) => void,
    onWifi: (credentials: WifiCredentials) => void,
    onEndpoint: (body: Uint8Array) => void,
    deviceAddress: string,
    deviceName: string,
    deviceUuid: string,
    allowMfiIntermediateDownload: boolean = false
  ) {
    this.sendBytes = sendBytes;
    this.log = log;
    this.onWifi = onWifi;
    this.onEndpoint = onEndpoint;
    this.deviceAddress = deviceAddress;
    this.deviceName = deviceName;
    this.deviceUuid = deviceUuid;
    this.mfiVerifier = new MfiVerifier(log, allowMfiIntermediateDownload);
  }

  get isAccessoryVerified(): boolean {
    return this.authenticated;
  }

  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    const syncFrame: Iap2LinkFrame = {
      control: 0x80,
      sequence: this.takeSequence(),
      acknowledgement: 0,
      sessionId: 0,
      payload: encodeIap2SyncPayload()
    };
    await this.sendBytes(concatBytes(LINK_MARKER, encodeIap2LinkFrame(syncFrame)));
    this.log('已发送 iAP2 链路同步包，等待车机协商');
  }

  async receive(bytes: Uint8Array): Promise<void> {
    for (const frame of this.linkDecoder.push(bytes)) {
      await this.receiveLinkFrame(frame);
    }
  }

  async onWifiConnected(): Promise<void> {
    if (!this.authenticated) {
      throw new Error('未完成车机 MFi 证书/签名验证；不会发送 CarPlay 会话启动消息');
    }
    await this.sendControl(MESSAGE.WIRELESS_UPDATE, numberParameter(0, 1, 1));
    await this.sendControl(MESSAGE.DEVICE_LANGUAGE_UPDATE, stringParameter(0, 'zh-CN'));
    await this.sendControl(MESSAGE.DEVICE_INFORMATION_UPDATE, stringParameter(0, this.deviceName));
    const now = new Date();
    const epochSeconds = Math.floor(now.getTime() / 1000);
    const time = new Uint8Array(8);
    let remaining = epochSeconds;
    for (let index = 7; index >= 0; index--) {
      time[index] = remaining & 0xff;
      remaining = Math.floor(remaining / 256);
    }
    const timeZoneMinutes = 0 - now.getTimezoneOffset();
    await this.sendControl(MESSAGE.DEVICE_TIME_UPDATE, concatBytes(
        this.parameter(0, time),
        numberParameter(1, timeZoneMinutes, 2),
        numberParameter(2, 0, 1)
      ));
    await this.sendControl(MESSAGE.DEVICE_UUID_UPDATE, stringParameter(0, this.deviceUuid));
    await this.sendControl(MESSAGE.CARPLAY_AVAILABILITY, this.parameter(1, concatBytes(
        numberParameter(0, 1, 1),
        stringParameter(1, this.deviceAddress)
      )));
      this.transportIdentifierTimer = setTimeout((): void => {
        this.transportIdentifierTimer = undefined;
        void this.sendTransportIdentifier().catch((error: Error): void => {
          this.log(`发送 iAP2 传输标识失败：${error.message}`);
        });
      }, 3000);
      this.log('已上报设备信息并请求 CarPlay 会话');
  }

  cancel(): void {
      if (this.identificationTimer !== undefined) {
        clearTimeout(this.identificationTimer);
        this.identificationTimer = undefined;
      }
      if (this.transportIdentifierTimer !== undefined) {
        clearTimeout(this.transportIdentifierTimer);
        this.transportIdentifierTimer = undefined;
      }
      this.started = false;
  }

  private async receiveLinkFrame(frame: Iap2LinkFrame): Promise<void> {
    if ((frame.control & 0x80) !== 0 && frame.payload.length >= 10) {
      const peerControlSession = this.readControlSessionId(frame.payload);
      if (peerControlSession === undefined) {
        throw new Error('iAP2 同步包没有声明控制会话，无法发送 IDENTIFICATION_START');
      }
      this.lastReceivedSequence = frame.sequence;
      this.controlSessionId = peerControlSession;
      const isSynAck = (frame.control & 0x40) !== 0;
      if (isSynAck) {
        this.log(`收到 iAP2 SYN-ACK，控制会话 ${this.controlSessionId}`);
      } else {
        const echoedSync = frame.payload.slice();
        echoedSync[1] = 0x7f;
        const acknowledgement: Iap2LinkFrame = {
          control: 0xc0,
          sequence: this.takeSequence(),
          acknowledgement: frame.sequence,
          sessionId: 0,
          payload: echoedSync
        };
        await this.sendBytes(encodeIap2LinkFrame(acknowledgement));
        this.log(`收到 iAP2 同步包，控制会话 ${this.controlSessionId}`);
      }
      if (!this.identificationRequested) {
        this.identificationRequested = true;
        await this.sendControl(MESSAGE.IDENTIFICATION_START);
        this.log('已发送 iAP2 IDENTIFICATION_START，等待车机识别信息');
        this.identificationTimer = setTimeout((): void => {
          this.identificationTimer = undefined;
          if (!this.validatedAccessoryCertificate && !this.authenticated) {
            this.log('等待 iAP2 0x1D01 超时：检查车机是否接受 SYN-ACK、RFCOMM 链路序号与识别消息');
          }
        }, 8000);
      }
      return;
    }
    if ((frame.control & 0x40) === 0 || frame.payload.length === 0) {
      return;
    }
    this.lastReceivedSequence = frame.sequence;
    const acknowledgement: Iap2LinkFrame = {
      control: 0x40,
      sequence: this.nextSequence++ & 0xff,
      acknowledgement: frame.sequence,
      sessionId: 0,
      payload: new Uint8Array(0)
    };
    await this.sendBytes(encodeIap2LinkFrame(acknowledgement));
    if (frame.sessionId !== this.controlSessionId && frame.sessionId !== 0) {
      this.log(`忽略未协商的 iAP2 会话 ${frame.sessionId}`);
      return;
    }
    for (const message of this.controlDecoder.push(frame.payload)) {
      await this.receiveControlMessage(message.messageId, message.body);
    }
  }

  private readControlSessionId(payload: Uint8Array): number | undefined {
    for (let offset = 10; offset + 2 < payload.length; offset += 3) {
      const sessionId = payload[offset];
      const sessionKind = payload[offset + 1];
      if (sessionId !== undefined && sessionId > 0 && sessionKind === 0) {
        return sessionId;
      }
    }
    return undefined;
  }

  private async receiveControlMessage(messageId: number, body: Uint8Array): Promise<void> {
    this.log(`收到 iAP2 消息 0x${messageId.toString(16).padStart(4, '0')}`);
    if (messageId === MESSAGE.IDENTIFICATION_INFORMATION) {
      if (this.identificationTimer !== undefined) {
        clearTimeout(this.identificationTimer);
        this.identificationTimer = undefined;
      }
      this.chooseChallengeLength(body);
      await this.sendControl(MESSAGE.IDENTIFICATION_ACCEPTED);
      await this.sendControl(MESSAGE.MFI_CERTIFICATE_REQUEST);
      return;
    }
    if (messageId === MESSAGE.MFI_CERTIFICATE) {
      const certificatePayload = decodeIap2Parameters(body).find((param) => param.id === 0)?.value;
      if (!certificatePayload || certificatePayload.length === 0) {
        throw new Error('车机 MFi 证书消息中没有证书数据');
      }
      this.validatedAccessoryCertificate =
        await this.mfiVerifier.validateAccessoryCertificate(certificatePayload);
      await this.sendMfiChallenge();
      return;
    }
    if (messageId === 0xaa04) {
      this.challengeIndex++;
      if (this.challengeIndex < this.challengeLengths.length) {
        await this.sendMfiChallenge();
      } else {
        this.log('车机拒绝了所有支持的 MFi 挑战长度');
      }
      return;
    }
    if (messageId === MESSAGE.MFI_RESPONSE) {
      const certificate = this.validatedAccessoryCertificate;
      const challenge = this.pendingMfiChallenge;
      const signature = decodeIap2Parameters(body).find((param) => param.id === 0)?.value;
      if (!certificate || !challenge || !signature) {
        throw new Error('MFi challenge 响应缺少证书、挑战或签名数据');
      }
      await this.mfiVerifier.verifyChallenge(certificate, challenge, signature);
      this.authenticated = true;
      this.validatedAccessoryCertificate = undefined;
      this.pendingMfiChallenge = undefined;
      await this.sendControl(MESSAGE.MFI_AUTHENTICATION_SUCCEEDED);
      await this.sendControl(MESSAGE.WIFI_REQUEST);
      this.log('MFi X.509 证书链与 challenge 签名已通过系统信任验证；已请求车机 Wi-Fi 配置');
      return;
    }
    if (messageId === MESSAGE.WIFI_CONFIGURATION) {
      const credentials = this.parseWifi(body);
      if (!credentials.ssid) {
        throw new Error('车机返回的 iAP2 Wi-Fi 配置中没有 SSID');
      }
      this.onWifi(credentials);
      return;
    }
    if (messageId === MESSAGE.CARPLAY_START_SESSION) {
      this.onEndpoint(body);
      await this.sendTransportIdentifier();
      return;
    }
    if (messageId === MESSAGE.START_HID) {
      await this.sendControl(MESSAGE.DEVICE_HID_REPORT);
      return;
    }
    if (messageId === MESSAGE.CARPLAY_AVAILABILITY && !this.authenticated) {
      this.log('车机请求开始 CarPlay，但 iAP2 认证尚未完成');
    }
  }

  private async sendControl(messageId: number, body: Uint8Array = new Uint8Array(0)): Promise<void> {
    const encoded = encodeIap2Control(messageId, body);
    const maximumPayload = 1014;
    for (let offset = 0; offset < encoded.length; offset += maximumPayload) {
      const payload = encoded.slice(offset, Math.min(encoded.length, offset + maximumPayload));
      const linkFrame: Iap2LinkFrame = {
        control: 0x40,
        sequence: this.takeSequence(),
        acknowledgement: this.lastReceivedSequence,
        sessionId: this.controlSessionId,
        payload
      };
      await this.sendBytes(encodeIap2LinkFrame(linkFrame));
    }
  }

  private parameter(id: number, value: Uint8Array): Uint8Array {
    const result = new Uint8Array(4 + value.length);
    result[0] = (result.length >>> 8) & 0xff;
    result[1] = result.length & 0xff;
    result[2] = (id >>> 8) & 0xff;
    result[3] = id & 0xff;
    result.set(value, 4);
    return result;
  }

  private takeSequence(): number {
    const sequence = this.nextSequence;
    this.nextSequence = (this.nextSequence + 1) & 0xff;
    return sequence;
  }

  private chooseChallengeLength(body: Uint8Array): void {
    const params = decodeIap2Parameters(body);
    let identity = '';
    for (const param of params) {
      if (param.id <= 2) {
        identity += `${decodeIap2String(param.value)} `;
      }
    }
    const normalized = identity.toLowerCase();
    this.challengeLength = normalized.includes('audi') ||
        normalized.includes('mib') ||
        normalized.includes('delphi') ||
        normalized.includes('harman') ||
        normalized.includes('porsche') ? 20 : 32;
    this.challengeIndex = this.challengeLengths.indexOf(this.challengeLength);
    this.log(`车机身份已读取，首选 MFi challenge ${this.challengeLength}B`);
  }

  private async sendMfiChallenge(): Promise<void> {
    const length = this.challengeLengths[this.challengeIndex] ?? this.challengeLength;
    const challenge = await cryptoFramework.createRandom().generateRandom(length);
    this.pendingMfiChallenge = new Uint8Array(challenge.data);
    await this.sendControl(MESSAGE.MFI_CHALLENGE, this.parameter(0, this.pendingMfiChallenge));
    this.log(`已发送 ${length} 字节 MFi challenge；等待证书签名验证`);
  }

  private async sendTransportIdentifier(): Promise<void> {
    if (this.transportIdentifierSent || this.transportIdentifierPending) {
      return;
    }
    this.transportIdentifierPending = true;
    if (this.transportIdentifierTimer !== undefined) {
      clearTimeout(this.transportIdentifierTimer);
      this.transportIdentifierTimer = undefined;
    }
    try {
      await this.sendControl(MESSAGE.TRANSPORT_IDENTIFIER, stringParameter(0, this.deviceAddress));
      this.transportIdentifierSent = true;
    } finally {
      this.transportIdentifierPending = false;
    }
  }

  private parseWifi(body: Uint8Array): WifiCredentials {
    const params = decodeIap2Parameters(body);
    const values = new Map<number, Uint8Array>();
    for (const param of params) {
      values.set(param.id, param.value);
    }
    const result: WifiCredentials = {
      ssid: decodeIap2String(values.get(1) ?? new Uint8Array(0)),
      password: decodeIap2String(values.get(2) ?? new Uint8Array(0)),
      securityType: values.get(3)?.[0] ?? 0,
      channel: values.get(4)?.[0] ?? 0
    };
    return result;
  }
}
