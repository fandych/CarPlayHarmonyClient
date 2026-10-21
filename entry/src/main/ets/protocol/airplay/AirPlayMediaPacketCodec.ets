import { HarmonyAirPlayCrypto } from './HarmonyAirPlayCrypto';

export interface AirPlayMediaCipher {
  seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array>;
}

export class HarmonyAirPlayMediaCipher implements AirPlayMediaCipher {
  seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
    return HarmonyAirPlayCrypto.chachaSeal(key, nonce, plaintext, aad);
  }
}

export class AirPlayMediaPacketCodec {
  static readonly VIDEO_HEADER_SIZE: number = 128;
  static readonly VIDEO_FRAME_OPCODE: number = 0;
  static readonly VIDEO_CONFIG_OPCODE: number = 1;
  static readonly VIDEO_KEEPALIVE_OPCODE: number = 2;
  static readonly VIDEO_KEEPALIVE_WITH_STATS_OPCODE: number = 5;
  static readonly RTP_HEADER_SIZE: number = 12;
  static readonly CHACHA_TAG_SIZE: number = 16;
  static readonly AUDIO_NONCE_SIZE: number = 8;

  static splitAnnexB(bytes: Uint8Array): Uint8Array[] {
    const starts: number[] = [];
    const prefixLengths: number[] = [];
    let index = 0;
    while (index + 2 < bytes.length) {
      if (bytes[index] === 0 && bytes[index + 1] === 0 && bytes[index + 2] === 1) {
        starts.push(index);
        prefixLengths.push(3);
        index += 3;
      } else if (index + 3 < bytes.length && bytes[index] === 0 && bytes[index + 1] === 0 &&
        bytes[index + 2] === 0 && bytes[index + 3] === 1) {
        starts.push(index);
        prefixLengths.push(4);
        index += 4;
      } else {
        index++;
      }
    }
    if (starts.length === 0) {
      return bytes.length === 0 ? [] : [bytes.slice()];
    }
    const units: Uint8Array[] = [];
    for (let unit = 0; unit < starts.length; unit++) {
      const start = starts[unit] + prefixLengths[unit];
      const end = unit + 1 < starts.length ? starts[unit + 1] : bytes.length;
      if (end > start) {
        units.push(bytes.slice(start, end));
      }
    }
    return units;
  }

  static buildAvcC(annexB: Uint8Array): Uint8Array {
    const units = AirPlayMediaPacketCodec.splitAnnexB(annexB);
    const sps = units.find((unit: Uint8Array) => unit.length > 0 && (unit[0] & 0x1F) === 7);
    const pps = units.find((unit: Uint8Array) => unit.length > 0 && (unit[0] & 0x1F) === 8);
    if (sps === undefined || pps === undefined || sps.length < 4) {
      throw new Error('H.264 configuration requires valid SPS and PPS NAL units.');
    }
    if (sps.length > 0xFFFF || pps.length > 0xFFFF) {
      throw new Error('H.264 parameter set exceeds the avcC length limit.');
    }
    const body = new Uint8Array(11 + sps.length + pps.length);
    let offset = 0;
    body[offset++] = 1;
    body[offset++] = sps[1];
    body[offset++] = sps[2];
    body[offset++] = sps[3];
    body[offset++] = 0xFF;
    body[offset++] = 0xE1;
    body[offset++] = (sps.length >>> 8) & 0xFF;
    body[offset++] = sps.length & 0xFF;
    body.set(sps, offset);
    offset += sps.length;
    body[offset++] = 1;
    body[offset++] = (pps.length >>> 8) & 0xFF;
    body[offset++] = pps.length & 0xFF;
    body.set(pps, offset);
    return body;
  }

