export interface Iap2CsmFrame {
  messageId: number;
  body: Uint8Array;
}

export interface Iap2Param {
  id: number;
  value: Uint8Array;
}

const CSM_START = 0x4040;
const CSM_HEADER_BYTES = 6;
const MAX_FRAME_BYTES = 0xFFFF;

function readU16(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function writeU16(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = (value >>> 8) & 0xFF;
  bytes[offset + 1] = value & 0xFF;
}

function concatenate(left: Uint8Array, right: Uint8Array): Uint8Array {
  const output = new Uint8Array(left.length + right.length);
  output.set(left);
  output.set(right, left.length);
  return output;
}

function encodeUtf8(value: string): Uint8Array {
  const bytes: number[] = [];
  for (let index = 0; index < value.length; index++) {
    let codePoint = value.charCodeAt(index);
    if (codePoint >= 0xD800 && codePoint <= 0xDBFF && index + 1 < value.length) {
      const low = value.charCodeAt(index + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + low - 0xDC00;
        index++;
      } else {
        codePoint = 0xFFFD;
      }
    } else if (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
      codePoint = 0xFFFD;
    }

    if (codePoint <= 0x7F) {
      bytes.push(codePoint);
    } else if (codePoint <= 0x7FF) {
      bytes.push(0xC0 | (codePoint >>> 6), 0x80 | (codePoint & 0x3F));
    } else if (codePoint <= 0xFFFF) {
      bytes.push(0xE0 | (codePoint >>> 12), 0x80 | ((codePoint >>> 6) & 0x3F), 0x80 | (codePoint & 0x3F));
    } else {
      bytes.push(
        0xF0 | (codePoint >>> 18),
        0x80 | ((codePoint >>> 12) & 0x3F),
        0x80 | ((codePoint >>> 6) & 0x3F),
        0x80 | (codePoint & 0x3F)
      );
    }
  }
  return new Uint8Array(bytes);
}

function decodeUtf8(bytes: Uint8Array): string {
  const chars: string[] = [];
  let index = 0;
  while (index < bytes.length) {
    const first = bytes[index];
    let codePoint = 0xFFFD;
    let byteCount = 1;
    if (first <= 0x7F) {
      codePoint = first;
    } else if ((first & 0xE0) === 0xC0 && index + 1 < bytes.length) {
      codePoint = ((first & 0x1F) << 6) | (bytes[index + 1] & 0x3F);
      byteCount = 2;
    } else if ((first & 0xF0) === 0xE0 && index + 2 < bytes.length) {
      codePoint = ((first & 0x0F) << 12) | ((bytes[index + 1] & 0x3F) << 6) | (bytes[index + 2] & 0x3F);
      byteCount = 3;
    } else if ((first & 0xF8) === 0xF0 && index + 3 < bytes.length) {
      codePoint = ((first & 0x07) << 18) | ((bytes[index + 1] & 0x3F) << 12) |
        ((bytes[index + 2] & 0x3F) << 6) | (bytes[index + 3] & 0x3F);
      byteCount = 4;
    }
    index += byteCount;
    if (codePoint <= 0xFFFF) {
      chars.push(String.fromCharCode(codePoint));
    } else {
      const adjusted = codePoint - 0x10000;
      chars.push(String.fromCharCode(0xD800 + (adjusted >>> 10)));
      chars.push(String.fromCharCode(0xDC00 + (adjusted & 0x3FF)));
    }
  }
  return chars.join('');
}

export class Iap2Csm {
  static encode(messageId: number, body: Uint8Array = new Uint8Array(0)): Uint8Array {
    if (!Number.isInteger(messageId) || messageId < 0 || messageId > 0xFFFF) {
      throw new Error('iAP2 CSM message id must fit in u16');
    }
    if (body.length > MAX_FRAME_BYTES - CSM_HEADER_BYTES) {
      throw new Error('iAP2 CSM body exceeds the maximum frame length');
    }

    const frame = new Uint8Array(CSM_HEADER_BYTES + body.length);
    writeU16(frame, 0, CSM_START);
    writeU16(frame, 2, frame.length);
    writeU16(frame, 4, messageId);
    frame.set(body, CSM_HEADER_BYTES);
    return frame;
  }

  static param(id: number, value: Uint8Array): Uint8Array {
    if (!Number.isInteger(id) || id < 0 || id > 0xFFFF) {
      throw new Error('iAP2 CSM parameter id must fit in u16');
    }
    if (value.length > MAX_FRAME_BYTES - 4) {
      throw new Error('iAP2 CSM parameter exceeds the maximum length');
    }

    const output = new Uint8Array(value.length + 4);
    writeU16(output, 0, output.length);
    writeU16(output, 2, id);
    output.set(value, 4);
    return output;
  }

  static u8(id: number, value: number): Uint8Array {
    if (!Number.isInteger(value) || value < 0 || value > 0xFF) {
      throw new Error('iAP2 CSM u8 value is out of range');
    }
    return Iap2Csm.param(id, new Uint8Array([value]));
  }

  static u16(id: number, value: number): Uint8Array {
    if (!Number.isInteger(value) || value < 0 || value > 0xFFFF) {
      throw new Error('iAP2 CSM u16 value is out of range');
    }
    const bytes = new Uint8Array(2);
    writeU16(bytes, 0, value);
    return Iap2Csm.param(id, bytes);
  }

  static string(id: number, value: string): Uint8Array {
    if (value.indexOf('\0') >= 0) {
      throw new Error('iAP2 CSM strings must not contain NUL');
    }
    const encoded = encodeUtf8(value);
    return Iap2Csm.param(id, concatenate(encoded, new Uint8Array([0])));
  }

  static group(id: number, ...children: Uint8Array[]): Uint8Array {
    let totalLength = 0;
    for (let index = 0; index < children.length; index++) {
      totalLength += children[index].length;
    }
    const value = new Uint8Array(totalLength);
    let offset = 0;
    for (let index = 0; index < children.length; index++) {
      value.set(children[index], offset);
      offset += children[index].length;
    }
    return Iap2Csm.param(id, value);
  }

  static parseParams(bytes: Uint8Array): Iap2Param[] {
    const params: Iap2Param[] = [];
    let offset = 0;
    while (offset + 4 <= bytes.length) {
      const length = readU16(bytes, offset);
      if (length < 4 || offset + length > bytes.length) {
        break;
      }
      params.push({
        id: readU16(bytes, offset + 2),
        value: bytes.slice(offset + 4, offset + length)
      });
      offset += length;
    }
    return params;
  }

  static asString(param: Iap2Param): string | null {
    if (param.value.length === 0 || param.value[param.value.length - 1] !== 0) {
      return null;
    }
    return decodeUtf8(param.value.slice(0, param.value.length - 1));
  }

  static asU16List(param: Iap2Param): number[] {
    if (param.value.length % 2 !== 0) {
      throw new Error('iAP2 CSM u16 list has an odd byte length');
    }
    const values: number[] = [];
    for (let offset = 0; offset < param.value.length; offset += 2) {
      values.push(readU16(param.value, offset));
    }
    return values;
  }
}

export class Iap2CsmParser {
  private buffer: Uint8Array = new Uint8Array(0);

  offer(chunk: Uint8Array): Iap2CsmFrame[] {
    this.buffer = concatenate(this.buffer, chunk);
    const frames: Iap2CsmFrame[] = [];

    while (true) {
      let start = -1;
      for (let index = 0; index + 1 < this.buffer.length; index++) {
        if (this.buffer[index] === 0x40 && this.buffer[index + 1] === 0x40) {
          start = index;
          break;
        }
      }
      if (start < 0) {
        this.buffer = this.buffer.length > 0 && this.buffer[this.buffer.length - 1] === 0x40
          ? this.buffer.slice(this.buffer.length - 1)
          : new Uint8Array(0);
        break;
      }
      if (start > 0) {
        this.buffer = this.buffer.slice(start);
      }
      if (this.buffer.length < CSM_HEADER_BYTES) {
        break;
      }

      const length = readU16(this.buffer, 2);
      if (length < CSM_HEADER_BYTES) {
        this.buffer = this.buffer.slice(1);
        continue;
      }
      if (this.buffer.length < length) {
        break;
      }

      frames.push({
        messageId: readU16(this.buffer, 4),
        body: this.buffer.slice(CSM_HEADER_BYTES, length)
      });
      this.buffer = this.buffer.slice(length);
    }
    return frames;
  }
}
