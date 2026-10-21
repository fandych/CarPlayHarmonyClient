import common from '@ohos.app.ability.common';
import { AirPlayService } from '../network/AirPlayMdnsDiscovery';
import { concatBytes, decodeUtf8, encodeUtf8 } from '../protocol/Iap2Codec';
import { chachaOpen, chachaSeal } from '../crypto/AirPlayStreamCrypto';
import { BinaryPlist } from './BinaryPlist';
import {
  generateX25519KeyPair,
  hkdfSha512,
  signEd25519,
  verifyEd25519,
  x25519SharedSecret
} from './AirPlayCrypto';
import { AirPlayControllerIdentity, AirPlayIdentityStore } from './AirPlayIdentityStore';
import { AirPlayMediaSession, AirPlayMediaSessionInfo } from './AirPlayMediaSession';
import { AirPlayRtspClient, AirPlayRtspResponse } from './AirPlayRtspClient';
import { PlistNode } from './BinaryPlist';
import { Srp6aSession } from './Srp6aClient';
import { decodeTlv8, encodeTlv8, Tlv8Item, Tlv8Type } from './Tlv8';

export interface AirPlayPairingResult {
  receiverId: string;
  encryptedControl: boolean;
  model: string;
  features: string;
}

interface PairSetupResult {
  receiverId: string;
}

export class AirPlayRtspStatusError extends Error {
  readonly statusCode: number;

  constructor(response: AirPlayRtspResponse) {
    super(`AirPlay RTSP server returned ${response.statusLine}`);
    this.statusCode = response.statusCode;
  }
}

export class AirPlayPairingClient {
  private readonly identityStore: AirPlayIdentityStore = new AirPlayIdentityStore();
  private readonly log: (message: string) => void;
  private client?: AirPlayRtspClient;
  private service?: AirPlayService;
  private receiverInfo?: PlistNode;
  private sharedSecret?: Uint8Array;
  private mediaSession?: AirPlayMediaSession;

  constructor(log: (message: string) => void) {
    this.log = log;
  }

