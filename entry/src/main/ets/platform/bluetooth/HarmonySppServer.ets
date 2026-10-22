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
  listen(callback: SocketCallback): void;
  accept(serverId: number, callback: SocketCallback): void;
  peer(socketId: number): string;
  connected(socketId: number): boolean;
  write(socketId: number, bytes: ArrayBuffer): Promise<void>;
  onRead(socketId: number, listener: (data: ArrayBuffer) => void): void;
  offRead(socketId: number, listener: (data: ArrayBuffer) => void): void;
  closeClient(socketId: number): void;
  closeServer(socketId: number): void;
}

export const PHONE_IAP2_UUID = '00000000-deca-fade-deca-deafdecacafe';

class HarmonyBluetoothSocketApi implements BluetoothSocketApi {
  state(): number { return access.getState(); }
  paired(): string[] { return connection.getPairedDevices(); }
  name(deviceId: string): string { return connection.getRemoteDeviceName(deviceId); }
  listen(callback: SocketCallback): void {
    socket.sppListen('CarPlay Sender', {
      uuid: PHONE_IAP2_UUID, secure: true, type: socket.SppType.SPP_RFCOMM
    }, callback);
  }
  accept(serverId: number, callback: SocketCallback): void { socket.sppAccept(serverId, callback); }
  peer(socketId: number): string { return socket.getDeviceId(socketId); }
  connected(socketId: number): boolean { return socket.isConnected(socketId); }
  write(socketId: number, bytes: ArrayBuffer): Promise<void> { return socket.sppWriteAsync(socketId, bytes); }
  onRead(socketId: number, listener: (data: ArrayBuffer) => void): void { socket.on('sppRead', socketId, listener); }
  offRead(socketId: number, listener: (data: ArrayBuffer) => void): void { socket.off('sppRead', socketId, listener); }
  closeClient(socketId: number): void { socket.sppCloseClientSocket(socketId); }
  closeServer(socketId: number): void { socket.sppCloseServerSocket(socketId); }
}

export class HarmonySppServer {
  private readonly api: BluetoothSocketApi;
  private cancelPending: (() => void) | undefined = undefined;
  private listenerServerId: number = -1;
  private listenerGeneration: number = 0;
  private listenerActive: boolean = false;
  private acceptRetryTimer: number | undefined = undefined;
  private activeListenerConnection: SppConnection | undefined = undefined;

  constructor(api: BluetoothSocketApi = new HarmonyBluetoothSocketApi()) {
    this.api = api;
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
    this.listenerGeneration++;
    this.listenerActive = false;
    if (this.acceptRetryTimer !== undefined) {
      clearTimeout(this.acceptRetryTimer);
      this.acceptRetryTimer = undefined;
    }
    const activeConnection = this.activeListenerConnection;
    this.activeListenerConnection = undefined;
    if (activeConnection !== undefined) {
      try {
        activeConnection.close();
      } catch (error) {
        carPlayDiagnostics.log('bluetooth', `关闭入站 RFCOMM 连接失败：${describeFailure(error)}`, true);
      }
    }
  }

