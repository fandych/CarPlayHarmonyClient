import huks from '@ohos.security.huks';
import { HarmonyAirPlayCrypto } from '../../protocol/airplay/HarmonyAirPlayCrypto';

export interface ControllerIdentity {
  pairingId: string;
  publicKey: Uint8Array;
}

const KEY_ALIAS = 'CarPlayHarmonyClient.Controller.Ed25519.v1';
const ED25519_SPKI_PREFIX: number[] = [0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00];

export class HarmonyControllerIdentityStore {
  private identity: ControllerIdentity | undefined = undefined;

  async getIdentity(): Promise<ControllerIdentity> {
    if (this.identity !== undefined) {
      return this.identity;
    }
    const exists = await huks.isKeyItemExist(KEY_ALIAS, {});
    if (!exists) {
      await huks.generateKeyItem(KEY_ALIAS, {
        properties: [
          { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ED25519 },
          { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
          { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_CURVE25519_KEY_SIZE_256 },
          { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE }
        ]
      });
    }
    const exported = await huks.exportKeyItem(KEY_ALIAS, {});
    if (exported.outData === undefined) {
      throw new Error('HUKS did not return the controller public key.');
    }
    const publicKey = HarmonyControllerIdentityStore.extractEd25519PublicKey(exported.outData);
    const fingerprint = await HarmonyAirPlayCrypto.sha256(publicKey);
    const pairingId = `carplay-harmony-${HarmonyControllerIdentityStore.toHex(fingerprint.slice(0, 16))}`;
    this.identity = { pairingId, publicKey };
    return this.identity;
  }

  async sign(message: Uint8Array): Promise<Uint8Array> {
    await this.getIdentity();
    const session = await huks.initSession(KEY_ALIAS, {
      properties: [
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN },
        { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_NONE }
      ]
    });
    const result = await huks.finishSession(session.handle, { inData: message });
    if (result.outData === undefined || result.outData.length !== 64) {
      throw new Error('HUKS returned an invalid Ed25519 signature.');
    }
    return result.outData;
  }

  private static extractEd25519PublicKey(encoded: Uint8Array): Uint8Array {
    if (encoded.length === 32) {
      return encoded.slice();
    }
    if (encoded.length !== ED25519_SPKI_PREFIX.length + 32) {
      throw new Error(`Unexpected HUKS Ed25519 public-key length: ${encoded.length}.`);
    }
    for (let index = 0; index < ED25519_SPKI_PREFIX.length; index++) {
      if (encoded[index] !== ED25519_SPKI_PREFIX[index]) {
        throw new Error('HUKS returned a public key with an unexpected encoding.');
      }
    }
    return encoded.slice(ED25519_SPKI_PREFIX.length);
  }

  private static toHex(value: Uint8Array): string {
    let output = '';
    for (const byte of value) {
      output += byte.toString(16).padStart(2, '0');
    }
    return output;
  }
}
