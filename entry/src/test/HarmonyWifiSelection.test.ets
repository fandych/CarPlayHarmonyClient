import { describe, expect, it } from '@ohos/hypium';
import { selectSingleWlanNetwork } from '../main/ets/platform/network/HarmonyWifiClient';

interface TestNetwork {
  netId: number;
}

export default function harmonyWifiSelectionTest(): void {
  describe('CarPlay WLAN selection', () => {
    it('requires one verified WLAN instead of falling back to the default network', 0, () => {
      let missing = false;
      try {
        selectSingleWlanNetwork<TestNetwork>([]);
      } catch (error) {
        missing = error.message.includes('WLAN count=0');
      }
      expect(missing).assertTrue();
    });

    it('rejects ambiguous multiple WLAN handles', 0, () => {
      const first: TestNetwork = { netId: 1 };
      const second: TestNetwork = { netId: 2 };
      let ambiguous = false;
      try {
        selectSingleWlanNetwork([first, second]);
      } catch (error) {
        ambiguous = error.message.includes('WLAN count=2');
      }
      expect(ambiguous).assertTrue();
    });

    it('keeps the verified WLAN handle identity', 0, () => {
      const wifi: TestNetwork = { netId: 15 };
      expect(selectSingleWlanNetwork([wifi]) === wifi).assertTrue();
    });
  });
}
