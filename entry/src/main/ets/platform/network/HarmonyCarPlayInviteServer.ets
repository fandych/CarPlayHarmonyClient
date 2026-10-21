import { common } from '@kit.AbilityKit';
import { mdns, socket } from '@kit.NetworkKit';
import { CarPlayInviteProtocol, CarPlayInviteRequest } from '../../protocol/airplay/CarPlayInviteProtocol';

export interface BluetoothIdentityProvider {
  getStableBluetoothAddress(): Promise<string | undefined>;
}

export class CarPlayInviteServer {
  private static readonly MAX_HEADER_BYTES: number = 16 * 1024;
  private readonly identityProvider: BluetoothIdentityProvider;
  private readonly onInvite: (request: CarPlayInviteRequest) => void;
  private readonly log: (message: string) => void;
  private readonly connections: Map<number, InviteConnectionState> = new Map<number, InviteConnectionState>();
  private server: socket.TCPSocketServer | undefined = undefined;
  private connectListener: ((connection: socket.TCPSocketConnection) => void) | undefined = undefined;
  private errorListener: ((error: Error) => void) | undefined = undefined;
  private service: mdns.LocalServiceInfo | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;

  constructor(
    identityProvider: BluetoothIdentityProvider,
    onInvite: (request: CarPlayInviteRequest) => void,
    log: (message: string) => void
  ) {
    this.identityProvider = identityProvider;
    this.onInvite = onInvite;
    this.log = log;
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.server !== undefined) {
      throw new Error('CarPlay invite server is already running or starting.');
    }
    const suppliedIdentity = await this.identityProvider.getStableBluetoothAddress();
    if (suppliedIdentity === undefined) {
      throw new Error('CarPlay invite service was not published: stable Bluetooth identity is unavailable.');
    }
    const identity = CarPlayInviteProtocol.createTxtIdentity(suppliedIdentity);
    const server = socket.constructTCPSocketServerInstance();
    await server.listen({ address: '0.0.0.0', port: 0 });
    const localAddress = await server.getLocalAddress();
    const port = localAddress.port ?? 0;
    if (port < 1 || port > 65535) {
      await server.close();
      throw new Error('CarPlay invite TCP server did not obtain a valid port.');
    }

