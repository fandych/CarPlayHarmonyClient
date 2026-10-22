import { socket } from '@kit.NetworkKit';
import { AirPlayControlCipher } from '../../protocol/airplay/AirPlayControlCipher';
import { AirPlayControlKeys } from '../../protocol/airplay/AirPlayPairingClient';
import { HarmonyAirPlayCrypto } from '../../protocol/airplay/HarmonyAirPlayCrypto';
import { AirPlayEventCommand, AirPlayEventProtocol } from '../../protocol/airplay/AirPlayEventProtocol';
import { BinaryPlist, BinaryPlistValue } from '../../protocol/airplay/BinaryPlist';
import { RtspEventMessage, RtspEventMessageParser } from '../../protocol/airplay/RtspEventMessageParser';

export class HarmonyAirPlayEventChannel {
  private readonly client: socket.TCPSocket = socket.constructTCPSocketInstance();
  private readonly host: string;
  private readonly port: number;
  private readonly cipher: AirPlayControlCipher;
  private readonly parser: RtspEventMessageParser = new RtspEventMessageParser();
  private readonly log: (message: string) => void;
  private readonly onError: (error: Error) => void;
  private readonly onCommand: (command: AirPlayEventCommand) => Promise<void> | void;
  private incomingQueue: Promise<void> = Promise.resolve();
  private sendQueue: Promise<void> = Promise.resolve();
  private connected: boolean = false;
  private closed: boolean = false;
  private terminalError: Error | undefined = undefined;
  private nextCseq: number = 0;

  private readonly messageListener = (event: socket.SocketMessageInfo): void => {
    const bytes = new Uint8Array(event.message).slice();
    this.incomingQueue = this.incomingQueue.then(async (): Promise<void> => {
      if (this.closed) {
        return;
      }
      const plaintext = await this.cipher.decrypt(bytes);
      for (const message of this.parser.offer(plaintext)) {
        await this.handleMessage(message);
      }
    }).catch((error: Error) => {
      this.reportError(error instanceof Error ? error : new Error('Malformed AirPlay event message.'));
    });
  };

  private readonly errorListener = (error: Error): void => {
    this.reportError(error);
  };

  private constructor(
    host: string,
    port: number,
    cipher: AirPlayControlCipher,
    log: (message: string) => void,
    onError: (error: Error) => void,
    onCommand: (command: AirPlayEventCommand) => Promise<void> | void
  ) {
    this.host = host;
    this.port = port;
    this.cipher = cipher;
    this.log = log;
    this.onError = onError;
    this.onCommand = onCommand;
  }

