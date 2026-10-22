import { describe, expect, it } from '@ohos/hypium';
import { access } from '@kit.ConnectivityKit';
import {
  BluetoothSocketApi, HarmonySppServer, PHONE_IAP2_UUID, SppConnection
} from '../main/ets/platform/bluetooth/HarmonySppServer';

type SocketCallback = (error: Error | undefined, socketId: number) => void;

class FakeBluetoothSocketApi implements BluetoothSocketApi {
  listenCallback: SocketCallback | undefined = undefined;
  acceptCallback: SocketCallback | undefined = undefined;
  readCallback: ((data: ArrayBuffer) => void) | undefined = undefined;
  closedClients: number[] = [];
  closeClientCalls: number[] = [];
  closedServers: number[] = [];
  written: Uint8Array[] = [];
  peerId: string = 'test-vehicle';
  isOn: boolean = true;

  state(): number { return this.isOn ? access.BluetoothState.STATE_ON : access.BluetoothState.STATE_OFF; }
  paired(): string[] { return []; }
  name(_deviceId: string): string { return 'test vehicle'; }
  listen(callback: SocketCallback): void { this.listenCallback = callback; }
  accept(_serverId: number, callback: SocketCallback): void { this.acceptCallback = callback; }
  peer(_socketId: number): string { return this.peerId; }
  connected(socketId: number): boolean { return !this.closedClients.includes(socketId); }
  async write(_socketId: number, bytes: ArrayBuffer): Promise<void> {
    this.written.push(new Uint8Array(bytes));
  }
  onRead(_socketId: number, listener: (data: ArrayBuffer) => void): void { this.readCallback = listener; }
  offRead(_socketId: number, _listener: (data: ArrayBuffer) => void): void { this.readCallback = undefined; }
  closeClient(socketId: number): void {
    this.closeClientCalls.push(socketId);
    this.closedClients.push(socketId);
  }
  closeServer(socketId: number): void { this.closedServers.push(socketId); }
}

export default function harmonySppServerTest(): void {
  describe('Harmony vehicle-initiated iAP2 Bluetooth', () => {
    it('starts the secure phone UUID listener and accepts an incoming vehicle connection', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppServer(api);
      const logs: string[] = [];
      let acceptedSocketId: number = -1;
      const started = client.listenForAccessory(
        (connection: SppConnection) => { acceptedSocketId = connection.socketId; },
        () => true,
        (line: string) => { logs.push(line); }
      );
      api.listenCallback?.(undefined, 10);
      await started;
      api.acceptCallback?.(undefined, 20);

      expect(acceptedSocketId).assertEqual(20);
      expect(logs.some((line: string) => line.includes(PHONE_IAP2_UUID))).assertTrue();
      expect(api.closedServers.includes(10)).assertFalse();
      client.stop();
      expect(api.closedServers.includes(10)).assertTrue();
      expect(api.closedClients.includes(20)).assertTrue();
    });

    it('rejects concurrent vehicles and continues accepting after the active client disconnects', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppServer(api);
      const acceptedIds: number[] = [];
      const started = client.listenForAccessory(
        (connection: SppConnection) => { acceptedIds.push(connection.socketId); },
        () => true,
        () => {}
      );
      api.listenCallback?.(undefined, 11);
      await started;
      api.acceptCallback?.(undefined, 21);
      const acceptNext = api.acceptCallback;
      acceptNext?.(undefined, 22);
      expect(acceptedIds.length).assertEqual(1);
      expect(api.closedClients.includes(22)).assertTrue();

      api.closeClient(21);
      api.acceptCallback?.(undefined, 23);
      expect(acceptedIds.length).assertEqual(2);
      expect(acceptedIds[1]).assertEqual(23);
      expect(api.closeClientCalls.filter((socketId: number) => socketId === 21).length).assertEqual(1);
      client.stop();
    });

    it('closes an incoming socket delivered after listener cancellation', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppServer(api);
      const started = client.listenForAccessory(() => {}, () => true, () => {});
      api.listenCallback?.(undefined, 12);
      await started;
      const lateAccept = api.acceptCallback;
      client.stop();
      lateAccept?.(undefined, 24);
      expect(api.closedServers.includes(12)).assertTrue();
      expect(api.closedClients.includes(24)).assertTrue();
    });

    it('surfaces native service-listen errors', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppServer(api);
      const started = client.listenForAccessory(() => {}, () => true, () => {});
      api.listenCallback?.(new Error('service unavailable'), -1);
      let message = '';
      try {
        await started;
      } catch (error) {
        message = error instanceof Error ? error.message : String(error);
      }
      expect(message).assertContain('service unavailable');
    });
  });
}
