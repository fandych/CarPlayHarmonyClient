import netSocket from '@ohos.net.socket';
import { chachaSeal } from '../crypto/AirPlayStreamCrypto';
import { concatBytes, toArrayBuffer } from '../protocol/Iap2Codec';

export interface AudioRtpSession {
  host: string;
  dataPort: number;
  controlPort: number;
  streamKey: Uint8Array;
  sampleRate: number;
}

const CHANNELS: number = 2;
const SAMPLES_PER_PACKET: number = 352;
const PCM_BYTES_PER_PACKET: number = SAMPLES_PER_PACKET * CHANNELS * 2;

export function buildAudioRtpHeader(sequence: number, timestamp: number, marker: boolean): Uint8Array {
  const header = new Uint8Array(12);
  header[0] = 0x80;
  header[1] = (marker ? 0x80 : 0) | 100;
  writeBe16(header, 2, sequence);
  writeBe32(header, 4, timestamp);
  writeBe32(header, 8, 0);
  return header;
}

export class AudioRtpSender {
  private socket?: netSocket.UDPSocket;
  private readonly log: (message: string) => void;
  private readonly onError: (message: string) => void;
  private session?: AudioRtpSession;
  private pendingPcm: Uint8Array = new Uint8Array(0);
  private sendQueue: Promise<void> = Promise.resolve();
  private sequence: number = 0;
  private timestamp: number = 0;
  private nonceCounter: number = 0;
  private syncSequence: number = 0;
  private firstPacket: boolean = true;
  private firstSync: boolean = true;
  private running: boolean = false;
  private syncTimer: number = -1;

  constructor(log: (message: string) => void, onError: (message: string) => void) {
    this.log = log;
    this.onError = onError;
  }

  async start(session: AudioRtpSession): Promise<void> {
    if (this.running) {
      throw new Error('Audio RTP sender is already running');
    }
    if (!session.host || session.dataPort < 1 || session.dataPort > 65535 ||
      session.controlPort < 0 || session.controlPort > 65535 || session.streamKey.length !== 32 ||
      (session.sampleRate !== 44100 && session.sampleRate !== 48000)) {
      throw new Error('Invalid AirPlay audio stream configuration');
    }
    const socket = netSocket.constructUDPSocketInstance();
    try {
      await socket.bind({ address: '0.0.0.0', port: 0 });
    } catch (error) {
      try {
        await socket.close();
      } catch (cleanupError) {
        this.onError(`Audio RTP socket cleanup failed: ${cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError)}`);
      }
      throw new Error(`Audio RTP socket bind failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    this.socket = socket;
    this.session = session;
    this.running = true;
    this.syncTimer = setInterval((): void => {
      void this.sendSync().catch((error: Error): void => this.onError(`AirPlay audio sync failed: ${error.message}`));
    }, 1000);
    this.log(`Audio RTP sender ready for ${session.host}:${session.dataPort}`);
  }

  pushPcm(data: Uint8Array): void {
    if (!this.running) {
      throw new Error('Audio RTP sender is not running');
    }
    if (data.length + this.pendingPcm.length > 1024 * 1024) {
      this.pendingPcm = new Uint8Array(0);
      throw new Error('Audio input exceeded the 1 MiB safety limit');
    }
    this.pendingPcm = concatBytes(this.pendingPcm, data);
    while (this.pendingPcm.length >= PCM_BYTES_PER_PACKET) {
      const pcm = this.pendingPcm.slice(0, PCM_BYTES_PER_PACKET);
      this.pendingPcm = this.pendingPcm.slice(PCM_BYTES_PER_PACKET);
      const bigEndianPcm = toBigEndianS16(pcm);
      this.sendQueue = this.sendQueue
        .then((): Promise<void> => this.sendPacket(bigEndianPcm))
        .catch((error: Error): void => {
          this.onError(`AirPlay audio packet failed: ${error.message}`);
        });
    }
  }

  async stop(): Promise<void> {
    this.running = false;
    if (this.syncTimer >= 0) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
    await this.sendQueue;
    const socket = this.socket;
    this.socket = undefined;
    this.session = undefined;
    this.pendingPcm = new Uint8Array(0);
    if (socket) {
      await socket.close();
    }
    this.log('Audio RTP sender stopped');
  }

  private async sendPacket(pcm: Uint8Array): Promise<void> {
    const socket = this.socket;
    const session = this.session;
    if (!socket || !session || !this.running) {
      return;
    }
    const header = buildAudioRtpHeader(this.sequence, this.timestamp, this.firstPacket);
    const nonce = nonce64(this.nonceCounter);
    const aad = header.slice(4, 12);
    const encrypted = await chachaSeal(session.streamKey, nonce, pcm, aad);
    const suffix = nonce.slice(4, 12);
    const datagram = concatBytes(header, encrypted, suffix);
    const options: netSocket.UDPSendOptions = {
      data: toArrayBuffer(datagram),
      address: { address: session.host, port: session.dataPort }
    };
    await socket.send(options);
    this.sequence = (this.sequence + 1) & 0xffff;
    this.timestamp = (this.timestamp + SAMPLES_PER_PACKET) >>> 0;
    this.nonceCounter++;
    this.firstPacket = false;
  }

  private async sendSync(): Promise<void> {
    const socket = this.socket;
    const session = this.session;
    if (!socket || !session || !this.running || session.controlPort < 1) {
      return;
    }
    const current = this.timestamp;
    const packet = new Uint8Array(20);
    packet[0] = this.firstSync ? 0x90 : 0x80;
    packet[1] = 0xd4;
    writeBe16(packet, 2, this.syncSequence++);
    writeBe32(packet, 4, current);
    packet.set(ntpNow(), 8);
    writeBe32(packet, 16, (current + SAMPLES_PER_PACKET) >>> 0);
    const options: netSocket.UDPSendOptions = {
      data: toArrayBuffer(packet),
      address: { address: session.host, port: session.controlPort }
    };
    await socket.send(options);
    this.firstSync = false;
  }
}

function toBigEndianS16(source: Uint8Array): Uint8Array {
  const result = new Uint8Array(source.length);
  for (let index = 0; index + 1 < source.length; index += 2) {
    result[index] = source[index + 1];
    result[index + 1] = source[index];
  }
  return result;
}

function nonce64(counter: number): Uint8Array {
  const nonce = new Uint8Array(12);
  let remaining = counter;
  for (let index = 4; index < 12; index++) {
    nonce[index] = remaining & 0xff;
    remaining = Math.floor(remaining / 256);
  }
  return nonce;
}

function ntpNow(): Uint8Array {
  const now = Date.now();
  const seconds = Math.floor(now / 1000) + 2208988800;
  const fraction = Math.floor(((now % 1000) * 0x100000000) / 1000);
  const result = new Uint8Array(8);
  writeBe32(result, 0, seconds);
  writeBe32(result, 4, fraction);
  return result;
}

function writeBe16(target: Uint8Array, offset: number, value: number): void {
  target[offset] = (value >>> 8) & 0xff;
  target[offset + 1] = value & 0xff;
}

function writeBe32(target: Uint8Array, offset: number, value: number): void {
  target[offset] = (value >>> 24) & 0xff;
  target[offset + 1] = (value >>> 16) & 0xff;
  target[offset + 2] = (value >>> 8) & 0xff;
  target[offset + 3] = value & 0xff;
}
