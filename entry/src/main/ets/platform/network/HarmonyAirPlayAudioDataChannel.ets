import { socket } from '@kit.NetworkKit';
import { AirPlayAudioProfile } from '../../protocol/airplay/AirPlayAudioProfileProtocol';
import { AirPlayAudioSyncPacket } from '../../protocol/airplay/AirPlayAudioSyncPacket';
import { AirPlayMediaPacketCodec } from '../../protocol/airplay/AirPlayMediaPacketCodec';

const MAX_AAC_ACCESS_UNIT_BYTES = 256 * 1024;
const AUDIO_SYNC_INTERVAL_MS = 1000;

export class HarmonyAirPlayAudioDataChannel {
  private readonly host: string;
  private readonly dataPort: number;
  private readonly controlPort: number;
  private readonly profile: AirPlayAudioProfile;
  private readonly streamKey: Uint8Array;
  private readonly log: (message: string) => void;
  private udp: socket.UDPSocket | undefined = undefined;
  private sendQueue: Promise<void> = Promise.resolve();
  private sequence: number = 0;
  private syncSequence: number = 0;
  private timestamp: number = 0;
  private nonceCounter: number = 0;
  private lastSyncAt: number = 0;
  private firstAudioPacket: boolean = true;
  private firstSyncPacket: boolean = true;
  private closed: boolean = false;

  constructor(
    host: string,
    dataPort: number,
    controlPort: number,
    profile: AirPlayAudioProfile,
    streamKey: Uint8Array,
    log: (message: string) => void
  ) {
    if (host.length === 0 || !Number.isInteger(dataPort) || dataPort < 1 || dataPort > 65535 ||
      !Number.isInteger(controlPort) || controlPort < 0 || controlPort > 65535 ||
      streamKey.length !== 32 || profile.streamType < 1 || profile.streamType > 127 ||
      profile.samplesPerFrame < 1) {
      throw new Error('AirPlay AAC data-channel parameters are invalid.');
    }
    this.host = host;
    this.dataPort = dataPort;
    this.controlPort = controlPort;
    this.profile = profile;
    this.streamKey = streamKey.slice();
    this.log = log;
  }

  async start(): Promise<void> {
    if (this.udp !== undefined || this.closed) {
      throw new Error('AirPlay audio data channel cannot be started in its current state.');
    }
    const udp = socket.constructUDPSocketInstance();
    try {
      await udp.bind({ address: '0.0.0.0', port: 0 });
      this.udp = udp;
      this.log(`AirPlay AAC audio UDP channel ready: ${this.host}:${this.dataPort}.`);
    } catch (error) {
      try {
        await udp.close();
      } catch (closeError) {
        this.log(`AirPlay audio UDP rollback failed: ${closeError instanceof Error ? closeError.message : String(closeError)}`);
      }
      throw new Error(`Failed to bind AirPlay audio UDP channel: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  sendFrame(encodedFrame: Uint8Array): Promise<void> {
    if (this.closed || this.udp === undefined) {
      return Promise.reject(new Error('AirPlay audio data channel is not active.'));
    }
    if (encodedFrame.length === 0 || encodedFrame.length > MAX_AAC_ACCESS_UNIT_BYTES) {
      return Promise.reject(new Error('AirPlay AAC access unit is empty or oversized.'));
    }
    const frame = encodedFrame.slice();
    const operation = this.sendQueue.then(async (): Promise<void> => {
      const udp = this.udp;
      if (this.closed || udp === undefined) {
        throw new Error('AirPlay audio data channel closed before sending.');
      }
      const accessUnit = HarmonyAirPlayAudioDataChannel.stripAdtsHeader(frame);
      try {
        const now = Date.now();
        if (this.controlPort > 0 &&
          (this.lastSyncAt === 0 || now - this.lastSyncAt >= AUDIO_SYNC_INTERVAL_MS)) {
          await this.sendSyncPacket(udp, now);
        }
        if (this.nonceCounter >= Number.MAX_SAFE_INTEGER) {
          throw new Error('AirPlay audio nonce counter is exhausted.');
        }
        const packet = await AirPlayMediaPacketCodec.sealAudioPacket(
          accessUnit,
          this.streamKey,
          this.sequence,
          this.timestamp,
          this.nonceCounter,
          this.profile.streamType,
          this.firstAudioPacket,
          false
        );
        try {
          await HarmonyAirPlayAudioDataChannel.sendDatagram(udp, packet, this.host, this.dataPort);
        } finally {
          packet.fill(0);
        }
        this.sequence = (this.sequence + 1) & 0xFFFF;
        this.timestamp = (this.timestamp + this.profile.samplesPerFrame) >>> 0;
        this.nonceCounter++;
        this.firstAudioPacket = false;
      } finally {
        accessUnit.fill(0);
      }
    }).catch((error: Error) => {
      throw error instanceof Error ? error : new Error(`AirPlay AAC frame send failed: ${String(error)}`);
    }).finally(() => {
      frame.fill(0);
    });
    this.sendQueue = operation.then(() => {}, () => {});
    return operation;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    await this.sendQueue;
    const udp = this.udp;
    this.udp = undefined;
    try {
      if (udp !== undefined) {
        await udp.close();
      }
    } catch (error) {
      throw new Error(`Failed to close AirPlay audio UDP channel: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      this.streamKey.fill(0);
      this.timestamp = 0;
      this.nonceCounter = 0;
    }
  }

  private async sendSyncPacket(udp: socket.UDPSocket, nowMillis: number): Promise<void> {
    const nextTimestamp = (this.timestamp + this.profile.samplesPerFrame) >>> 0;
    const packet = AirPlayAudioSyncPacket.build(
      this.syncSequence,
      this.timestamp,
      nextTimestamp,
      nowMillis,
      this.firstSyncPacket
    );
    try {
      await HarmonyAirPlayAudioDataChannel.sendDatagram(udp, packet, this.host, this.controlPort);
      this.syncSequence = (this.syncSequence + 1) & 0xFFFF;
      this.lastSyncAt = nowMillis;
      this.firstSyncPacket = false;
    } finally {
      packet.fill(0);
    }
  }

  private static async sendDatagram(
    udp: socket.UDPSocket,
    packet: Uint8Array,
    host: string,
    port: number
  ): Promise<void> {
    const data = new ArrayBuffer(packet.length);
    new Uint8Array(data).set(packet);
    await udp.send({ data, address: { address: host, port } });
  }

  private static stripAdtsHeader(frame: Uint8Array): Uint8Array {
    if (frame.length < 7 || frame[0] !== 0xFF || (frame[1] & 0xF6) !== 0xF0) {
      return frame.slice();
    }
    const headerLength = (frame[1] & 1) !== 0 ? 7 : 9;
    const frameLength = ((frame[3] & 3) << 11) | (frame[4] << 3) | (frame[5] >>> 5);
    if (frameLength !== frame.length || headerLength >= frameLength) {
      throw new Error('Harmony AAC capture returned a malformed ADTS access unit.');
    }
    return frame.slice(headerLength);
  }
}
