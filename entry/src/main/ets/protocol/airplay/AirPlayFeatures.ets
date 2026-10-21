export interface AirPlayFeatureBitmap {
  low: number;
  high: number;
}

export interface AirPlayTxtAttribute {
  key: string;
  value: number[];
}

export class AirPlayFeatures {
  static readFeatureText(attributes: AirPlayTxtAttribute[] | undefined): string | undefined {
    if (attributes === undefined) {
      return undefined;
    }
    const matches = attributes.filter((attribute: AirPlayTxtAttribute) =>
      attribute.key.toLowerCase() === 'features');
    if (matches.length !== 1 || matches[0].value.length > 64) {
      return undefined;
    }

    let text = '';
    for (const byte of matches[0].value) {
      if (!Number.isInteger(byte) || byte < 0 || byte > 0x7F) {
        return undefined;
      }
      text += String.fromCharCode(byte);
    }
    return text;
  }

  static parse(text: string | undefined): AirPlayFeatureBitmap | undefined {
    if (text === undefined) {
      return undefined;
    }
    const parts = text.trim().split(',').map((part: string) => part.trim());
    if (parts.length < 1 || parts.length > 2 || parts.some((part: string) => part.length === 0)) {
      return undefined;
    }
    const low = AirPlayFeatures.parseHex(parts[0]);
    const high = parts.length === 2 ? AirPlayFeatures.parseHex(parts[1]) : 0;
    if (low === undefined || high === undefined) {
      return undefined;
    }
    return { low, high };
  }

  static supportsHomeKitPairing(text: string | undefined): boolean | undefined {
    const bitmap = AirPlayFeatures.parse(text);
    if (bitmap === undefined) {
      return undefined;
    }
    return ((bitmap.high >>> 6) & 1) !== 0;
  }

  private static parseHex(value: string): number | undefined {
    const cleaned = value.replace(/^0x/i, '');
    if (!/^[0-9a-fA-F]{1,8}$/.test(cleaned)) {
      return undefined;
    }
    return Number.parseInt(cleaned, 16);
  }
}
