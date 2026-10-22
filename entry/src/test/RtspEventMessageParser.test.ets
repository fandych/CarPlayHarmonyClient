import { describe, it, expect } from '@ohos/hypium';
import { RtspEventMessageParser } from '../main/ets/protocol/airplay/RtspEventMessageParser';

function ascii(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index++) {
    bytes[index] = value.charCodeAt(index);
  }
  return bytes;
}

function concat(left: Uint8Array, right: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(left.length + right.length);
  bytes.set(left);
  bytes.set(right, left.length);
  return bytes;
}

export default function rtspEventMessageParserTest(): void {
  describe('AirPlay event channel RTSP parser', () => {
    it('reassembles a fragmented request and its binary body', 0, () => {
      const parser = new RtspEventMessageParser();
      const header = ascii('POST /command RTSP/1.0\r\nCSeq: 7\r\nContent-Length: 4\r\n\r\n');
      const body = new Uint8Array([0, 1, 13, 10]);
      const message = concat(header, body);
      expect(parser.offer(message.slice(0, 17)).length).assertEqual(0);
      const parsed = parser.offer(message.slice(17));
      expect(parsed.length).assertEqual(1);
      expect(parsed[0].kind).assertEqual('request');
      expect(parsed[0].method).assertEqual('POST');
      expect(parsed[0].target).assertEqual('/command');
      expect(parsed[0].headers.get('cseq')).assertEqual('7');
      expect(Array.from(parsed[0].body).join(',')).assertEqual('0,1,13,10');
    });

    it('distinguishes responses from requests in a coalesced read', 0, () => {
      const parser = new RtspEventMessageParser();
      const response = ascii('RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n');
      const request = ascii('OPTIONS * RTSP/1.0\r\nCSeq: 2\r\nContent-Length: 0\r\n\r\n');
      const messages = parser.offer(concat(response, request));
      expect(messages.length).assertEqual(2);
      expect(messages[0].kind).assertEqual('response');
      expect(messages[1].kind).assertEqual('request');
      expect(messages[1].headers.get('cseq')).assertEqual('2');
    });

    it('rejects malformed start lines', 0, () => {
      const parser = new RtspEventMessageParser();
      let rejected = false;
      try {
        parser.offer(ascii('NOT RTSP\r\n\r\n'));
      } catch {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
