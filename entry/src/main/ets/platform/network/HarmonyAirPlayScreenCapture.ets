import nativeScreenCapture, { ScreenCaptureEvent } from 'libentry.so';
import { AirPlayMediaPacketCodec } from '../../protocol/airplay/AirPlayMediaPacketCodec';

const CODEC_DATA_FLAG = 1 << 3;
const INCOMPLETE_FRAME_FLAG = 1 << 2;
const MAX_ENCODED_FRAME_BYTES = 4 * 1024 * 1024;
const MAX_PENDING_CAPTURE_EVENTS = 8;

export interface HarmonyAirPlayScreenCaptureCallbacks {
  onCodecData(data: Uint8Array): Promise<void>;
  onFrame(data: Uint8Array, timestamp: number): Promise<void>;
  onState(state: number): void;
  onError(error: Error): void;
}

export class HarmonyAirPlayScreenCapture {
  private readonly width: number;
  private readonly height: number;
  private readonly displayId: number;
  private readonly callbacks: HarmonyAirPlayScreenCaptureCallbacks;
  private processing: Promise<void> = Promise.resolve();
  private pendingEvents: number = 0;
  private codecDataFragments: Uint8Array[] = [];
  private pendingCodecUnits: Uint8Array[] = [];
  private videoFrameFragments: Uint8Array[] = [];
  private codecDataLength: number = 0;
  private pendingCodecLength: number = 0;
  private videoFrameLength: number = 0;
  private started: boolean = false;
  private failed: boolean = false;
  private closed: boolean = false;

  constructor(
    width: number,
    height: number,
    displayId: number,
    callbacks: HarmonyAirPlayScreenCaptureCallbacks
  ) {
    this.width = width;
    this.height = height;
    this.displayId = displayId;
    this.callbacks = callbacks;
  }

  start(): void {
    if (this.closed || this.failed || this.started) {
      throw new Error('HarmonyOS screen capture is already started or closed.');
    }
    nativeScreenCapture.startCapture(this.width, this.height, this.displayId, (event: ScreenCaptureEvent) => {
      this.enqueue(event);
    });
    this.started = true;
  }

  async stop(): Promise<void> {
    if (this.closed) {
      return;
    }
    if (this.started) {
      nativeScreenCapture.stopCapture();
      this.started = false;
    }
    this.closed = true;
    await this.processing;
    this.clearFragments();
  }

  private enqueue(event: ScreenCaptureEvent): void {
    if (this.closed || this.failed) {
      this.clearEvent(event);
      return;
    }
    if (this.pendingEvents >= MAX_PENDING_CAPTURE_EVENTS) {
      this.clearEvent(event);
      this.fail(new Error('The H.264 processing queue is overloaded; screen sharing was stopped.'));
      return;
    }
    this.pendingEvents++;
    this.processing = this.processing.then(async (): Promise<void> => {
      try {
        if (this.closed || this.failed) {
          this.clearEvent(event);
        } else {
          await this.consume(event);
        }
      } catch (error) {
        this.fail(error instanceof Error ? error : new Error(String(error)));
      } finally {
        this.pendingEvents--;
      }
    });
  }

  private clearEvent(event: ScreenCaptureEvent): void {
    if (event.kind === 'buffer') {
      new Uint8Array(event.data).fill(0);
    }
  }

  private fail(error: Error): void {
    if (this.failed || this.closed) {
      return;
    }
    this.failed = true;
    this.clearFragments();
    if (this.started) {
      try {
        nativeScreenCapture.stopCapture();
        this.started = false;
      } catch (stopError) {
        const detail = stopError instanceof Error ? stopError.message : String(stopError);
        this.callbacks.onError(new Error(`${error.message}; failed to stop screen capture: ${detail}`));
        return;
      }
    }
    this.callbacks.onError(error);
  }

