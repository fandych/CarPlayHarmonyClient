import { describe, expect, it } from '@ohos/hypium';
import { access, connection } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BluetoothSocketApi, HarmonySppClient, PairedAccessory
} from '../main/ets/platform/bluetooth/HarmonySppClient';

type SocketCallback = (error: Error | undefined, socketId: number) => void;
const TARGET: PairedAccessory = { deviceId: 'selected-test-receiver', name: 'test receiver' };

class FakeBluetoothSocketApi implements BluetoothSocketApi {
  listenCallback: SocketCallback | undefined = undefined;
  acceptCallback: SocketCallback | undefined = undefined;
  connectCallback: SocketCallback | undefined = undefined;
  readCallback: ((data: ArrayBuffer) => void) | undefined = undefined;
  closedClients: number[] = [];
  closedServers: number[] = [];
  written: Uint8Array[] = [];
  peerId: string = TARGET.deviceId;
  isOn: boolean = true;
  isPaired: boolean = true;
  connectCount: number = 0;
  state(): number { return this.isOn ? access.BluetoothState.STATE_ON : access.BluetoothState.STATE_OFF; }
  paired(): string[] { return this.isPaired ? [TARGET.deviceId] : []; }
  name(deviceId: string): string { return TARGET.name; }
  bond(deviceId: string): number { return connection.BondState.BOND_STATE_BONDED; }
  async uuids(deviceId: string): Promise<string[]> { return []; }
  listen(callback: SocketCallback): void { this.listenCallback = callback; }
  accept(serverId: number, callback: SocketCallback): void { this.acceptCallback = callback; }
  connect(deviceId: string, callback: SocketCallback): void { this.connectCallback = callback; this.connectCount++; }
  peer(socketId: number): string { return this.peerId; }
  connected(socketId: number): boolean { return !this.closedClients.includes(socketId); }
  async write(socketId: number, bytes: ArrayBuffer): Promise<void> { this.written.push(new Uint8Array(bytes)); }
  onRead(socketId: number, listener: (data: ArrayBuffer) => void): void { this.readCallback = listener; }
  offRead(socketId: number, listener: (data: ArrayBuffer) => void): void { this.readCallback = undefined; }
  closeClient(socketId: number): void { this.closedClients.push(socketId); }
  closeServer(socketId: number): void { this.closedServers.push(socketId); }
}

