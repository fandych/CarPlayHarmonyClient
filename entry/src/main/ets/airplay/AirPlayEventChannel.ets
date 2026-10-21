import netSocket from '@ohos.net.socket';
import { AirPlayControlCipher } from './ControlCipher';
import { hkdfSha512 } from './AirPlayCrypto';
import { concatBytes, decodeUtf8, encodeUtf8, toArrayBuffer } from '../protocol/Iap2Codec';

export interface AirPlayEventRequest {
  method: string;
  target: string;
  cseq: number;
  headers: Map<string, string>;
  body: Uint8Array;
}

export interface ParsedAirPlayEventRequests {
  requests: AirPlayEventRequest[];
  remaining: Uint8Array;
}

export function parseAirPlayEventRequests(input: Uint8Array): ParsedAirPlayEventRequests {
  const requests: AirPlayEventRequest[] = [];
  let remaining = input;
  while (remaining.length > 0) {
    const headerEnd = findHeaderEnd(remaining);
    if (headerEnd < 0) {
      if (remaining.length > 64 * 1024) {
        throw new Error('AirPlay event request header exceeded 64 KiB');
      }
      break;
    }
    const lines = decodeUtf8(remaining.slice(0, headerEnd)).split('\r\n');
    const requestLine = lines[0] ?? '';
    const requestParts = requestLine.split(' ');
    if (requestParts.length < 3 || !requestParts[2].startsWith('RTSP/')) {
      throw new Error(`Invalid AirPlay event request line: ${requestLine}`);
    }
    const headers: Map<string, string> = new Map<string, string>();
    for (let index = 1; index < lines.length; index++) {
      const line = lines[index];
      const separator = line.indexOf(':');
      if (separator > 0) {
        headers.set(line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim());
      }
    }
    if (headers.has('transfer-encoding')) {
      throw new Error('Chunked AirPlay event request bodies are not supported');
    }
    const cseqText = headers.get('cseq');
    const cseq = Number.parseInt(cseqText ?? '', 10);
    const contentLengthText = headers.get('content-length') ?? '0';
    const contentLength = Number.parseInt(contentLengthText, 10);
    if (!Number.isInteger(cseq) || cseq < 0) {
      throw new Error('AirPlay event request is missing a valid CSeq');
    }
    if (!Number.isInteger(contentLength) || contentLength < 0 || contentLength > 1024 * 1024) {
      throw new Error(`Invalid AirPlay event Content-Length: ${contentLengthText}`);
    }
    const bodyStart = headerEnd + 4;
    const requestLength = bodyStart + contentLength;
    if (remaining.length < requestLength) {
      break;
    }
    const request: AirPlayEventRequest = {
      method: requestParts[0],
      target: requestParts[1],
      cseq,
      headers,
      body: remaining.slice(bodyStart, requestLength)
    };
    requests.push(request);
    remaining = remaining.slice(requestLength);
  }
  if (remaining.length > 1024 * 1024) {
    throw new Error('AirPlay event receive buffer exceeded the 1 MiB safety limit');
  }
  const result: ParsedAirPlayEventRequests = { requests, remaining };
  return result;
}

export function buildAirPlayEventResponse(cseq: number): Uint8Array {
  if (!Number.isInteger(cseq) || cseq < 0) {
    throw new Error('Invalid AirPlay event response CSeq');
  }
  return encodeUtf8(`RTSP/1.0 200 OK\r\nCSeq: ${cseq}\r\nContent-Length: 0\r\n\r\n`);
}

export class AirPlayEventChannel {
  private socket?: netSocket.TCPSocket;
  private messageHandler?: (info: netSocket.SocketMessageInfo) => void;
  private errorHandler?: (error: Error) => void;
  private cipher?: AirPlayControlCipher;
  private receiveBuffer: Uint8Array = new Uint8Array(0);
  private receiveQueue: Promise<void> = Promise.resolve();
  private running: boolean = false;
  private readonly log: (message: string) => void;
  private readonly onRequest: (request: AirPlayEventRequest) => void;

