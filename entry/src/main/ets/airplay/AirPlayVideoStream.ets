import { chachaSeal } from '../crypto/AirPlayStreamCrypto';
import { concatBytes } from '../protocol/Iap2Codec';

export const AIRPLAY_VIDEO_HEADER_SIZE: number = 128;
const VIDEO_CONFIG_OPCODE: number = 1;
const VIDEO_FRAME_OPCODE: number = 0;
const ENCRYPTED_VIDEO_FLAG: number = 0x04;
const CHACHA_TAG_SIZE: number = 16;
const MAX_QUEUED_FRAMES: number = 12;

export interface EncodedH264Event {
  type: 'codecConfig' | 'frame' | 'streamChanged' | 'error' | 'overflow';
  data?: Uint8Array;
  timestampUs: number;
  flags: number;
  message?: string;
}

export function splitH264NalUnits(data: Uint8Array): Uint8Array[] {
  const annexB = splitAnnexB(data);
  if (annexB.length > 0) {
    return annexB;
  }
  const configuration = splitAvcConfigurationRecord(data);
  if (configuration.length > 0) {
    return configuration;
  }
  const lengthPrefixed = splitLengthPrefixed(data);
  if (lengthPrefixed.length > 0) {
    return lengthPrefixed;
  }
  return data.length > 0 ? [data.slice()] : [];
}

export function buildAvcConfigurationRecord(units: Uint8Array[]): Uint8Array {
  const sequenceParameters: Uint8Array[] = [];
  const pictureParameters: Uint8Array[] = [];
  for (const unit of units) {
    const type = unit.length > 0 ? unit[0] & 0x1f : -1;
    if (type === 7) {
      sequenceParameters.push(unit);
    } else if (type === 8) {
      pictureParameters.push(unit);
    }
  }
  const sps = sequenceParameters[0];
  const pps = pictureParameters[0];
  if (!sps || !pps || sps.length < 4 || sps.length > 0xffff || pps.length > 0xffff) {
    throw new Error('H.264 codec configuration is missing a usable SPS or PPS');
  }
  const record = new Uint8Array(11 + sps.length + pps.length);
  let offset = 0;
  record[offset++] = 1;
  record[offset++] = sps[1];
  record[offset++] = sps[2];
  record[offset++] = sps[3];
  record[offset++] = 0xff;
  record[offset++] = 0xe1;
  writeBe16(record, offset, sps.length);
  offset += 2;
  record.set(sps, offset);
  offset += sps.length;
  record[offset++] = 1;
  writeBe16(record, offset, pps.length);
  offset += 2;
  record.set(pps, offset);
  return record;
}

export function packH264Nals(units: Uint8Array[]): Uint8Array {
  let totalLength = 0;
  for (const unit of units) {
    if (unit.length === 0 || unit.length > 0xffffffff) {
      throw new Error('H.264 NAL unit has an invalid length');
    }
    totalLength += 4 + unit.length;
  }
  if (totalLength > 4 * 1024 * 1024) {
    throw new Error('H.264 access unit exceeds the 4 MiB safety limit');
  }
  const packed = new Uint8Array(totalLength);
  let offset = 0;
  for (const unit of units) {
    writeBe32(packed, offset, unit.length);
    offset += 4;
    packed.set(unit, offset);
    offset += unit.length;
  }
  return packed;
}

export function buildAirPlayVideoConfigHeader(bodyLength: number, width: number, height: number): Uint8Array {
  validateVideoShape(width, height);
  const header = buildAirPlayVideoHeader(VIDEO_CONFIG_OPCODE, bodyLength, false);
  header[6] = ENCRYPTED_VIDEO_FLAG;
  writeFloat32Le(header, 16, width);
  writeFloat32Le(header, 20, height);
  return header;
}

export function buildAirPlayVideoFrameHeader(bodyLength: number, nowMillis: number = Date.now()): Uint8Array {
  const header = buildAirPlayVideoHeader(VIDEO_FRAME_OPCODE, bodyLength, true, nowMillis);
  header[6] = ENCRYPTED_VIDEO_FLAG;
  return header;
}

export function buildVideoFrameNonce(counter: bigint): Uint8Array {
  if (counter < BigInt(0) || counter > BigInt('18446744073709551615')) {
    throw new Error('H.264 frame nonce counter is out of range');
  }
  const nonce = new Uint8Array(12);
  for (let index = 0; index < 8; index++) {
    nonce[4 + index] = Number((counter >> BigInt(index * 8)) & BigInt(0xff));
  }
  return nonce;
}

