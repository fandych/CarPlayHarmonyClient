import util from '@ohos.util';
import { concatBytes, encodeUtf8 } from '../protocol/Iap2Codec';

interface DecodedLength {
  length: number;
  cursor: number;
}

export class PlistNode {
  readonly kind: string;
  boolValue: boolean = false;
  integerValue: bigint = BigInt(0);
  realValue: number = 0;
  dataValue: Uint8Array = new Uint8Array(0);
  stringValue: string = '';
  arrayValue: PlistNode[] = [];
  dictionaryValue: Map<string, PlistNode> = new Map<string, PlistNode>();

  private constructor(kind: string) {
    this.kind = kind;
  }

  static nullValue(): PlistNode {
    return new PlistNode('null');
  }

  static boolean(value: boolean): PlistNode {
    const node = new PlistNode('boolean');
    node.boolValue = value;
    return node;
  }

  static integer(value: bigint | number): PlistNode {
    const node = new PlistNode('integer');
    node.integerValue = typeof value === 'number' ? BigInt(Math.trunc(value)) : value;
    return node;
  }

  static real(value: number): PlistNode {
    const node = new PlistNode('real');
    node.realValue = value;
    return node;
  }

  static data(value: Uint8Array): PlistNode {
    const node = new PlistNode('data');
    node.dataValue = value.slice();
    return node;
  }

  static string(value: string): PlistNode {
    const node = new PlistNode('string');
    node.stringValue = value;
    return node;
  }

  static array(value: PlistNode[]): PlistNode {
    const node = new PlistNode('array');
    node.arrayValue = value.slice();
    return node;
  }

  static dictionary(value: Map<string, PlistNode>): PlistNode {
    const node = new PlistNode('dictionary');
    node.dictionaryValue = new Map<string, PlistNode>(value);
    return node;
  }

  get(key: string): PlistNode | undefined {
    if (this.kind !== 'dictionary') {
      throw new Error('Property lookup requires a binary plist dictionary');
    }
    return this.dictionaryValue.get(key);
  }
}

export class BinaryPlist {
  static decode(bytes: Uint8Array): PlistNode {
    if (bytes.length < 40 || !BinaryPlist.hasHeader(bytes)) {
      throw new Error('Invalid or truncated bplist00 data');
    }
    const trailer = bytes.length - 32;
    const offsetSize = bytes[trailer + 6];
    const referenceSize = bytes[trailer + 7];
    const objectCount = toSafeNumber(readUnsigned(bytes, trailer + 8, 8), 'object count');
    const topObject = toSafeNumber(readUnsigned(bytes, trailer + 16, 8), 'root object');
    const offsetTable = toSafeNumber(readUnsigned(bytes, trailer + 24, 8), 'offset table');
    if (offsetSize < 1 || offsetSize > 8 || referenceSize < 1 || referenceSize > 8 ||
      objectCount < 1 || objectCount > 100000 || topObject >= objectCount ||
      offsetTable < 8 || offsetTable + objectCount * offsetSize > trailer) {
      throw new Error('Invalid bplist00 trailer');
    }

    const offsets: number[] = [];
    for (let index = 0; index < objectCount; index++) {
      const offset = toSafeNumber(readUnsigned(bytes, offsetTable + index * offsetSize, offsetSize), 'object offset');
      if (offset < 8 || offset >= offsetTable) {
        throw new Error(`Invalid bplist00 object offset ${offset}`);
      }
      offsets.push(offset);
    }
    const cache: Map<number, PlistNode> = new Map<number, PlistNode>();
    return BinaryPlist.decodeObject(bytes, offsets, referenceSize, objectCount, topObject, offsetTable, cache, 0);
  }

  static encode(root: PlistNode): Uint8Array {
    const objects: Uint8Array[] = [];
    const rootIndex = BinaryPlist.encodeObject(root, objects);
    if (rootIndex !== 0) {
      throw new Error('Internal bplist00 root reference error');
    }
    const referenceSize: number = 4;
    const offsets: number[] = [];
    let objectBytes = 8;
    for (let index = 0; index < objects.length; index++) {
      offsets.push(objectBytes);
      objectBytes += objects[index].length;
    }
    const offsetSize = widthForUnsigned(BigInt(objectBytes));
    const offsetTableOffset = objectBytes;
    const totalLength = offsetTableOffset + objects.length * offsetSize + 32;
    const output = new Uint8Array(totalLength);
    output.set(encodeUtf8('bplist00'), 0);
    let cursor = 8;
    for (const object of objects) {
      output.set(object, cursor);
      cursor += object.length;
    }
    for (let index = 0; index < offsets.length; index++) {
      writeUnsigned(output, offsetTableOffset + index * offsetSize, offsetSize, BigInt(offsets[index]));
    }
    const trailer = totalLength - 32;
    output[trailer + 6] = offsetSize;
    output[trailer + 7] = referenceSize;
    writeUnsigned(output, trailer + 8, 8, BigInt(objects.length));
    writeUnsigned(output, trailer + 16, 8, BigInt(rootIndex));
    writeUnsigned(output, trailer + 24, 8, BigInt(offsetTableOffset));
    return output;
  }

