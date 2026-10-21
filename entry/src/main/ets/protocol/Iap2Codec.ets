import util from '@ohos.util';

export interface Iap2ControlFrame {
  messageId: number;
  body: Uint8Array;
}

export interface Iap2LinkFrame {
  control: number;
  sequence: number;
  acknowledgement: number;
  sessionId: number;
  payload: Uint8Array;
}

export interface Iap2Parameter {
  id: number;
  value: Uint8Array;
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
  let length = 0;
  for (const part of parts) {
    length += part.length;
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const result = new Uint8Array(bytes.length);
  result.set(bytes);
  return result.buffer;
}

export function encodeUtf8(value: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(value);
}

export function decodeUtf8(value: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(value);
}

export function readU16(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function writeU16(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = (value >>> 8) & 0xff;
  bytes[offset + 1] = value & 0xff;
}

function checksum(bytes: Uint8Array, end: number): number {
  let sum = 0;
  for (let index = 0; index < end; index++) {
    sum += bytes[index];
  }
  return (-sum) & 0xff;
}

export function encodeIap2Control(messageId: number, body: Uint8Array = new Uint8Array(0)): Uint8Array {
  if (messageId < 0 || messageId > 0xffff || body.length + 6 > 0xffff) {
    throw new Error('iAP2 control frame is too large or has an invalid message ID');
  }
  const result = new Uint8Array(6 + body.length);
  writeU16(result, 0, 0x4040);
  writeU16(result, 2, result.length);
  writeU16(result, 4, messageId);
  result.set(body, 6);
  return result;
}

export function encodeIap2Parameter(id: number, value: Uint8Array): Uint8Array {
  if (id < 0 || id > 0xffff || value.length + 4 > 0xffff) {
    throw new Error('iAP2 parameter is too large or has an invalid ID');
  }
  const result = new Uint8Array(4 + value.length);
  writeU16(result, 0, result.length);
  writeU16(result, 2, id);
  result.set(value, 4);
  return result;
}

export function stringParameter(id: number, value: string): Uint8Array {
  if (value.indexOf('\0') >= 0) {
    throw new Error('iAP2 strings cannot contain a NUL character');
  }
  return encodeIap2Parameter(id, concatBytes(encodeUtf8(value), new Uint8Array([0])));
}

export function numberParameter(id: number, value: number, width: 1 | 2 | 4): Uint8Array {
  const bytes = new Uint8Array(width);
  for (let index = width - 1; index >= 0; index--) {
    bytes[index] = value & 0xff;
    value = Math.floor(value / 256);
  }
  return encodeIap2Parameter(id, bytes);
}

export function groupedParameter(id: number, children: Uint8Array[]): Uint8Array {
  return encodeIap2Parameter(id, concatBytes(...children));
}

export function decodeIap2Parameters(bytes: Uint8Array): Iap2Parameter[] {
  const parameters: Iap2Parameter[] = [];
  let offset = 0;
  while (offset + 4 <= bytes.length) {
    const length = readU16(bytes, offset);
    if (length < 4 || offset + length > bytes.length) {
      throw new Error('Malformed iAP2 parameter length');
    }
    const parameter: Iap2Parameter = {
      id: readU16(bytes, offset + 2),
      value: bytes.slice(offset + 4, offset + length)
    };
    parameters.push(parameter);
    offset += length;
  }
  if (offset !== bytes.length) {
    throw new Error('Trailing bytes in iAP2 parameter body');
  }
  return parameters;
}

export function decodeIap2String(value: Uint8Array): string {
  let end = value.indexOf(0);
  if (end < 0) {
    end = value.length;
  }
  return decodeUtf8(value.slice(0, end));
}

export function encodeIap2LinkFrame(frame: Iap2LinkFrame): Uint8Array {
  if (frame.payload.length + 10 > 0xffff) {
    throw new Error('iAP2 link frame is too large');
  }
  const result = new Uint8Array(10 + frame.payload.length);
  result[0] = 0xff;
  result[1] = 0x5a;
  writeU16(result, 2, result.length);
  result[4] = frame.control & 0xff;
  result[5] = frame.sequence & 0xff;
  result[6] = frame.acknowledgement & 0xff;
  result[7] = frame.sessionId & 0xff;
  result[8] = checksum(result, 8);
  result.set(frame.payload, 9);
  result[result.length - 1] = checksum(result.subarray(9, result.length - 1), result.length - 10);
  return result;
}

function findLinkHeader(bytes: Uint8Array): number {
  for (let index = 0; index + 1 < bytes.length; index++) {
    if (bytes[index] === 0xff && bytes[index + 1] === 0x5a) {
      return index;
    }
  }
  return -1;
}

export class Iap2LinkDecoder {
  private buffer: Uint8Array = new Uint8Array(0);

  push(chunk: Uint8Array): Iap2LinkFrame[] {
    if (chunk.length + this.buffer.length > 1024 * 1024) {
      this.buffer = new Uint8Array(0);
      throw new Error('iAP2 link input exceeded the 1 MiB safety limit');
    }
    this.buffer = concatBytes(this.buffer, chunk);
    const frames: Iap2LinkFrame[] = [];
    while (true) {
      const start = findLinkHeader(this.buffer);
      if (start < 0) {
        this.buffer = this.buffer.slice(Math.max(0, this.buffer.length - 1));
        break;
      }
      if (start > 0) {
        this.buffer = this.buffer.slice(start);
      }
      if (this.buffer.length < 9) {
        break;
      }
      const length = readU16(this.buffer, 2);
      if (length < 10 || (this.buffer.subarray(0, 9).reduce((sum: number, value: number) => sum + value, 0) & 0xff) !== 0) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      if (this.buffer.length < length) {
        break;
      }
      let payloadSum = 0;
      for (let index = 9; index < length; index++) {
        payloadSum += this.buffer[index];
      }
      if ((payloadSum & 0xff) !== 0) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      const frame: Iap2LinkFrame = {
        control: this.buffer[4],
        sequence: this.buffer[5],
        acknowledgement: this.buffer[6],
        sessionId: this.buffer[7],
        payload: this.buffer.slice(9, length - 1)
      };
      frames.push(frame);
      this.buffer = this.buffer.slice(length);
    }
    return frames;
  }
}

export function encodeIap2SyncPayload(controlSessionId: number = 10): Uint8Array {
  const sessions = new Uint8Array([
    controlSessionId & 0xff, 0x00, 0x02,
    (controlSessionId + 1) & 0xff, 0x02, 0x01,
    (controlSessionId + 2) & 0xff, 0x01, 0x02
  ]);
  const header = new Uint8Array(10);
  header[0] = 1;
  header[1] = 4;
  writeU16(header, 2, 1024);
  writeU16(header, 4, 4000);
  writeU16(header, 6, 4000);
  header[8] = 4;
  header[9] = 4;
  return concatBytes(header, sessions);
}

export class Iap2ControlDecoder {
  private buffer: Uint8Array = new Uint8Array(0);

  push(chunk: Uint8Array): Iap2ControlFrame[] {
    if (chunk.length + this.buffer.length > 1024 * 1024) {
      this.buffer = new Uint8Array(0);
      throw new Error('iAP2 control input exceeded the 1 MiB safety limit');
    }
    this.buffer = concatBytes(this.buffer, chunk);
    const frames: Iap2ControlFrame[] = [];
    while (true) {
      let start = -1;
      for (let index = 0; index + 1 < this.buffer.length; index++) {
        if (this.buffer[index] === 0x40 && this.buffer[index + 1] === 0x40) {
          start = index;
          break;
        }
      }
      if (start < 0) {
        this.buffer = this.buffer.slice(Math.max(0, this.buffer.length - 1));
        break;
      }
      if (start > 0) {
        this.buffer = this.buffer.slice(start);
      }
      if (this.buffer.length < 6) {
        break;
      }
      const length = readU16(this.buffer, 2);
      if (length < 6) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      if (this.buffer.length < length) {
        break;
      }
      const frame: Iap2ControlFrame = {
        messageId: readU16(this.buffer, 4),
        body: this.buffer.slice(6, length)
      };
      frames.push(frame);
      this.buffer = this.buffer.slice(length);
    }
    return frames;
  }
}
