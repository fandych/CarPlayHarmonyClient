import { describe, it, expect } from '@ohos/hypium';
import { KeyCode } from '@kit.InputKit';
import {
  HarmonyMediaKeyInputController,
  KeyboardControllerPort
} from '../main/ets/platform/input/HarmonyMediaKeyInputController';

class FakeKeyboardController implements KeyboardControllerPort {
  readonly events: string[] = [];

  async pressKey(keyCode: KeyCode): Promise<void> {
    this.events.push(`down:${keyCode}`);
  }

  async releaseKey(keyCode: KeyCode): Promise<void> {
    this.events.push(`up:${keyCode}`);
  }
}

export default function harmonyMediaKeyInputControllerTest(): void {
  describe('HarmonyOS media key injection', () => {
    it('pairs supported consumer usages with key release', 0, async () => {
      const controller = new FakeKeyboardController();
      const input = new HarmonyMediaKeyInputController(async () => controller);
      const dispatched = await input.dispatchUsage(0xB5);
      const ignored = await input.dispatchUsage(0xBC);
      expect(dispatched).assertTrue();
      expect(ignored).assertFalse();
      expect(controller.events.join('|')).assertEqual('down:12|up:12');
    });

    it('surfaces unavailable system keyboard permission', 0, async () => {
      const input = new HarmonyMediaKeyInputController(async () => {
        throw new Error('CONTROL_DEVICE permission denied');
      });
      let detail = '';
      try {
        await input.dispatchUsage(0xB0);
      } catch (error) {
        detail = error instanceof Error ? error.message : String(error);
      }
      expect(detail).assertEqual('CONTROL_DEVICE permission denied');
    });
  });
}