  private static hasHeader(bytes: Uint8Array): boolean {
    const header = encodeUtf8('bplist00');
    for (let index = 0; index < header.length; index++) {
      if (bytes[index] !== header[index]) {
        return false;
      }
    }
    return true;
  }

  private static decodeObject(
    bytes: Uint8Array,
    offsets: number[],
    referenceSize: number,
    objectCount: number,
    reference: number,
    objectLimit: number,
    cache: Map<number, PlistNode>,
    depth: number
  ): PlistNode {
    if (reference < 0 || reference >= objectCount || depth > 100) {
      throw new Error('Invalid or excessively nested bplist00 object reference');
    }
    const cached = cache.get(reference);
    if (cached) {
      return cached;
    }
    let cursor = offsets[reference];
    const marker = bytes[cursor];
    cursor++;
    const type = marker >>> 4;
    const info = marker & 0x0f;
    if (type === 0) {
      if (info === 0x00) {
        return PlistNode.nullValue();
      }
      if (info === 0x08) {
        return PlistNode.boolean(false);
      }
      if (info === 0x09) {
        return PlistNode.boolean(true);
      }
      throw new Error(`Unsupported bplist00 simple marker 0x${marker.toString(16)}`);
    }
    if (type === 1) {
      const size = 1 << info;
      if (cursor + size > objectLimit) {
        throw new Error('Truncated bplist00 integer');
      }
      const value = readSigned(bytes, cursor, size);
      return PlistNode.integer(value);
    }
    if (type === 2) {
      const size = 1 << info;
      if (size !== 4 && size !== 8) {
        throw new Error(`Unsupported bplist00 real width ${size}`);
      }
      if (cursor + size > objectLimit) {
        throw new Error('Truncated bplist00 real');
      }
      const view = new DataView(bytes.buffer, bytes.byteOffset + cursor, size);
      return PlistNode.real(size === 4 ? view.getFloat32(0, false) : view.getFloat64(0, false));
    }
    if (type === 3) {
      if (info !== 3 || cursor + 8 > objectLimit) {
        throw new Error('Invalid bplist00 date');
      }
      const view = new DataView(bytes.buffer, bytes.byteOffset + cursor, 8);
      return PlistNode.real(view.getFloat64(0, false));
    }
    if (type === 4 || type === 5 || type === 6 || type === 7 || type === 8) {
      const lengthInfo = BinaryPlist.decodeLength(bytes, cursor, info, objectLimit);
      cursor = lengthInfo.cursor;
      const length = lengthInfo.length;
      if (type === 8) {
        if (length < 1 || length > 8) {
          throw new Error('Unsupported bplist00 UID width');
        }
        return PlistNode.integer(readUnsigned(bytes, cursor, length));
      }
      const byteLength = type === 6 ? length * 2 : length;
      if (cursor + byteLength > objectLimit) {
        throw new Error('Truncated bplist00 scalar object');
      }
      const value = bytes.slice(cursor, cursor + byteLength);
      if (type === 4) {
        return PlistNode.data(value);
      }
      if (type === 5) {
        return PlistNode.string(util.TextDecoder.create('utf-8').decodeToString(value));
      }
      if (type === 7) {
        return PlistNode.string(util.TextDecoder.create('utf-8').decodeToString(value));
      }
      return PlistNode.string(decodeUtf16Be(value));
    }
    if (type === 0x0a || type === 0x0c || type === 0x0d) {
      const lengthInfo = BinaryPlist.decodeLength(bytes, cursor, info, objectLimit);
      cursor = lengthInfo.cursor;
      const count = lengthInfo.length;
      const referenceCount = type === 0x0d ? count * 2 : count;
      if (cursor + referenceCount * referenceSize > objectLimit) {
        throw new Error('Truncated bplist00 collection');
      }
      if (type === 0x0d) {
        const dictionary = PlistNode.dictionary(new Map<string, PlistNode>());
        cache.set(reference, dictionary);
        const keyRefs: number[] = [];
        const valueRefs: number[] = [];
        for (let index = 0; index < count; index++) {
          keyRefs.push(toSafeNumber(readUnsigned(bytes, cursor + index * referenceSize, referenceSize), 'key reference'));
          valueRefs.push(toSafeNumber(readUnsigned(bytes, cursor + (count + index) * referenceSize, referenceSize), 'value reference'));
        }
        for (let index = 0; index < count; index++) {
          const keyNode = BinaryPlist.decodeObject(bytes, offsets, referenceSize, objectCount, keyRefs[index], objectLimit, cache, depth + 1);
          if (keyNode.kind !== 'string') {
            throw new Error('bplist00 dictionary key is not a string');
          }
          const valueNode = BinaryPlist.decodeObject(bytes, offsets, referenceSize, objectCount, valueRefs[index], objectLimit, cache, depth + 1);
          dictionary.dictionaryValue.set(keyNode.stringValue, valueNode);
        }
        return dictionary;
      }
      const array = PlistNode.array([]);
      cache.set(reference, array);
      for (let index = 0; index < count; index++) {
        const childRef = toSafeNumber(readUnsigned(bytes, cursor + index * referenceSize, referenceSize), 'array reference');
        array.arrayValue.push(BinaryPlist.decodeObject(bytes, offsets, referenceSize, objectCount, childRef, objectLimit, cache, depth + 1));
      }
      return array;
    }
    throw new Error(`Unsupported bplist00 object type ${type}`);
  }

