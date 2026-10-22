export class AirPlayAudioSyncPacket {
  static readonly SIZE: number = 20;
  private static readonly PAYLOAD_TYPE: number = 0xD4;

  static build(
    sequence: number,
    currentRtpTimestamp: number,
    nextRtpTimestamp: number,
    nowMillis: number,
    first: boolean
  ): Uint8Array {
    AirPlayAudioSyncPacket.requireUnsigned(sequence, 0xFFFF, 'audio sync sequence');
    AirPlayAudioSyncPacket.requireUnsigned(currentRtpTimestamp, 0xFFFFFFFF, 'current RTP timestamp');
    AirPlayAudioSyncPacket.requireUnsigned(nextRtpTimestamp, 0xFFFFFFFF, 'next RTP timestamp');
    if (!Number.isSafeInteger(nowMillis) || nowMillis < 0) {
      throw new Error('AirPlay audio sync clock value is invalid.');
    }
    const packet = new Uint8Array(AirPlayAudioSyncPacket.SIZE);
    packet[0] = first ? 0x90 : 0x80;
    packet[1] = AirPlayAudioSyncPacket.PAYLOAD_TYPE;
    packet[2] = Math.floor(sequence / 256) & 0xFF;
    packet[3] = sequence & 0xFF;
    AirPlayAudioSyncPacket.writeU32Be(packet, 4, currentRtpTimestamp);
    packet.set(AirPlayAudioSyncPacket.ntpFromMillis(nowMillis), 8);
    AirPlayAudioSyncPacket.writeU32Be(packet, 16, nextRtpTimestamp);
    return packet;
  }

  static ntpFromMillis(nowMillis: number): Uint8Array {
    if (!Number.isSafeInteger(nowMillis) || nowMillis < 0) {
      throw new Error('AirPlay NTP clock value is invalid.');
    }
    const seconds = Math.floor(nowMillis / 1000);
    const fraction = Math.floor(((nowMillis % 1000) * 0x100000000) / 1000);
    const result = new Uint8Array(8);
    AirPlayAudioSyncPacket.writeU32Be(result, 0, seconds % 0x100000000);
    AirPlayAudioSyncPacket.writeU32Be(result, 4, fraction);
    return result;
  }

  private static writeU32Be(bytes: Uint8Array, offset: number, value: number): void {
    bytes[offset] = Math.floor(value / 0x1000000) & 0xFF;
    bytes[offset + 1] = Math.floor(value / 0x10000) & 0xFF;
    bytes[offset + 2] = Math.floor(value / 0x100) & 0xFF;
    bytes[offset + 3] = value & 0xFF;
  }

  private static requireUnsigned(value: number, maximum: number, label: string): void {
    if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
      throw new Error(`AirPlay ${label} is outside the supported range.`);
    }
  }
}