  constructor(log: (message: string) => void, onRequest: (request: AirPlayEventRequest) => void) {
    this.log = log;
    this.onRequest = onRequest;
  }

  async connect(host: string, port: number, sharedSecret: Uint8Array): Promise<void> {
    if (this.socket) {
      throw new Error('AirPlay event channel is already connected');
    }
    if (!host || port < 1 || port > 65535 || sharedSecret.length === 0) {
      throw new Error('Invalid AirPlay event endpoint or missing verified shared secret');
    }
    const phoneWriteKey = await hkdfSha512(
      sharedSecret,
      encodeUtf8('Events-Salt'),
      encodeUtf8('Events-Read-Encryption-Key')
    );
    const phoneReadKey = await hkdfSha512(
      sharedSecret,
      encodeUtf8('Events-Salt'),
      encodeUtf8('Events-Write-Encryption-Key')
    );
    this.cipher = new AirPlayControlCipher(phoneReadKey, phoneWriteKey);
    const socket = netSocket.constructTCPSocketInstance();
    this.socket = socket;
    this.running = true;
    this.messageHandler = (info: netSocket.SocketMessageInfo): void => {
      const chunk = new Uint8Array(info.message);
      this.receiveQueue = this.receiveQueue
        .then((): Promise<void> => this.handleIncoming(chunk))
        .catch((error: Error): void => {
          this.log(`AirPlay event channel receive failed: ${error.message}`);
          this.running = false;
        });
    };
    this.errorHandler = (error: Error): void => {
      this.log(`AirPlay event channel socket error: ${error.message}`);
      this.running = false;
    };
    try {
      socket.on('message', this.messageHandler);
      socket.on('error', this.errorHandler);
      await socket.connect({
        address: { address: host, port },
        timeout: 5000
      });
      this.log(`AirPlay encrypted event channel connected to ${host}:${port}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      try {
        await this.close();
      } catch (cleanupError) {
        throw new Error(
          `AirPlay event connect failed: ${message}; cleanup failed: ` +
            `${cleanupError instanceof Error ? cleanupError.message : String(cleanupError)}`
        );
      }
      throw new Error(`AirPlay event connect failed: ${message}`);
    }
  }

  async close(): Promise<void> {
    this.running = false;
    const socket = this.socket;
    this.socket = undefined;
    if (!socket) {
      return;
    }
    const failures: string[] = [];
    if (this.messageHandler) {
      try {
        socket.off('message', this.messageHandler);
      } catch (error) {
        failures.push(`message listener: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (this.errorHandler) {
      try {
        socket.off('error', this.errorHandler);
      } catch (error) {
        failures.push(`error listener: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    this.messageHandler = undefined;
    this.errorHandler = undefined;
    this.cipher = undefined;
    this.receiveBuffer = new Uint8Array(0);
    try {
      await socket.close();
    } catch (error) {
      failures.push(`socket: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (failures.length > 0) {
      throw new Error(`AirPlay event cleanup failed: ${failures.join('; ')}`);
    }
  }

  private async handleIncoming(data: Uint8Array): Promise<void> {
    const cipher = this.cipher;
    if (!cipher || !this.running) {
      return;
    }
    const plaintext = await cipher.decrypt(data);
    this.receiveBuffer = concatBytes(this.receiveBuffer, plaintext);
    const parsed = parseAirPlayEventRequests(this.receiveBuffer);
    this.receiveBuffer = parsed.remaining;
    for (const request of parsed.requests) {
      this.onRequest(request);
      const response = await cipher.encrypt(buildAirPlayEventResponse(request.cseq));
      const socket = this.socket;
      if (!socket || !this.running) {
        return;
      }
      await socket.send({ data: toArrayBuffer(response) });
    }
  }
}

function findHeaderEnd(bytes: Uint8Array): number {
  for (let index = 0; index + 3 < bytes.length; index++) {
    if (bytes[index] === 13 && bytes[index + 1] === 10 && bytes[index + 2] === 13 && bytes[index + 3] === 10) {
      return index;
    }
  }
  return -1;
}