  static async connect(
    host: string,
    port: number,
    sharedSecret: Uint8Array,
    log: (message: string) => void,
    onError: (error: Error) => void,
    onCommand: (command: AirPlayEventCommand) => Promise<void> | void = () => {}
  ): Promise<HarmonyAirPlayEventChannel> {
    if (host.length === 0 || !Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error('Invalid AirPlay event endpoint.');
    }
    let phoneWriteKey: Uint8Array | undefined = undefined;
    let phoneReadKey: Uint8Array | undefined = undefined;
    let sharedSecretCopy: Uint8Array | undefined = undefined;
    let cipher: AirPlayControlCipher | undefined = undefined;
    let channel: HarmonyAirPlayEventChannel | undefined = undefined;
    try {
      phoneWriteKey = await HarmonyAirPlayCrypto.hkdfSha512(
        sharedSecret,
        HarmonyAirPlayEventChannel.ascii('Events-Salt'),
        HarmonyAirPlayEventChannel.ascii('Events-Read-Encryption-Key')
      );
      phoneReadKey = await HarmonyAirPlayCrypto.hkdfSha512(
        sharedSecret,
        HarmonyAirPlayEventChannel.ascii('Events-Salt'),
        HarmonyAirPlayEventChannel.ascii('Events-Write-Encryption-Key')
      );
      sharedSecretCopy = sharedSecret.slice();
      const keys: AirPlayControlKeys = { phoneWriteKey, phoneReadKey, sharedSecret: sharedSecretCopy };
      cipher = new AirPlayControlCipher(keys);
      channel = new HarmonyAirPlayEventChannel(host, port, cipher, log, onError, onCommand);
      phoneWriteKey.fill(0);
      phoneReadKey.fill(0);
      sharedSecretCopy.fill(0);
      await channel.open();
      return channel;
    } catch (error) {
      if (channel !== undefined) {
        try {
          await channel.close();
        } catch (closeError) {
          const detail = closeError instanceof Error ? closeError.message : String(closeError);
          log(`Failed to close AirPlay event socket after connection error: ${detail}`);
        }
      } else if (cipher !== undefined) {
        cipher.clearSecrets();
      }
      throw error instanceof Error ? error : new Error(String(error));
    } finally {
      phoneWriteKey?.fill(0);
      phoneReadKey?.fill(0);
      sharedSecretCopy?.fill(0);
    }
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.detachListeners();
    await Promise.all([this.incomingQueue, this.sendQueue]);
    try {
      await this.client.close();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to close AirPlay event socket: ${detail}`);
    } finally {
      this.connected = false;
      this.cipher.clearSecrets();
    }
  }

  async sendCommand(command: Map<string, BinaryPlistValue>): Promise<void> {
    if (!this.connected || this.closed || this.terminalError !== undefined) {
      throw this.terminalError ?? new Error('AirPlay event channel is not connected.');
    }
    if (this.nextCseq >= 0x7FFFFFFF) {
      throw new Error('AirPlay event channel CSeq range is exhausted.');
    }
    const body = BinaryPlist.encode(command);
    const cseq = ++this.nextCseq;
    const header = HarmonyAirPlayEventChannel.ascii(
      `POST /command RTSP/1.0\r\nContent-Type: application/x-apple-binary-plist\r\n` +
      `Content-Length: ${body.length}\r\nCSeq: ${cseq}\r\n\r\n`
    );
    const plaintext = HarmonyAirPlayEventChannel.concat(header, body);
    body.fill(0);
    try {
      await this.sendPlaintext(plaintext);
    } finally {
      plaintext.fill(0);
    }
  }

  private async open(): Promise<void> {
    this.client.on('message', this.messageListener);
    this.client.on('error', this.errorListener);
    try {
      await this.client.connect({
        address: {
          address: this.host,
          port: this.port,
          family: this.host.includes(':') ? 2 : 1
        },
        timeout: 5000
      });
      this.connected = true;
      if (this.terminalError !== undefined) {
        throw this.terminalError;
      }
      this.log(`AirPlay encrypted event channel connected to ${this.host}:${this.port}.`);
    } catch (error) {
      this.detachListeners();
      throw error instanceof Error ? error : new Error('AirPlay event socket connection failed.');
    }
  }

  private async handleMessage(message: RtspEventMessage): Promise<void> {
    if (message.kind !== 'request') {
      return;
    }
    const cseq = message.headers.get('cseq');
    const cseqHeader = cseq !== undefined && /^\d+$/.test(cseq) ? `CSeq: ${cseq}\r\n` : '';
    const response = HarmonyAirPlayEventChannel.ascii(
      `RTSP/1.0 200 OK\r\n${cseqHeader}Content-Length: 0\r\n\r\n`
    );
    await this.sendPlaintext(response);
    if (message.method !== 'POST' || message.target !== '/command') {
      this.log(`AirPlay event request acknowledged: ${message.method} ${message.target}.`);
      return;
    }
    try {
      const command = AirPlayEventProtocol.parseCommand(message.body);
      await this.onCommand(command);
      const label = command.kind === 'unknown' ? command.commandType : command.kind;
      this.log(`AirPlay event command received: ${label}.`);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      this.log(`AirPlay event command could not be handled: ${detail}`);
    }
  }

  private sendPlaintext(plaintext: Uint8Array): Promise<void> {
    if (this.closed || this.terminalError !== undefined) {
      return Promise.reject(this.terminalError ?? new Error('AirPlay event channel is closed.'));
    }
    const copy = plaintext.slice();
    const operation = this.sendQueue.then(async (): Promise<void> => {
      if (this.closed || this.terminalError !== undefined) {
        throw this.terminalError ?? new Error('AirPlay event channel closed before sending.');
      }
      const encrypted = await this.cipher.encrypt(copy);
      const data = new ArrayBuffer(encrypted.length);
      new Uint8Array(data).set(encrypted);
      try {
        await this.client.send({ data });
      } finally {
        encrypted.fill(0);
      }
    }).catch((error: Error) => {
      const failure = error instanceof Error ? error : new Error('AirPlay event channel send failed.');
      this.reportError(failure);
      throw failure;
    }).finally(() => {
      copy.fill(0);
    });
    this.sendQueue = operation.catch(() => {});
    return operation;
  }

  private reportError(error: Error): void {
    if (this.closed || this.terminalError !== undefined) {
      return;
    }
    this.terminalError = error;
    this.log(`AirPlay event channel failed: ${error.message}`);
    this.onError(error);
  }

  private detachListeners(): void {
    this.client.off('message', this.messageListener);
    this.client.off('error', this.errorListener);
  }

  private static ascii(value: string): Uint8Array {
    const bytes = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code > 0x7F) {
        throw new Error('AirPlay event headers must contain ASCII characters only.');
      }
      bytes[index] = code;
    }
    return bytes;
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const result = new Uint8Array(left.length + right.length);
    result.set(left);
    result.set(right, left.length);
    return result;
  }
}
