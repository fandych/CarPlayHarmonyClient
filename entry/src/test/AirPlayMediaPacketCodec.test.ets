import { describe, it, expect } from '@ohos/hypium';
import {
  AirPlayMediaCipher,
  AirPlayMediaPacketCodec
} from '../main/ets/protocol/airplay/AirPlayMediaPacketCodec';

class DeterministicMediaCipher implements AirPlayMediaCipher {
  lastNonce: Uint8Array = new Uint8Array(0);
  lastAad: Uint8Array = new Uint8Array(0);
  lastPlaintext: Uint8Array = new Uint8Array(0);

  async seal(_key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
    this.lastNonce = nonce.slice();
    this.lastAad = aad.slice();
    this.lastPlaintext = plaintext.slice();
    const result = new Uint8Array(plaintext.length + 16);
    result.set(plaintext);
    return result;
  }
}

function asciiBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index++) {
    bytes[index] = value.charCodeAt(index);
  }
  return bytes;
}

export default function airPlayMediaPacketCodecTest(): void {
  describe('AirPlay media packet codec', () => {
    it('builds H.264 avcC and the 128-byte encrypted video config header', 0, () => {
      const annexB = new Uint8Array([
        0, 0, 0, 1, 0x67, 0x42, 0, 0x1E,
        0, 0, 1, 0x68, 0xAA,
        0, 0, 1, 0x65, 0xBB
      ]);
      const avcC = AirPlayMediaPacketCodec.buildAvcC(annexB);
      expect(avcC.length).assertEqual(17);
      expect(avcC[0]).assertEqual(1);
      expect(avcC[5]).assertEqual(0xE1);
      expect(avcC[12]).assertEqual(1);

      const packet = AirPlayMediaPacketCodec.buildVideoConfigPacket(avcC, 1920, 1080);
      expect(packet.length).assertEqual(128 + avcC.length);
      expect(packet[0]).assertEqual(avcC.length);
      expect(packet[4]).assertEqual(AirPlayMediaPacketCodec.VIDEO_CONFIG_OPCODE);
      expect(packet[6]).assertEqual(0x04);
      expect(packet[16]).assertEqual(0);
      expect(packet[18]).assertEqual(0xF0);
      expect(packet[19]).assertEqual(0x44);
      expect(packet[23]).assertEqual(0x44);
    });

    it('normalizes length-prefixed encoder output to Annex-B and preserves avcC records', 0, () => {
      const lengthPrefixed = new Uint8Array([
        0, 0, 0, 3, 0x65, 0xAA, 0xBB,
        0, 0, 0, 2, 0x41, 0xCC
      ]);
      const normalized = AirPlayMediaPacketCodec.normalizeAnnexB(lengthPrefixed);
      expect(Array.from(normalized).join(',')).assertEqual(
        '0,0,0,1,101,170,187,0,0,0,1,65,204'
      );
      const parameterSets = new Uint8Array([
        0, 0, 0, 1, 0x67, 0x42, 0, 0x1E,
        0, 0, 1, 0x68, 0xAA
      ]);
      const avcC = AirPlayMediaPacketCodec.buildAvcC(parameterSets);
      expect(AirPlayMediaPacketCodec.isAvcConfigurationRecord(avcC)).assertTrue();
      expect(Array.from(AirPlayMediaPacketCodec.buildAvcC(avcC)).join(','))
        .assertEqual(Array.from(avcC).join(','));
    });

    it('builds an unencrypted 128-byte video keep-alive packet', 0, () => {
      const packet = AirPlayMediaPacketCodec.buildKeepAlivePacket();
      expect(packet.length).assertEqual(AirPlayMediaPacketCodec.VIDEO_HEADER_SIZE);
      expect(packet[0]).assertEqual(0);
      expect(packet[1]).assertEqual(0);
      expect(packet[2]).assertEqual(0);
      expect(packet[3]).assertEqual(0);
      expect(packet[4]).assertEqual(AirPlayMediaPacketCodec.VIDEO_KEEPALIVE_OPCODE);
    });

    it('binds the video stream key parameters to the negotiated connection ID', 0, () => {
      const parameters = AirPlayMediaPacketCodec.videoStreamKeyParameters(123456789);
      expect(Array.from(parameters.salt).join(',')).assertEqual(
        Array.from(asciiBytes('DataStream-Salt123456789')).join(',')
      );
      expect(Array.from(parameters.info).join(',')).assertEqual(
        Array.from(asciiBytes('DataStream-Output-Encryption-Key')).join(',')
      );
    });

    it('seals video frames with the 128-byte header as AAD and counter nonce', 0, async () => {
      const cipher = new DeterministicMediaCipher();
      const frame = await AirPlayMediaPacketCodec.sealVideoFrame(
        new Uint8Array([0, 0, 1, 0x65, 0xAA]),
        new Uint8Array(32),
        1,
        new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]),
        cipher
      );
      expect(frame.length).assertEqual(128 + 6 + 16);
      expect(frame[0]).assertEqual(22);
      expect(frame[4]).assertEqual(AirPlayMediaPacketCodec.VIDEO_FRAME_OPCODE);
      expect(cipher.lastAad.length).assertEqual(128);
      expect(cipher.lastAad[8]).assertEqual(1);
      expect(cipher.lastNonce[4]).assertEqual(1);
      expect(cipher.lastPlaintext[3]).assertEqual(2);
      expect(cipher.lastPlaintext[4]).assertEqual(0x65);
    });

    it('seals big-endian PCM in RTP with timestamp AAD and trailing nonce', 0, async () => {
      const cipher = new DeterministicMediaCipher();
      const packet = await AirPlayMediaPacketCodec.sealAudioPacket(
        new Uint8Array([0x34, 0x12, 0x78, 0x56]),
        new Uint8Array(32),
        1,
        0x01020304,
        2,
        100,
        true,
        true,
        cipher
      );
      expect(packet.length).assertEqual(40);
      expect(packet[0]).assertEqual(0x80);
      expect(packet[1]).assertEqual(0xE4);
      expect(packet[2]).assertEqual(0);
      expect(packet[3]).assertEqual(1);
      expect(packet[4]).assertEqual(1);
      expect(packet[5]).assertEqual(2);
      expect(packet[6]).assertEqual(3);
      expect(packet[7]).assertEqual(4);
      expect(cipher.lastAad.length).assertEqual(8);
      expect(cipher.lastPlaintext[0]).assertEqual(0x12);
      expect(cipher.lastPlaintext[1]).assertEqual(0x34);
      expect(packet[32]).assertEqual(2);
      expect(packet[33]).assertEqual(0);
    });
  });
}
