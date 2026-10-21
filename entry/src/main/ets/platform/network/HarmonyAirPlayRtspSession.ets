import { socket } from '@kit.NetworkKit';
import { AirPlayControlKeys } from '../../protocol/airplay/AirPlayPairingClient';
import { AirPlayControlCipher } from '../../protocol/airplay/AirPlayControlCipher';
import { RtspRequestEncoder, RtspRequestHeader } from '../../protocol/airplay/RtspRequestEncoder';
import { RtspResponse, RtspResponseParser } from '../../protocol/airplay/RtspResponseParser';
import { AirPlayServiceEndpoint } from './HarmonyMdnsBrowser';

const REQUEST_TIMEOUT_MS = 5000;

interface PendingResponse {
  cseq: number;
  resolve: (response: RtspResponse) => void;
  reject: (error: Error) => void;
  timeout: number;
}

export class HarmonyAirPlayRtspSession {
  private readonly client: socket.TCPSocket = socket.constructTCPSocketInstance();
  private readonly parser: RtspResponseParser = new RtspResponseParser();
  private incomingQueue: Promise<void> = Promise.resolve();
  private controlCipher: AirPlayControlCipher | undefined = undefined;
  private pending: PendingResponse | undefined = undefined;
  private nextCseq: number = 1;
  private connected: boolean = false;
  private closed: boolean = false;
  private terminalError: Error | undefined = undefined;

  private readonly messageListener = (event: socket.SocketMessageInfo): void => {
    const bytes = new Uint8Array(event.message).slice();
    this.incomingQueue = this.incomingQueue.then(async (): Promise<void> => {
      const plaintext = this.controlCipher === undefined ? bytes : await this.controlCipher.decrypt(bytes);
      if (plaintext.length === 0) {
        return;
      }
      const responses = this.parser.offer(plaintext);
      responses.forEach((response: RtspResponse) => this.resolveResponse(response));
    }).catch((error: Error) => {
      this.failPending(error instanceof Error ? error : new Error('Malformed RTSP response.'));
    });
  };

  private readonly errorListener = (error: Error): void => {
    this.failPending(error);
  };

  async connect(endpoint: AirPlayServiceEndpoint): Promise<void> {
    if (this.connected || this.closed) {
      throw new Error('RTSP session cannot be connected in its current state.');
    }
    if (endpoint.host.length === 0 || !Number.isInteger(endpoint.port) ||
      endpoint.port < 1 || endpoint.port > 65535) {
      throw new Error('Invalid AirPlay RTSP endpoint.');
    }

    this.client.on('message', this.messageListener);
    this.client.on('error', this.errorListener);
    try {
      await this.client.connect({
        address: {
          address: endpoint.host,
          port: endpoint.port
        },
        timeout: REQUEST_TIMEOUT_MS
      });
      this.connected = true;
    } catch (error) {
      this.detachListeners();
      this.terminalError = error instanceof Error ? error : new Error('AirPlay RTSP connection failed.');
      throw error instanceof Error ? error : new Error('AirPlay RTSP connection failed.');
    }
  }

  async request(
    method: string,
    target: string,
    body: Uint8Array = new Uint8Array(0),
    headers: RtspRequestHeader[] = []
  ): Promise<RtspResponse> {
    if (!this.connected || this.closed || this.terminalError !== undefined) {
      throw new Error('RTSP session is not connected.');
    }
    if (this.pending !== undefined) {
      throw new Error('An RTSP request is already awaiting a response.');
    }

    const cseq = this.nextCseq++;
    const request = RtspRequestEncoder.encode(method, target, cseq, body, [
      { name: 'User-Agent', value: 'CarPlayHarmonyClient/1.0' },
      ...headers
    ]);
    const responsePromise = new Promise<RtspResponse>((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (this.pending?.cseq === cseq) {
          this.pending = undefined;
          this.terminalError = new Error(`RTSP request ${cseq} timed out.`);
          reject(this.terminalError);
        }
      }, REQUEST_TIMEOUT_MS);
      this.pending = { cseq, resolve, reject, timeout };
    });

    try {
      const cipher = this.controlCipher;
      const wireRequest = cipher === undefined ? request : await cipher.encrypt(request);
      if (!this.hasPendingRequest(cseq)) {
        return responsePromise;
      }
      const data = new ArrayBuffer(wireRequest.length);
      new Uint8Array(data).set(wireRequest);
      await this.client.send({ data });
    } catch (error) {
      this.failPending(error instanceof Error ? error : new Error('RTSP request send failed.'));
    }
    return responsePromise;
  }

  enableControlEncryption(keys: AirPlayControlKeys): void {
    if (!this.connected || this.closed || this.terminalError !== undefined ||
      this.pending !== undefined || this.controlCipher !== undefined) {
      throw new Error('RTSP control encryption cannot be enabled in the current session state.');
    }
    this.controlCipher = new AirPlayControlCipher(keys);
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.failPending(new Error('RTSP session closed before the response arrived.'));
    this.detachListeners();
    try {
      await this.client.close();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to close AirPlay RTSP socket: ${detail}`);
    }
  }

  private resolveResponse(response: RtspResponse): void {
    const pending = this.pending;
    if (pending === undefined || response.headers.get('cseq') !== `${pending.cseq}`) {
      this.failPending(new Error('AirPlay RTSP response did not match the outstanding CSeq.'));
      return;
    }
    this.pending = undefined;
    clearTimeout(pending.timeout);
    pending.resolve(response);
  }

  private hasPendingRequest(cseq: number): boolean {
    const pending = this.pending;
    return pending !== undefined && pending.cseq === cseq;
  }

  private failPending(error: Error): void {
    this.terminalError = error;
    const pending = this.pending;
    if (pending === undefined) {
      return;
    }
    this.pending = undefined;
    clearTimeout(pending.timeout);
    pending.reject(error);
  }

  private detachListeners(): void {
    this.client.off('message', this.messageListener);
    this.client.off('error', this.errorListener);
  }
}
