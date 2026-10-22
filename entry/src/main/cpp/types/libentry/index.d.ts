export interface ScreenCaptureBuffer {
  kind: 'buffer';
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
  ScreenCaptureBuffer | ScreenCaptureState | ScreenCaptureError | ScreenCaptureOverflow;

export interface NativeScreenCapture {
  startCapture(width: number, height: number, displayId: number,
    callback: (event: ScreenCaptureEvent) => void): void;
  stopCapture(): void;
}

declare const nativeScreenCapture: NativeScreenCapture;
export default nativeScreenCapture;
