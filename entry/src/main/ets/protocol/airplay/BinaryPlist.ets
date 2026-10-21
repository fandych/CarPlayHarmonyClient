export type BinaryPlistValue =
  | null
  | boolean
  | number
  | string
  | Uint8Array
  | BinaryPlistValue[]
  | Map<string, BinaryPlistValue>;

const MAX_OBJECTS = 8192;
const MAX_DEPTH = 64;
const HEADER = [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30];

interface PlistLayout {
  offsetSize: number;
  referenceSize: number;
  objectCount: number;
  rootIndex: number;
  offsets: number[];
  objectTableEnd: number;
}

interface PlistPayload {
  length: number;
  start: number;
}

interface PlistEncodeNode {
  value: BinaryPlistValue;
  children: number[];
}

export class BinaryPlist {
  static parse(bytes: Uint8Array): BinaryPlistValue {
    const layout = BinaryPlist.readLayout(bytes);
    const cache: Array<BinaryPlistValue | undefined> = new Array<BinaryPlistValue | undefined>(layout.objectCount);
    const active: Set<number> = new Set<number>();
    return BinaryPlist.readObject(bytes, layout, layout.rootIndex, 0, cache, active);
  }

  static encode(value: BinaryPlistValue): Uint8Array {
    const nodes: PlistEncodeNode[] = [];
    const rootIndex = BinaryPlist.collectEncodeNode(value, nodes, 0);
    if (rootIndex < 0 || nodes.length > MAX_OBJECTS) {
      throw new Error('Bplist object count exceeds the supported limit.');
    }
    const referenceSize = BinaryPlist.integerWidth(nodes.length - 1);
    const objectBytes: Uint8Array[] = [];
    const offsets: number[] = [];
    let objectOffset = HEADER.length;
    for (const node of nodes) {
      offsets.push(objectOffset);
      const encoded = BinaryPlist.encodeNode(node, referenceSize);
      objectBytes.push(encoded);
      objectOffset += encoded.length;
      if (!Number.isSafeInteger(objectOffset) || objectOffset > 16 * 1024 * 1024) {
        throw new Error('Bplist encoded document exceeds the supported size.');
      }
    }
    const offsetTableOffset = objectOffset;
    const offsetSize = BinaryPlist.integerWidth(offsetTableOffset);
    const offsetTable = new Uint8Array(offsets.length * offsetSize);
    for (let index = 0; index < offsets.length; index++) {
      BinaryPlist.writeUnsigned(offsetTable, index * offsetSize, offsetSize, offsets[index]);
    }
    const trailer = new Uint8Array(32);
    trailer[6] = offsetSize;
    trailer[7] = referenceSize;
    BinaryPlist.writeUnsigned(trailer, 8, 8, nodes.length);
    BinaryPlist.writeUnsigned(trailer, 16, 8, rootIndex);
    BinaryPlist.writeUnsigned(trailer, 24, 8, offsetTableOffset);
    return BinaryPlist.concat(
      new Uint8Array(HEADER),
      ...objectBytes,
      offsetTable,
      trailer
    );
  }

  private static readLayout(bytes: Uint8Array): PlistLayout {
    const trailerOffset = bytes.length - 32;
    if (bytes.length < 40 || !BinaryPlist.matchesHeader(bytes)) {
      throw new Error('Invalid or truncated bplist00 document.');
    }

    const offsetSize = bytes[trailerOffset + 6];
    const referenceSize = bytes[trailerOffset + 7];
    const objectCount = BinaryPlist.readUnsigned(bytes, trailerOffset + 8, 8);
    const rootIndex = BinaryPlist.readUnsigned(bytes, trailerOffset + 16, 8);
    const offsetTableOffset = BinaryPlist.readUnsigned(bytes, trailerOffset + 24, 8);
    if (!BinaryPlist.isIntegerWidth(offsetSize) || !BinaryPlist.isIntegerWidth(referenceSize)) {
      throw new Error('Invalid bplist offset or reference width.');
    }
    if (!Number.isInteger(objectCount) || objectCount < 1 || objectCount > MAX_OBJECTS ||
      rootIndex < 0 || rootIndex >= objectCount) {
      throw new Error('Invalid bplist object count or root reference.');
    }
    if (!Number.isInteger(offsetTableOffset) || offsetTableOffset < HEADER.length + 1 ||
      offsetTableOffset + objectCount * offsetSize > trailerOffset) {
      throw new Error('Bplist offset table is outside the document.');
    }

    const offsets: number[] = [];
    for (let index = 0; index < objectCount; index++) {
      const objectOffset = BinaryPlist.readUnsigned(bytes, offsetTableOffset + index * offsetSize, offsetSize);
      if (!Number.isInteger(objectOffset) || objectOffset < HEADER.length || objectOffset >= offsetTableOffset) {
        throw new Error(`Invalid bplist object offset ${index}.`);
      }
      offsets.push(objectOffset);
    }
    return {
      offsetSize,
      referenceSize,
      objectCount,
      rootIndex,
      offsets,
      objectTableEnd: offsetTableOffset
    };
  }

