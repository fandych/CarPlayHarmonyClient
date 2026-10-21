export interface Iap2LinkPacketData {
  control: number;
  sequence: number;
  acknowledgement: number;
  sessionId: number;
  payload: Uint8Array | null;
}

const START_DATA = 0xFF5A;
const HEADER_BYTES = 9;
const MIN_PACKET_BYTES = HEADER_BYTES;
const MAX_PACKET_BYTES = 0xFFFF;

function readU16(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function writeU16(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = (value >>> 8) & 0xFF;
  bytes[offset + 1] = value & 0xFF;
}

function checksum(bytes: Uint8Array, start: number, end: number): number {
  let sum = 0;
  for (let index = start; index < end; index++) {
    sum += bytes[index];
  }
  return (-sum) & 0xFF;
}

function validChecksum(bytes: Uint8Array, start: number, end: number): boolean {
  let sum = 0;
  for (let index = start; index < end; index++) {
    sum += bytes[index];
  }
  return (sum & 0xFF) === 0;
}

export class Iap2LinkPacket {
  static encode(packet: Iap2LinkPacketData): Uint8Array {
    const payloadLength = packet.payload === null ? 0 : packet.payload.length;
    const totalLength = HEADER_BYTES + payloadLength + (packet.payload === null ? 0 : 1);
    if (totalLength > MAX_PACKET_BYTES) {
      throw new Error('iAP2 link packet exceeds the maximum length');
    }
    const bytes = new Uint8Array(totalLength);
    writeU16(bytes, 0, START_DATA);
    writeU16(bytes, 2, totalLength);
    bytes[4] = packet.control & 0xFF;
    bytes[5] = packet.sequence & 0xFF;
    bytes[6] = packet.acknowledgement & 0xFF;
    bytes[7] = packet.sessionId & 0xFF;
    bytes[8] = checksum(bytes, 0, 8);
    if (packet.payload !== null) {
      bytes.set(packet.payload, HEADER_BYTES);
      bytes[bytes.length - 1] = checksum(bytes, HEADER_BYTES, bytes.length - 1);
    }
    return bytes;
  }

  static decode(bytes: Uint8Array): Iap2LinkPacketData | null {
    if (bytes.length < MIN_PACKET_BYTES || readU16(bytes, 0) !== START_DATA) {
      return null;
    }
    if (readU16(bytes, 2) !== bytes.length || !validChecksum(bytes, 0, HEADER_BYTES)) {
      return null;
    }
    const payload = bytes.length === HEADER_BYTES ? null : bytes.slice(HEADER_BYTES, bytes.length - 1);
    if (payload !== null && !validChecksum(bytes, HEADER_BYTES, bytes.length)) {
      return null;
    }
    return {
      control: bytes[4],
      sequence: bytes[5],
      acknowledgement: bytes[6],
      sessionId: bytes[7],
      payload
    };
  }
}

export class Iap2LinkStreamParser {
  private buffer: Uint8Array = new Uint8Array(0);

  offer(chunk: Uint8Array): Iap2LinkPacketData[] {
    const merged = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer);
    merged.set(chunk, this.buffer.length);
    this.buffer = merged;

    const packets: Iap2LinkPacketData[] = [];
    while (true) {
      let start = -1;
      for (let index = 0; index + 1 < this.buffer.length; index++) {
        if (this.buffer[index] === 0xFF && this.buffer[index + 1] === 0x5A) {
          start = index;
          break;
        }
      }
      if (start < 0) {
        this.buffer = this.buffer.length > 0 && this.buffer[this.buffer.length - 1] === 0xFF
          ? this.buffer.slice(this.buffer.length - 1)
          : new Uint8Array(0);
        break;
      }
      if (start > 0) {
        this.buffer = this.buffer.slice(start);
      }
      if (this.buffer.length < 4) {
        break;
      }
      const length = readU16(this.buffer, 2);
      if (length < MIN_PACKET_BYTES || length > MAX_PACKET_BYTES) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      if (this.buffer.length < length) {
        break;
      }
      const packet = Iap2LinkPacket.decode(this.buffer.slice(0, length));
      if (packet === null) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      packets.push(packet);
      this.buffer = this.buffer.slice(length);
    }
    return packets;
  }
}
