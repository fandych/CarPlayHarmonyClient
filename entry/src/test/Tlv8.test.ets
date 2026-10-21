import { describe, it, expect } from '@ohos/hypium';
import { Tlv8, Tlv8Item } from '../main/ets/protocol/airplay/Tlv8';

function expectBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index++) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

export default function tlv8Test(): void {
  describe('AirPlay TLV8 codec', () => {
    it('encodes and decodes simple pairing state fields', 0, () => {
      const items: Tlv8Item[] = [
        { type: Tlv8.TYPE_METHOD, value: new Uint8Array([0]) },
        { type: Tlv8.TYPE_STATE, value: new Uint8Array([1]) }
      ];
      const encoded = Tlv8.encode(items);
      expectBytes(encoded, [0x00, 0x01, 0x00, 0x06, 0x01, 0x01]);
      const decoded = Tlv8.decode(encoded);
      expect(decoded.get(Tlv8.TYPE_METHOD)?.[0]).assertEqual(0);
      expect(decoded.get(Tlv8.TYPE_STATE)?.[0]).assertEqual(1);
    });

    it('reassembles 255-byte fragments without merging repeated fields', 0, () => {
      const longValue = new Uint8Array(260);
      longValue.fill(0xA5);
      const encoded = Tlv8.encode([
        { type: Tlv8.TYPE_PUBLIC_KEY, value: longValue },
        { type: Tlv8.TYPE_STATE, value: new Uint8Array([3]) },
        { type: Tlv8.TYPE_STATE, value: new Uint8Array([5]) }
      ]);
      const decoded = Tlv8.decode(encoded);
      expect(decoded.get(Tlv8.TYPE_PUBLIC_KEY)?.length).assertEqual(260);
      expect(decoded.get(Tlv8.TYPE_STATE)?.[0]).assertEqual(5);
    });

    it('rejects truncated TLV8 fields', 0, () => {
      let truncatedHeaderRejected = false;
      try {
        Tlv8.decode(new Uint8Array([Tlv8.TYPE_STATE]));
      } catch {
        truncatedHeaderRejected = true;
      }
      expect(truncatedHeaderRejected).assertTrue();

      let truncatedValueRejected = false;
      try {
        Tlv8.decode(new Uint8Array([Tlv8.TYPE_STATE, 2, 1]));
      } catch {
        truncatedValueRejected = true;
      }
      expect(truncatedValueRejected).assertTrue();
    });
  });
}
