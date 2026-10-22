import { describe, it, expect } from '@ohos/hypium';
import { AirPlayAudioProfileProtocol } from '../main/ets/protocol/airplay/AirPlayAudioProfileProtocol';
import { AirPlayAudioSyncPacket } from '../main/ets/protocol/airplay/AirPlayAudioSyncPacket';
import { BinaryPlist, BinaryPlistValue } from '../main/ets/protocol/airplay/BinaryPlist';

export default function airPlayAudioProtocolTest(): void {
  describe('AirPlay AAC profile and RTP sync protocol', () => {
    it('selects only receiver-advertised AAC media profiles in stream priority order', 0, () => {
      const mainHigh: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      mainHigh.set('type', 102);
      mainHigh.set('audioType', 'media');
      mainHigh.set('audioOutputFormats', (1 << 22) | (1 << 23));
      const main: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      main.set('type', 100);
      main.set('audioType', 'media');
      main.set('audioOutputFormats', 1 << 22);
      const formats: BinaryPlistValue[] = [mainHigh, main];

      const highLatency: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      highLatency.set('type', 102);
      highLatency.set('audioType', 'media');
      highLatency.set('outputLatencyMicros', 310000);
      const info: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      info.set('audioFormats', formats);
      info.set('audioLatencies', [highLatency]);

      const profiles = AirPlayAudioProfileProtocol.readAacCandidates(BinaryPlist.encode(info));
      expect(profiles.length).assertEqual(3);
      expect(profiles[0].streamType).assertEqual(102);
      expect(profiles[0].sampleRate).assertEqual(44100);
      expect(profiles[0].latencyMs).assertEqual(310);
      expect(profiles[1].streamType).assertEqual(102);
      expect(profiles[1].sampleRate).assertEqual(48000);
      expect(profiles[2].streamType).assertEqual(100);
    });

    it('does not invent AAC capabilities when the receiver omits them', 0, () => {
      const info: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      info.set('audioFormats', []);
      expect(AirPlayAudioProfileProtocol.readAacCandidates(BinaryPlist.encode(info)).length).assertEqual(0);
    });

    it('builds the first and subsequent 20-byte audio sync packets', 0, () => {
      const packet = AirPlayAudioSyncPacket.build(
        0x1234,
        0x01020304,
        0x05060708,
        1700000000125,
        true
      );
      expect(packet.length).assertEqual(20);
      expect(packet[0]).assertEqual(0x90);
      expect(packet[1]).assertEqual(0xD4);
      expect(packet[2]).assertEqual(0x12);
      expect(packet[3]).assertEqual(0x34);
      expect(packet[4]).assertEqual(0x01);
      expect(packet[7]).assertEqual(0x04);
      const ntp = AirPlayAudioSyncPacket.ntpFromMillis(1700000000125);
      expect(Array.from(packet.slice(8, 16)).join(',')).assertEqual(Array.from(ntp).join(','));
      expect(packet[16]).assertEqual(0x05);
      expect(packet[19]).assertEqual(0x08);

      const next = AirPlayAudioSyncPacket.build(0, 9, 10, 1700000001125, false);
      expect(next[0]).assertEqual(0x80);
      expect(next[1]).assertEqual(0xD4);
    });
  });
}
