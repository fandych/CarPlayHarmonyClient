export interface Tlv8Item {
  type: number;
  value: Uint8Array;
}

export class Tlv8 {
  static readonly TYPE_METHOD: number = 0x00;
  static readonly TYPE_IDENTIFIER: number = 0x01;
  static readonly TYPE_SALT: number = 0x02;
  static readonly TYPE_PUBLIC_KEY: number = 0x03;
  static readonly TYPE_PROOF: number = 0x04;
  static readonly TYPE_ENCRYPTED_DATA: number = 0x05;
  static readonly TYPE_STATE: number = 0x06;
  static readonly TYPE_ERROR: number = 0x07;
  static readonly TYPE_SIGNATURE: number = 0x0A;

  private static readonly SEPARATOR_TYPE: number = 0xFF;
  private static readonly MAX_FRAGMENT_LENGTH: number = 0xFF;

  static encode(items: Tlv8Item[]): Uint8Array {
    const output: number[] = [];
    let previousType: number | undefined = undefined;
    for (const item of items) {
      if (!Number.isInteger(item.type) || item.type < 0 || item.type > 0xFF) {
        throw new Error('TLV8 type must be an unsigned byte.');
      }
      if (previousType === item.type) {
        output.push(Tlv8.SEPARATOR_TYPE, 0);
      }
      let offset = 0;
      do {
        const length = Math.min(Tlv8.MAX_FRAGMENT_LENGTH, item.value.length - offset);
        output.push(item.type, length);
        for (let index = 0; index < length; index++) {
          output.push(item.value[offset + index]);
        }
        offset += length;
      } while (offset < item.value.length);
      previousType = item.type;
    }
    return new Uint8Array(output);
  }

  static decode(buffer: Uint8Array): Map<number, Uint8Array> {
    const output: Map<number, Uint8Array> = new Map<number, Uint8Array>();
    let position = 0;
    let lastType: number | undefined = undefined;
    let lastLength = 0;
    while (position < buffer.length) {
      if (position + 2 > buffer.length) {
        throw new Error('Truncated TLV8 header.');
      }
      const type = buffer[position];
      const length = buffer[position + 1];
      position += 2;
      if (position + length > buffer.length) {
        throw new Error('Truncated TLV8 value.');
      }
      const value = buffer.slice(position, position + length);
      position += length;
      const previousValue = output.get(type);
      if (type === lastType && lastLength === Tlv8.MAX_FRAGMENT_LENGTH && previousValue !== undefined) {
        output.set(type, Tlv8.concat(previousValue, value));
      } else {
        output.set(type, value);
      }
      lastType = type;
      lastLength = length;
    }
    return output;
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const result = new Uint8Array(left.length + right.length);
    result.set(left);
    result.set(right, left.length);
    return result;
  }
}
