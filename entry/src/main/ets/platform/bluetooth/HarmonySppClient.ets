import { access, connection, socket } from '@kit.ConnectivityKit';
import { describeFailure } from '../diagnostics/DiagnosticFormat';
import { carPlayDiagnostics } from '../diagnostics/CarPlayDiagnostics';

export interface PairedAccessory {
  deviceId: string;
  name: string;
}

export interface SppConnection {
  socketId: number;
  deviceName: string;
  write: (bytes: Uint8Array) => Promise<void>;
  onData: (listener: (data: ArrayBuffer) => void) => void;
  onClosed: (listener: (reason: string) => void) => void;
  offData: () => void;
  close: () => void;
}

type SocketCallback = (error: Error | undefined, socketId: number) => void;
type Logger = (message: string) => void;

export interface BluetoothSocketApi {
  state(): number;
  paired(): string[];
  name(deviceId: string): string;
  bond(deviceId: string): number;
  uuids(deviceId: string): Promise<string[]>;
  listen(callback: SocketCallback): void;
  accept(serverId: number, callback: SocketCallback): void;
  connect(deviceId: string, callback: SocketCallback): void;
  peer(socketId: number): string;
  connected(socketId: number): boolean;
  write(socketId: number, bytes: ArrayBuffer): Promise<void>;
  onRead(socketId: number, listener: (data: ArrayBuffer) => void): void;
  offRead(socketId: number, listener: (data: ArrayBuffer) => void): void;
  closeClient(socketId: number): void;
  closeServer(socketId: number): void;
}

export const ACCESSORY_IAP2_UUID = '00000000-deca-fade-deca-deafdecacaff';
export const PHONE_IAP2_UUID = '00000000-deca-fade-deca-deafdecacafe';

class HarmonyBluetoothSocketApi implements BluetoothSocketApi {
  state(): number { return access.getState(); }
  paired(): string[] { return connection.getPairedDevices(); }
  name(deviceId: string): string { return connection.getRemoteDeviceName(deviceId); }
  bond(deviceId: string): number { return connection.getPairState(deviceId); }
  async uuids(deviceId: string): Promise<string[]> {
    return connection.getRemoteProfileUuids(deviceId);
  }
  listen(callback: SocketCallback): void {
    socket.sppListen('iAP2', {
      uuid: PHONE_IAP2_UUID, secure: true, type: socket.SppType.SPP_RFCOMM
    }, callback);
  }
  accept(serverId: number, callback: SocketCallback): void { socket.sppAccept(serverId, callback); }
  connect(deviceId: string, callback: SocketCallback): void {
    socket.sppConnect(deviceId, {
      uuid: ACCESSORY_IAP2_UUID, secure: true, type: socket.SppType.SPP_RFCOMM
    }, callback);
  }
  peer(socketId: number): string { return socket.getDeviceId(socketId); }
  connected(socketId: number): boolean { return socket.isConnected(socketId); }
  write(socketId: number, bytes: ArrayBuffer): Promise<void> { return socket.sppWriteAsync(socketId, bytes); }
  onRead(socketId: number, listener: (data: ArrayBuffer) => void): void { socket.on('sppRead', socketId, listener); }
  offRead(socketId: number, listener: (data: ArrayBuffer) => void): void { socket.off('sppRead', socketId, listener); }
  closeClient(socketId: number): void { socket.sppCloseClientSocket(socketId); }
  closeServer(socketId: number): void { socket.sppCloseServerSocket(socketId); }
}

export class HarmonySppClient {
  private readonly api: BluetoothSocketApi;
  private readonly waitMs: number;
  private cancelPending: (() => void) | undefined = undefined;
  private outboundPending: boolean = false;

  constructor(api: BluetoothSocketApi = new HarmonyBluetoothSocketApi(), waitMs: number = 30000) {
    this.api = api;
    this.waitMs = waitMs;
  }

  pairedAccessories(): PairedAccessory[] {
    this.requireBluetooth();
    return this.api.paired().map((deviceId: string): PairedAccessory => {
      return { deviceId, name: this.api.name(deviceId) || '未知设备' };
    });
  }

  stop(): void {
    const cancel = this.cancelPending;
    this.cancelPending = undefined;
    cancel?.();
  }