  static buildVideoConfigPacket(avcC: Uint8Array, width: number, height: number): Uint8Array {
    AirPlayMediaPacketCodec.requireDimensions(width, height);
    const header = new Uint8Array(AirPlayMediaPacketCodec.VIDEO_HEADER_SIZE);
    AirPlayMediaPacketCodec.writeU32Le(header, 0, avcC.length);
    header[4] = AirPlayMediaPacketCodec.VIDEO_CONFIG_OPCODE;
    header[6] = 0x04;
    AirPlayMediaPacketCodec.writeFloat32Le(header, 16, width);
    AirPlayMediaPacketCodec.writeFloat32Le(header, 20, height);
    return AirPlayMediaPacketCodec.concat(header, avcC);
  }

  static buildKeepAlivePacket(statsBody: Uint8Array = new Uint8Array(0)): Uint8Array {
    const header = new Uint8Array(AirPlayMediaPacketCodec.VIDEO_HEADER_SIZE);
    AirPlayMediaPacketCodec.writeU32Le(header, 0, statsBody.length);
    header[4] = statsBody.length === 0
      ? AirPlayMediaPacketCodec.VIDEO_KEEPALIVE_OPCODE
      : AirPlayMediaPacketCodec.VIDEO_KEEPALIVE_WITH_STATS_OPCODE;
    if (statsBody.length > 0) {
      AirPlayMediaPacketCodec.writeFloat32Le(header, 120, 0);
      AirPlayMediaPacketCodec.writeFloat32Le(header, 124, statsBody.length);
    }
    return AirPlayMediaPacketCodec.concat(header, statsBody);
  }

  static async sealVideoFrame(
    annexB: Uint8Array,
    key: Uint8Array,
    frameCounter: number,
    ntpTimestampLittleEndian: Uint8Array = new Uint8Array(8),
    cipher: AirPlayMediaCipher = new HarmonyAirPlayMediaCipher()
  ): Promise<Uint8Array> {
    AirPlayMediaPacketCodec.requireCounter(frameCounter);
    if (ntpTimestampLittleEndian.length !== 8) {
      throw new Error('Video NTP timestamp must be exactly 8 bytes.');
    }
    const nals = AirPlayMediaPacketCodec.splitAnnexB(annexB);
    if (nals.length === 0) {
      throw new Error('Cannot encode an empty H.264 video frame.');
    }
    const plain = AirPlayMediaPacketCodec.packNals(nals);
    const header = new Uint8Array(AirPlayMediaPacketCodec.VIDEO_HEADER_SIZE);
    AirPlayMediaPacketCodec.writeU32Le(header, 0, plain.length + AirPlayMediaPacketCodec.CHACHA_TAG_SIZE);
    header[4] = AirPlayMediaPacketCodec.VIDEO_FRAME_OPCODE;
    header.set(ntpTimestampLittleEndian, 8);
    const sealed = await cipher.seal(
      key,
      HarmonyAirPlayCrypto.nonceCounter(frameCounter),
      plain,
      header
    );
    if (sealed.length !== plain.length + AirPlayMediaPacketCodec.CHACHA_TAG_SIZE) {
      throw new Error('ChaCha20-Poly1305 returned an invalid video frame length.');
    }
    return AirPlayMediaPacketCodec.concat(header, sealed);
  }

  static async sealAudioPacket(
    payload: Uint8Array,
    key: Uint8Array,
    sequence: number,
    timestamp: number,
    nonceCounter: number,
    streamType: number = 100,
    marker: boolean = false,
    pcmS16LittleEndian: boolean = true,
    cipher: AirPlayMediaCipher = new HarmonyAirPlayMediaCipher()
  ): Promise<Uint8Array> {
    AirPlayMediaPacketCodec.requireCounter(nonceCounter);
    AirPlayMediaPacketCodec.requireUnsigned(sequence, 16, 'RTP sequence');
    AirPlayMediaPacketCodec.requireUnsigned(timestamp, 32, 'RTP timestamp');
    AirPlayMediaPacketCodec.requireUnsigned(streamType, 7, 'RTP payload type');
    const header = new Uint8Array(AirPlayMediaPacketCodec.RTP_HEADER_SIZE);
    header[0] = 0x80;
    header[1] = (marker ? 0x80 : 0) | streamType;
    header[2] = (sequence >>> 8) & 0xFF;
    header[3] = sequence & 0xFF;
    AirPlayMediaPacketCodec.writeU32Be(header, 4, timestamp);
    const wirePayload = pcmS16LittleEndian
      ? AirPlayMediaPacketCodec.swapS16ByteOrder(payload)
      : payload.slice();
    const sealed = await cipher.seal(
      key,
      HarmonyAirPlayCrypto.nonceCounter(nonceCounter),
      wirePayload,
      header.slice(4, 12)
    );
    if (sealed.length !== wirePayload.length + AirPlayMediaPacketCodec.CHACHA_TAG_SIZE) {
      throw new Error('ChaCha20-Poly1305 returned an invalid RTP payload length.');
    }
    const nonceTail = AirPlayMediaPacketCodec.nonceTail(nonceCounter);
    return AirPlayMediaPacketCodec.concat(header, sealed, nonceTail);
  }

