import audio from '@ohos.multimedia.audio';

export type PcmDataHandler = (data: Uint8Array) => void;

export class PlaybackAudioCapture {
  private capturer?: audio.AudioCapturer;
  private readHandler?: (data: ArrayBuffer) => void;
  private readonly onPcmData: PcmDataHandler;
  private readonly onStatus: (status: string) => void;
  private readonly sampleRate: number;
  private started: boolean = false;

  constructor(onPcmData: PcmDataHandler, onStatus: (status: string) => void, sampleRate: number = 48000) {
    this.onPcmData = onPcmData;
    this.onStatus = onStatus;
    if (sampleRate !== 44100 && sampleRate !== 48000) {
      throw new Error(`Unsupported playback capture sample rate ${sampleRate}`);
    }
    this.sampleRate = sampleRate;
  }

  async requestStart(): Promise<void> {
    if (this.capturer) {
      throw new Error('播放音频采集已经初始化');
    }
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: this.sampleRate === 44100
        ? audio.AudioSamplingRate.SAMPLE_RATE_44100
        : audio.AudioSamplingRate.SAMPLE_RATE_48000,
      channels: audio.AudioChannel.CHANNEL_2,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_PLAYBACK_CAPTURE,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo,
      capturerInfo,
      playbackCaptureMode: audio.AudioPlaybackCaptureMode.MODE_MEDIA
    };
    const capturer = await audio.createAudioCapturer(options);
    this.capturer = capturer;
    this.readHandler = (data: ArrayBuffer): void => {
      this.onPcmData(new Uint8Array(data));
    };
    try {
      capturer.on('readData', this.readHandler);
      this.onStatus('等待系统授权播放音频捕获');
      capturer.requestPlaybackCaptureStart((state: audio.PlaybackCaptureStartState): void => {
        if (state !== audio.PlaybackCaptureStartState.STATE_SUCCESS) {
          this.onStatus(
            state === audio.PlaybackCaptureStartState.STATE_NOT_AUTHORIZED
              ? '播放音频捕获未获用户授权'
              : '播放音频捕获启动失败'
          );
          void this.stop().catch((error: Error): void => {
            this.onStatus(`清理音频捕获失败：${error.message}`);
          });
          return;
        }
        void this.startCapturer(capturer).catch((error: Error): void => {
          this.onStatus(`音频采集清理失败：${error.message}`);
        });
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await this.stop();
      throw new Error(`请求播放音频捕获失败：${message}`);
    }
  }

  async stop(): Promise<void> {
    const capturer = this.capturer;
    if (!capturer) {
      return;
    }
    const failures: string[] = [];
    if (this.readHandler) {
      try {
        capturer.off('readData', this.readHandler);
      } catch (error) {
        failures.push(error instanceof Error ? error.message : String(error));
      }
    }
    this.readHandler = undefined;
    this.capturer = undefined;
    if (this.started) {
      try {
        await capturer.stop();
      } catch (error) {
        failures.push(error instanceof Error ? error.message : String(error));
      }
    }
    this.started = false;
    try {
      await capturer.release();
    } catch (error) {
      failures.push(error instanceof Error ? error.message : String(error));
    }
    if (failures.length > 0) {
      throw new Error(`音频采集资源释放失败：${failures.join('; ')}`);
    }
    this.onStatus('播放音频捕获已停止');
  }

  private async startCapturer(capturer: audio.AudioCapturer): Promise<void> {
    try {
      await capturer.start();
      this.started = true;
      this.onStatus('已授权捕获播放音频；当前仅在本机统计 PCM，尚未推送到车机');
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.onStatus(`启动音频采集失败：${message}`);
      await this.stop();
    }
  }
}