  private static readObject(
    bytes: Uint8Array,
    layout: PlistLayout,
    index: number,
    depth: number,
    cache: Array<BinaryPlistValue | undefined>,
    active: Set<number>
  ): BinaryPlistValue {
    if (!Number.isInteger(index) || index < 0 || index >= layout.objectCount) {
      throw new Error('Bplist object reference is out of range.');
    }
    const existing = cache[index];
    if (existing !== undefined) {
      return existing;
    }
    if (depth > MAX_DEPTH || active.has(index)) {
      throw new Error('Bplist object graph is cyclic or too deeply nested.');
    }

    active.add(index);
    const offset = layout.offsets[index];
    const marker = BinaryPlist.readByte(bytes, offset, layout.objectTableEnd);
    const type = marker >>> 4;
    const info = marker & 0x0F;
    let value: BinaryPlistValue;
    switch (type) {
      case 0:
        value = BinaryPlist.readSimple(info);
        break;
      case 1:
        value = BinaryPlist.readUnsigned(bytes, offset + 1, 1 << info, layout.objectTableEnd);
        break;
      case 2:
        value = BinaryPlist.readReal(bytes, offset + 1, info, layout.objectTableEnd);
        break;
      case 3:
        if (info !== 3) {
          throw new Error('Unsupported bplist date width.');
        }
        value = BinaryPlist.readReal(bytes, offset + 1, info, layout.objectTableEnd);
        break;
      case 4: {
        const payload = BinaryPlist.readPayload(bytes, offset, info, layout.objectTableEnd);
        value = bytes.slice(payload.start, payload.start + payload.length);
        break;
      }
      case 5: {
        const payload = BinaryPlist.readPayload(bytes, offset, info, layout.objectTableEnd);
        value = BinaryPlist.decodeAscii(bytes, payload.start, payload.length);
        break;
      }
      case 6: {
        const payload = BinaryPlist.readPayload(bytes, offset, info, layout.objectTableEnd);
        value = BinaryPlist.decodeUtf16(bytes, payload.start, payload.length, layout.objectTableEnd);
        break;
      }
      case 7: {
        const payload = BinaryPlist.readPayload(bytes, offset, info, layout.objectTableEnd);
        value = BinaryPlist.decodeUtf8(bytes, payload.start, payload.length);
        break;
      }
      case 8:
        value = BinaryPlist.readUnsigned(bytes, offset + 1, info + 1, layout.objectTableEnd);
        break;
      case 10:
      case 12: {
        const payload = BinaryPlist.readPayload(bytes, offset, info, layout.objectTableEnd);
        const result: BinaryPlistValue[] = [];
        for (let child = 0; child < payload.length; child++) {
          const childIndex = BinaryPlist.readReference(bytes, payload.start + child * layout.referenceSize, layout);
          result.push(BinaryPlist.readObject(bytes, layout, childIndex, depth + 1, cache, active));
        }
        value = result;
        break;
      }
      case 13: {
        const payload = BinaryPlist.readPayload(bytes, offset, info, layout.objectTableEnd);
        const result: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
        const valuesStart = payload.start + payload.length * layout.referenceSize;
        for (let child = 0; child < payload.length; child++) {
          const keyIndex = BinaryPlist.readReference(bytes, payload.start + child * layout.referenceSize, layout);
          const key = BinaryPlist.readObject(bytes, layout, keyIndex, depth + 1, cache, active);
          if (typeof key !== 'string' || result.has(key)) {
            throw new Error('Bplist dictionary contains a non-string or duplicate key.');
          }
          const valueIndex = BinaryPlist.readReference(bytes, valuesStart + child * layout.referenceSize, layout);
          result.set(key, BinaryPlist.readObject(bytes, layout, valueIndex, depth + 1, cache, active));
        }
        value = result;
        break;
      }
      default:
        throw new Error(`Unsupported bplist object type ${type}.`);
    }
    active.delete(index);
    cache[index] = value;
    return value;
  }

