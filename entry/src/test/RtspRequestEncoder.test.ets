import { describe, it, expect } from '@ohos/hypium';
import { RtspRequestEncoder } from '../main/ets/protocol/airplay/RtspRequestEncoder';

function asciiText(bytes: Uint8Array): string {
  let text = '';
  for (const byte of bytes) {
    text += String.fromCharCode(byte);
  }
  return text;
}

export default function rtspRequestEncoderTest(): void {
  describe('AirPlay RTSP request encoding', () => {
    it('encodes binary pairing bodies and calculates byte length', 0, () => {
      const body = new Uint8Array([0x06, 0x01, 0x05, 0x00, 0xFF]);
      const request = RtspRequestEncoder.encode('POST', '/pair-setup', 2, body, [
        { name: 'Content-Type', value: 'application/pairing+tlv8' },
        { name: 'X-Apple-HKP', value: '2' }
      ]);
      const headerLength = request.length - body.length;
      const header = asciiText(request.slice(0, headerLength - 4));
      expect(header.includes('POST /pair-setup RTSP/1.0')).assertTrue();
      expect(header.includes('CSeq: 2')).assertTrue();
      expect(header.includes('Content-Length: 5')).assertTrue();
      expect(header.includes('Content-Type: application/pairing+tlv8')).assertTrue();
      expect(headerLength > 4).assertTrue();
      expect(request.slice(headerLength).length).assertEqual(body.length);
      expect(request[request.length - 1]).assertEqual(0xFF);
    });

    it('rejects header injection and caller-supplied managed headers', 0, () => {
      let rejectedInjection = false;
      try {
        RtspRequestEncoder.encode('GET', '/info', 1, new Uint8Array(0), [
          { name: 'X-Test', value: 'ok\r\nCSeq: 9' }
        ]);
      } catch {
        rejectedInjection = true;
      }
      expect(rejectedInjection).assertTrue();

      let rejectedCseq = false;
      try {
        RtspRequestEncoder.encode('GET', '/info', 1, new Uint8Array(0), [
          { name: 'CSeq', value: '8' }
        ]);
      } catch {
        rejectedCseq = true;
      }
      expect(rejectedCseq).assertTrue();
    });
  });
}
