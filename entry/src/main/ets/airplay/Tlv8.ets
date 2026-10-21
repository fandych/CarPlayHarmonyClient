import { concatBytes } from '../protocol/Iap2Codec';

export interface Tlv8Item {
  type: number;
  value: Uint8Array;
}

const SEPARATOR_TYPE: number = 0xff;
const MAX_FRAGMENT: number = 255;

export function encodeTlv8(items: Tlv8Item[]): Uint8Array {
  const fragments: Uint8Array[] = [];
  let previousType: number = -1;
  for (const item of items) {
    if (item.type < 0 || item.type >= SEPARATOR_TYPE) {
      throw new Error(`Invalid TLV8 type ${item.type}`);
    }
    if (item.type === previousType) {
      fragments.push(new Uint8Array([SEPARATOR_TYPE, 0]));
    }
    let offset = 0;
    if (item.value.length === 0) {
      fragments.push(new Uint8Array([item.type, 0]));
    } else {
      while (offset < item.value.length) {
        const length = Math.min(MAX_FRAGMENT, item.value.length - offset);
        fragments.push(new Uint8Array([item.type, length]));
        fragments.push(item.value.slice(offset, offset + length));
        offset += length;
      }
    }
    previousType = item.type;
  }
  return concatBytes(...fragments);
}

export function decodeTlv8(bytes: Uint8Array): Map<number, Uint8Array> {
  const values: Map<number, Uint8Array> = new Map<number, Uint8Array>();
  let offset = 0;
  let previousType: number = -1;
  let previousLength: number = 0;
  let separatorSeen: boolean = false;

  while (offset < bytes.length) {
    if (offset + 2 > bytes.length) {
      throw new Error('Truncated TLV8 header');
    }
    const type = bytes[offset];
    const length = bytes[offset + 1];
    offset += 2;
    if (offset + length > bytes.length) {
      throw new Error('Truncated TLV8 value');
    }
    const value = bytes.slice(offset, offset + length);
    offset += length;

    if (type === SEPARATOR_TYPE) {
      if (length !== 0) {
        throw new Error('Invalid TLV8 separator length');
      }
      separatorSeen = true;
      previousType = -1;
      previousLength = 0;
      continue;
    }
    if (previousType === type && previousLength === MAX_FRAGMENT && !separatorSeen) {
      const prior = values.get(type) ?? new Uint8Array(0);
      values.set(type, concatBytes(prior, value));
    } else {
      values.set(type, value);
    }
    previousType = type;
    previousLength = length;
    separatorSeen = false;
  }
  return values;
}

export interface Tlv8TypeIds {
  METHOD: number;
  IDENTIFIER: number;
  SALT: number;
  PUBLIC_KEY: number;
  PROOF: number;
  ENCRYPTED_DATA: number;
  STATE: number;
  ERROR: number;
  SIGNATURE: number;
}

export const Tlv8Type: Tlv8TypeIds = {
  METHOD: 0x00,
  IDENTIFIER: 0x01,
  SALT: 0x02,
  PUBLIC_KEY: 0x03,
  PROOF: 0x04,
  ENCRYPTED_DATA: 0x05,
  STATE: 0x06,
  ERROR: 0x07,
  SIGNATURE: 0x0a
};