export default function harmonySppClientTest(): void {
  describe('Harmony bidirectional iAP2 Bluetooth', () => {
    it('accepts the selected receiver inbound and closes a late outbound winner', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      api.listenCallback?.(undefined, 10);
      api.acceptCallback?.(undefined, 20);
      const active = await task;
      try {
        api.connectCallback?.(undefined, 21);
        expect(active.socketId).assertEqual(20);
        expect(api.closedServers.includes(10)).assertTrue();
        expect(api.closedClients.includes(21)).assertTrue();
      } finally {
        active.close();
      }
    });

    it('accepts outbound and closes late listener and inbound sockets', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      api.connectCallback?.(undefined, 30);
      const active = await task;
      try {
        api.listenCallback?.(undefined, 11);
        expect(api.closedServers.includes(11)).assertTrue();
        expect(active.socketId).assertEqual(30);
      } finally {
        active.close();
      }
    });

    it('rejects non-target inbound and continues accepting the selected receiver', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      api.listenCallback?.(undefined, 10);
      api.peerId = 'different-receiver';
      api.acceptCallback?.(undefined, 40);
      expect(api.closedClients.includes(40)).assertTrue();
      api.peerId = TARGET.deviceId;
      api.acceptCallback?.(undefined, 41);
      const active = await task;
      expect(active.socketId).assertEqual(41);
      active.close();
    });

    it('keeps listening after outbound fails and preserves its system error code', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const logs: string[] = [];
      const task = client.connectToAccessory(TARGET, () => true, (line: string) => { logs.push(line); });
      const failure: BusinessError = { name: 'BusinessError', code: 2900099, message: 'Operation failed' };
      api.listenCallback?.(undefined, 10);
      api.connectCallback?.(failure, -1);
      api.acceptCallback?.(undefined, 50);
      const active = await task;
      expect(logs.some((line: string) => line.includes('2900099'))).assertTrue();
      expect(active.socketId).assertEqual(50);
      active.close();
    });

    it('rejects when both directions fail without replacing the native reason', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      api.listenCallback?.(new Error('listen unsupported'), -1);
      const failure: BusinessError = { name: 'BusinessError', code: 2900004, message: 'Profile not supported' };
      api.connectCallback?.(failure, -1);
      let message = '';
      try {
        await task;
      } catch (error) {
        message = error.message;
      }
      expect(message).assertContain('2900004');
      expect(message).assertContain('Profile not supported');
    });

    it('closes native results delivered after cancellation', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      client.stop();
      let cancelled = false;
      try {
        await task;
      } catch (error) {
        cancelled = error.message.includes('取消');
      }
      api.listenCallback?.(undefined, 60);
      api.connectCallback?.(undefined, 61);
      expect(cancelled).assertTrue();
      expect(api.closedServers.includes(60)).assertTrue();
      expect(api.closedClients.includes(61)).assertTrue();
    });

    it('does not launch a second native connect while a cancelled call is pending', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const first = client.connectToAccessory(TARGET, () => true, () => {});
      const oldConnect = api.connectCallback;
      client.stop();
      let cancelled = false;
      try {
        await first;
      } catch (error) {
        cancelled = error.message.includes('取消');
      }
      const second = client.connectToAccessory(TARGET, () => true, () => {});
      api.listenCallback?.(undefined, 70);
      api.acceptCallback?.(undefined, 71);
      const active = await second;
      try {
        oldConnect?.(undefined, 72);
        expect(cancelled).assertTrue();
        expect(api.connectCount).assertEqual(1);
        expect(api.closedClients.includes(72)).assertTrue();
      } finally {
        active.close();
      }
    });

    it('times out without leaking the listener and closes a late connect', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api, 20);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      api.listenCallback?.(undefined, 80);
      let timedOut = false;
      try {
        await task;
      } catch (error) {
        timedOut = error.message.includes('超时');
      }
      api.connectCallback?.(undefined, 81);
      expect(timedOut).assertTrue();
      expect(api.closedServers.includes(80)).assertTrue();
      expect(api.closedClients.includes(81)).assertTrue();
    });

    it('serializes writes and transmits only the requested typed-array slice', 0, async () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      const task = client.connectToAccessory(TARGET, () => true, () => {});
      api.connectCallback?.(undefined, 90);
      const active = await task;
      try {
        const first = active.write(new Uint8Array([9, 1, 2, 9]).subarray(1, 3));
        const second = active.write(new Uint8Array([3]));
        await Promise.all([first, second]);
        expect(api.written.length).assertEqual(2);
        expect(api.written[0].length).assertEqual(2);
        expect(api.written[0][0]).assertEqual(1);
        expect(api.written[0][1]).assertEqual(2);
        expect(api.written[1][0]).assertEqual(3);
      } finally {
        active.close();
      }
    });

    it('distinguishes Bluetooth disabled and selected device no longer paired', 0, () => {
      const api = new FakeBluetoothSocketApi();
      const client = new HarmonySppClient(api);
      api.isOn = false;
      let disabled = false;
      try {
        client.connectToAccessory(TARGET, () => true, () => {});
      } catch (error) {
        disabled = error.message.includes('蓝牙未开启');
      }
      api.isOn = true;
      api.isPaired = false;
      let unpaired = false;
      try {
        client.connectToAccessory(TARGET, () => true, () => {});
      } catch (error) {
        unpaired = error.message.includes('未配对');
      }
      expect(disabled).assertTrue();
      expect(unpaired).assertTrue();
      expect(api.connectCount).assertEqual(0);
    });
  });
}