  private static readSimple(info: number): BinaryPlistValue {
    switch (info) {
      case 0:
        return null;
      case 8:
        return false;
      case 9:
        return true;
      default:
        throw new Error(`Unsupported bplist simple value ${info}.`);
    }
  }

  private static readReal(bytes: Uint8Array, offset: number, info: number, end: number = bytes.length): number {
    const width = 1 << info;
    if ((width !== 4 && width !== 8) || offset < 0 || offset + width > end) {
      throw new Error('Invalid bplist real value.');
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset + offset, width);
    return width === 4 ? view.getFloat32(0, false) : view.getFloat64(0, false);
  }

  private static readPayload(bytes: Uint8Array, offset: number, info: number, end: number): PlistPayload {
    let length = info;
    let start = offset + 1;
    if (info === 15) {
      const marker = BinaryPlist.readByte(bytes, start, end);
      if ((marker >>> 4) !== 1) {
        throw new Error('Invalid extended bplist length.');
      }
      const width = 1 << (marker & 0x0F);
      length = BinaryPlist.readUnsigned(bytes, start + 1, width, end);
      start += 1 + width;
    }
    if (!Number.isInteger(length) || length < 0 || length > end - start) {
      throw new Error('Bplist payload length exceeds the object table.');
    }
    return { length, start };
  }

  private static readReference(bytes: Uint8Array, offset: number, layout: PlistLayout): number {
    return BinaryPlist.readUnsigned(bytes, offset, layout.referenceSize, layout.objectTableEnd);
  }

  private static readUnsigned(bytes: Uint8Array, offset: number, width: number, end: number = bytes.length): number {
    if (!BinaryPlist.isIntegerWidth(width) || offset < 0 || offset + width > end) {
      throw new Error('Bplist integer exceeds the available bytes.');
    }
    let value = 0;
    for (let index = 0; index < width; index++) {
      value = value * 256 + bytes[offset + index];
      if (!Number.isSafeInteger(value)) {
        throw new Error('Bplist integer exceeds JavaScript safe integer range.');
      }
    }
    return value;
  }

  private static collectEncodeNode(
    value: BinaryPlistValue,
    nodes: PlistEncodeNode[],
    depth: number
  ): number {
    if (depth > MAX_DEPTH || nodes.length >= MAX_OBJECTS) {
      throw new Error('Bplist object graph exceeds the supported depth or count.');
    }
    const index = nodes.length;
    const node: PlistEncodeNode = { value, children: [] };
    nodes.push(node);
    if (Array.isArray(value)) {
      value.forEach((child: BinaryPlistValue) => {
        node.children.push(BinaryPlist.collectEncodeNode(child, nodes, depth + 1));
      });
    } else if (value instanceof Map) {
      value.forEach((child: BinaryPlistValue, key: string) => {
        node.children.push(BinaryPlist.collectEncodeNode(key, nodes, depth + 1));
        node.children.push(BinaryPlist.collectEncodeNode(child, nodes, depth + 1));
      });
    }
    return index;
  }

