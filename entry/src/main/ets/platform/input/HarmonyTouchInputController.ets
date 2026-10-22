import { inputEventClient } from '@kit.InputKit';
import { AirPlayHidContact } from '../../protocol/airplay/AirPlayEventProtocol';

export interface InjectedTouchPoint {
  id: number;
  displayId: number;
  displayX: number;
  displayY: number;
}

export interface TouchControllerPort {
  touchDown(point: InjectedTouchPoint): Promise<void>;
  touchMove(point: InjectedTouchPoint): Promise<void>;
  touchUp(point: InjectedTouchPoint): Promise<void>;
}

interface ActiveTouch {
  displayId: number;
  point: InjectedTouchPoint;
}

export class HarmonyTouchInputController {
  private readonly controllerFactory: () => Promise<TouchControllerPort>;
  private controller: TouchControllerPort | undefined = undefined;
  private readonly activeTouches: Map<number, ActiveTouch> = new Map<number, ActiveTouch>();
  private operations: Promise<void> = Promise.resolve();

  constructor(
    controllerFactory: () => Promise<TouchControllerPort> =
      () => inputEventClient.createTouchController()
  ) {
    this.controllerFactory = controllerFactory;
  }

  applyContacts(
    displayId: number,
    displayWidth: number,
    displayHeight: number,
    sourceWidth: number,
    sourceHeight: number,
    contacts: AirPlayHidContact[]
  ): Promise<void> {
    HarmonyTouchInputController.requireDimension(displayWidth, 'target display width');
    HarmonyTouchInputController.requireDimension(displayHeight, 'target display height');
    HarmonyTouchInputController.requireDimension(sourceWidth, 'receiver display width');
    HarmonyTouchInputController.requireDimension(sourceHeight, 'receiver display height');
    if (!Number.isInteger(displayId) || displayId < 0) {
      return Promise.reject(new Error('Touch input requires a valid target display ID.'));
    }
    return this.enqueue(async (): Promise<void> => {
      const controller = await this.getController();
      for (const contact of contacts) {
        if (!Number.isInteger(contact.slot) || contact.slot < 0 || contact.slot > 9 ||
          !Number.isInteger(contact.x) || !Number.isInteger(contact.y) ||
          contact.x < 0 || contact.y < 0) {
          throw new Error('AirPlay touch report contains an invalid contact.');
        }
        const point: InjectedTouchPoint = {
          id: contact.slot,
          displayId,
          displayX: HarmonyTouchInputController.scale(contact.x, sourceWidth, displayWidth),
          displayY: HarmonyTouchInputController.scale(contact.y, sourceHeight, displayHeight)
        };
        const active = this.activeTouches.get(contact.slot);
        if (active !== undefined && active.displayId !== displayId) {
          throw new Error('An active touch cannot be moved between displays.');
        }
        if (contact.down) {
          if (active === undefined) {
            await controller.touchDown(point);
          } else {
            await controller.touchMove(point);
          }
          this.activeTouches.set(contact.slot, { displayId, point });
        } else if (active !== undefined) {
          await controller.touchUp(point);
          this.activeTouches.delete(contact.slot);
        }
      }
    });
  }

  releaseAll(): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (this.activeTouches.size === 0) {
        return;
      }
      const controller = await this.getController();
      const failures: string[] = [];
      const ids: number[] = [];
      this.activeTouches.forEach((_active: ActiveTouch, id: number) => ids.push(id));
      for (const id of ids) {
        const active = this.activeTouches.get(id);
        if (active === undefined) {
          continue;
        }
        try {
          await controller.touchUp(active.point);
          this.activeTouches.delete(id);
        } catch (error) {
          failures.push(error instanceof Error ? error.message : String(error));
        }
      }
      if (failures.length > 0) {
        throw new Error(`Unable to release ${failures.length} active touch point(s): ${failures.join('; ')}`);
      }
    });
  }

  private getController(): Promise<TouchControllerPort> {
    if (this.controller !== undefined) {
      return Promise.resolve(this.controller);
    }
    return this.controllerFactory().then((controller: TouchControllerPort) => {
      this.controller = controller;
      return controller;
    });
  }

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const result = this.operations.then(operation);
    this.operations = result.then(() => {}, () => {});
    return result;
  }

  private static scale(value: number, sourceSize: number, targetSize: number): number {
    if (sourceSize === 1 || targetSize === 1) {
      return 0;
    }
    const bounded = Math.min(value, sourceSize - 1);
    return Math.round(bounded * (targetSize - 1) / (sourceSize - 1));
  }

  private static requireDimension(value: number, label: string): void {
    if (!Number.isInteger(value) || value < 1) {
      throw new Error(`Touch input requires a valid ${label}.`);
    }
  }
}
