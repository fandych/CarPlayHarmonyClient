import bluetoothSocket from '@ohos.bluetooth.socket';
import { toArrayBuffer } from '../protocol/Iap2Codec';

export type ByteHandler = (bytes: Uint8Array) => void;

export class BluetoothIap2Server {
  private serverId: number = -1;
  private clientId: number = -1;
  private readHandler?: (data: ArrayBuffer) => void;
  private onClientData?: ByteHandler;
  private onClientConnected?: () => void;
  private onFailure?: (message: string) => void;

  async start(onConnected: () => void, onData: ByteHandler, onError: (message: string) => void): Promise<void> {
    if (this.serverId >= 0) {
      throw new Error('Bluetooth listener is already running');
    }
    this.onClientConnected = onConnected;
    this.onClientData = onData;
    this.onFailure = onError;
    await new Promise<void>((resolve, reject) => {
      const options: bluetoothSocket.SppOptions = {
        uuid: '00000000-deca-fade-deca-deafdecacafe',
        secure: true,
        type: bluetoothSocket.SppType.SPP_RFCOMM
      };
      try {
        bluetoothSocket.sppListen('CarPlay Sender', options, (error, serverId) => {
          if (error) {
            reject(new Error(`Bluetooth RFCOMM listen failed (${error.code}): ${error.message}`));
            return;
          }
          this.serverId = serverId;
          this.acceptNext();
          resolve();
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        reject(new Error(`Bluetooth RFCOMM listen failed: ${message}`));
      }
    });
  }

  async send(bytes: Uint8Array): Promise<void> {
    if (this.clientId < 0) {
      throw new Error('No Bluetooth accessory is connected');
    }
    try {
      await bluetoothSocket.sppWriteAsync(this.clientId, toArrayBuffer(bytes));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`Bluetooth RFCOMM write failed: ${message}`);
    }
  }

  stop(): void {
    if (this.clientId >= 0) {
      if (this.readHandler) {
        try {
          bluetoothSocket.off('sppRead', this.clientId, this.readHandler);
        } catch (error) {
          this.onFailure?.(`Bluetooth read listener cleanup failed: ${this.errorMessage(error)}`);
        }
      }
      try {
        bluetoothSocket.sppCloseClientSocket(this.clientId);
      } catch (error) {
        this.onFailure?.(`Bluetooth client socket cleanup failed: ${this.errorMessage(error)}`);
      }
      this.clientId = -1;
    }
    if (this.serverId >= 0) {
      try {
        bluetoothSocket.sppCloseServerSocket(this.serverId);
      } catch (error) {
        this.onFailure?.(`Bluetooth server socket cleanup failed: ${this.errorMessage(error)}`);
      }
      this.serverId = -1;
    }
    this.readHandler = undefined;
    this.onClientData = undefined;
    this.onClientConnected = undefined;
    this.onFailure = undefined;
  }

  private acceptNext(): void {
    if (this.serverId < 0) {
      return;
    }
    try {
      bluetoothSocket.sppAccept(this.serverId, (error, clientId) => {
        if (error) {
          if (this.serverId >= 0) {
            this.onFailure?.(`Bluetooth accept failed (${error.code}): ${error.message}`);
            setTimeout((): void => this.acceptNext(), 500);
          }
          return;
        }
        try {
          this.closeClient();
          this.clientId = clientId;
          this.readHandler = (data: ArrayBuffer): void => {
            this.onClientData?.(new Uint8Array(data));
          };
          bluetoothSocket.on('sppRead', clientId, this.readHandler);
          this.onClientConnected?.();
          this.acceptNext();
        } catch (acceptError) {
          this.onFailure?.(`Bluetooth client setup failed: ${this.errorMessage(acceptError)}`);
          if (this.clientId === clientId) {
            this.clientId = -1;
            this.readHandler = undefined;
          }
          try {
            bluetoothSocket.sppCloseClientSocket(clientId);
          } catch (closeError) {
            this.onFailure?.(`Bluetooth client cleanup failed: ${this.errorMessage(closeError)}`);
          }
          setTimeout((): void => this.acceptNext(), 500);
        }
      });
    } catch (error) {
      this.onFailure?.(`Bluetooth accept failed: ${this.errorMessage(error)}`);
      setTimeout((): void => this.acceptNext(), 500);
    }
  }

  private closeClient(): void {
    if (this.clientId < 0) {
      return;
    }
    if (this.readHandler) {
      try {
        bluetoothSocket.off('sppRead', this.clientId, this.readHandler);
      } catch (error) {
        this.onFailure?.(`Bluetooth read listener cleanup failed: ${this.errorMessage(error)}`);
      }
    }
    try {
      bluetoothSocket.sppCloseClientSocket(this.clientId);
    } catch (error) {
      this.onFailure?.(`Bluetooth client socket cleanup failed: ${this.errorMessage(error)}`);
    }
    this.clientId = -1;
    this.readHandler = undefined;
  }

  private errorMessage(error: Error | string): string {
    return error instanceof Error ? error.message : String(error);
  }
}