export class AirPlayVideoStreamSender {
  private readonly streamKey: Uint8Array;
  private readonly width: number;
  private readonly height: number;
  private readonly sendBytes: (data: Uint8Array) => Promise<void>;
  private readonly log: (message: string) => void;
  private frameCounter: bigint = BigInt(0);
  private configSent: boolean = false;
  private pendingSps?: Uint8Array;
  private pendingPps?: Uint8Array;
  private sendQueue: Promise<void> = Promise.resolve();
  private framesSent: number = 0;
  private queuedFrames: number = 0;

  constructor(
    streamKey: Uint8Array,
    width: number,
    height: number,
    sendBytes: (data: Uint8Array) => Promise<void>,
    log: (message: string) => void
  ) {
    validateVideoShape(width, height);
    if (streamKey.length !== 32) {
      throw new Error('AirPlay screen-stream key must be 32 bytes');
    }
    this.streamKey = streamKey.slice();
    this.width = width;
    this.height = height;
    this.sendBytes = sendBytes;
    this.log = log;
  }

  handleEncoderEvent(event: EncodedH264Event): Promise<void> {
    const isFrame = event.type === 'frame';
    if (isFrame && this.queuedFrames >= MAX_QUEUED_FRAMES) {
      return Promise.reject(new Error('AirPlay video sender queue is full; stopping to avoid stale frames'));
    }
    if (isFrame) {
      this.queuedFrames++;
    }
    const operation = this.sendQueue.then((): Promise<void> => this.processEvent(event));
    this.sendQueue = operation.finally((): void => {
      if (isFrame) {
        this.queuedFrames--;
      }
    });
    return operation;
  }

  async flush(): Promise<void> {
    await this.sendQueue;
  }

  private async processEvent(event: EncodedH264Event): Promise<void> {
    if (event.type === 'error' || event.type === 'overflow') {
      throw new Error(event.message || `Native H.264 encoder reported ${event.type}`);
    }
    if (event.type === 'streamChanged') {
      this.log('H.264 encoder output format changed; awaiting codec configuration');
      this.configSent = false;
      return;
    }
    const data = event.data;
    if (!data || data.length === 0) {
      return;
    }
    const units = splitH264NalUnits(data);
    if (event.type === 'codecConfig') {
      await this.collectCodecConfiguration(units);
      return;
    }
    if (!this.configSent) {
      await this.collectCodecConfiguration(units);
      if (!this.configSent) {
        return;
      }
    }
    await this.sendFrame(units);
  }

  private async collectCodecConfiguration(units: Uint8Array[]): Promise<void> {
    for (const unit of units) {
      if (unit.length === 0) {
        continue;
      }
      const type = unit[0] & 0x1f;
      if (type === 7) {
        this.pendingSps = unit.slice();
      } else if (type === 8) {
        this.pendingPps = unit.slice();
      }
    }
    if (!this.pendingSps || !this.pendingPps || this.configSent) {
      return;
    }
    const record = buildAvcConfigurationRecord([this.pendingSps, this.pendingPps]);
    const header = buildAirPlayVideoConfigHeader(record.length, this.width, this.height);
    await this.sendBytes(concatBytes(header, record));
    this.configSent = true;
    this.log(`AirPlay H.264 config sent (${this.width}x${this.height}, ${record.length} bytes)`);
  }

  private async sendFrame(units: Uint8Array[]): Promise<void> {
    const filtered = units.filter((unit: Uint8Array): boolean => unit.length > 0);
    if (filtered.length === 0) {
      return;
    }
    const plain = packH264Nals(filtered);
    const header = buildAirPlayVideoFrameHeader(plain.length + CHACHA_TAG_SIZE);
    const encrypted = await chachaSeal(
      this.streamKey,
      buildVideoFrameNonce(this.frameCounter),
      plain,
      header
    );
    await this.sendBytes(concatBytes(header, encrypted));
    this.frameCounter++;
    this.framesSent++;
    if (this.framesSent <= 3 || this.framesSent % 120 === 0) {
      this.log(`AirPlay H.264 frame ${this.framesSent} sent (${plain.length} bytes)`);
    }
  }
}

function buildAirPlayVideoHeader(
  opcode: number,
  bodyLength: number,
  includeTimestamp: boolean,
  nowMillis: number = Date.now()
): Uint8Array {
  if (!Number.isInteger(bodyLength) || bodyLength < 0 || bodyLength > 4 * 1024 * 1024) {
    throw new Error(`AirPlay video body length is out of range: ${bodyLength}`);
  }
  const header = new Uint8Array(AIRPLAY_VIDEO_HEADER_SIZE);
  writeLe32(header, 0, bodyLength);
  header[4] = opcode;
  if (includeTimestamp) {
    const seconds = Math.floor(nowMillis / 1000) + 2208988800;
    const fraction = Math.floor(((nowMillis % 1000) * 0x100000000) / 1000);
    const ntp = (BigInt(seconds) << BigInt(32)) | BigInt(fraction);
    for (let index = 0; index < 8; index++) {
      header[8 + index] = Number((ntp >> BigInt(index * 8)) & BigInt(0xff));
    }
  }
  return header;
}