  private static decodeLength(
    bytes: Uint8Array,
    cursor: number,
    info: number,
    objectLimit: number
  ): DecodedLength {
    if (info < 15) {
      const result: DecodedLength = { length: info, cursor };
      return result;
    }
    if (cursor >= objectLimit) {
      throw new Error('Missing bplist00 extended length');
    }
    const marker = bytes[cursor];
    if ((marker >>> 4) !== 1) {
      throw new Error('bplist00 extended length is not an integer');
    }
    const size = 1 << (marker & 0x0f);
    if (cursor + 1 + size > objectLimit) {
      throw new Error('Truncated bplist00 extended length');
    }
    const length = toSafeNumber(readUnsigned(bytes, cursor + 1, size), 'object length');
    const result: DecodedLength = { length, cursor: cursor + 1 + size };
    return result;
  }

  private static encodeObject(value: PlistNode, objects: Uint8Array[]): number {
    const index = objects.length;
    objects.push(new Uint8Array(0));
    if (value.kind === 'dictionary') {
      const keys: string[] = [];
      const values: PlistNode[] = [];
      value.dictionaryValue.forEach((item: PlistNode, key: string): void => {
        keys.push(key);
        values.push(item);
      });
      const keyRefs: number[] = [];
      const valueRefs: number[] = [];
      for (const key of keys) {
        keyRefs.push(BinaryPlist.encodeObject(PlistNode.string(key), objects));
      }
      for (const item of values) {
        valueRefs.push(BinaryPlist.encodeObject(item, objects));
      }
      objects[index] = encodeCollection(0xd0, keyRefs.concat(valueRefs), keys.length);
      return index;
    }
    if (value.kind === 'array') {
      const refs: number[] = [];
      for (const item of value.arrayValue) {
        refs.push(BinaryPlist.encodeObject(item, objects));
      }
      objects[index] = encodeCollection(0xa0, refs, refs.length);
      return index;
    }
    objects[index] = encodeScalar(value);
    return index;
  }
}

function encodeScalar(value: PlistNode): Uint8Array {
  if (value.kind === 'null') {
    return new Uint8Array([0x00]);
  }
  if (value.kind === 'boolean') {
    return new Uint8Array([value.boolValue ? 0x09 : 0x08]);
  }
  if (value.kind === 'integer') {
    return encodeInteger(value.integerValue);
  }
  if (value.kind === 'real') {
    const bytes = new Uint8Array(9);
    bytes[0] = 0x23;
    new DataView(bytes.buffer).setFloat64(1, value.realValue, false);
    return bytes;
  }
  if (value.kind === 'data') {
    return concatBytes(encodeLengthPrefix(0x40, value.dataValue.length), value.dataValue);
  }
  if (value.kind === 'string') {
    const isAscii = isAsciiString(value.stringValue);
    if (isAscii) {
      const data = encodeUtf8(value.stringValue);
      return concatBytes(encodeLengthPrefix(0x50, data.length), data);
    }
    const data = encodeUtf16Be(value.stringValue);
    return concatBytes(encodeLengthPrefix(0x60, value.stringValue.length), data);
  }
  throw new Error(`Unsupported bplist00 scalar kind ${value.kind}`);
}

