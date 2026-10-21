import { common } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';
import { HarmonyAirPlayCrypto } from '../../protocol/airplay/HarmonyAirPlayCrypto';
import { AirPlayServiceEndpoint } from '../network/HarmonyMdnsBrowser';
import { ReceiverIdentity, PairSetupClient } from '../../protocol/airplay/AirPlayPairingClient';
import { HarmonyControllerIdentityStore } from './HarmonyControllerIdentityStore';

const PREFERENCES_NAME = 'airplay_pairing_records_v1';
const RECORD_PREFIX = 'AirPlay-Peer-Identity-v1\u0000';

export class HarmonyAirPlayPairingStore {
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async load(
    endpoint: AirPlayServiceEndpoint,
    identityStore: HarmonyControllerIdentityStore
  ): Promise<ReceiverIdentity | undefined> {
    const endpointDigest = await this.endpointDigest(endpoint);
    const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    const raw = await store.get(HarmonyAirPlayPairingStore.preferenceKey(endpointDigest), '');
    if (typeof raw !== 'string') {
      throw new Error('Stored AirPlay pairing record has an invalid value type.');
    }
    if (raw.length === 0) {
      return undefined;
    }
    const fields = raw.split('|');
    if (fields.length !== 4 || fields[0] !== 'v1') {
      throw new Error('Stored AirPlay pairing record has an unsupported format.');
    }
    const pairingIdBytes = HarmonyAirPlayPairingStore.fromHex(fields[1]);
    const publicKey = HarmonyAirPlayPairingStore.fromHex(fields[2]);
    const signature = HarmonyAirPlayPairingStore.fromHex(fields[3]);
    if (pairingIdBytes.length === 0 || publicKey.length !== 32 || signature.length !== 64) {
      throw new Error('Stored AirPlay pairing record contains invalid key material.');
    }
    const pairingId = PairSetupClient.decodeIdentifier(pairingIdBytes);
    const controller = await identityStore.getIdentity();
    const signedRecord = HarmonyAirPlayPairingStore.signedRecord(endpointDigest, pairingId, publicKey);
    if (!await HarmonyAirPlayCrypto.verifyEd25519(controller.publicKey, signedRecord, signature)) {
      throw new Error('Stored AirPlay pairing record signature is invalid; refusing to trust it.');
    }
    return { pairingId, publicKey };
  }

  async save(
    endpoint: AirPlayServiceEndpoint,
    receiver: ReceiverIdentity,
    identityStore: HarmonyControllerIdentityStore
  ): Promise<void> {
    if (receiver.pairingId.length === 0 || receiver.publicKey.length !== 32) {
      throw new Error('Cannot persist an invalid AirPlay receiver identity.');
    }
    const endpointDigest = await this.endpointDigest(endpoint);
    const signature = await identityStore.sign(
      HarmonyAirPlayPairingStore.signedRecord(endpointDigest, receiver.pairingId, receiver.publicKey)
    );
    const record = [
      'v1',
      HarmonyAirPlayPairingStore.toHex(PairSetupClient.ascii(receiver.pairingId)),
      HarmonyAirPlayPairingStore.toHex(receiver.publicKey),
      HarmonyAirPlayPairingStore.toHex(signature)
    ].join('|');
    const store = await preferences.getPreferences(this.context, PREFERENCES_NAME);
    await store.put(HarmonyAirPlayPairingStore.preferenceKey(endpointDigest), record);
    await store.flush();
  }

  private async endpointDigest(endpoint: AirPlayServiceEndpoint): Promise<Uint8Array> {
    const identity = `${endpoint.name}\n${endpoint.host}\n${endpoint.port}`;
    return HarmonyAirPlayCrypto.sha256(HarmonyAirPlayPairingStore.encodeUtf8(identity));
  }

  private static preferenceKey(endpointDigest: Uint8Array): string {
    return `receiver_${HarmonyAirPlayPairingStore.toHex(endpointDigest)}`;
  }

  private static signedRecord(
    endpointDigest: Uint8Array,
    pairingId: string,
    publicKey: Uint8Array
  ): Uint8Array {
    return HarmonyAirPlayCrypto.concat(
      HarmonyAirPlayPairingStore.encodeUtf8(RECORD_PREFIX),
      endpointDigest,
      PairSetupClient.ascii(pairingId),
      publicKey
    );
  }

  private static encodeUtf8(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let index = 0; index < value.length; index++) {
      let point = value.charCodeAt(index);
      if (point >= 0xD800 && point <= 0xDBFF) {
        const low = value.charCodeAt(index + 1);
        if (low < 0xDC00 || low > 0xDFFF) {
          throw new Error('AirPlay endpoint identity contains an invalid UTF-16 surrogate.');
        }
        point = 0x10000 + ((point - 0xD800) << 10) + (low - 0xDC00);
        index++;
      } else if (point >= 0xDC00 && point <= 0xDFFF) {
        throw new Error('AirPlay endpoint identity contains an invalid UTF-16 surrogate.');
      }
      if (point <= 0x7F) {
        bytes.push(point);
      } else if (point <= 0x7FF) {
        bytes.push(0xC0 | (point >>> 6), 0x80 | (point & 0x3F));
      } else if (point <= 0xFFFF) {
        bytes.push(0xE0 | (point >>> 12), 0x80 | ((point >>> 6) & 0x3F), 0x80 | (point & 0x3F));
      } else {
        bytes.push(
          0xF0 | (point >>> 18),
          0x80 | ((point >>> 12) & 0x3F),
          0x80 | ((point >>> 6) & 0x3F),
          0x80 | (point & 0x3F)
        );
      }
    }
    return new Uint8Array(bytes);
  }

  private static toHex(bytes: Uint8Array): string {
    let output = '';
    for (const byte of bytes) {
      output += byte.toString(16).padStart(2, '0');
    }
    return output;
  }

  private static fromHex(value: string): Uint8Array {
    if (value.length === 0 || (value.length & 1) !== 0 || !/^[0-9a-f]+$/i.test(value)) {
      throw new Error('Stored AirPlay pairing record contains malformed hexadecimal data.');
    }
    const output = new Uint8Array(value.length / 2);
    for (let index = 0; index < output.length; index++) {
      output[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
    }
    return output;
  }
}
