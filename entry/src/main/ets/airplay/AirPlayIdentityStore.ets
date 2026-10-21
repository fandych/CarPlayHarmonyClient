import common from '@ohos.app.ability.common';
import cryptoFramework from '@ohos.security.cryptoFramework';
import preferences from '@ohos.data.preferences';
import { AirPlayAsymmetricKeyPair, generateEd25519KeyPair } from './AirPlayCrypto';

export interface AirPlayControllerIdentity {
  pairingId: string;
  privateKeyDer: Uint8Array;
  publicKeyRaw: Uint8Array;
  newlyCreated: boolean;
}

export class AirPlayIdentityStore {
  async loadOrCreate(context: common.UIAbilityContext): Promise<AirPlayControllerIdentity> {
    const store = await preferences.getPreferences(context, 'airplay_controller_identity');
    const pairingIdValue = await store.get('pairingId', '');
    const privateKeyValue = await store.get('privateKeyDerHex', '');
    const publicKeyValue = await store.get('publicKeyRawHex', '');
    const pairingId = typeof pairingIdValue === 'string' ? pairingIdValue : '';
    const privateKeyHex = typeof privateKeyValue === 'string' ? privateKeyValue : '';
    const publicKeyHex = typeof publicKeyValue === 'string' ? publicKeyValue : '';

    if (pairingId || privateKeyHex || publicKeyHex) {
      if (!pairingId || !privateKeyHex || !publicKeyHex) {
        throw new Error('AirPlay 本地身份数据不完整；请清除应用身份数据后重新配对');
      }
      const privateKeyDer = fromHex(privateKeyHex);
      const publicKeyRaw = fromHex(publicKeyHex);
      if (privateKeyDer.length === 0 || publicKeyRaw.length !== 32) {
        throw new Error('AirPlay 本地身份密钥格式无效');
      }
      const stored: AirPlayControllerIdentity = { pairingId, privateKeyDer, publicKeyRaw, newlyCreated: false };
      return stored;
    }

    const keyPair: AirPlayAsymmetricKeyPair = await generateEd25519KeyPair();
    const random = await cryptoFramework.createRandom().generateRandom(16);
    const generatedPairingId = `HOS-${toHex(new Uint8Array(random.data))}`;
    await store.put('pairingId', generatedPairingId);
    await store.put('privateKeyDerHex', toHex(keyPair.privateKeyDer));
    await store.put('publicKeyRawHex', toHex(keyPair.publicKeyRaw));
    await store.flush();
    const generated: AirPlayControllerIdentity = {
      pairingId: generatedPairingId,
      privateKeyDer: keyPair.privateKeyDer,
      publicKeyRaw: keyPair.publicKeyRaw,
      newlyCreated: true
    };
    return generated;
  }
}

function toHex(bytes: Uint8Array): string {
  let result = '';
  for (const byte of bytes) {
    result += byte.toString(16).padStart(2, '0');
  }
  return result;
}

function fromHex(hex: string): Uint8Array {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) {
    throw new Error('Invalid hexadecimal key data');
  }
  const result = new Uint8Array(hex.length / 2);
  for (let index = 0; index < result.length; index++) {
    result[index] = parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return result;
}
