declare module 'libprojection.so' {
  export interface EncodedVideoEvent {
    type: 'codecConfig' | 'frame' | 'streamChanged' | 'error' | 'overflow';
    data?: Uint8Array;
    timestampUs: number;
    flags: number;
    message?: string;
  }

  export interface VideoEncoderHandle {
    handle: number;
    surfaceId: string;
  }

  export function createVideoEncoder(
    width: number,
    height: number,
    frameRate: number,
    bitrate: number,
    onEvent: (event: EncodedVideoEvent) => void
  ): VideoEncoderHandle;

  export function stopVideoEncoder(handle: number): void;

  export function requestKeyFrame(handle: number): boolean;
}