  connectToAccessory(target: PairedAccessory, isCurrent: () => boolean, log: Logger): Promise<SppConnection> {
    this.stop();
    this.requireBluetooth();
    if (!this.api.paired().some((id: string) => id.toUpperCase() === target.deviceId.toUpperCase()) ||
      this.api.bond(target.deviceId) !== connection.BondState.BOND_STATE_BONDED) {
      throw new Error('所选接收端未配对，请在系统设置配对后重新选择。');
    }
    const alias = carPlayDiagnostics.identifier(target.deviceId);
    carPlayDiagnostics.identifier(target.name);
    log(`目标 ${alias} 已配对；监听 phone UUID=${PHONE_IAP2_UUID}，主动连接 accessory UUID=${ACCESSORY_IAP2_UUID}。`);
    return new Promise<SppConnection>((resolve, reject) => {
      let completed = false;
      let serverId: number | undefined = undefined;
      let listenerFailed = false;
      let outboundFailure: string | undefined = undefined;
      const closeClient = (id: number): void => {
        try {
          this.api.closeClient(id);
        } catch (error) {
          log(`关闭迟到/竞争 RFCOMM socket 失败：${describeFailure(error)}`);
        }
      };
      const closeServer = (): void => {
        if (serverId !== undefined) {
          const id = serverId;
          serverId = undefined;
          try {
            this.api.closeServer(id);
          } catch (error) {
            log(`关闭 iAP2 监听失败：${describeFailure(error)}`);
          }
        }
      };
      const finish = (): void => {
        completed = true;
        clearTimeout(timeout);
        clearTimeout(outboundTimeout);
        if (this.cancelPending === cancel) {
          this.cancelPending = undefined;
        }
        closeServer();
      };
      const failIfNoRoute = (): void => {
        if (!completed && listenerFailed && outboundFailure !== undefined) {
          finish();
          reject(new Error(`入站监听不可用且出站失败：${outboundFailure}`));
        }
      };
      const claim = (id: number, direction: string): void => {
        if (completed || !isCurrent()) {
          closeClient(id);
          return;
        }
        finish();
        log(`RFCOMM 已连接 ${alias}；direction=${direction}。`);
        resolve(this.createConnection(id, alias, log));
      };
      const cancel = (): void => {
        if (!completed) {
          finish();
          reject(new Error('蓝牙连接已取消。'));
        }
      };
      const timeout = setTimeout(() => {
        if (!completed) {
          finish();
          reject(new Error(`等待所选接收端超时；outbound=${outboundFailure ?? 'pending'}；` +
            '未观察到目标入站连接。请确认接收端已启动无线 CarPlay；服务缓存缺失不代表未配对。'));
        }
      }, this.waitMs);
      let outboundExpired = false;
      const outboundTimeout = setTimeout(() => {
        outboundExpired = true;
        outboundFailure = 'RFCOMM 出站连接超时；仍等待接收端回连';
        log(outboundFailure);
        failIfNoRoute();
      }, Math.min(12000, this.waitMs));
      this.cancelPending = cancel;
      const acceptNext = (): void => {
        if (completed || serverId === undefined) {
          return;
        }
        try {
          this.api.accept(serverId, (error: Error | undefined, id: number) => {
            if (error) {
              if (!completed) {
                listenerFailed = true;
                log(`iAP2 accept 失败：${describeFailure(error)}`);
                closeServer();
                failIfNoRoute();
              }
              return;
            }
            if (completed || !isCurrent()) {
              closeClient(id);
              return;
            }
            try {
              if (this.api.peer(id).toUpperCase() !== target.deviceId.toUpperCase()) {
                log('拒绝非所选接收端的入站 RFCOMM 连接。');
                closeClient(id);
                acceptNext();
                return;
              }
              claim(id, 'inbound');
            } catch (failure) {
              log(`读取入站对端身份失败：${describeFailure(failure)}`);
              closeClient(id);
              acceptNext();
            }
          });
        } catch (error) {
          listenerFailed = true;
          log(`iAP2 accept 调用失败：${describeFailure(error)}`);
          closeServer();
          failIfNoRoute();
        }
      };
      try {
        this.api.listen((error: Error | undefined, id: number) => {
          if (error) {
            if (!completed) {
              listenerFailed = true;
              log(`iAP2 phone 服务监听失败：${describeFailure(error)}`);
              failIfNoRoute();
            }
            return;
          }
          serverId = id;
          if (completed || !isCurrent()) {
            closeServer();
            return;
          }
          log('iAP2 phone 服务已监听，等待所选接收端回连。');
          acceptNext();
        });
      } catch (error) {
        listenerFailed = true;
        log(`iAP2 listen 调用失败：${describeFailure(error)}`);
      }
      // UUID caches can omit custom services. Query for diagnostics, never use absence as a rejection.
      void this.api.uuids(target.deviceId).then((uuids: string[]) => {
        if (!completed) {
          log(`SDP 缓存：accessory=${uuids.some((uuid: string) => uuid.toLowerCase() === ACCESSORY_IAP2_UUID) ?
            'observed' : 'unknown'}；profileCount=${uuids.length}。`);
        }
      }).catch((error: Error) => {
        if (!completed) {
          log(`SDP 查询不可用，服务状态未知：${describeFailure(error)}`);
        }
      });
      if (completed) {
        return;
      }
      if (this.outboundPending) {
        outboundFailure = '上一轮原生出站调用尚未返回；本轮只监听回连，避免并发 RFCOMM 拨号。';
        clearTimeout(outboundTimeout);
        log(outboundFailure);
        failIfNoRoute();
        return;
      }
      try {
        this.outboundPending = true;
        this.api.connect(target.deviceId, (error: Error | undefined, id: number) => {
          this.outboundPending = false;
          if (error) {
            if (!completed) {
              outboundFailure = describeFailure(error);
              log(`iAP2 出站失败：${outboundFailure}；监听仍可等待接收端回连。`);
              clearTimeout(outboundTimeout);
              failIfNoRoute();
            }
            return;
          }
          if (outboundExpired) {
            closeClient(id);
          } else {
            claim(id, 'outbound');
          }
        });
      } catch (error) {
        this.outboundPending = false;
        outboundFailure = describeFailure(error);
        log(`iAP2 connect 调用失败：${outboundFailure}`);
        clearTimeout(outboundTimeout);
        failIfNoRoute();
      }
    });
  }

