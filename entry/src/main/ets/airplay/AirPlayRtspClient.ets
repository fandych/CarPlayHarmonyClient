import netSocket from '@ohos.net.socket';
import { decodeUtf8, encodeUtf8, concatBytes, toArrayBuffer } from '../protocol/Iap2Codec';
import { AirPlayControlCipher } from './ControlCipher';

export interface AirPlayRtspResponse {
  statusCode: number;
  statusLine: string;
  headers: Map<string, string>;
  body: Uint8Array;
}

export interface AirPlayRtspHeaders {
  contentType?: string;
  appleHkp?: boolean;
  applePd?: boolean;
  userAgent?: string;
}

interface PendingResponse {
  cseq: number;
  resolve: (response: AirPlayRtspResponse) => void;
  reject: (error: Error) => void;
  timeoutId: number;
}

export class AirPlayRtspClient {
  private socket?: netSocket.TCPSocket;
  private messageHandler?: (info: netSocket.SocketMessageInfo) => void;
  private errorHandler?: (error: Error) => void;
  private receiveBuffer: Uint8Array = new Uint8Array(0);
  private pending?: PendingResponse;
  private cipher?: AirPlayControlCipher;
  private receiveQueue: Promise<void> = Promise.resolve();
  private nextCseq: number = 1;
  private readonly onError: (message: string) => void;

  constructor(onError: (message: string) => void) {
    this.onError = onError;
  }

  async connect(host: string, port: number): Promise<void> {
    if (this.socket) {
      throw new Error('AirPlay RTSP client is already connected');
    }
    if (!host || port < 1 || port > 65535) {
      throw new Error('Invalid AirPlay RTSP endpoint');
    }
    const socket = netSocket.constructTCPSocketInstance();
    this.socket = socket;
    this.messageHandler = (info: netSocket.SocketMessageInfo): void => {
      const data = new Uint8Array(info.message);
      this.receiveQueue = this.receiveQueue
        .then((): Promise<void> => this.handleIncoming(data))
        .catch((error: Error): void => {
          this.onError(`AirPlay RTSP receive failed: ${error.message}`);
          this.failPending(error);
        });
    };
    this.errorHandler = (error: Error): void => {
    this.onError(`AirPlay RTSP socket error: ${error.message}`);
    this.failPending(error);
    };
    try {
      socket.on('message', this.messageHandler);
      socket.on('error', this.errorHandler);
      const options: netSocket.TCPConnectOptions = {
        address: { address: host, port },
        timeout: 5000
      };
      await socket.connect(options);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      try {
        await this.close();
      } catch (cleanupError) {
        const cleanupMessage = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
        throw new Error(`AirPlay RTSP connect failed: ${message}; cleanup failed: ${cleanupMessage}`);
      }
      throw new Error(`AirPlay RTSP connect failed: ${message}`);
    }
  }

  async request(
    method: string,
    path: string,
    body: Uint8Array = new Uint8Array(0),
    headers: AirPlayRtspHeaders = {}
  ): Promise<AirPlayRtspResponse> {
    const socket = this.socket;
    if (!socket) {
      throw new Error('AirPlay RTSP client is not connected');
    }
    if (this.pending) {
      throw new Error('An AirPlay RTSP request is already pending');
    }
    const cseq = this.nextCseq++;
    let requestText = `${method} ${path} RTSP/1.0\r\nCSeq: ${cseq}\r\n`;
    requestText += `User-Agent: ${headers.userAgent ?? 'HarmonyCarPlaySender/26'}\r\n`;
    if (headers.contentType) {
      requestText += `Content-Type: ${headers.contentType}\r\n`;
    }
    if (headers.appleHkp) {
      requestText += 'X-Apple-HKP: 2\r\n';
    }
    if (headers.applePd) {
      requestText += 'X-Apple-PD: 1\r\n';
    }
    requestText += `Content-Length: ${body.length}\r\nConnection: keep-alive\r\n\r\n`;
    const plaintext = concatBytes(encodeUtf8(requestText), body);
    const outbound = this.cipher ? await this.cipher.encrypt(plaintext) : plaintext;

    const responsePromise = new Promise<AirPlayRtspResponse>((resolve, reject) => {
      const timeoutId = setTimeout((): void => {
        this.failPending(new Error(`AirPlay RTSP ${method} ${path} timed out`));
      }, 8000);
      const pending: PendingResponse = { cseq, resolve, reject, timeoutId };
      this.pending = pending;
    });
    const sendOptions: netSocket.TCPSendOptions = { data: toArrayBuffer(outbound) };
    try {
      await socket.send(sendOptions);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.failPending(new Error(`AirPlay RTSP write failed: ${message}`));
    }
    return responsePromise;
  }