    const serviceAttribute: mdns.ServiceAttribute[] = [
      { key: 'id', value: CarPlayInviteProtocol.toNumberArray(CarPlayInviteProtocol.ascii(identity)) },
      {
        key: 'srcvers',
        value: CarPlayInviteProtocol.toNumberArray(
          CarPlayInviteProtocol.ascii(CarPlayInviteProtocol.SENDER_VERSION)
        )
      }
    ];
    const service: mdns.LocalServiceInfo = {
      serviceType: CarPlayInviteProtocol.SERVICE_TYPE,
      serviceName: CarPlayInviteProtocol.SERVICE_NAME,
      port,
      serviceAttribute
    };
    this.server = server;
    this.context = context;
    try {
      this.connectListener = (connection: socket.TCPSocketConnection): void => this.onConnection(connection);
      this.errorListener = (error: Error): void => {
        this.log(`CarPlay invite server socket error: ${error.message}`);
      };
      server.on('connect', this.connectListener);
      server.on('error', this.errorListener);
      const registeredService = await mdns.addLocalService(context, service);
      this.service = registeredService;
      this.log(
        `已发布 ${CarPlayInviteProtocol.SERVICE_TYPE} :${port}；TXT id=${identity} srcvers=${CarPlayInviteProtocol.SENDER_VERSION}。`
      );
    } catch (error) {
      if (this.connectListener !== undefined) {
        server.off('connect', this.connectListener);
      }
      if (this.errorListener !== undefined) {
        server.off('error', this.errorListener);
      }
      this.server = undefined;
      this.context = undefined;
      this.connectListener = undefined;
      this.errorListener = undefined;
      try {
        await server.close();
      } catch (closeError) {
        const detail = closeError instanceof Error ? closeError.message : String(closeError);
        this.log(`CarPlay invite server rollback failed to release TCP socket: ${detail}`);
      }
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to publish CarPlay invite service: ${detail}`);
    }
  }

  async stop(): Promise<void> {
    const server = this.server;
    const service = this.service;
    const context = this.context;
    this.server = undefined;
    this.service = undefined;
    this.context = undefined;
    this.connections.forEach((state: InviteConnectionState) => {
      clearTimeout(state.timeout);
      state.connection.off('message', state.messageListener);
      state.connection.off('error', state.errorListener);
      void state.connection.close().catch((error: Error) => {
        this.log(`Closing CarPlay invite client socket failed: ${error.message}`);
      });
    });
    this.connections.clear();
    if (server !== undefined) {
      if (this.connectListener !== undefined) {
        server.off('connect', this.connectListener);
      }
      if (this.errorListener !== undefined) {
        server.off('error', this.errorListener);
      }
    }
    this.connectListener = undefined;
    this.errorListener = undefined;

    let serviceError: Error | undefined = undefined;
    if (service !== undefined && context !== undefined) {
      try {
        await mdns.removeLocalService(context, service);
      } catch (error) {
        serviceError = error instanceof Error ? error : new Error(String(error));
      }
    }
    let socketError: Error | undefined = undefined;
    if (server !== undefined) {
      try {
        await server.close();
      } catch (error) {
        socketError = error instanceof Error ? error : new Error(String(error));
      }
    }
    if (serviceError !== undefined || socketError !== undefined) {
      throw new Error(
        `CarPlay invite shutdown failed${serviceError === undefined ? '' : ` (mDNS: ${serviceError.message})`}` +
        `${socketError === undefined ? '' : ` (TCP: ${socketError.message})`}`
      );
    }
  }

  private onConnection(connection: socket.TCPSocketConnection): void {
    const state = new InviteConnectionState(connection);
    state.messageListener = (event: socket.SocketMessageInfo): void => {
      void this.onMessage(state, new Uint8Array(event.message));
    };
    state.errorListener = (error: Error): void => {
      this.finishConnection(state, `CarPlay invite client socket error: ${error.message}`);
    };
    state.timeout = setTimeout(() => {
      this.finishConnection(state, 'CarPlay invite client timed out before sending an HTTP request.');
    }, 10_000);
    this.connections.set(connection.clientId, state);
    connection.on('message', state.messageListener);
    connection.on('error', state.errorListener);
  }

  private async onMessage(state: InviteConnectionState, bytes: Uint8Array): Promise<void> {
    if (state.finished) {
      return;
    }
    state.buffer = CarPlayInviteServer.concat(state.buffer, bytes);
    if (state.buffer.length > CarPlayInviteServer.MAX_HEADER_BYTES) {
      await this.respond(state, CarPlayInviteProtocol.ascii(
        'HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
      ));
      return;
    }
    const headerEnd = CarPlayInviteServer.findHeaderEnd(state.buffer);
    if (headerEnd < 0) {
      return;
    }
    let request: CarPlayInviteRequest;
    try {
      const header = CarPlayInviteServer.decodeAscii(state.buffer.slice(0, headerEnd + 4));
      request = CarPlayInviteProtocol.parseRequest(header);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      this.log(`Rejected malformed CarPlay invite request: ${detail}`);
      await this.respond(state, CarPlayInviteProtocol.ascii(
        'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
      ));
      return;
    }
    if (request.method === 'GET' && request.path === CarPlayInviteProtocol.INVITE_PATH) {
      try {
        this.onInvite(request);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        this.log(`CarPlay invite handoff failed: ${detail}`);
        await this.respond(state, CarPlayInviteProtocol.ascii(
          'HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        ));
        return;
      }
      this.log(`收到车机 CarPlay 邀请；receiver=${request.receiverDeviceId ?? 'unknown'}。`);
    }
    await this.respond(state, CarPlayInviteProtocol.response(request));
  }

  private async respond(state: InviteConnectionState, response: Uint8Array): Promise<void> {
    if (state.finished) {
      return;
    }
    try {
      const data = new ArrayBuffer(response.length);
      new Uint8Array(data).set(response);
      await state.connection.send({ data });
      this.finishConnection(state, 'CarPlay invite HTTP request completed.');
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      this.finishConnection(state, `CarPlay invite response failed: ${detail}`);
    }
  }

  private finishConnection(state: InviteConnectionState, message: string): void {
    if (state.finished) {
      return;
    }
    state.finished = true;
    clearTimeout(state.timeout);
    state.connection.off('message', state.messageListener);
    state.connection.off('error', state.errorListener);
    this.connections.delete(state.connection.clientId);
    this.log(message);
    void state.connection.close().catch((error: Error) => {
      this.log(`Closing CarPlay invite connection failed: ${error.message}`);
    });
  }

  private static findHeaderEnd(bytes: Uint8Array): number {
    for (let index = 0; index + 3 < bytes.length; index++) {
      if (bytes[index] === 13 && bytes[index + 1] === 10 &&
        bytes[index + 2] === 13 && bytes[index + 3] === 10) {
        return index;
      }
    }
    return -1;
  }

  private static decodeAscii(bytes: Uint8Array): string {
    let output = '';
    for (const byte of bytes) {
      if (byte > 0x7F) {
        throw new Error('CarPlay invite request headers contain non-ASCII data.');
      }
      output += String.fromCharCode(byte);
    }
    return output;
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const output = new Uint8Array(left.length + right.length);
    output.set(left);
    output.set(right, left.length);
    return output;
  }
}

class InviteConnectionState {
  readonly connection: socket.TCPSocketConnection;
  buffer: Uint8Array = new Uint8Array(0);
  finished: boolean = false;
  timeout: number = 0;
  messageListener: (event: socket.SocketMessageInfo) => void = () => {};
  errorListener: (error: Error) => void = () => {};

  constructor(connection: socket.TCPSocketConnection) {
    this.connection = connection;
  }
}