  private static encodeNode(node: PlistEncodeNode, referenceSize: number): Uint8Array {
    const value = node.value;
    if (value === null) {
      return new Uint8Array([0x00]);
    }
    if (typeof value === 'boolean') {
      return new Uint8Array([value ? 0x09 : 0x08]);
    }
    if (typeof value === 'number') {
      if (!Number.isFinite(value)) {
        throw new Error('Bplist numbers must be finite.');
      }
      if (Number.isInteger(value) && value >= 0) {
        return BinaryPlist.encodeInteger(value);
      }
      const bytes = new Uint8Array(9);
      bytes[0] = 0x23;
      new DataView(bytes.buffer).setFloat64(1, value, false);
      return bytes;
    }
    if (typeof value === 'string') {
      const encoded = BinaryPlist.encodeUtf8(value);
      const ascii = encoded.every((byte: number) => byte <= 0x7F);
      return BinaryPlist.concat(
        BinaryPlist.encodeLength(ascii ? 0x50 : 0x70, encoded.length),
        encoded
      );
    }
    if (value instanceof Uint8Array) {
      return BinaryPlist.concat(BinaryPlist.encodeLength(0x40, value.length), value);
    }
    if (Array.isArray(value)) {
      const references = BinaryPlist.encodeReferences(node.children, referenceSize);
      return BinaryPlist.concat(BinaryPlist.encodeLength(0xA0, node.children.length), references);
    }
    if (value instanceof Map) {
      const count = node.children.length / 2;
      const keys: number[] = [];
      const values: number[] = [];
      for (let index = 0; index < node.children.length; index += 2) {
        keys.push(node.children[index]);
        values.push(node.children[index + 1]);
      }
      return BinaryPlist.concat(
        BinaryPlist.encodeLength(0xD0, count),
        BinaryPlist.encodeReferences(keys, referenceSize),
        BinaryPlist.encodeReferences(values, referenceSize)
      );
    }
    throw new Error('Bplist value type is unsupported.');
  }

