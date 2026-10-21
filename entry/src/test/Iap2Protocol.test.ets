import { describe, it, expect } from '@ohos/hypium';
import { Iap2Csm, Iap2CsmParser } from '../main/ets/protocol/iap2/Iap2Csm';
import { Iap2LinkPacket, Iap2LinkStreamParser } from '../main/ets/protocol/iap2/Iap2LinkPacket';
import { Iap2LinkEngine } from '../main/ets/protocol/iap2/Iap2LinkEngine';
import { BinaryPlist } from '../main/ets/protocol/airplay/BinaryPlist';
import { RtspResponseParser } from '../main/ets/protocol/airplay/RtspResponseParser';
import { Iap2SenderSession, parseCarPlayStartSession } from '../main/ets/protocol/iap2/Iap2SenderSession';

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index++) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function bytesFromHex(hex: string): Uint8Array {
  const bytes: number[] = [];
  for (let index = 0; index < hex.length; index += 2) {
    bytes.push(Number.parseInt(hex.slice(index, index + 2), 16));
  }
  return new Uint8Array(bytes);
}

function joinBytes(parts: Uint8Array[]): Uint8Array {
  let length = 0;
  parts.forEach((part: Uint8Array) => length += part.length);
  const result = new Uint8Array(length);
  let offset = 0;
  parts.forEach((part: Uint8Array) => {
    result.set(part, offset);
    offset += part.length;
  });
  return result;
}

function containsMessageId(messages: Uint8Array[], messageId: number): boolean {
  return messages.some((message: Uint8Array) => {
    const frames = new Iap2CsmParser().offer(message);
    return frames.length === 1 && frames[0].messageId === messageId;
  });
}

