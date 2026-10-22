export interface ScreenCaptureBuffer {
  kind: 'buffer';
  data: ArrayBuffer;
  flags: number;
  timestamp: number;
}

export interface ScreenCaptureAudioBuffer {
  kind: 'audio';
  data: ArrayBuffer;
  flags: number;
  timestamp: number;
}

export interface ScreenCaptureState {
  kind: 'state';
  state: number;
}

export interface ScreenCaptureError {
  kind: 'error';
  code: number;
}

export interface ScreenCaptureOverflow {
  kind: 'overflow';
  dropped: number;
}

export type ScreenCaptureEvent =
  ScreenCaptureBuffer | ScreenCaptureAudioBuffer | ScreenCaptureState | ScreenCaptureError | ScreenCaptureOverflow;

export interface NativeScreenCapture {
  startCapture(width: number, height: number, displayId: number, audioSampleRate: number,
    callback: (event: ScreenCaptureEvent) => void): void;
  stopCapture(): void;
  createVirtualSurface(width: number, height: number): string;
  destroyVirtualSurface(): void;
}

declare const nativeScreenCapture: NativeScreenCapture;
export default nativeScreenCapture;
