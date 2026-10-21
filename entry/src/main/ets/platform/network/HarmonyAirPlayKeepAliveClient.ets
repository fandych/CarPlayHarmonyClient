import { socket } from '@kit.NetworkKit';
import { HarmonyAirPlayCrypto } from '../../protocol/airplay/HarmonyAirPlayCrypto';

const KEEP_ALIVE_INTERVAL_MS = 5000;

export class HarmonyAirPlayKeepAliveClient {
  private readonly host: string;
  private readonly port: number;
  private readonly onError: (error: Error) => void;
  private udp: socket.UDPSocket | undefined = undefined;
  private timer: number | undefined = undefined;
  private stopped: boolean = false;

  constructor(host: string, port: number, onError: (error: Error) => void) {
    this.host = host;
    this.port = port;
    this.onError = onError;
  }

  async start(): Promise<void> {
    if (this.udp !== undefined || this.stopped) {
      throw new Error('AirPlay keep-alive client cannot be started in its current state.');
    }
    if (this.host.length === 0 || !Number.isInteger(this.port) || this.port < 1 || this.port > 65535) {
      throw new Error('Invalid AirPlay keep-alive endpoint.');
    }
    const udp = socket.constructUDPSocketInstance();
    try {
      await udp.bind({ address: '0.0.0.0', port: 0 });
      this.udp = udp;
      await this.sendPacket();
      this.scheduleNext();
    } catch (error) {
      this.udp = undefined;
      try {
        await udp.close();
      } catch (closeError) {
        const detail = closeError instanceof Error ? closeError.message : String(closeError);
        this.onError(new Error(`AirPlay keep-alive socket rollback failed: ${detail}`));
      }
      throw new Error(
        `Failed to start AirPlay keep-alive client: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    const udp = this.udp;
    this.udp = undefined;
    if (udp === undefined) {
      return;
    }
    try {
      await udp.close();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to close AirPlay keep-alive socket: ${detail}`);
    }
  }

  private scheduleNext(): void {
    if (this.stopped || this.udp === undefined) {
      return;
    }
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.onTimer();
    }, KEEP_ALIVE_INTERVAL_MS);
  }

  private async onTimer(): Promise<void> {
    if (this.stopped || this.udp === undefined) {
      return;
    }
    try {
      await this.sendPacket();
      this.scheduleNext();
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error));
      this.onError(failure);
      try {
        await this.stop();
      } catch (closeError) {
        this.onError(closeError instanceof Error ? closeError : new Error(String(closeError)));
      }
    }
  }

  private async sendPacket(): Promise<void> {
    const udp = this.udp;
    if (udp === undefined || this.stopped) {
      throw new Error('AirPlay keep-alive client is not running.');
    }
    const packet = await HarmonyAirPlayCrypto.randomBytes(4);
    const data = new ArrayBuffer(packet.length);
    new Uint8Array(data).set(packet);
    await udp.send({
      data,
      address: { address: this.host, port: this.port }
    });
  }
}
