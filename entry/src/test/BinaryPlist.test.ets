import { describe, it, expect } from '@ohos/hypium';
import { BinaryPlist, BinaryPlistValue } from '../main/ets/protocol/airplay/BinaryPlist';

export default function binaryPlistTest(): void {
  describe('Binary Plist encoder', () => {
    it('round-trips nested SETUP values, UTF-8, data, booleans, and signed integers', 0, () => {
      const stream: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      stream.set('type', 110);
      stream.set('streamConnectionID', 0x12345678);
      stream.set('uuid', '屏幕-1');
      stream.set('enabled', true);
      stream.set('offset', -42);
      stream.set('metadata', new Uint8Array([0, 1, 0xFE, 0xFF]));
      const request: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      request.set('deviceID', 'A1:B2:C3:D4:E5:F6');
      request.set('streams', [stream]);
      request.set('latency', 25.5);
      request.set('empty', null);

      const decoded = BinaryPlist.parse(BinaryPlist.encode(request));
      expect(decoded instanceof Map).assertTrue();
      if (!(decoded instanceof Map)) {
        return;
      }
      expect(decoded.get('deviceID') as string).assertEqual('A1:B2:C3:D4:E5:F6');
      expect(decoded.get('latency') as number).assertEqual(25.5);
      expect(decoded.get('empty')).assertEqual(null);
      const decodedStreams = decoded.get('streams') as BinaryPlistValue[];
      expect(decodedStreams.length).assertEqual(1);
      const decodedStream = decodedStreams[0] as Map<string, BinaryPlistValue>;
      expect(decodedStream.get('streamConnectionID') as number).assertEqual(0x12345678);
      expect(decodedStream.get('uuid') as string).assertEqual('屏幕-1');
      expect(decodedStream.get('enabled') as boolean).assertTrue();
      expect(decodedStream.get('offset') as number).assertEqual(-42);
      expect((decodedStream.get('metadata') as Uint8Array)[2]).assertEqual(0xFE);
    });

    it('encodes signed-positive boundary values without setting the sign bit', 0, () => {
      const encoded = BinaryPlist.encode(128);
      expect(encoded[8]).assertEqual(0x11);
      expect(encoded[9]).assertEqual(0);
      expect(encoded[10]).assertEqual(128);
      expect(BinaryPlist.parse(encoded) as number).assertEqual(128);
      expect(BinaryPlist.parse(BinaryPlist.encode(-128)) as number).assertEqual(-128);
      expect(BinaryPlist.parse(BinaryPlist.encode(32768)) as number).assertEqual(32768);
    });
  });
}