  private static encodeInteger(value: number): Uint8Array {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error('Bplist integer exceeds the supported nonnegative safe range.');
    }
    let width = 8;
    if (value <= 0x7F) {
      width = 1;
    } else if (value <= 0x7FFF) {
      width = 2;
    } else if (value <= 0x7FFFFFFF) {
      width = 4;
    }
    const encoded = new Uint8Array(width + 1);
    encoded[0] = 0x10 | Math.log2(width);
    let remaining = value;
    for (let index = width; index > 0; index--) {
      encoded[index] = ((remaining % 256) + 256) % 256;
      remaining = Math.floor(remaining / 256);
    }
    return encoded;
  }

  private static encodeLength(typeMarker: number, length: number): Uint8Array {
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new Error('Bplist payload length is invalid.');
    }
    if (length < 15) {
      return new Uint8Array([typeMarker | length]);
    }
    return BinaryPlist.concat(
      new Uint8Array([typeMarker | 0x0F]),
      BinaryPlist.encodeInteger(length)
    );
  }

  private static encodeReferences(references: number[], width: number): Uint8Array {
    const encoded = new Uint8Array(references.length * width);
    references.forEach((reference: number, index: number) => {
      BinaryPlist.writeUnsigned(encoded, index * width, width, reference);
    });
    return encoded;
  }

  private static encodeUtf8(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let index = 0; index < value.length; index++) {
      let point = value.charCodeAt(index);
      if (point >= 0xD800 && point <= 0xDBFF) {
        const low = value.charCodeAt(index + 1);
        if (low < 0xDC00 || low > 0xDFFF) {
          throw new Error('Bplist string contains an invalid UTF-16 surrogate.');
        }
        point = 0x10000 + ((point - 0xD800) << 10) + (low - 0xDC00);
        index++;
      } else if (point >= 0xDC00 && point <= 0xDFFF) {
        throw new Error('Bplist string contains an invalid UTF-16 surrogate.');
      }
      if (point <= 0x7F) {
        bytes.push(point);
      } else if (point <= 0x7FF) {
        bytes.push(0xC0 | (point >>> 6), 0x80 | (point & 0x3F));
      } else if (point <= 0xFFFF) {
        bytes.push(0xE0 | (point >>> 12), 0x80 | ((point >>> 6) & 0x3F), 0x80 | (point & 0x3F));
      } else {
        bytes.push(
          0xF0 | (point >>> 18),
          0x80 | ((point >>> 12) & 0x3F),
          0x80 | ((point >>> 6) & 0x3F),
          0x80 | (point & 0x3F)
        );
      }
    }
    return new Uint8Array(bytes);
  }

  private static integerWidth(value: number): number {
    if (value <= 0xFF) {
      return 1;
    }
    if (value <= 0xFFFF) {
      return 2;
    }
    if (value <= 0xFFFFFFFF) {
      return 4;
    }
    return 8;
  }

  private static writeUnsigned(bytes: Uint8Array, offset: number, width: number, value: number): void {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error('Bplist unsigned integer is out of range.');
    }
    let remaining = value;
    for (let index = width - 1; index >= 0; index--) {
      bytes[offset + index] = remaining % 256;
      remaining = Math.floor(remaining / 256);
    }
    if (remaining !== 0) {
      throw new Error('Bplist unsigned integer does not fit its encoded width.');
    }
  }

  private static concat(...values: Uint8Array[]): Uint8Array {
    let length = 0;
    values.forEach((value: Uint8Array) => length += value.length);
    const output = new Uint8Array(length);
    let offset = 0;
    values.forEach((value: Uint8Array) => {
      output.set(value, offset);
      offset += value.length;
    });
    return output;
  }

  private static readByte(bytes: Uint8Array, offset: number, end: number): number {
    if (offset < 0 || offset >= end) {
      throw new Error('Unexpected end of bplist object data.');
    }
    return bytes[offset];
  }

  private static decodeAscii(bytes: Uint8Array, offset: number, length: number): string {
    const codes: number[] = [];
    for (let index = 0; index < length; index++) {
      const code = bytes[offset + index];
      if (code > 0x7F) {
        throw new Error('Bplist ASCII string contains a non-ASCII byte.');
      }
      codes.push(code);
    }
    return String.fromCharCode(...codes);
  }

  private static decodeUtf16(bytes: Uint8Array, offset: number, length: number, end: number): string {
    if (offset + length * 2 > end) {
      throw new Error('Bplist UTF-16 string exceeds the object table.');
    }
    const units: number[] = [];
    for (let index = 0; index < length; index++) {
      units.push((bytes[offset + index * 2] << 8) | bytes[offset + index * 2 + 1]);
    }
    const parts: string[] = [];
    for (let index = 0; index < units.length; index += 1024) {
      parts.push(String.fromCharCode(...units.slice(index, index + 1024)));
    }
    return parts.join('');
  }

  private static decodeUtf8(bytes: Uint8Array, offset: number, length: number): string {
    const end = offset + length;
    const points: number[] = [];
    let index = offset;
    while (index < end) {
      const first = bytes[index];
      let point: number;
      let count: number;
      if (first <= 0x7F) {
        point = first;
        count = 1;
      } else if ((first & 0xE0) === 0xC0) {
        point = first & 0x1F;
        count = 2;
      } else if ((first & 0xF0) === 0xE0) {
        point = first & 0x0F;
        count = 3;
      } else if ((first & 0xF8) === 0xF0) {
        point = first & 0x07;
        count = 4;
      } else {
        throw new Error('Invalid UTF-8 in bplist string.');
      }
      if (index + count > end) {
        throw new Error('Truncated UTF-8 in bplist string.');
      }
      for (let part = 1; part < count; part++) {
        const next = bytes[index + part];
        if ((next & 0xC0) !== 0x80) {
          throw new Error('Invalid UTF-8 continuation byte in bplist string.');
        }
        point = (point << 6) | (next & 0x3F);
      }
      if ((count === 2 && point < 0x80) || (count === 3 && point < 0x800) ||
        (count === 4 && point < 0x10000) || point > 0x10FFFF ||
        (point >= 0xD800 && point <= 0xDFFF)) {
        throw new Error('Non-canonical UTF-8 in bplist string.');
      }
      points.push(point);
      index += count;
    }
    const parts: string[] = [];
    for (let point = 0; point < points.length; point += 512) {
      const chars: number[] = [];
      for (let cursor = point; cursor < Math.min(points.length, point + 512); cursor++) {
        const code = points[cursor];
        if (code <= 0xFFFF) {
          chars.push(code);
        } else {
          const adjusted = code - 0x10000;
          chars.push(0xD800 + (adjusted >>> 10), 0xDC00 + (adjusted & 0x3FF));
        }
      }
      parts.push(String.fromCharCode(...chars));
    }
    return parts.join('');
  }

  private static matchesHeader(bytes: Uint8Array): boolean {
    if (bytes.length < HEADER.length) {
      return false;
    }
    for (let index = 0; index < HEADER.length; index++) {
      if (bytes[index] !== HEADER[index]) {
        return false;
      }
    }
    return true;
  }

  private static isIntegerWidth(width: number): boolean {
    return width === 1 || width === 2 || width === 4 || width === 8;
  }
}