  async pair(context: common.UIAbilityContext, service: AirPlayService): Promise<AirPlayPairingResult> {
    const receiverPublicKey = decodeHex(service.txt['pk'] ?? '');
    if (receiverPublicKey.length !== 32) {
      throw new Error('AirPlay mDNS TXT 没有有效的 32 字节 receiver public key；拒绝未验证的配对');
    }
    const identity = await this.identityStore.loadOrCreate(context);
    try {
      await this.connect(service);
      let setupReceiverId = '';
      let usedPairVerifyFastPath = false;
      try {
        const client = this.client;
        if (!client) {
          throw new Error('AirPlay RTSP connection disappeared before pair-setup');
        }
        const setup = new PairSetupClient(client, identity, this.log);
        const receiver = await setup.run(receiverPublicKey);
        setupReceiverId = receiver.receiverId;
      } catch (error) {
        if (!(error instanceof AirPlayRtspStatusError) || error.statusCode !== 403 || identity.newlyCreated) {
            throw error instanceof Error ? error : new Error(String(error));
        }
        this.log('pair-setup 被拒绝；仅对已有本地身份尝试已配对设备的 pair-verify 快路径');
        await this.close();
        await this.connect(service);
        usedPairVerifyFastPath = true;
      }

      const client = this.client;
      if (!client) {
        throw new Error('AirPlay RTSP connection disappeared during pairing');
      }
      const keys = await new PairVerifyClient(client, identity, this.log).run(receiverPublicKey);
      if (setupReceiverId && setupReceiverId !== keys.receiverId) {
        throw new Error('pair-setup and pair-verify receiver identities do not match');
      }
      client.activateEncryption(keys.phoneReadKey, keys.phoneWriteKey);
      const infoResponse = await client.request(
        'POST',
        '/info',
        new Uint8Array(0),
        { contentType: 'application/x-apple-binary-plist' }
      );
      if (infoResponse.statusCode !== 200) {
        throw new AirPlayRtspStatusError(infoResponse);
      }
      const info = BinaryPlist.decode(infoResponse.body);
      if (info.kind !== 'dictionary') {
        throw new Error('AirPlay /info response is not a binary plist dictionary');
      }
      const modelNode = info.get('model');
      const featureNode = info.get('features');
      const model = modelNode?.kind === 'string' ? modelNode.stringValue : '未提供';
      const features = featureNode?.kind === 'integer'
        ? `0x${featureNode.integerValue.toString(16)}`
        : featureNode?.kind === 'string' ? featureNode.stringValue : '未提供';
      const receiverId = setupReceiverId || keys.receiverId;
      this.service = service;
      this.receiverInfo = info;
      this.sharedSecret = keys.sharedSecret.slice();
      this.log(
        `AirPlay pair-verify 已通过：receiver=${receiverId} model=${model} features=${features} ` +
          `路径=${usedPairVerifyFastPath ? '已配对快路径' : '新配对'}`
      );
      const result: AirPlayPairingResult = { receiverId, encryptedControl: true, model, features };
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      try {
        await this.close();
      } catch (cleanupError) {
        const cleanupMessage = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
        throw new Error(`${message}; RTSP cleanup failed: ${cleanupMessage}`);
      }
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  private async connect(service: AirPlayService): Promise<void> {
    const client = new AirPlayRtspClient(this.log);
    this.client = client;
    try {
      await client.connect(service.host, service.port);
    } catch (error) {
      this.client = undefined;
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`连接 AirPlay 接收端失败：${message}`);
    }
  }

  async startCarPlaySession(deviceId: string, deviceName: string): Promise<AirPlayMediaSessionInfo> {
    const client = this.client;
    const receiverInfo = this.receiverInfo;
    const sharedSecret = this.sharedSecret;
    const service = this.service;
    if (!client || !receiverInfo || !sharedSecret || !service) {
      throw new Error('AirPlay pair-verify must succeed before starting a media session');
    }
    if (this.mediaSession) {
      throw new Error('AirPlay media session is already active');
    }
    const session = new AirPlayMediaSession(
      client,
      service.host,
      (message: string): void => this.log(message)
    );
    this.mediaSession = session;
    try {
      return await session.start(deviceId, deviceName, sharedSecret, receiverInfo);
    } catch (error) {
      this.mediaSession = undefined;
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async close(): Promise<void> {
    const failures: string[] = [];
    const mediaSession = this.mediaSession;
    this.mediaSession = undefined;
    if (mediaSession) {
      try {
        await mediaSession.stop();
      } catch (error) {
        failures.push(`AirPlay media session: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    const client = this.client;
    this.client = undefined;
    this.service = undefined;
    this.receiverInfo = undefined;
    this.sharedSecret = undefined;
    if (client) {
      try {
        await client.close();
      } catch (error) {
        failures.push(`AirPlay RTSP client: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (failures.length > 0) {
      throw new Error(`AirPlay cleanup failed: ${failures.join('; ')}`);
    }
  }
}

class PairSetupClient {
  private readonly client: AirPlayRtspClient;
  private readonly identity: AirPlayControllerIdentity;
  private readonly log: (message: string) => void;

  constructor(client: AirPlayRtspClient, identity: AirPlayControllerIdentity, log: (message: string) => void) {
    this.client = client;
    this.identity = identity;
    this.log = log;
  }

  async run(receiverPublicKey: Uint8Array): Promise<PairSetupResult> {
    const m2 = decodeTlv8(await this.exchange('/pair-setup', [
      { type: Tlv8Type.METHOD, value: new Uint8Array([0]) },
      { type: Tlv8Type.STATE, value: new Uint8Array([1]) }
    ]));
    const salt = required(m2, Tlv8Type.SALT, 'pair-setup M2 salt');
    const serverPublic = required(m2, Tlv8Type.PUBLIC_KEY, 'pair-setup M2 public key');
    this.log(`pair-setup M2 received: salt=${salt.length}B, B=${serverPublic.length}B`);

    const srp = await Srp6aSession.start(salt, serverPublic);
    const clientProof = await srp.clientProof();
    const m4 = decodeTlv8(await this.exchange('/pair-setup', [
      { type: Tlv8Type.STATE, value: new Uint8Array([3]) },
      { type: Tlv8Type.PUBLIC_KEY, value: srp.publicKeyA },
      { type: Tlv8Type.PROOF, value: clientProof }
    ]));
    requireState(m4, 4, 'pair-setup M4');
    const serverProof = required(m4, Tlv8Type.PROOF, 'pair-setup M4 proof');
    if (!(await srp.verifyServerProof(serverProof))) {
      throw new Error('pair-setup SRP server proof verification failed');
    }
    const sessionKey = srp.getSessionKey();
    this.log('pair-setup SRP mutual proof verified');

    const encryptionKey = await hkdfSha512(
      sessionKey,
      encodeUtf8('Pair-Setup-Encrypt-Salt'),
      encodeUtf8('Pair-Setup-Encrypt-Info')
    );
    const controllerSignKey = await hkdfSha512(
      sessionKey,
      encodeUtf8('Pair-Setup-Controller-Sign-Salt'),
      encodeUtf8('Pair-Setup-Controller-Sign-Info')
    );
    const identifier = encodeUtf8(this.identity.pairingId);
    const controllerSignature = await signEd25519(
      this.identity.privateKeyDer,
      concatBytes(controllerSignKey, identifier, this.identity.publicKeyRaw)
    );
    const innerM5 = encodeTlv8([
      { type: Tlv8Type.IDENTIFIER, value: identifier },
      { type: Tlv8Type.PUBLIC_KEY, value: this.identity.publicKeyRaw },
      { type: Tlv8Type.SIGNATURE, value: controllerSignature }
    ]);
    const encryptedM5 = await chachaSeal(encryptionKey, nonceLabel('PS-Msg05'), innerM5, new Uint8Array(0));
    const m6 = decodeTlv8(await this.exchange('/pair-setup', [
      { type: Tlv8Type.STATE, value: new Uint8Array([5]) },
      { type: Tlv8Type.ENCRYPTED_DATA, value: encryptedM5 }
    ]));
    requireState(m6, 6, 'pair-setup M6');

    const encryptedM6 = required(m6, Tlv8Type.ENCRYPTED_DATA, 'pair-setup M6 encrypted data');
    const innerM6 = decodeTlv8(await chachaOpen(
      encryptionKey,
      nonceLabel('PS-Msg06'),
      encryptedM6,
      new Uint8Array(0)
    ));
    const receiverIdentifierBytes = required(innerM6, Tlv8Type.IDENTIFIER, 'pair-setup receiver identifier');
    const receiverKey = required(innerM6, Tlv8Type.PUBLIC_KEY, 'pair-setup receiver public key');
    const receiverSignature = required(innerM6, Tlv8Type.SIGNATURE, 'pair-setup receiver signature');
    if (receiverKey.length !== receiverPublicKey.length || !constantTimeEqual(receiverKey, receiverPublicKey)) {
      throw new Error('pair-setup receiver key does not match the AirPlay mDNS identity');
    }
    const accessorySignKey = await hkdfSha512(
      sessionKey,
      encodeUtf8('Pair-Setup-Accessory-Sign-Salt'),
      encodeUtf8('Pair-Setup-Accessory-Sign-Info')
    );
    const receiverSignedMessage = concatBytes(accessorySignKey, receiverIdentifierBytes, receiverKey);
    if (!(await verifyEd25519(receiverKey, receiverSignedMessage, receiverSignature))) {
      throw new Error('pair-setup receiver Ed25519 signature verification failed');
    }
    const receiver: PairSetupResult = {
      receiverId: decodeUtf8(receiverIdentifierBytes)
    };
    this.log(`pair-setup receiver identity verified: ${receiver.receiverId}`);
    return receiver;
  }

  private async exchange(path: string, items: Tlv8Item[]): Promise<Uint8Array> {
    const body = encodeTlv8(items);
    const response = await this.client.request(
      'POST',
      path,
      body,
      { contentType: 'application/pairing+tlv8', appleHkp: true }
    );
    if (response.statusCode !== 200) {
      throw new AirPlayRtspStatusError(response);
    }
    return response.body;
  }
}

interface PairVerifyKeys {
  phoneWriteKey: Uint8Array;
  phoneReadKey: Uint8Array;
  sharedSecret: Uint8Array;
  receiverId: string;
}

class PairVerifyClient {
  private readonly client: AirPlayRtspClient;
  private readonly identity: AirPlayControllerIdentity;
  private readonly log: (message: string) => void;

  constructor(client: AirPlayRtspClient, identity: AirPlayControllerIdentity, log: (message: string) => void) {
    this.client = client;
    this.identity = identity;
    this.log = log;
  }

  async run(receiverStaticPublicKey: Uint8Array): Promise<PairVerifyKeys> {
    const ephemeral = await generateX25519KeyPair();
    const m2 = decodeTlv8(await this.exchange('/pair-verify', [
      { type: Tlv8Type.STATE, value: new Uint8Array([1]) },
      { type: Tlv8Type.PUBLIC_KEY, value: ephemeral.publicKeyRaw }
    ]));
    requireState(m2, 2, 'pair-verify M2');
    const receiverEphemeral = required(m2, Tlv8Type.PUBLIC_KEY, 'pair-verify M2 public key');
    const encryptedM2 = required(m2, Tlv8Type.ENCRYPTED_DATA, 'pair-verify M2 encrypted data');

    const sharedSecret = await x25519SharedSecret(ephemeral.privateKeyDer, receiverEphemeral);
    const encryptionKey = await hkdfSha512(
      sharedSecret,
      encodeUtf8('Pair-Verify-Encrypt-Salt'),
      encodeUtf8('Pair-Verify-Encrypt-Info')
    );
    const innerM2 = decodeTlv8(await chachaOpen(
      encryptionKey,
      nonceLabel('PV-Msg02'),
      encryptedM2,
      new Uint8Array(0)
    ));
    const receiverIdentifierBytes = required(innerM2, Tlv8Type.IDENTIFIER, 'pair-verify receiver identifier');
    const receiverSignature = required(innerM2, Tlv8Type.SIGNATURE, 'pair-verify receiver signature');
    const receiverSignedMessage = concatBytes(receiverEphemeral, receiverIdentifierBytes, ephemeral.publicKeyRaw);
    if (!(await verifyEd25519(receiverStaticPublicKey, receiverSignedMessage, receiverSignature))) {
      throw new Error('pair-verify receiver signature does not match the mDNS identity');
    }

    const controllerIdentifier = encodeUtf8(this.identity.pairingId);
    const controllerSignature = await signEd25519(
      this.identity.privateKeyDer,
      concatBytes(ephemeral.publicKeyRaw, controllerIdentifier, receiverEphemeral)
    );
    const innerM3 = encodeTlv8([
      { type: Tlv8Type.IDENTIFIER, value: controllerIdentifier },
      { type: Tlv8Type.SIGNATURE, value: controllerSignature }
    ]);
    const encryptedM3 = await chachaSeal(
      encryptionKey,
      nonceLabel('PV-Msg03'),
      innerM3,
      new Uint8Array(0)
    );
    const m4 = decodeTlv8(await this.exchange('/pair-verify', [
      { type: Tlv8Type.STATE, value: new Uint8Array([3]) },
      { type: Tlv8Type.ENCRYPTED_DATA, value: encryptedM3 }
    ]));
    requireState(m4, 4, 'pair-verify M4');

    const phoneWriteKey = await hkdfSha512(
      sharedSecret,
      encodeUtf8('Control-Salt'),
      encodeUtf8('Control-Write-Encryption-Key')
    );
    const phoneReadKey = await hkdfSha512(
      sharedSecret,
      encodeUtf8('Control-Salt'),
      encodeUtf8('Control-Read-Encryption-Key')
    );
    const keys: PairVerifyKeys = {
      phoneWriteKey,
      phoneReadKey,
      sharedSecret,
      receiverId: decodeUtf8(receiverIdentifierBytes)
    };
    this.log('pair-verify receiver signature verified; control keys derived');
    return keys;
  }

  private async exchange(path: string, items: Tlv8Item[]): Promise<Uint8Array> {
    const response = await this.client.request(
      'POST',
      path,
      encodeTlv8(items),
      { contentType: 'application/pairing+tlv8', applePd: true }
    );
    if (response.statusCode !== 200) {
      throw new AirPlayRtspStatusError(response);
    }
    return response.body;
  }
}

function required(values: Map<number, Uint8Array>, type: number, field: string): Uint8Array {
  const value = values.get(type);
  if (!value) {
    throw new Error(`Missing ${field}`);
  }
  return value;
}

function requireState(values: Map<number, Uint8Array>, expected: number, field: string): void {
  const state = values.get(Tlv8Type.STATE);
  if (!state || state.length !== 1 || state[0] !== expected) {
    const error = values.get(Tlv8Type.ERROR);
    const errorCode = error && error.length > 0 ? error[0].toString() : 'unknown';
    throw new Error(`${field} returned unexpected state; error=${errorCode}`);
  }
}

function nonceLabel(label: string): Uint8Array {
  const nonce = new Uint8Array(12);
  const bytes = encodeUtf8(label);
  nonce.set(bytes.slice(0, 8), 4);
  return nonce;
}

function decodeHex(hex: string): Uint8Array {
  const normalized = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (normalized.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(normalized)) {
    throw new Error('AirPlay TXT public key is not valid hexadecimal');
  }
  const result = new Uint8Array(normalized.length / 2);
  for (let index = 0; index < result.length; index++) {
    result[index] = parseInt(normalized.slice(index * 2, index * 2 + 2), 16);
  }
  return result;
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}
