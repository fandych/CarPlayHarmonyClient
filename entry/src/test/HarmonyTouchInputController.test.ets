import { describe, it, expect } from '@ohos/hypium';
import {
  HarmonyTouchInputController,
  InjectedTouchPoint,
  TouchControllerPort
} from '../main/ets/platform/input/HarmonyTouchInputController';

class FakeTouchController implements TouchControllerPort {
  readonly events: string[] = [];

  async touchDown(point: InjectedTouchPoint): Promise<void> {
    this.events.push(`down:${point.id}:${point.displayId}:${point.displayX}:${point.displayY}`);
  }

  async touchMove(point: InjectedTouchPoint): Promise<void> {
    this.events.push(`move:${point.id}:${point.displayId}:${point.displayX}:${point.displayY}`);
  }

  async touchUp(point: InjectedTouchPoint): Promise<void> {
    this.events.push(`up:${point.id}:${point.displayId}:${point.displayX}:${point.displayY}`);
  }
}

export default function harmonyTouchInputControllerTest(): void {
  describe('HarmonyOS touch input state machine', () => {
    it('scales coordinates and pairs down, move, and up on one display', 0, async () => {
      const controller = new FakeTouchController();
      const input = new HarmonyTouchInputController(async () => controller);
      await input.applyContacts(7, 1280, 720, 1412, 654, [
        { slot: 0, x: 0, y: 0, down: true }
      ]);
      await input.applyContacts(7, 1280, 720, 1412, 654, [
        { slot: 0, x: 1411, y: 653, down: true }
      ]);
      await input.applyContacts(7, 1280, 720, 1412, 654, [
        { slot: 0, x: 706, y: 327, down: false }
      ]);
      expect(controller.events.join('|')).assertEqual(
        'down:0:7:0:0|move:0:7:1279:719|up:0:7:640:360'
      );
    });

    it('releases active contacts during teardown', 0, async () => {
      const controller = new FakeTouchController();
      const input = new HarmonyTouchInputController(async () => controller);
      await input.applyContacts(3, 640, 360, 640, 360, [
        { slot: 1, x: 24, y: 50, down: true }
      ]);
      await input.releaseAll();
      await input.releaseAll();
      expect(controller.events.join('|')).assertEqual('down:1:3:24:50|up:1:3:24:50');
    });

    it('surfaces missing system touch capability', 0, async () => {
      const input = new HarmonyTouchInputController(async () => {
        throw new Error('CONTROL_DEVICE permission denied');
      });
      let detail = '';
      try {
        await input.applyContacts(1, 10, 10, 10, 10, [
          { slot: 0, x: 1, y: 1, down: true }
        ]);
      } catch (error) {
        detail = error instanceof Error ? error.message : String(error);
      }
      expect(detail).assertEqual('CONTROL_DEVICE permission denied');
    });
  });
}
