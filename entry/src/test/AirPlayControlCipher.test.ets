import { describe, it, expect } from '@ohos/hypium';
import {
  AirPlayControlCipher,
  AirPlayControlCipherCrypto
} from '../main/ets/protocol/airplay/AirPlayControlCipher';
import { AirPlayControlKeys } from '../main/ets/protocol/airplay/AirPlayPairingClient';

class DeterministicControlCipherCrypto implements AirPlayControlCipherCrypto {
  sealKeys: Uint8Array[] = [];
  sealNonces: Uint8Array[] = [];
  sealAads: Uint8Array[] = [];
  openKeys: Uint8Array[] = [];
  openNonces: Uint8Array[] = [];
  openAads: Uint8Array[] = [];

  async seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
    this.sealKeys.push(key.slice());
    this.sealNonces.push(nonce.slice());
    this.sealAads.push(aad.slice());
    const result = new Uint8Array(plaintext.length + 16);
    result.set(plaintext);
    return result;
  }

  async open(key: Uint8Array, nonce: Uint8Array, ciphertext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
    this.openKeys.push(key.slice());
    this.openNonces.push(nonce.slice());
    this.openAads.push(aad.slice());
    return ciphertext.slice(0, ciphertext.length - 16);
  }
}

export default function airPlayControlCipherTest(): void {
  describe('AirPlay encrypted RTSP framing', () => {
    it('chunks writes and reassembles fragmented read frames with separate counters', 0, async () => {
      const keys: AirPlayControlKeys = {
        phoneWriteKey: new Uint8Array(32).fill(0x11),
        phoneReadKey: new Uint8Array(32).fill(0x22),
        sharedSecret: new Uint8Array(32).fill(0x33)
      };
      const provider = new DeterministicControlCipherCrypto();
      const writer = new AirPlayControlCipher(keys, provider);
      const reader = new AirPlayControlCipher(keys, provider);
      const request = new Uint8Array(1423).fill(0xA5);
      const encrypted = await writer.encrypt(request);
      expect(encrypted.length).assertEqual(1459);
      expect(encrypted[0]).assertEqual(0x8E);
      expect(encrypted[1]).assertEqual(0x05);
      expect(encrypted[1440]).assertEqual(1);
      expect(encrypted[1441]).assertEqual(0);
      expect(provider.sealAads.length).assertEqual(2);
      expect(provider.sealNonces[0][4]).assertEqual(0);
      expect(provider.sealNonces[1][4]).assertEqual(1);
      expect(provider.sealKeys[0][0]).assertEqual(0x11);

      const firstFragment = await reader.decrypt(encrypted.slice(0, 12));
      expect(firstFragment.length).assertEqual(0);
      const plaintext = await reader.decrypt(encrypted.slice(12));
      expect(plaintext.length).assertEqual(request.length);
      expect(plaintext[1422]).assertEqual(0xA5);
      expect(provider.openNonces[0][4]).assertEqual(0);
      expect(provider.openNonces[1][4]).assertEqual(1);
      expect(provider.openKeys[0][0]).assertEqual(0x22);
      expect(provider.openAads[1][0]).assertEqual(1);
    });
  });
}