  activateEncryption(readKey: Uint8Array, writeKey: Uint8Array): void {
    if (this.pending) {
      throw new Error('Cannot enable AirPlay control encryption while a request is pending');
    }
    if (this.receiveBuffer.length > 0) {
      throw new Error('Cannot enable AirPlay control encryption with unparsed plaintext data');
    }
    this.cipher = new AirPlayControlCipher(readKey, writeKey);
  }

  async close(): Promise<void> {
    this.failPending(new Error('AirPlay RTSP connection closed'));
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
    try {
      await socket.close();
    } catch (error) {
      failures.push(`socket close: ${error instanceof Error ? error.message : String(error)}`);
    }
    if (failures.length > 0) {
      throw new Error(`AirPlay RTSP cleanup failed (${failures.join('; ')})`);
    }
  }

  private async handleIncoming(data: Uint8Array): Promise<void> {
    const plaintext = this.cipher ? await this.cipher.decrypt(data) : data;
    if (plaintext.length === 0) {
      return;
    }
    if (this.receiveBuffer.length + plaintext.length > 1024 * 1024) {
      this.receiveBuffer = new Uint8Array(0);
      throw new Error('AirPlay RTSP response exceeded the 1 MiB safety limit');
    }
    this.receiveBuffer = concatBytes(this.receiveBuffer, plaintext);
    this.parseResponse();
  }

  private parseResponse(): void {
    while (this.pending) {
      const headerEnd = findHeaderEnd(this.receiveBuffer);
      if (headerEnd < 0) {
        return;
      }
      const headerText = decodeUtf8(this.receiveBuffer.slice(0, headerEnd));
      const lines = headerText.split('\r\n');
      const statusLine = lines[0] ?? '';
      const statusCode = parseStatusCode(statusLine);
      const headers: Map<string, string> = new Map<string, string>();
      for (let index = 1; index < lines.length; index++) {
        const line = lines[index];
        const separator = line.indexOf(':');
        if (separator > 0) {
          headers.set(line.slice(0, separator).trim().toLowerCase(), line.slice(separator + 1).trim());
        }
      }
      if (headers.has('transfer-encoding')) {
        throw new Error('Chunked RTSP response bodies are not supported');
      }
      const contentLengthValue = headers.get('content-length') ?? '0';
      const contentLength = Number.parseInt(contentLengthValue, 10);
      if (!Number.isFinite(contentLength) || contentLength < 0 || contentLength > 1024 * 1024) {
        throw new Error(`Invalid AirPlay RTSP Content-Length: ${contentLengthValue}`);
      }
      const bodyStart = headerEnd + 4;
      const responseLength = bodyStart + contentLength;
      if (this.receiveBuffer.length < responseLength) {
        return;
      }
      const cseqValue = headers.get('cseq');
      if (cseqValue && Number.parseInt(cseqValue, 10) !== this.pending.cseq) {
        throw new Error(`AirPlay RTSP CSeq mismatch: expected ${this.pending.cseq}, got ${cseqValue}`);
      }
      const response: AirPlayRtspResponse = {
        statusCode,
        statusLine,
        headers,
        body: this.receiveBuffer.slice(bodyStart, responseLength)
      };
      this.receiveBuffer = this.receiveBuffer.slice(responseLength);
      this.resolvePending(response);
    }
  }

  private resolvePending(response: AirPlayRtspResponse): void {
    const pending = this.pending;
    if (!pending) {
      throw new Error('Received an unsolicited AirPlay RTSP response');
    }
    clearTimeout(pending.timeoutId);
    this.pending = undefined;
    pending.resolve(response);
  }

  private failPending(error: Error): void {
    const pending = this.pending;
    if (!pending) {
      return;
    }
    clearTimeout(pending.timeoutId);
    this.pending = undefined;
    pending.reject(error);
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

function parseStatusCode(statusLine: string): number {
  const parts = statusLine.split(' ');
  if (parts.length < 2) {
    throw new Error(`Invalid AirPlay RTSP status line: ${statusLine}`);
  }
  const statusCode = Number.parseInt(parts[1], 10);
  if (!Number.isFinite(statusCode)) {
    throw new Error(`Invalid AirPlay RTSP status code: ${statusLine}`);
  }
  return statusCode;
}