  listenForAccessory(
    onConnection: (connection: SppConnection) => void,
    isCurrent: () => boolean,
    log: Logger
  ): Promise<void> {
    this.stop();
    this.requireBluetooth();
    const generation = ++this.listenerGeneration;
    this.listenerActive = true;

    return new Promise<void>((resolve, reject) => {
      let startupSettled = false;
      const closeServer = (): void => {
        if (this.listenerServerId < 0) {
          return;
        }
        const id = this.listenerServerId;
        this.listenerServerId = -1;
        try {
          this.api.closeServer(id);
        } catch (error) {
          log(`关闭 iAP2 手机监听失败：${describeFailure(error)}`);
        }
      };
      const cancel = (): void => {
        if (generation !== this.listenerGeneration) {
          return;
        }
        this.listenerActive = false;
        if (this.acceptRetryTimer !== undefined) {
          clearTimeout(this.acceptRetryTimer);
          this.acceptRetryTimer = undefined;
        }
        closeServer();
        if (!startupSettled) {
          startupSettled = true;
          reject(new Error('蓝牙监听已取消。'));
        }
      };
      const failStart = (error: Error): void => {
        this.listenerActive = false;
        closeServer();
        if (this.cancelPending === cancel) {
          this.cancelPending = undefined;
        }
        if (!startupSettled) {
          startupSettled = true;
          reject(error);
        }
      };
      const acceptNext = (): void => {
        if (!this.listenerActive || generation !== this.listenerGeneration || !isCurrent()) {
          cancel();
          return;
        }
        if (this.listenerServerId < 0) {
          return;
        }
        try {
          this.api.accept(this.listenerServerId, (error: Error | undefined, id: number) => {
            if (!this.listenerActive || generation !== this.listenerGeneration || !isCurrent()) {
              if (!error) {
                try {
                  this.api.closeClient(id);
                } catch (closeError) {
                  log(`关闭迟到 RFCOMM 连接失败：${describeFailure(closeError)}`);
                }
              }
              cancel();
              return;
            }
            if (error) {
              log(`iAP2 accept 失败：${describeFailure(error)}；500ms 后重试。`);
              this.acceptRetryTimer = setTimeout((): void => {
                this.acceptRetryTimer = undefined;
                acceptNext();
              }, 500);
              return;
            }

            const active = this.activeListenerConnection;
            if (active !== undefined) {
              let activeConnected = true;
              try {
                activeConnected = this.api.connected(active.socketId);
              } catch (connectionError) {
                log(`查询当前 RFCOMM 连接状态失败：${describeFailure(connectionError)}`);
              }
              if (activeConnected) {
                log('已有车机 RFCOMM 连接；拒绝并发入站连接。');
                try {
                  this.api.closeClient(id);
                } catch (closeError) {
                  log(`关闭并发 RFCOMM 连接失败：${describeFailure(closeError)}`);
                }
                acceptNext();
                return;
              }
              this.activeListenerConnection = undefined;
              try {
                active.close();
              } catch (closeError) {
                log(`清理已断开的 RFCOMM 连接失败：${describeFailure(closeError)}`);
              }
            }

            let deviceName = '未知车机';
            let deviceAlias = '未识别车机';
            try {
              const deviceId = this.api.peer(id);
              if (deviceId.length > 0) {
                deviceName = this.api.name(deviceId) || deviceName;
                deviceAlias = carPlayDiagnostics.identifier(deviceId);
              }
            } catch (identityError) {
              log(`读取入站 RFCOMM 对端名称失败：${describeFailure(identityError)}`);
            }
            const connection = this.createConnection(id, deviceName, log);
            this.activeListenerConnection = connection;
            log(`已接受车机主动发起的安全 RFCOMM 连接：${deviceAlias}。`);
            try {
              onConnection(connection);
            } catch (connectionError) {
              log(`处理入站 RFCOMM 连接失败：${describeFailure(connectionError)}`);
              this.activeListenerConnection = undefined;
              try {
                connection.close();
              } catch (closeError) {
                log(`关闭未处理的入站 RFCOMM 连接失败：${describeFailure(closeError)}`);
              }
            }
            acceptNext();
          });
        } catch (error) {
          log(`iAP2 accept 调用失败：${describeFailure(error)}；500ms 后重试。`);
          this.acceptRetryTimer = setTimeout((): void => {
            this.acceptRetryTimer = undefined;
            acceptNext();
          }, 500);
        }
      };

      this.cancelPending = cancel;
      try {
        this.api.listen((error: Error | undefined, id: number) => {
          if (!this.listenerActive || generation !== this.listenerGeneration || !isCurrent()) {
            if (!error) {
              try {
                this.api.closeServer(id);
              } catch (closeError) {
                log(`关闭迟到 iAP2 监听失败：${describeFailure(closeError)}`);
              }
            }
            cancel();
            return;
          }
          if (error) {
            failStart(new Error(`iAP2 手机服务监听失败：${describeFailure(error)}`));
            return;
          }
          this.listenerServerId = id;
          startupSettled = true;
          log(`iAP2 手机服务已安全监听 UUID=${PHONE_IAP2_UUID}，等待车机主动连接。`);
          resolve();
          acceptNext();
        });
      } catch (error) {
        failStart(new Error(`iAP2 手机服务监听失败：${describeFailure(error)}`));
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
        let socketConnected = true;
        try {
          socketConnected = this.api.connected(id);
        } catch (error) {
          log(`查询待关闭 RFCOMM 状态失败：${describeFailure(error)}`);
        }
        let readFailure: Error | undefined = undefined;
        try {
          offData();
        } catch (error) {
          if (socketConnected) {
            readFailure = error;
          } else {
            log(`断开后移除 RFCOMM 读取监听失败：${describeFailure(error)}`);
          }
        }
        if (socketConnected) {
          try {
            this.api.closeClient(id);
          } finally {
            log(`RFCOMM closed; txBytes=${sent}; rxBytes=${received}。`);
          }
        } else {
          log(`RFCOMM peer already disconnected; txBytes=${sent}; rxBytes=${received}。`);
        }
        if (readFailure !== undefined) {
          throw readFailure;
        }
      }
    };
  }
}