  static swapS16ByteOrder(source: Uint8Array): Uint8Array {
    if ((source.length & 1) !== 0) {
      throw new Error('16-bit PCM payload must contain a whole number of samples.');
    }
    const output = source.slice();
    for (let index = 0; index < output.length; index += 2) {
      const first = output[index];
      output[index] = output[index + 1];
      output[index + 1] = first;
    }
    return output;
  }

  private static packNals(nals: Uint8Array[]): Uint8Array {
    let length = 0;
    nals.forEach((nal: Uint8Array) => {
      if (nal.length === 0 || nal.length > 0xFFFFFFFF) {
        throw new Error('H.264 NAL unit length is invalid.');
      }
      length += 4 + nal.length;
    });
    const output = new Uint8Array(length);
    let offset = 0;
    nals.forEach((nal: Uint8Array) => {
      AirPlayMediaPacketCodec.writeU32Be(output, offset, nal.length);
      offset += 4;
      output.set(nal, offset);
      offset += nal.length;
    });
    return output;
  }

  private static nonceTail(counter: number): Uint8Array {
    const tail = new Uint8Array(AirPlayMediaPacketCodec.AUDIO_NONCE_SIZE);
    let value = counter;
    for (let index = 0; index < tail.length; index++) {
      tail[index] = value % 256;
      value = Math.floor(value / 256);
    }
    return tail;
  }

  private static requireDimensions(width: number, height: number): void {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0) {
      throw new Error('Video dimensions must be positive integers.');
    }
  }

  private static requireCounter(counter: number): void {
    if (!Number.isSafeInteger(counter) || counter < 0) {
      throw new Error('AirPlay media nonce counter is out of range.');
    }
  }

  private static requireUnsigned(value: number, bits: number, label: string): void {
    if (!Number.isInteger(value) || value < 0 || value >= Math.pow(2, bits)) {
      throw new Error(`${label} is out of range.`);
    }
  }

  private static writeFloat32Le(bytes: Uint8Array, offset: number, value: number): void {
    const buffer = new ArrayBuffer(4);
    new DataView(buffer).setFloat32(0, value, true);
    bytes.set(new Uint8Array(buffer), offset);
  }

  private static writeU32Le(bytes: Uint8Array, offset: number, value: number): void {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >>> 8) & 0xFF;
    bytes[offset + 2] = (value >>> 16) & 0xFF;
    bytes[offset + 3] = Math.floor(value / 0x1000000) & 0xFF;
  }

  private static writeU32Be(bytes: Uint8Array, offset: number, value: number): void {
    bytes[offset] = Math.floor(value / 0x1000000) & 0xFF;
    bytes[offset + 1] = (value >>> 16) & 0xFF;
    bytes[offset + 2] = (value >>> 8) & 0xFF;
    bytes[offset + 3] = value & 0xFF;
  }

  private static concat(...arrays: Uint8Array[]): Uint8Array {
    let length = 0;
    arrays.forEach((array: Uint8Array) => length += array.length);
    const output = new Uint8Array(length);
    let offset = 0;
    arrays.forEach((array: Uint8Array) => {
      output.set(array, offset);
      offset += array.length;
    });
    return output;
  }
}
