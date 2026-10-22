import { describe, expect, it } from '@ohos/hypium';
import { access } from '@kit.ConnectivityKit';
import { Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BluetoothIdentityError, HarmonyBluetoothIdentityProvider, SystemBluetoothAccess
} from '../main/ets/platform/bluetooth/HarmonyBluetoothIdentityProvider';
import { Iap2SenderSession } from '../main/ets/protocol/iap2/Iap2SenderSession';
import { Iap2Csm, Iap2CsmParser } from '../main/ets/protocol/iap2/Iap2Csm';
import {
  DeterministicMfiVerifier, authenticateTestAccessory, deterministicTestRandomBytes
} from './Iap2MfiTestSupport';

class FakeNativeBluetoothError extends Error {
  readonly code: number;
  constructor(failure: BusinessError) {
    super(failure.message);
    this.code = failure.code;
  }
}

class MissingSystemBluetoothAccess implements SystemBluetoothAccess {
  getState(): access.BluetoothState { return access.BluetoothState.STATE_ON; }
}

class FakeSystemBluetoothAccess implements SystemBluetoothAccess {
  address: string = '10:20:30:aa:bb:cc';
  reads: number = 0;
  enabled: boolean = true;
  failure: BusinessError | undefined = undefined;
  getState(): access.BluetoothState {
    return this.enabled ? access.BluetoothState.STATE_ON : access.BluetoothState.STATE_OFF;
  }
  getLocalAddress(): string {
    this.reads++;
    if (this.failure !== undefined) {
      throw new FakeNativeBluetoothError(this.failure);
    }
    return this.address;
  }
}

async function failureKind(provider: HarmonyBluetoothIdentityProvider): Promise<string> {
  try {
    await provider.getStableBluetoothAddress();
    return 'unexpected-success';
  } catch (error) {
    if (error instanceof BluetoothIdentityError) {
      return error.kind;
    }
    throw new Error(`Unexpected identity failure: ${error.message}`);
  }
}

export default function harmonyBluetoothIdentityTest(): void {
  describe('System Bluetooth identity', () => {
    it('reads and normalizes the real local address only after both permissions pass', 0, async () => {
      const api = new FakeSystemBluetoothAccess();
      const provider = new HarmonyBluetoothIdentityProvider(0, api, () => true);
      expect(await provider.getStableBluetoothAddress()).assertEqual('10:20:30:AA:BB:CC');
      expect(api.reads).assertEqual(1);
    });

    it('never calls the system API when the local MAC permission is denied', 0, async () => {
      const api = new FakeSystemBluetoothAccess();
      const provider = new HarmonyBluetoothIdentityProvider(0, api, (permission: Permissions) =>
        permission === 'ohos.permission.ACCESS_BLUETOOTH');
      expect(await failureKind(provider)).assertEqual('permission-denied');
      expect(api.reads).assertEqual(0);
    });

    it('does not mistake Bluetooth permission alone for system authorization', 0, async () => {
      const api = new FakeSystemBluetoothAccess();
      const provider = new HarmonyBluetoothIdentityProvider(0, api, () => false);
      expect(await failureKind(provider)).assertEqual('permission-denied');
      expect(api.reads).assertEqual(0);
    });

    it('reports when a granted device does not expose the system API', 0, async () => {
      const api = new MissingSystemBluetoothAccess();
      expect(await failureKind(new HarmonyBluetoothIdentityProvider(0, api, () => true)))
        .assertEqual('api-unavailable');
    });

    it('preserves non-system-app native error 202 without falling back to a fake MAC', 0, async () => {
      const api = new FakeSystemBluetoothAccess();
      api.failure = { name: 'BusinessError', code: 202, message: 'Non-system applications are not allowed' };
      const provider = new HarmonyBluetoothIdentityProvider(0, api, () => true);
      let code: number | undefined = undefined;
      try {
        await provider.getStableBluetoothAddress();
      } catch (error) {
        if (error instanceof BluetoothIdentityError) {
          code = error.code;
        }
      }
      expect(code).assertEqual(202);
      expect(await failureKind(provider)).assertEqual('system-api-failed');
    });

    it('rejects Bluetooth-off and malformed or placeholder addresses', 0, async () => {
      const api = new FakeSystemBluetoothAccess();
      const provider = new HarmonyBluetoothIdentityProvider(0, api, () => true);
      api.enabled = false;
      expect(await failureKind(provider)).assertEqual('bluetooth-off');
      expect(api.reads).assertEqual(0);
      api.enabled = true;
      for (const value of ['02:00:00:00:00:00', '00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff', '', '192.168.1.1']) {
        api.address = value;
        expect(await failureKind(provider)).assertEqual('invalid-address');
      }
    });

    it('detects an identity change rather than silently mixing session identities', 0, async () => {
      const api = new FakeSystemBluetoothAccess();
      const provider = new HarmonyBluetoothIdentityProvider(0, api, () => true);
      await provider.getStableBluetoothAddress();
      api.address = '10:20:30:AA:BB:CD';
      expect(await failureKind(provider)).assertEqual('identity-changed');
    });

    it('uses the verified local identity in availability and transport confirmation after MFi authentication', 0,
      async () => {
      const sent: Uint8Array[] = [];
      const session = new Iap2SenderSession((bytes: Uint8Array) => { sent.push(bytes); },
        () => {}, () => {}, undefined, undefined, '10:20:30:AA:BB:CC',
        undefined, undefined, new DeterministicMfiVerifier(), undefined, undefined, deterministicTestRandomBytes);
      const capabilities = new Uint8Array([...Iap2Csm.param(6, new Uint8Array([0x43, 0x01])),
        ...Iap2Csm.param(7, new Uint8Array([0x43, 0x00, 0x4E, 0x0E]))]);
      session.receive(Iap2Csm.encode(0x1D01, capabilities));
      await session.whenIdle();
      await authenticateTestAccessory(session, sent);
      const availability = sent.map((bytes: Uint8Array) => new Iap2CsmParser().offer(bytes)[0])
        .find((frame) => frame.messageId === 0x4300);
      expect(availability !== undefined).assertTrue();
      if (availability === undefined) {
        throw new Error('Missing availability frame.');
      }
      const group = Iap2Csm.parseParams(availability.body)[0];
      const wireless = Iap2Csm.parseParams(group.value);
      expect(group.id).assertEqual(1);
      expect(wireless[0].value[0]).assertEqual(1);
      expect(Iap2Csm.asString(wireless[1])).assertEqual('10:20:30:AA:BB:CC');
      session.receive(Iap2Csm.encode(0x4301, Iap2Csm.u16(2, 7000)));
      await session.whenIdle();
      const transport = sent.map((bytes: Uint8Array) => new Iap2CsmParser().offer(bytes)[0])
        .find((frame) => frame.messageId === 0x4E0E);
      expect(transport !== undefined).assertTrue();
      if (transport !== undefined) {
        expect(Iap2Csm.asString(Iap2Csm.parseParams(transport.body)[0])).assertEqual('10:20:30:AA:BB:CC');
      }
      session.close();
    });
  });
}
