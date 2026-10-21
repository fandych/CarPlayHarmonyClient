import { describe, it, expect } from '@ohos/hypium';
import { Srp6aClient, Srp6aCryptoProvider } from '../main/ets/protocol/airplay/Srp6aClient';

class DeterministicSrpCryptoProvider implements Srp6aCryptoProvider {
  async randomBytes(length: number): Promise<Uint8Array> {
    const output = new Uint8Array(length);
    output.fill(1);
    return output;
  }

  async sha512(_data: Uint8Array): Promise<Uint8Array> {
    const output = new Uint8Array(64);
    output.fill(0xA5);
    return output;
  }
}

export default function srp6aClientTest(): void {
  describe('AirPlay SRP-6a client', () => {
    it('uses a 3072-bit padded public value and rejects zero server keys', 0, async () => {
      const session = await Srp6aClient.start(
        new Uint8Array([0x01, 0x02, 0x03]),
        new DeterministicSrpCryptoProvider()
      );
      expect(session.publicKeyA.length).assertEqual(384);
      let rejected = false;
      try {
        await session.prove(new Uint8Array([0]));
      } catch {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('derives 64-byte SRP proof material for a nonzero server value', 0, async () => {
      const session = await Srp6aClient.start(
        new Uint8Array([0xA5, 0x5A]),
        new DeterministicSrpCryptoProvider()
      );
      const proof = await session.prove(new Uint8Array([1]));
      expect(proof.clientProof.length).assertEqual(64);
      expect(proof.sessionKey.length).assertEqual(64);
      expect(await proof.verifyServerProof(new Uint8Array(64))).assertFalse();
    });
  });
}