function encodeCollection(marker: number, refs: number[], count: number): Uint8Array {
  const referenceSize: number = 4;
  const bytes: Uint8Array[] = [encodeLengthPrefix(marker, count)];
  for (const reference of refs) {
    bytes.push(encodeUnsigned(BigInt(reference), referenceSize));
  }
  return concatBytes(...bytes);
}

function encodeInteger(value: bigint): Uint8Array {
  const signed64Max = (BigInt(1) << BigInt(63)) - BigInt(1);
  const signed64Min = -(BigInt(1) << BigInt(63));
  if (value < signed64Min || value > signed64Max) {
    throw new Error('bplist00 integer exceeds the signed 64-bit encoder range');
  }
  let width = 1;
  while (width < 8) {
    const bits = BigInt(width * 8 - 1);
    const min = -(BigInt(1) << bits);
    const max = (BigInt(1) << bits) - BigInt(1);
    if (value >= min && value <= max) {
      break;
    }
    width *= 2;
  }
  const unsigned = value < BigInt(0) ? (BigInt(1) << BigInt(width * 8)) + value : value;
  const header: Uint8Array = new Uint8Array([0x10 | log2(width)]);
  return concatBytes(header, encodeUnsigned(unsigned, width));
}

function encodeLengthPrefix(marker: number, count: number): Uint8Array {
  if (count < 15) {
    return new Uint8Array([marker | count]);
  }
  const lengthInteger = encodeInteger(BigInt(count));
  return concatBytes(new Uint8Array([marker | 0x0f]), lengthInteger);
}

function readUnsigned(bytes: Uint8Array, offset: number, width: number): bigint {
  if (width < 1 || width > 16 || offset < 0 || offset + width > bytes.length) {
    throw new Error('Invalid bplist00 integer range');
  }
  let value = BigInt(0);
  for (let index = 0; index < width; index++) {
    value = (value << BigInt(8)) | BigInt(bytes[offset + index]);
  }
  return value;
}

function readSigned(bytes: Uint8Array, offset: number, width: number): bigint {
  const unsigned = readUnsigned(bytes, offset, width);
  const signBit = BigInt(1) << BigInt(width * 8 - 1);
  return (unsigned & signBit) !== BigInt(0)
    ? unsigned - (BigInt(1) << BigInt(width * 8))
    : unsigned;
}

function toSafeNumber(value: bigint, description: string): number {
  if (value < BigInt(0) || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`bplist00 ${description} is out of range`);
  }
  return Number(value);
}

function widthForUnsigned(value: bigint): number {
  if (value <= BigInt(0xff)) return 1;
  if (value <= BigInt(0xffff)) return 2;
  if (value <= BigInt(0xffffffff)) return 4;
  return 8;
}

function encodeUnsigned(value: bigint, width: number): Uint8Array {
  const bytes = new Uint8Array(width);
  let remaining = value;
  for (let index = width - 1; index >= 0; index--) {
    bytes[index] = Number(remaining & BigInt(0xff));
    remaining >>= BigInt(8);
  }
  return bytes;
}

function writeUnsigned(target: Uint8Array, offset: number, width: number, value: bigint): void {
  target.set(encodeUnsigned(value, width), offset);
}

function log2(width: number): number {
  if (width === 1) return 0;
  if (width === 2) return 1;
  if (width === 4) return 2;
  if (width === 8) return 3;
  throw new Error(`Unsupported bplist00 integer width ${width}`);
}

function isAsciiString(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    if (value.charCodeAt(index) > 0x7f) return false;
  }
  return true;
}

function encodeUtf16Be(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length * 2);
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    bytes[index * 2] = (code >>> 8) & 0xff;
    bytes[index * 2 + 1] = code & 0xff;
  }
  return bytes;
}

function decodeUtf16Be(bytes: Uint8Array): string {
  if (bytes.length % 2 !== 0) {
    throw new Error('Invalid UTF-16BE bplist00 string');
  }
  let value = '';
  for (let index = 0; index < bytes.length; index += 2) {
    value += String.fromCharCode((bytes[index] << 8) | bytes[index + 1]);
  }
  return value;
}
