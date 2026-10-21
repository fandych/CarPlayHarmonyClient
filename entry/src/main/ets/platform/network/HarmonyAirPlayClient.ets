import { common } from '@kit.AbilityKit';
import { BinaryPlist, BinaryPlistValue } from '../../protocol/airplay/BinaryPlist';
import { RtspRequestHeader } from '../../protocol/airplay/RtspRequestEncoder';
import { RtspResponse } from '../../protocol/airplay/RtspResponseParser';
import { PairSetupClient, PairVerifyClient, AirPlayControlKeys, ReceiverIdentity } from '../../protocol/airplay/AirPlayPairingClient';
import { HarmonyControllerIdentityStore } from '../security/HarmonyControllerIdentityStore';
import { HarmonyAirPlayPairingStore } from '../security/HarmonyAirPlayPairingStore';
import { AirPlayServiceEndpoint } from './HarmonyMdnsBrowser';

import { HarmonyAirPlayRtspSession } from './HarmonyAirPlayRtspSession';
import { HarmonyAirPlayPairingTransport } from './HarmonyAirPlayPairingTransport';

export class AirPlayPairingResult {
  readonly receiver: ReceiverIdentity;
  readonly controlKeys: AirPlayControlKeys;

  constructor(receiver: ReceiverIdentity, controlKeys: AirPlayControlKeys) {
    this.receiver = receiver;
    this.controlKeys = controlKeys;
  }
}

export class AirPlayVerifiedRtspSession {
  readonly receiver: ReceiverIdentity;
  readonly controlKeys: AirPlayControlKeys;
  private readonly session: HarmonyAirPlayRtspSession;
  private closed: boolean = false;

  constructor(
    session: HarmonyAirPlayRtspSession,
    receiver: ReceiverIdentity,
    controlKeys: AirPlayControlKeys
  ) {
    this.session = session;
    this.receiver = receiver;
    this.controlKeys = controlKeys;
  }

  request(
    method: string,
    target: string,
    body: Uint8Array = new Uint8Array(0),
    headers: RtspRequestHeader[] = []
  ): Promise<RtspResponse> {
    if (this.closed) {
      throw new Error('Verified AirPlay RTSP session is closed.');
    }
    return this.session.request(method, target, body, headers);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    await this.session.close();
  }
}

export class HarmonyAirPlayClient {
  async inspect(endpoint: AirPlayServiceEndpoint, log: (message: string) => void): Promise<RtspResponse> {
    const session = new HarmonyAirPlayRtspSession();
    try {
      await session.connect(endpoint);
      return await session.request('GET', '/info');
    } finally {
      try {
        await session.close();
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        log(`关闭 AirPlay RTSP 探测连接失败（${detail}）。`);
      }
    }
  }

  async pairAndVerify(
    context: common.UIAbilityContext,
    endpoint: AirPlayServiceEndpoint,
    log: (message: string) => void
  ): Promise<AirPlayPairingResult> {
    const verifiedSession = await this.openVerifiedSession(context, endpoint, log);
    try {
      return new AirPlayPairingResult(verifiedSession.receiver, verifiedSession.controlKeys);
    } finally {
      try {
        await verifiedSession.close();
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        log(`关闭 AirPlay 配对连接失败（${detail}）。`);
      }
    }
  }

  async openVerifiedSession(
    context: common.UIAbilityContext,
    endpoint: AirPlayServiceEndpoint,
    log: (message: string) => void
  ): Promise<AirPlayVerifiedRtspSession> {
    if (endpoint.homeKitPairingSupported === false) {
      throw new Error('The AirPlay endpoint explicitly does not support HomeKit pairing.');
    }
    const session = new HarmonyAirPlayRtspSession();
    try {
      await session.connect(endpoint);
      const pairing = await this.performPairing(context, endpoint, session, log);
      return new AirPlayVerifiedRtspSession(session, pairing.receiver, pairing.controlKeys);
    } catch (error) {
      try {
        await session.close();
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        log(`配对失败后的 AirPlay RTSP 清理失败（${detail}）。`);
      }
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  private async performPairing(
    context: common.UIAbilityContext,
    endpoint: AirPlayServiceEndpoint,
    session: HarmonyAirPlayRtspSession,
    log: (message: string) => void
  ): Promise<AirPlayPairingResult> {
    const identityStore = new HarmonyControllerIdentityStore();
    const transport = new HarmonyAirPlayPairingTransport(session);
    const pairingStore = new HarmonyAirPlayPairingStore(context);
    const storedReceiver = await pairingStore.load(endpoint, identityStore);
    let receiver: ReceiverIdentity;
    if (storedReceiver !== undefined) {
      receiver = storedReceiver;
      log('找到已验证的 AirPlay 配件身份，跳过 pair-setup 并执行 pair-verify。');
    } else {
      receiver = await new PairSetupClient(identityStore, transport, log).run();
    }
    const controlKeys = await new PairVerifyClient(identityStore, transport, log).run(receiver);
    session.enableControlEncryption(controlKeys);
    if (storedReceiver === undefined) {
      try {
        await pairingStore.save(endpoint, receiver, identityStore);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        log(`pair-verify 已成功，但保存配件身份缓存失败；后续可能需要重新配对（${detail}）。`);
      }
    }
    return new AirPlayPairingResult(receiver, controlKeys);
  }

  static describeInfo(response: RtspResponse): string {
    if (response.statusCode !== 200) {
      return `AirPlay /info 返回 ${response.statusCode} ${response.reason || '(无状态说明)'}。`;
    }
    if (response.body.length === 0) {
      return 'AirPlay /info 返回成功，但没有能力清单数据。';
    }
    let value: BinaryPlistValue;
    try {
      value = BinaryPlist.parse(response.body);
    } catch {
      return `AirPlay /info 返回成功，但 Binary Plist 解析失败（${response.body.length} 字节）。`;
    }
    if (!(value instanceof Map)) {
      return 'AirPlay /info 返回的能力清单不是字典。';
    }
    const name = value.get('name');
    const model = value.get('model');
    return `AirPlay /info 能力清单已解析${typeof name === 'string' ? `：${name}` : ''}${typeof model === 'string' ? ` / ${model}` : ''}。`;
  }
}
