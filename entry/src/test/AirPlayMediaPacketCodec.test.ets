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
