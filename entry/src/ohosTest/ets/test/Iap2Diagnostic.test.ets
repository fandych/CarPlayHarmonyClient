import { describe, it, expect } from '@ohos/hypium';
import { describeIap2CsmFrame, Iap2Csm } from '../../../main/ets/protocol/iap2/Iap2Csm';

function concatenate(parts: Uint8Array[]): Uint8Array {
  const length = parts.reduce((total: number, part: Uint8Array) => total + part.length, 0);
  const output = new Uint8Array(length);
  let offset = 0;
  parts.forEach((part: Uint8Array) => {
    output.set(part, offset);
    offset += part.length;
  });
  return output;
}

export default function iap2DiagnosticTest() {
  describe('Iap2DiagnosticTest', () => {
    it('logs safe capability bytes without exposing identity strings', 0, () => {
      const frame = {
        messageId: 0x1D01,
        body: concatenate([
          Iap2Csm.string(0, 'private-device-name'),
          Iap2Csm.param(6, new Uint8Array([0x1D, 0x00, 0xAA, 0x01])),
          Iap2Csm.param(7, new Uint8Array([0x57, 0x02, 0x43, 0x01]))
        ])
      };
      const line = describeIap2CsmFrame('rx', frame);
      expect(line.includes('private-device-name')).assertEqual(false);
      expect(line.includes('p6=1d00aa01')).assertEqual(true);
      expect(line.includes('bodyBytes=')).assertEqual(true);
      expect(line.includes('params=')).assertEqual(true);
    });

    it('never writes Wi-Fi message parameter values to logs', 0, () => {
      const frame = {
        messageId: 0x5703,
        body: concatenate([
          Iap2Csm.string(1, 'private-ssid'),
          Iap2Csm.string(2, 'private-passphrase')
        ])
      };
      const line = describeIap2CsmFrame('rx', frame);
      expect(line.includes('private-ssid')).assertEqual(false);
      expect(line.includes('private-passphrase')).assertEqual(false);
      expect(line.includes('0x0001:')).assertEqual(true);
      expect(line.includes('0x0002:')).assertEqual(true);
    });
  });
}
