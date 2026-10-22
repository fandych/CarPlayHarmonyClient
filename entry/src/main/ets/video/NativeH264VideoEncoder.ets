import nativeProjection from 'libprojection.so';
import { EncodedH264Event } from '../airplay/AirPlayVideoStream';

interface VideoEncoderHandle {
  handle: number;
  surfaceId: string;
}

interface NativeProjectionModule {
  createVideoEncoder(
    width: number,
    height: number,
    frameRate: number,
    bitrate: number,
    onEvent: (event: EncodedH264Event) => void
  ): VideoEncoderHandle;
  stopVideoEncoder(handle: number): void;
  requestKeyFrame(handle: number): boolean;
}

const nativeApi = nativeProjection as NativeProjectionModule;

export interface H264EncoderConfig {
  width: number;
  height: number;
  frameRate: number;
  bitrate: number;
}

export class NativeH264VideoEncoder {
  private encoder?: VideoEncoderHandle;

  start(config: H264EncoderConfig, onEvent: (event: EncodedH264Event) => void): string {
    if (this.encoder) {
      throw new Error('H.264 encoder is already running');
    }
    const encoder = nativeApi.createVideoEncoder(
      config.width,
      config.height,
      config.frameRate,
      config.bitrate,
      onEvent
    );
    this.encoder = encoder;
    return encoder.surfaceId;
  }

  requestKeyFrame(): boolean {
    const encoder = this.encoder;
    return encoder ? nativeApi.requestKeyFrame(encoder.handle) : false;
  }

  stop(): void {
    const encoder = this.encoder;
    this.encoder = undefined;
    if (encoder) {
      nativeApi.stopVideoEncoder(encoder.handle);
    }
  }
}