  private requireBluetooth(): void {
    const state = this.api.state();
    if (state !== access.BluetoothState.STATE_ON) {
      throw new Error(`蓝牙未开启或尚未就绪，state=${state}；请先在系统设置开启蓝牙。`);
    }
  }

  private createConnection(id: number, alias: string, log: Logger): SppConnection {
    let readListener: ((data: ArrayBuffer) => void) | undefined = undefined;
    let closedListener: ((reason: string) => void) | undefined = undefined;
    let closed = false;
    let sent = 0;
    let received = 0;
    let writes: Promise<void> = Promise.resolve();
    const offData = (): void => {
      if (readListener !== undefined) {
        const listener = readListener;
        readListener = undefined;
        this.api.offRead(id, listener);
      }
    };
    const watcher = setInterval(() => {
      if (closed) {
        return;
      }
      let reason = '';
      try {
        if (!this.api.connected(id)) {
          reason = '接收端已关闭 RFCOMM 连接。';
        }
      } catch (error) {
        reason = `查询 RFCOMM 状态失败：${describeFailure(error)}`;
      }
      if (reason.length > 0) {
        clearInterval(watcher);
        closedListener?.(reason);
      }
    }, 1000);
    return {
      socketId: id,
      deviceName: alias,
      write: (bytes: Uint8Array): Promise<void> => {
        const data = bytes.slice().buffer as ArrayBuffer;
        writes = writes.then(async () => {
          if (closed) {
            throw new Error('RFCOMM socket is closed.');
          }
          await this.api.write(id, data);
          if (sent === 0) {
            log(`RFCOMM first-tx bytes=${data.byteLength}。`);
          }
          sent += data.byteLength;
        });
        return writes;
      },
      onData: (listener: (data: ArrayBuffer) => void): void => {
        offData();
        readListener = (data: ArrayBuffer): void => {
          if (!closed) {
            if (received === 0) {
              log(`RFCOMM first-rx bytes=${data.byteLength}。`);
            }
            received += data.byteLength;
            listener(data);
          }
        };
        this.api.onRead(id, readListener);
      },
      onClosed: (listener: (reason: string) => void): void => { closedListener = listener; },
      offData,
      close: (): void => {
        if (closed) {
          return;
        }
        closed = true;
        clearInterval(watcher);
        let readFailure: Error | undefined = undefined;
        try {
          offData();
        } catch (error) {
          readFailure = error;
        }
        try {
          this.api.closeClient(id);
        } finally {
          log(`RFCOMM closed; txBytes=${sent}; rxBytes=${received}。`);
        }
        if (readFailure !== undefined) {
          throw readFailure;
        }
      }
    };
  }
}
