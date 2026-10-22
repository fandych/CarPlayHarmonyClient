import { inputEventClient, KeyCode } from '@kit.InputKit';

export interface KeyboardControllerPort {
  pressKey(keyCode: KeyCode): Promise<void>;
  releaseKey(keyCode: KeyCode): Promise<void>;
}

export class HarmonyMediaKeyInputController {
  private readonly controllerFactory: () => Promise<KeyboardControllerPort>;
  private controller: KeyboardControllerPort | undefined = undefined;
  private readonly pressedKeys: Set<KeyCode> = new Set<KeyCode>();
  private operations: Promise<void> = Promise.resolve();

  constructor(
    controllerFactory: () => Promise<KeyboardControllerPort> =
      () => inputEventClient.createKeyboardController()
  ) {
    this.controllerFactory = controllerFactory;
  }

  dispatchUsage(usage: number): Promise<boolean> {
    const keyCode = HarmonyMediaKeyInputController.keyCodeForUsage(usage);
    if (keyCode === undefined) {
      return Promise.resolve(false);
    }
    return this.enqueue(async (): Promise<boolean> => {
      const controller = await this.getController();
      await controller.pressKey(keyCode);
      this.pressedKeys.add(keyCode);
      await controller.releaseKey(keyCode);
      this.pressedKeys.delete(keyCode);
      return true;
    });
  }

  releaseAll(): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (this.pressedKeys.size === 0) {
        return;
      }
      const controller = await this.getController();
      const keys: KeyCode[] = [];
      this.pressedKeys.forEach((keyCode: KeyCode) => keys.push(keyCode));
      const failures: string[] = [];
      for (const keyCode of keys) {
        try {
          await controller.releaseKey(keyCode);
          this.pressedKeys.delete(keyCode);
        } catch (error) {
          failures.push(error instanceof Error ? error.message : String(error));
        }
      }
      if (failures.length > 0) {
        throw new Error(`Unable to release ${failures.length} media key(s): ${failures.join('; ')}`);
      }
    });
  }

  private getController(): Promise<KeyboardControllerPort> {
    if (this.controller !== undefined) {
      return Promise.resolve(this.controller);
    }
    return this.controllerFactory().then((controller: KeyboardControllerPort) => {
      this.controller = controller;
      return controller;
    });
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.operations.then(operation);
    this.operations = result.then(() => {}, () => {});
    return result;
  }

  private static keyCodeForUsage(usage: number): KeyCode | undefined {
    switch (usage) {
      case 0xB0:
        return KeyCode.KEYCODE_MEDIA_PLAY;
      case 0xB1:
        return KeyCode.KEYCODE_MEDIA_PAUSE;
      case 0xB3:
        return KeyCode.KEYCODE_MEDIA_FAST_FORWARD;
      case 0xB4:
        return KeyCode.KEYCODE_MEDIA_REWIND;
      case 0xB5:
        return KeyCode.KEYCODE_MEDIA_NEXT;
      case 0xB6:
        return KeyCode.KEYCODE_MEDIA_PREVIOUS;
      case 0xB9:
        return KeyCode.KEYCODE_MEDIA_STOP;
      default:
        return undefined;
    }
  }
}