function splitAnnexB(data: Uint8Array): Uint8Array[] {
  const starts: number[] = [];
  const prefixSizes: number[] = [];
  let index = 0;
  while (index + 3 < data.length) {
    if (data[index] === 0 && data[index + 1] === 0) {
      if (data[index + 2] === 1) {
        starts.push(index);
        prefixSizes.push(3);
        index += 3;
        continue;
      }
      if (index + 3 < data.length && data[index + 2] === 0 && data[index + 3] === 1) {
        starts.push(index);
        prefixSizes.push(4);
        index += 4;
        continue;
      }
    }
    index++;
  }
  if (starts.length === 0) {
    return [];
  }
  const result: Uint8Array[] = [];
  for (let unitIndex = 0; unitIndex < starts.length; unitIndex++) {
    const bodyStart = (starts[unitIndex] ?? 0) + (prefixSizes[unitIndex] ?? 0);
    const bodyEnd = unitIndex + 1 < starts.length ? starts[unitIndex + 1] ?? data.length : data.length;
    if (bodyEnd > bodyStart) {
      result.push(data.slice(bodyStart, bodyEnd));
    }
  }
  return result;
}

function splitLengthPrefixed(data: Uint8Array): Uint8Array[] {
  const result: Uint8Array[] = [];
  let offset = 0;
  while (offset + 4 <= data.length) {
    const length = readBe32(data, offset);
    offset += 4;
    if (length <= 0 || length > data.length - offset) {
      return [];
    }
    result.push(data.slice(offset, offset + length));
    offset += length;
  }
  return offset === data.length ? result : [];
}

function splitAvcConfigurationRecord(data: Uint8Array): Uint8Array[] {
  if (data.length < 7 || data[0] !== 1) {
    return [];
  }
  const units: Uint8Array[] = [];
  let offset = 6;
  const spsCount = (data[5] ?? 0) & 0x1f;
  for (let index = 0; index < spsCount; index++) {
    if (offset + 2 > data.length) {
      return [];
    }
    const length = readBe16(data, offset);
    offset += 2;
    if (length === 0 || offset + length > data.length) {
      return [];
    }
    units.push(data.slice(offset, offset + length));
    offset += length;
  }
  if (offset >= data.length) {
    return [];
  }
  const ppsCount = data[offset] ?? 0;
  offset++;
  for (let index = 0; index < ppsCount; index++) {
    if (offset + 2 > data.length) {
      return [];
    }
    const length = readBe16(data, offset);
    offset += 2;
    if (length === 0 || offset + length > data.length) {
      return [];
    }
    units.push(data.slice(offset, offset + length));
    offset += length;
  }
  return offset === data.length ? units : [];
}

function validateVideoShape(width: number, height: number): void {
  if (!Number.isInteger(width) || !Number.isInteger(height) ||
    width < 320 || height < 240 || width > 1920 || height > 1200 ||
    (width & 1) !== 0 || (height & 1) !== 0) {
    throw new Error(`Unsupported AirPlay H.264 dimensions ${width}x${height}`);
  }
}

function writeLe32(target: Uint8Array, offset: number, value: number): void {
  target[offset] = value & 0xff;
  target[offset + 1] = (value >>> 8) & 0xff;
  target[offset + 2] = (value >>> 16) & 0xff;
  target[offset + 3] = (value >>> 24) & 0xff;
}

function writeBe16(target: Uint8Array, offset: number, value: number): void {
  target[offset] = (value >>> 8) & 0xff;
  target[offset + 1] = value & 0xff;
}

function readBe16(source: Uint8Array, offset: number): number {
  return ((source[offset] ?? 0) << 8) | (source[offset + 1] ?? 0);
}

function writeBe32(target: Uint8Array, offset: number, value: number): void {
  target[offset] = (value >>> 24) & 0xff;
  target[offset + 1] = (value >>> 16) & 0xff;
  target[offset + 2] = (value >>> 8) & 0xff;
  target[offset + 3] = value & 0xff;
}

function readBe32(source: Uint8Array, offset: number): number {
  return ((source[offset] ?? 0) * 0x1000000) +
    ((source[offset + 1] ?? 0) << 16) +
    ((source[offset + 2] ?? 0) << 8) +
    (source[offset + 3] ?? 0);
}

function writeFloat32Le(target: Uint8Array, offset: number, value: number): void {
  const buffer = new ArrayBuffer(4);
  new DataView(buffer).setFloat32(0, value, true);
  target.set(new Uint8Array(buffer), offset);
}