export default function iap2ProtocolTest(): void {
  describe('IAP2 protocol codecs', () => {
    it('encodes a CSM frame with a big-endian header', 0, () => {
      const frame = Iap2Csm.encode(0x1D00);
      assertBytes(frame, [0x40, 0x40, 0x00, 0x06, 0x1D, 0x00]);
    });

    it('reassembles fragmented CSM frames and skips leading noise', 0, () => {
      const expected = Iap2Csm.encode(0x4300);
      const parser = new Iap2CsmParser();
      const frames = parser.offer(new Uint8Array([0x12, expected[0], expected[1], expected[2], expected[3]]));
      expect(frames.length).assertEqual(0);
      const completed = parser.offer(expected.slice(4));
      expect(completed.length).assertEqual(1);
      expect(completed[0].messageId).assertEqual(0x4300);
    });

    it('encodes and validates an iAP2 link packet', 0, () => {
      const encoded = Iap2LinkPacket.encode({
        control: 0x40,
        sequence: 3,
        acknowledgement: 7,
        sessionId: 10,
        payload: new Uint8Array([0x40, 0x40, 0x00, 0x06, 0x1D, 0x00])
      });
      expect(Iap2LinkPacket.decode(encoded) !== null).assertTrue();
      const decoded = Iap2LinkPacket.decode(encoded);
      expect(decoded?.sequence).assertEqual(3);
      expect(decoded?.sessionId).assertEqual(10);
      encoded[encoded.length - 1] = (encoded[encoded.length - 1] + 1) & 0xFF;
      expect(Iap2LinkPacket.decode(encoded) === null).assertTrue();
    });

    it('encodes acknowledgement-only packets without a payload checksum byte', 0, () => {
      const encoded = Iap2LinkPacket.encode({
        control: 0x40,
        sequence: 100,
        acknowledgement: 99,
        sessionId: 0,
        payload: null
      });
      expect(encoded.length).assertEqual(9);
      expect(Iap2LinkPacket.decode(encoded)?.payload === null).assertTrue();
    });

    it('round trips nested TLV and NUL-terminated strings', 0, () => {
      const nested = Iap2Csm.group(17, Iap2Csm.string(1, 'blue'), Iap2Csm.u16(2, 0x4301));
      const params = Iap2Csm.parseParams(nested);
      expect(params.length).assertEqual(1);
      const children = Iap2Csm.parseParams(params[0].value);
      expect(children[0].id).assertEqual(1);
      expect(children[0].value.length).assertEqual(5);
      expect(children[0].value[0]).assertEqual(0x62);
      expect(Iap2Csm.asString(children[0])).assertEqual('blue');
      expect(children[1].value[0]).assertEqual(0x43);
      expect(children[1].value[1]).assertEqual(0x01);
    });

    it('reassembles link packets from arbitrary stream chunks', 0, () => {
      const bytes = Iap2LinkPacket.encode({
        control: 0x40,
        sequence: 8,
        acknowledgement: 7,
        sessionId: 10,
        payload: new Uint8Array([1, 2, 3])
      });
      const parser = new Iap2LinkStreamParser();
      let resultCount = 0;
      for (let index = 0; index < bytes.length; index++) {
        resultCount += parser.offer(bytes.slice(index, index + 1)).length;
      }
      expect(resultCount).assertEqual(1);
    });

    it('negotiates an iAP2 link and delivers control payloads', 0, () => {
      let toPhone: Uint8Array[] = [];
      let toCar: Uint8Array[] = [];
      const phone = new Iap2LinkEngine((bytes: Uint8Array) => toCar.push(bytes));
      const car = new Iap2LinkEngine((bytes: Uint8Array) => toPhone.push(bytes));
      phone.start();
      car.start();

      for (let turn = 0; turn < 4; turn++) {
        const phoneOutput = toPhone;
        toPhone = [];
        for (let index = 0; index < phoneOutput.length; index++) {
          phone.feed(phoneOutput[index]);
        }
        const carOutput = toCar;
        toCar = [];
        for (let index = 0; index < carOutput.length; index++) {
          car.feed(carOutput[index]);
        }
      }
      expect(phone.state).assertEqual('normal');
      expect(car.state).assertEqual('normal');

      let received = 0;
      car.onControl = (bytes: Uint8Array) => {
        received = bytes[5];
      };
      toCar = [];
      toPhone = [];
      phone.sendControl(Iap2Csm.encode(0x1D00));
      const pending = toCar;
      toCar = [];
      for (let index = 0; index < pending.length; index++) {
        car.feed(pending[index]);
      }
      expect(received).assertEqual(0x00);
    });

    it('parses AirPlay Binary Plist dictionaries, unsigned values, arrays and UTF-16', 0, () => {
      const plist = bytesFromHex(
        '62706c6973743030d50102030405060b0c0d0e57646973706c617955656d6f6a6957656e61626c656455666c616773546e616d65' +
        'd20708090a566865696768745577696474681102d0110500628f66673a091188ad57436172506c617908131b21292f34394046494c' +
        '5152550000000000000101000000000000000f0000000000000000000000000000005d'
      );
      const parsed = BinaryPlist.parse(plist);
      expect(parsed instanceof Map).assertTrue();
      if (!(parsed instanceof Map)) {
        return;
      }
      expect(parsed.get('name')).assertEqual('CarPlay');
      expect(parsed.get('flags')).assertEqual(34989);
      expect(parsed.get('enabled')).assertTrue();
      expect(parsed.get('emoji')).assertEqual('车机');
      const display = parsed.get('display');
      expect(display instanceof Map).assertTrue();
      if (display instanceof Map) {
        expect(display.get('width')).assertEqual(1280);
        expect(display.get('height')).assertEqual(720);
      }
    });

    it('rejects malformed Binary Plist trailers', 0, () => {
      let rejected = false;
      try {
        BinaryPlist.parse(new Uint8Array([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]));
      } catch {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('parses fragmented RTSP responses with binary bodies', 0, () => {
      const parser = new RtspResponseParser();
      const head = new Uint8Array([
        0x52, 0x54, 0x53, 0x50, 0x2F, 0x31, 0x2E, 0x30, 0x20, 0x32, 0x30, 0x30, 0x20, 0x4F, 0x4B, 0x0D, 0x0A,
        0x43, 0x53, 0x65, 0x71, 0x3A, 0x20, 0x31, 0x0D, 0x0A, 0x43, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D,
        0x4C, 0x65, 0x6E, 0x67, 0x74, 0x68, 0x3A, 0x20, 0x33, 0x0D, 0x0A, 0x0D, 0x0A, 0x62
      ]);
      expect(parser.offer(head).length).assertEqual(0);
      const responses = parser.offer(new Uint8Array([0x70, 0x6C]));
      expect(responses.length).assertEqual(1);
      expect(responses[0].statusCode).assertEqual(200);
      expect(responses[0].headers.get('cseq')).assertEqual('1');
      assertBytes(responses[0].body, [0x62, 0x70, 0x6C]);
    });

    it('parses CarPlayStartSession endpoint and nested Wi-Fi configuration', 0, () => {
      const wireless = Iap2Csm.group(
        1,
        Iap2Csm.string(0, 'CarAP'),
        Iap2Csm.string(1, 'car-password'),
        Iap2Csm.u8(2, 36),
        Iap2Csm.string(3, '192.168.49.1'),
        Iap2Csm.u8(4, 2)
      );
      const body = joinBytes([
        wireless,
        Iap2Csm.param(2, new Uint8Array([0x00, 0x00, 0xC0, 0x00])),
        Iap2Csm.string(3, 'receiver-id'),
        Iap2Csm.string(4, 'receiver-key'),
        Iap2Csm.string(5, '1.0')
      ]);
      const frames = new Iap2CsmParser().offer(Iap2Csm.encode(0x4301, body));
      expect(frames.length).assertEqual(1);
      const endpoint = parseCarPlayStartSession(frames[0]);
      expect(endpoint.ssid).assertEqual('CarAP');
      expect(endpoint.passphrase).assertEqual('car-password');
      expect(endpoint.securityType).assertEqual(2);
      expect(endpoint.channel).assertEqual(36);
      expect(endpoint.airPlayPort).assertEqual(49152);
      expect(endpoint.deviceIdentifier).assertEqual('receiver-id');
      expect(endpoint.publicKey).assertEqual('receiver-key');
      expect(endpoint.sourceVersion).assertEqual('1.0');
      expect(endpoint.ipAddresses.length).assertEqual(1);
      expect(endpoint.ipAddresses[0]).assertEqual('192.168.49.1');
    });

    it('uses accessory capability lists and acknowledges StartHID', 0, () => {
      const sent: Uint8Array[] = [];
      const logs: string[] = [];
      const session = new Iap2SenderSession(
        (bytes: Uint8Array) => sent.push(bytes),
        (message: string) => logs.push(message),
        () => {}
      );
      session.start();
      sent.length = 0;

      const identification = joinBytes([
        Iap2Csm.string(0, 'Car'),
        Iap2Csm.string(1, 'Model'),
        Iap2Csm.string(2, 'Maker'),
        Iap2Csm.param(6, new Uint8Array([0x43, 0x01, 0x57, 0x03, 0x68, 0x00])),
        Iap2Csm.param(7, new Uint8Array([0x43, 0x00]))
      ]);
      session.receive(Iap2Csm.encode(0x1D01, identification));
      session.receive(Iap2Csm.encode(0xAA03));

      expect(containsMessageId(sent, 0xAA05)).assertTrue();
      expect(containsMessageId(sent, 0x5702)).assertFalse();
      expect(logs.some((message: string) => message.indexOf('不支持旧版 Wi-Fi 配置交换') >= 0)).assertTrue();

      sent.length = 0;
      session.receive(Iap2Csm.encode(0x6800));
      expect(containsMessageId(sent, 0x6801)).assertTrue();
      const response = new Iap2CsmParser().offer(sent[0])[0];
      const parameters = Iap2Csm.parseParams(response.body);
      expect(Iap2Csm.asU16List(parameters[0])[0]).assertEqual(0);
      expect(parameters[1].value[0]).assertEqual(0);
      session.close();
    });

    it('requests legacy Wi-Fi configuration when the accessory advertises support', 0, () => {
      const sent: Uint8Array[] = [];
      const session = new Iap2SenderSession(
        (bytes: Uint8Array) => sent.push(bytes),
        () => {},
        () => {}
      );
      const identification = joinBytes([
        Iap2Csm.param(6, new Uint8Array([0x57, 0x03])),
        Iap2Csm.param(7, new Uint8Array([0x57, 0x02]))
      ]);
      session.receive(Iap2Csm.encode(0x1D01, identification));
      session.receive(Iap2Csm.encode(0xAA03));
      expect(containsMessageId(sent, 0x5702)).assertTrue();
      session.close();
    });

    it('treats malformed accessory capability lists as unknown', 0, () => {
      const sent: Uint8Array[] = [];
      const logs: string[] = [];
      const session = new Iap2SenderSession(
        (bytes: Uint8Array) => sent.push(bytes),
        (message: string) => logs.push(message),
        () => {}
      );
      session.receive(Iap2Csm.encode(0x1D01, Iap2Csm.param(7, new Uint8Array([0x57]))));
      session.receive(Iap2Csm.encode(0xAA03));
      expect(containsMessageId(sent, 0x5702)).assertTrue();
      expect(logs.some((message: string) => message.indexOf('格式无效') >= 0)).assertTrue();
      session.close();
    });
  });
}