  private async consume(event: ScreenCaptureEvent): Promise<void> {
    if (event.kind === 'state') {
      this.callbacks.onState(event.state);
      if (event.state === 1 || event.state === 2 || event.state === 3 ||
        event.state === 4 || event.state === 10) {
        nativeScreenCapture.stopCapture();
        this.started = false;
        this.clearFragments();
      }
      return;
    }
    if (event.kind === 'error') {
      throw new Error(`HarmonyOS screen capture failed with code ${event.code}.`);
    }
    if (event.kind === 'overflow') {
      throw new Error(`The H.264 callback queue overflowed and dropped ${event.dropped} encoded buffers.`);
    }

    const eventBytes = new Uint8Array(event.data);
    const data = eventBytes.slice();
    eventBytes.fill(0);
    if (data.length === 0) {
      return;
    }
    if ((event.flags & CODEC_DATA_FLAG) !== 0) {
      this.codecDataFragments.push(data);
      this.codecDataLength += data.length;
      this.requireFragmentLimit(this.codecDataLength);
      if ((event.flags & INCOMPLETE_FRAME_FLAG) === 0) {
        const codecData = this.joinFragments(this.codecDataFragments, this.codecDataLength);
        this.codecDataFragments = [];
        this.codecDataLength = 0;
        if (AirPlayMediaPacketCodec.isAvcConfigurationRecord(codecData)) {
          try {
            await this.callbacks.onCodecData(codecData);
          } finally {
            codecData.fill(0);
          }
        } else {
          let normalized = new Uint8Array(0);
          try {
            normalized = AirPlayMediaPacketCodec.normalizeAnnexB(codecData);
          } finally {
            codecData.fill(0);
          }
          this.pendingCodecUnits.push(normalized);
          this.pendingCodecLength += normalized.length;
          this.requireFragmentLimit(this.pendingCodecLength);
          const combined = this.concat(this.pendingCodecUnits, this.pendingCodecLength);
          const units = AirPlayMediaPacketCodec.splitAnnexB(combined);
          const hasSps = units.some((unit: Uint8Array) => unit.length > 0 && (unit[0] & 0x1F) === 7);
          const hasPps = units.some((unit: Uint8Array) => unit.length > 0 && (unit[0] & 0x1F) === 8);
          if (hasSps && hasPps) {
            this.clearPendingCodecUnits();
            try {
              await this.callbacks.onCodecData(combined);
            } finally {
              combined.fill(0);
            }
          } else {
            combined.fill(0);
          }
        }
      }
      return;
    }

    this.videoFrameFragments.push(data);
    this.videoFrameLength += data.length;
    this.requireFragmentLimit(this.videoFrameLength);
    if ((event.flags & INCOMPLETE_FRAME_FLAG) === 0) {
      const frame = this.joinFragments(this.videoFrameFragments, this.videoFrameLength);
      this.videoFrameFragments = [];
      this.videoFrameLength = 0;
      try {
        await this.callbacks.onFrame(frame, event.timestamp);
      } finally {
        frame.fill(0);
      }
    }
  }

  private requireFragmentLimit(length: number): void {
    if (length > MAX_ENCODED_FRAME_BYTES) {
      this.clearFragments();
      throw new Error('HarmonyOS screen encoder produced an oversized H.264 frame.');
    }
  }

  private joinFragments(fragments: Uint8Array[], length: number): Uint8Array {
    const result = new Uint8Array(length);
    let offset = 0;
    for (const fragment of fragments) {
      result.set(fragment, offset);
      offset += fragment.length;
      fragment.fill(0);
    }
    return result;
  }

  private concat(fragments: Uint8Array[], length: number): Uint8Array {
    const result = new Uint8Array(length);
    let offset = 0;
    for (const fragment of fragments) {
      result.set(fragment, offset);
      offset += fragment.length;
    }
    return result;
  }

  private clearPendingCodecUnits(): void {
    this.pendingCodecUnits.forEach((unit: Uint8Array) => unit.fill(0));
    this.pendingCodecUnits = [];
    this.pendingCodecLength = 0;
  }

  private clearFragments(): void {
    this.codecDataFragments.forEach((fragment: Uint8Array) => fragment.fill(0));
    this.videoFrameFragments.forEach((fragment: Uint8Array) => fragment.fill(0));
    this.clearPendingCodecUnits();
    this.codecDataFragments = [];
    this.videoFrameFragments = [];
    this.codecDataLength = 0;
    this.videoFrameLength = 0;
  }
}
