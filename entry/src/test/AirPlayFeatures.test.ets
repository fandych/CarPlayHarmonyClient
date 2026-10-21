import { describe, it, expect } from '@ohos/hypium';
import { AirPlayFeatures } from '../main/ets/protocol/airplay/AirPlayFeatures';

function asciiBytes(text: string): number[] {
  const bytes: number[] = [];
  for (let index = 0; index < text.length; index++) {
    bytes.push(text.charCodeAt(index));
  }
  return bytes;
}

export default function airPlayFeaturesTest(): void {
  describe('AirPlay mDNS feature parsing', () => {
    it('detects HomeKit pairing from a two-part feature bitmap', 0, () => {
      const text = AirPlayFeatures.readFeatureText([
        { key: 'features', value: asciiBytes('0x5653aee2,0x61') }
      ]);
      expect(text).assertEqual('0x5653aee2,0x61');
      expect(AirPlayFeatures.supportsHomeKitPairing(text)).assertTrue();
    });

    it('keeps pre-HomeKit receivers classified as not supporting pairing', 0, () => {
      expect(AirPlayFeatures.supportsHomeKitPairing('0x00000080,0x0')).assertFalse();
    });

    it('treats missing, malformed, or ambiguous TXT values as unknown', 0, () => {
      expect(AirPlayFeatures.readFeatureText(undefined) === undefined).assertTrue();
      expect(AirPlayFeatures.readFeatureText([
        { key: 'features', value: asciiBytes('0x80') },
        { key: 'FEATURES', value: asciiBytes('0x80') }
      ]) === undefined).assertTrue();
      expect(AirPlayFeatures.supportsHomeKitPairing('0x100000000,0x1') === undefined).assertTrue();
      expect(AirPlayFeatures.supportsHomeKitPairing('not-hex') === undefined).assertTrue();
      expect(AirPlayFeatures.supportsHomeKitPairing(undefined) === undefined).assertTrue();
    });

    it('rejects non-ASCII or oversized feature TXT data', 0, () => {
      expect(AirPlayFeatures.readFeatureText([
        { key: 'features', value: [0xFF] }
      ]) === undefined).assertTrue();
      expect(AirPlayFeatures.readFeatureText([
        { key: 'features', value: new Array<number>(65).fill(0x30) }
      ]) === undefined).assertTrue();
    });
  });
}
