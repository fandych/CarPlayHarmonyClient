import { socket } from '@kit.NetworkKit';

export class HarmonyAirPlayTimingServer {
  private static readonly PACKET_SIZE: number = 32;
  private static readonly REQUEST_PAYLOAD_TYPE: number = 0xD2;
  private static readonly RESPONSE_PAYLOAD_TYPE: number = 0xD3;
  private readonly log: (message: string) => void;
  private udp: socket.UDPSocket | undefined = undefined;
  private messageListener: ((event: socket.SocketMessageInfo) => void) | undefined = undefined;
  private errorListener: ((error: Error) => void) | undefined = undefined;
  private port: number = 0;

  constructor(log: (message: string) => void) {
    this.log = log;
  }

  async start(): Promise<number> {
    if (this.udp !== undefined) {
      throw new Error('AirPlay timing server is already running.');
    }
    const udp = socket.constructUDPSocketInstance();
    try {
      await udp.bind({ address: '0.0.0.0', port: 0 });
      const local = await udp.getLocalAddress();
      const port = local.port ?? 0;
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error('AirPlay timing server did not obtain a valid UDP port.');
      }
      this.messageListener = (event: socket.SocketMessageInfo): void => this.onMessage(event);
      this.errorListener = (error: Error): void => {
        this.log(`AirPlay timing UDP socket error: ${error.message}`);
      };
      udp.on('message', this.messageListener);
      udp.on('error', this.errorListener);
      this.udp = udp;
      this.port = port;
      this.log(`AirPlay timing server listening on UDP :${port}.`);
      return port;
    } catch (error) {
      try {
        await udp.close();
      } catch (closeError) {
        const detail = closeError instanceof Error ? closeError.message : String(closeError);
        this.log(`AirPlay timing socket rollback failed: ${detail}`);
      }
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to start AirPlay timing server: ${detail}`);
    }
  }

  async stop(): Promise<void> {
    const udp = this.udp;
    this.udp = undefined;
    this.port = 0;
    if (udp === undefined) {
      return;
    }
    if (this.messageListener !== undefined) {
      udp.off('message', this.messageListener);
    }
    if (this.errorListener !== undefined) {
      udp.off('error', this.errorListener);
    }
    this.messageListener = undefined;
    this.errorListener = undefined;
    try {
      await udp.close();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to stop AirPlay timing server: ${detail}`);
    }
  }

  private onMessage(event: socket.SocketMessageInfo): void {
    const request = new Uint8Array(event.message);
    const response = HarmonyAirPlayTimingServer.buildTimeSyncResponse(request, Date.now());
    if (response === undefined) {
      return;
    }
    const udp = this.udp;
    if (udp === undefined) {
      return;
    }
    const data = new ArrayBuffer(response.length);
    new Uint8Array(data).set(response);
    void udp.send({
      data,
      address: {
        address: event.remoteInfo.address,
        port: event.remoteInfo.port
      }
    }).catch((error: Error) => {
      this.log(`AirPlay timing response send failed: ${error.message}`);
    });
  }

  static buildTimeSyncResponse(request: Uint8Array, nowMillis: number): Uint8Array | undefined {
    if (request.length < HarmonyAirPlayTimingServer.PACKET_SIZE ||
      (request[0] >>> 6) !== 2 ||
      request[1] !== HarmonyAirPlayTimingServer.REQUEST_PAYLOAD_TYPE ||
      ((request[2] << 8) | request[3]) !== 7 ||
      !Number.isSafeInteger(nowMillis) || nowMillis < 0) {
      return undefined;
    }
    const response = new Uint8Array(HarmonyAirPlayTimingServer.PACKET_SIZE);
    response[0] = 0x80;
    response[1] = HarmonyAirPlayTimingServer.RESPONSE_PAYLOAD_TYPE;
    response[3] = 7;
    response.set(request.slice(24, 32), 8);
    const timestamp = HarmonyAirPlayTimingServer.ntpFromMillis(nowMillis);
    response.set(timestamp, 16);
    response.set(HarmonyAirPlayTimingServer.ntpFromMillis(nowMillis + 1), 24);
    return response;
  }

  private static ntpFromMillis(milliseconds: number): Uint8Array {
    const seconds = Math.floor(milliseconds / 1000);
    const fraction = Math.floor(((milliseconds % 1000) * 0x100000000) / 1000);
    const result = new Uint8Array(8);
    HarmonyAirPlayTimingServer.writeU32Be(result, 0, seconds % 0x100000000);
    HarmonyAirPlayTimingServer.writeU32Be(result, 4, fraction);
    return result;
  }

  private static writeU32Be(bytes: Uint8Array, offset: number, value: number): void {
    bytes[offset] = Math.floor(value / 0x1000000) & 0xFF;
    bytes[offset + 1] = (value >>> 16) & 0xFF;
    bytes[offset + 2] = (value >>> 8) & 0xFF;
    bytes[offset + 3] = value & 0xFF;
  }
}
