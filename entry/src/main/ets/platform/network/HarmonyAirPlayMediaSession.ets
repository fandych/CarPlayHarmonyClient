import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BinaryPlist } from '../../protocol/airplay/BinaryPlist';
import {
  AirPlayInitialSetupInfo,
  AirPlayMediaSetupProtocol,
  AirPlayMediaStreamPorts,
  AirPlaySenderMetadata
} from '../../protocol/airplay/AirPlayMediaSetupProtocol';
import { AirPlayMediaPacketCodec } from '../../protocol/airplay/AirPlayMediaPacketCodec';
import {
  AirPlayEventCommand, AirPlayEventProtocol, AirPlayHidDevice, AirPlayReceiverDisplayInfo
} from '../../protocol/airplay/AirPlayEventProtocol';
import {
  AirPlayAudioProfile, AirPlayAudioProfileProtocol
} from '../../protocol/airplay/AirPlayAudioProfileProtocol';
import { HarmonyAirPlayAudioDataChannel } from './HarmonyAirPlayAudioDataChannel';
import { HarmonyAirPlayCrypto } from '../../protocol/airplay/HarmonyAirPlayCrypto';
import { AirPlayServiceEndpoint } from './HarmonyMdnsBrowser';
import { AirPlayVerifiedRtspSession, HarmonyAirPlayClient } from './HarmonyAirPlayClient';
import { HarmonyAirPlayKeepAliveClient } from './HarmonyAirPlayKeepAliveClient';
import { HarmonyAirPlayTimingServer } from './HarmonyAirPlayTimingServer';
import { HarmonyAirPlayEventChannel } from './HarmonyAirPlayEventChannel';
import {
  HarmonyAirPlayScreenCapture, HarmonyAirPlayScreenCaptureCallbacks
} from './HarmonyAirPlayScreenCapture';

const PLIST_CONTENT_TYPE = 'application/x-apple-binary-plist';
const FEEDBACK_INTERVAL_MS = 1000;
const VIDEO_KEEP_ALIVE_INTERVAL_MS = 1000;

class MediaScreenCaptureCallbacks implements HarmonyAirPlayScreenCaptureCallbacks {
  readonly onCodecData: (data: Uint8Array) => Promise<void>;
  readonly onFrame: (data: Uint8Array, timestamp: number) => Promise<void>;
  readonly onAudioFrame: (data: Uint8Array, timestamp: number) => Promise<void>;
  readonly onState: (state: number) => void;
  readonly onError: (error: Error) => void;

  constructor(
    onCodecData: (data: Uint8Array) => Promise<void>,
    onFrame: (data: Uint8Array, timestamp: number) => Promise<void>,
    onAudioFrame: (data: Uint8Array, timestamp: number) => Promise<void>,
    onState: (state: number) => void,
    onError: (error: Error) => void
  ) {
    this.onCodecData = onCodecData;
    this.onFrame = onFrame;
    this.onAudioFrame = onAudioFrame;
    this.onState = onState;
    this.onError = onError;
  }
}

class HarmonyAirPlayVideoDataChannel {
  private readonly client: socket.TCPSocket = socket.constructTCPSocketInstance();
  private readonly host: string;
  private readonly port: number;
  private readonly onError: (error: Error) => void;
  private connected: boolean = false;
  private closed: boolean = false;
  private terminalError: Error | undefined = undefined;
  private sendQueue: Promise<void> = Promise.resolve();
  private readonly errorListener: (error: Error) => void;

  constructor(host: string, port: number, onError: (error: Error) => void) {
    this.host = host;
    this.port = port;
    this.onError = onError;
    this.errorListener = (error: Error): void => {
      this.reportError(error);
    };
  }

  async connect(): Promise<void> {
    this.client.on('error', this.errorListener);
    try {
      await this.client.connect({
        address: { address: this.host, port: this.port },
        timeout: 5000
      });
      this.connected = true;
    } catch (error) {
      this.client.off('error', this.errorListener);
      throw error instanceof Error ? error : new Error('AirPlay video data channel connection failed.');
    }
  }

  send(packet: Uint8Array): Promise<void> {
    if (!this.connected || this.closed || this.terminalError !== undefined) {
      return Promise.reject(this.terminalError ?? new Error('AirPlay video data channel is not connected.'));
    }
    if (packet.length === 0) {
      return Promise.reject(new Error('AirPlay video packet cannot be empty.'));
    }
    const copy = packet.slice();
    const operation = this.sendQueue.then(async (): Promise<void> => {
      if (this.closed || this.terminalError !== undefined) {
        throw this.terminalError ?? new Error('AirPlay video data channel closed before sending.');
      }
      const data = new ArrayBuffer(copy.length);
      new Uint8Array(data).set(copy);
      await this.client.send({ data });
    }).catch((error: Error) => {
      const failure = error instanceof Error ? error : new Error('AirPlay video packet send failed.');
      this.reportError(failure);
      throw failure;
    }).finally(() => {
      copy.fill(0);
    });
    this.sendQueue = operation.catch(() => {});
    return operation;
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.connected = false;
    this.client.off('error', this.errorListener);
    await this.sendQueue;
    try {
      await this.client.close();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to close AirPlay video data channel: ${detail}`);
    }
  }

  private reportError(error: Error): void {
    if (this.closed || this.terminalError !== undefined) {
      return;
    }
    this.terminalError = error;
    this.onError(error);
  }
}

export class HarmonyAirPlayMediaSession {
  readonly displayUuid: string;
  readonly streamConnectionId: number;
  readonly initialSetupInfo: AirPlayInitialSetupInfo;
  readonly videoPorts: AirPlayMediaStreamPorts;
  private readonly verifiedSession: AirPlayVerifiedRtspSession;
  private readonly videoStreamKey: Uint8Array;
  private readonly timingServer: HarmonyAirPlayTimingServer;
  private readonly videoDataChannel: HarmonyAirPlayVideoDataChannel;
  private readonly audioDataChannel: HarmonyAirPlayAudioDataChannel | undefined;
  private readonly audioProfile: AirPlayAudioProfile | undefined;
  private readonly eventChannel: HarmonyAirPlayEventChannel | undefined;
  private readonly keepAliveClient: HarmonyAirPlayKeepAliveClient | undefined;
  private screenCapture: HarmonyAirPlayScreenCapture | undefined = undefined;
  private readonly log: (message: string) => void;
  private readonly onError: (error: Error) => void;
  private feedbackTimer: number | undefined = undefined;
  private videoKeepAliveTimer: number | undefined = undefined;
  private terminalError: Error | undefined = undefined;
  private videoConfigured: boolean = false;
  private frameCounter: number = 0;
  private closed: boolean = false;

  private constructor(
    displayUuid: string,
    streamConnectionId: number,
    initialSetupInfo: AirPlayInitialSetupInfo,
    videoPorts: AirPlayMediaStreamPorts,
    verifiedSession: AirPlayVerifiedRtspSession,
    videoStreamKey: Uint8Array,
    timingServer: HarmonyAirPlayTimingServer,
    videoDataChannel: HarmonyAirPlayVideoDataChannel,
    audioDataChannel: HarmonyAirPlayAudioDataChannel | undefined,
    audioProfile: AirPlayAudioProfile | undefined,
    eventChannel: HarmonyAirPlayEventChannel | undefined,
    keepAliveClient: HarmonyAirPlayKeepAliveClient | undefined,
    log: (message: string) => void,
    onError: (error: Error) => void
  ) {
    this.displayUuid = displayUuid;
    this.streamConnectionId = streamConnectionId;
    this.initialSetupInfo = initialSetupInfo;
    this.videoPorts = videoPorts;
    this.verifiedSession = verifiedSession;
    this.videoStreamKey = videoStreamKey;
    this.timingServer = timingServer;
    this.videoDataChannel = videoDataChannel;
    this.audioDataChannel = audioDataChannel;
    this.audioProfile = audioProfile;
    this.eventChannel = eventChannel;
    this.keepAliveClient = keepAliveClient;
    this.log = log;
    this.onError = onError;
  }

  static async establish(
    context: common.UIAbilityContext,
    endpoint: AirPlayServiceEndpoint,
    realBluetoothAddress: string,
    senderMetadata: AirPlaySenderMetadata,
    log: (message: string) => void,
    isActive: () => boolean,
    onError: (error: Error) => void = (error: Error) => log(`AirPlay media session failed: ${error.message}`),
    onEventCommand: (command: AirPlayEventCommand) => Promise<void> | void = () => {}
  ): Promise<HarmonyAirPlayMediaSession> {
    const client = new HarmonyAirPlayClient();
    const verifiedSession = await client.openVerifiedSession(context, endpoint, log);
    const timingServer = new HarmonyAirPlayTimingServer(log);
    let videoDataChannel: HarmonyAirPlayVideoDataChannel | undefined = undefined;
    let audioDataChannel: HarmonyAirPlayAudioDataChannel | undefined = undefined;
    let eventChannel: HarmonyAirPlayEventChannel | undefined = undefined;
    let keepAliveClient: HarmonyAirPlayKeepAliveClient | undefined = undefined;
    let audioProfile: AirPlayAudioProfile | undefined = undefined;
    try {
      HarmonyAirPlayMediaSession.requireActive(isActive);
      const infoResponse = await verifiedSession.request('GET', '/info');
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (infoResponse.statusCode !== 200) {
        throw new Error(`Verified AirPlay /info request returned ${infoResponse.statusCode}.`);
      }
      const displayInfo = HarmonyAirPlayMediaSession.readDisplayInfo(infoResponse.body);
      const displayUuid = displayInfo.uuid;
      const hidDevices = AirPlayEventProtocol.readHidDevices(infoResponse.body);
      log(`AirPlay /info exposed ${hidDevices.length} HID device(s).`);
      const audioProfiles = AirPlayAudioProfileProtocol.readAacCandidates(infoResponse.body);
      audioProfile = audioProfiles.length > 0 ? audioProfiles[0] : undefined;
      if (audioProfile === undefined) {
        log('AirPlay /info did not advertise an AAC-LC media profile; external playback audio will not be captured.');
      } else {
        log(`AirPlay selected AAC-LC media profile: type=${audioProfile.streamType}, ` +
          `rate=${audioProfile.sampleRate}, latency=${audioProfile.latencyMs}ms.`);
      }
      const timingPort = await timingServer.start();
      HarmonyAirPlayMediaSession.requireActive(isActive);
      const sessionUuid = await HarmonyAirPlayMediaSession.randomUuid();
      const correlationUuid = await HarmonyAirPlayMediaSession.randomUuid();
      const connectionId = await HarmonyAirPlayMediaSession.randomConnectionId();

      const initialResponse = await verifiedSession.request(
        'SETUP',
        '/setup',
        AirPlayMediaSetupProtocol.buildInitialSetupBody(
          realBluetoothAddress,
          timingPort,
          sessionUuid,
          correlationUuid,
          senderMetadata
        ),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (initialResponse.statusCode !== 200) {
        throw new Error(`AirPlay initial SETUP returned ${initialResponse.statusCode}.`);
      }
      const initialSetupInfo = AirPlayMediaSetupProtocol.parseInitialSetupResponse(initialResponse.body);
      if (initialSetupInfo.eventPort > 0) {
        eventChannel = await HarmonyAirPlayEventChannel.connect(
          endpoint.host,
          initialSetupInfo.eventPort,
          verifiedSession.controlKeys.sharedSecret,
          log,
          onError,
          (command: AirPlayEventCommand) => onEventCommand(
            AirPlayEventProtocol.enrichCommand(command, hidDevices, displayInfo)
          )
        );
        HarmonyAirPlayMediaSession.requireActive(isActive);
      } else {
        log('AirPlay initial SETUP omitted eventPort; no event channel was started.');
      }
      if (initialSetupInfo.keepAlivePort > 0) {
        keepAliveClient = new HarmonyAirPlayKeepAliveClient(endpoint.host, initialSetupInfo.keepAlivePort, (error) => {
          log(`AirPlay UDP keep-alive failed: ${error.message}`);
        });
        await keepAliveClient.start();
        HarmonyAirPlayMediaSession.requireActive(isActive);
      } else {
        log('AirPlay initial SETUP omitted keepAlivePort; no UDP keep-alive was started.');
      }

      const modesResponse = await verifiedSession.request(
        'POST',
        '/command',
        BinaryPlist.encode(AirPlayEventProtocol.buildModesChangedCommand()),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (modesResponse.statusCode === 200) {
        log('AirPlay modesChanged accepted; sender reserved main display and audio resources.');
      } else {
        log(`AirPlay modesChanged returned ${modesResponse.statusCode}; continuing for receiver compatibility.`);
      }

      const screenResponse = await verifiedSession.request(
        'SETUP',
        '/',
        AirPlayMediaSetupProtocol.buildScreenSetupBody(connectionId, displayUuid),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (screenResponse.statusCode !== 200) {
        throw new Error(`AirPlay screen SETUP returned ${screenResponse.statusCode}.`);
      }
      const videoPorts = AirPlayMediaSetupProtocol.parseStreamPorts(
        screenResponse.body,
        AirPlayMediaSetupProtocol.SCREEN_STREAM_TYPE
      );
      videoDataChannel = new HarmonyAirPlayVideoDataChannel(
        endpoint.host,
        videoPorts.dataPort,
        (error: Error) => onError(error)
      );
      await videoDataChannel.connect();
      HarmonyAirPlayMediaSession.requireActive(isActive);

      const recordResponse = await verifiedSession.request(
        'RECORD',
        '/',
        AirPlayMediaSetupProtocol.buildRecordBody(),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (recordResponse.statusCode !== 200) {
        throw new Error(`AirPlay RECORD returned ${recordResponse.statusCode}.`);
      }
      if (audioProfile !== undefined) {
        audioDataChannel = await HarmonyAirPlayMediaSession.establishAudioDataChannel(
          verifiedSession,
          endpoint.host,
          audioProfile,
          log,
          isActive
        );
        HarmonyAirPlayMediaSession.requireActive(isActive);
        if (audioDataChannel === undefined) {
          audioProfile = undefined;
        }
      }
      const videoStreamKey = await AirPlayMediaPacketCodec.deriveVideoStreamKey(
        verifiedSession.controlKeys.sharedSecret,
        connectionId
      );
      if (!isActive()) {
        videoStreamKey.fill(0);
        throw new Error('AirPlay media-session negotiation was cancelled.');
      }
      const mediaSession = new HarmonyAirPlayMediaSession(
        displayUuid,
        connectionId,
        initialSetupInfo,
        videoPorts,
        verifiedSession,
        videoStreamKey,
        timingServer,
        videoDataChannel,
        audioDataChannel,
        audioProfile,
        eventChannel,
        keepAliveClient,
        log,
        onError
      );
      if (eventChannel !== undefined) {
        for (const device of hidDevices) {
          if (device.descriptor === undefined || !AirPlayEventProtocol.isTouchDescriptor(device.descriptor)) {
            continue;
          }
          if (audioDataChannel !== undefined && audioProfile !== undefined) {
            log(`AirPlay AAC audio stream active: type=${audioProfile.streamType}, dataPort negotiated.`);
          }
          try {
            await eventChannel.sendCommand(AirPlayEventProtocol.buildHidSetInputModeCommand(device.uuid));
            log(`AirPlay touch HID input mode enabled for device ${device.uuid}.`);
          } catch (error) {
            const detail = error instanceof Error ? error.message : String(error);
            log(`Unable to enable AirPlay touch HID input for device ${device.uuid}: ${detail}`);
          }
        }
      }
      mediaSession.scheduleFeedback();
      mediaSession.scheduleVideoKeepAlive();
      log(`AirPlay screen session active: display=${displayUuid}, dataPort=${videoPorts.dataPort}.`);
      return mediaSession;
    } catch (error) {
      const cleanupErrors: string[] = [];
      if (audioDataChannel !== undefined) {
        try {
          await audioDataChannel.close();
        } catch (closeError) {
          cleanupErrors.push(closeError instanceof Error ? closeError.message : String(closeError));
        }
      }
      if (eventChannel !== undefined) {
        try {
          await eventChannel.close();
        } catch (closeError) {
          cleanupErrors.push(closeError instanceof Error ? closeError.message : String(closeError));
        }
      }
      if (keepAliveClient !== undefined) {
        try {
          await keepAliveClient.stop();
        } catch (closeError) {
          cleanupErrors.push(closeError instanceof Error ? closeError.message : String(closeError));
        }
      }
      if (videoDataChannel !== undefined) {
        try {
          await videoDataChannel.close();
        } catch (closeError) {
          cleanupErrors.push(closeError instanceof Error ? closeError.message : String(closeError));
        }
      }
      try {
        await timingServer.stop();
      } catch (closeError) {
        cleanupErrors.push(closeError instanceof Error ? closeError.message : String(closeError));
      }
      try {
        await verifiedSession.close();
      } catch (closeError) {
        cleanupErrors.push(closeError instanceof Error ? closeError.message : String(closeError));
      }
      HarmonyAirPlayMediaSession.clearControlKeys(verifiedSession);
      const detail = error instanceof Error ? error.message : String(error);
      if (cleanupErrors.length > 0) {
        log(`AirPlay media-session rollback errors: ${cleanupErrors.join('; ')}`);
      }
      throw new Error(`Failed to establish AirPlay screen session: ${detail}`);
    }
  }

  private static async establishAudioDataChannel(
    session: AirPlayVerifiedRtspSession,
    host: string,
    profile: AirPlayAudioProfile,
    log: (message: string) => void,
    isActive: () => boolean
  ): Promise<HarmonyAirPlayAudioDataChannel | undefined> {
    let channel: HarmonyAirPlayAudioDataChannel | undefined = undefined;
    try {
      const connectionId = await HarmonyAirPlayMediaSession.randomConnectionId();
      const response = await session.request(
        'SETUP',
        '/',
        AirPlayMediaSetupProtocol.buildAudioSetupBody({
          streamType: profile.streamType,
          streamConnectionId: connectionId,
          audioFormat: profile.audioFormat,
          audioType: profile.audioType,
          latencyMs: profile.latencyMs,
          supportsHighAccuracyTimestamps: true,
          samplesPerFrame: profile.samplesPerFrame
        }),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (response.statusCode !== 200) {
        throw new Error(`AAC audio SETUP returned ${response.statusCode}.`);
      }
      const ports = AirPlayMediaSetupProtocol.parseStreamPorts(response.body, profile.streamType);
      const streamKey = await AirPlayMediaPacketCodec.deriveVideoStreamKey(
        session.controlKeys.sharedSecret,
        connectionId
      );
      try {
        channel = new HarmonyAirPlayAudioDataChannel(
          host,
          ports.dataPort,
          ports.controlPort,
          profile,
          streamKey,
          log
        );
      } finally {
        streamKey.fill(0);
      }
      await channel.start();
      HarmonyAirPlayMediaSession.requireActive(isActive);
      const recordResponse = await session.request(
        'RECORD',
        '/',
        AirPlayMediaSetupProtocol.buildRecordBody(),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      HarmonyAirPlayMediaSession.requireActive(isActive);
      if (recordResponse.statusCode !== 200) {
        throw new Error(`AirPlay audio RECORD returned ${recordResponse.statusCode}.`);
      }
      if (ports.controlPort === 0) {
        log('AirPlay AAC audio stream has no controlPort; audio sync packets are unavailable.');
      }
      return channel;
    } catch (error) {
      if (channel !== undefined) {
        try {
          await channel.close();
        } catch (closeError) {
          log(`AAC audio setup rollback failed: ${closeError instanceof Error ? closeError.message : String(closeError)}`);
        }
      }
      log(`AAC audio stream could not be established; video remains available: ${
        error instanceof Error ? error.message : String(error)
      }`);
      return undefined;
    }
  }

  async sendVideoPacket(packet: Uint8Array): Promise<void> {
    if (this.closed) {
      throw new Error('AirPlay media session is closed.');
    }
    if (this.terminalError !== undefined) {
      throw this.terminalError;
    }
    try {
      await this.videoDataChannel.send(packet);
    } catch (error) {
      this.reportError(error instanceof Error ? error : new Error(String(error)));
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async sendVideoConfiguration(annexBParameterSets: Uint8Array, width: number, height: number): Promise<void> {
    const avcC = AirPlayMediaPacketCodec.buildAvcC(annexBParameterSets);
    await this.sendVideoPacket(AirPlayMediaPacketCodec.buildVideoConfigPacket(avcC, width, height));
    this.videoConfigured = true;
  }

  async sendVideoFrame(
    annexB: Uint8Array,
    frameCounter: number,
    ntpTimestampLittleEndian: Uint8Array
  ): Promise<void> {
    if (!this.videoConfigured) {
      throw new Error('AirPlay video configuration must be sent before video frames.');
    }
    const normalizedFrame = AirPlayMediaPacketCodec.normalizeAnnexB(annexB);
    try {
      const packet = await AirPlayMediaPacketCodec.sealVideoFrame(
        normalizedFrame,
        this.videoStreamKey,
        frameCounter,
        ntpTimestampLittleEndian
      );
      await this.sendVideoPacket(packet);
    } finally {
      normalizedFrame.fill(0);
    }
  }

  startScreenCapture(
    width: number,
    height: number,
    displayId: number,
    onFirstFrame: () => void,
    onStopped: (reason: string) => void
  ): void {
    if (this.closed || this.terminalError !== undefined) {
      throw this.terminalError ?? new Error('AirPlay media session is not active.');
    }
    if (this.screenCapture !== undefined) {
      throw new Error('Screen capture is already active for this AirPlay media session.');
    }
    let firstFrameReported = false;
    const callbacks = new MediaScreenCaptureCallbacks(
      async (data: Uint8Array): Promise<void> => {
        await this.sendVideoConfiguration(data, width, height);
        this.log(`AirPlay H.264 configuration sent (${width}x${height}).`);
      },
      async (data: Uint8Array, _timestamp: number): Promise<void> => {
        if (!this.videoConfigured) {
          return;
        }
        if (this.frameCounter >= 0xFFFFFFFF) {
          throw new Error('AirPlay video frame counter exhausted for this media session.');
        }
        const counter = this.frameCounter++;
        await this.sendVideoFrame(data, counter, HarmonyAirPlayMediaSession.currentNtpTimestamp());
        if (!firstFrameReported) {
          firstFrameReported = true;
          this.log('First encoded screen frame sent to the AirPlay receiver.');
          onFirstFrame();
        }
      },
      async (data: Uint8Array, _timestamp: number): Promise<void> => {
        const audioChannel = this.audioDataChannel;
        if (audioChannel !== undefined) {
          await audioChannel.sendFrame(data);
        }
      },
      (state: number): void => {
        if (state === 0) {
          this.log('System screen-capture authorization granted; waiting for H.264 frames.');
          return;
        }
        if (state === 1 || state === 2 || state === 3 || state === 4 || state === 10) {
          this.videoConfigured = false;
          this.screenCapture = undefined;
          onStopped(`system capture state=${state}`);
        }
      },
      (error: Error): void => this.reportError(error)
    );
    const capture = new HarmonyAirPlayScreenCapture(
      width,
      height,
      displayId,
      this.audioProfile?.sampleRate ?? 0,
      callbacks
    );
    this.screenCapture = capture;
    try {
      capture.start();
      this.log(`Requested user-authorized screen capture at ${width}x${height}; the system consent prompt may appear.`);
    } catch (error) {
      this.screenCapture = undefined;
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async stopScreenCapture(): Promise<void> {
    const capture = this.screenCapture;
    if (capture === undefined) {
      return;
    }
    this.screenCapture = undefined;
    this.videoConfigured = false;
    await capture.stop();
    this.log('User-authorized screen capture stopped; AirPlay media session remains connected.');
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    if (this.feedbackTimer !== undefined) {
      clearTimeout(this.feedbackTimer);
      this.feedbackTimer = undefined;
    }
    if (this.videoKeepAliveTimer !== undefined) {
      clearTimeout(this.videoKeepAliveTimer);
      this.videoKeepAliveTimer = undefined;
    }
    const errors: string[] = [];
    if (this.screenCapture !== undefined) {
      const capture = this.screenCapture;
      this.screenCapture = undefined;
      try {
        await capture.stop();
      } catch (error) {
        errors.push(error instanceof Error ? error.message : String(error));
      }
    }
    if (this.audioDataChannel !== undefined) {
      try {
        await this.audioDataChannel.close();
      } catch (error) {
        errors.push(error instanceof Error ? error.message : String(error));
      }
    }
    if (this.keepAliveClient !== undefined) {
      try {
        await this.keepAliveClient.stop();
      } catch (error) {
        errors.push(error instanceof Error ? error.message : String(error));
      }
    }
    if (this.eventChannel !== undefined) {
      try {
        await this.eventChannel.close();
      } catch (error) {
        errors.push(error instanceof Error ? error.message : String(error));
      }
    }
    try {
      await this.videoDataChannel.close();
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
    try {
      await this.timingServer.stop();
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
    try {
      await this.verifiedSession.close();
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
    this.videoStreamKey.fill(0);
    HarmonyAirPlayMediaSession.clearControlKeys(this.verifiedSession);
    if (errors.length > 0) {
      throw new Error(`AirPlay media-session cleanup failed: ${errors.join('; ')}`);
    }
  }

  private scheduleFeedback(): void {
    if (this.closed || this.terminalError !== undefined) {
      return;
    }
    this.feedbackTimer = setTimeout(() => {
      this.feedbackTimer = undefined;
      void this.sendFeedback();
    }, FEEDBACK_INTERVAL_MS);
  }

  private scheduleVideoKeepAlive(): void {
    if (this.closed || this.terminalError !== undefined) {
      return;
    }
    this.videoKeepAliveTimer = setTimeout(() => {
      this.videoKeepAliveTimer = undefined;
      void this.sendVideoPacket(AirPlayMediaPacketCodec.buildKeepAlivePacket()).then(() => {
        this.scheduleVideoKeepAlive();
      }, (error: Error) => {
        this.reportError(error);
      });
    }, VIDEO_KEEP_ALIVE_INTERVAL_MS);
  }

  private async sendFeedback(): Promise<void> {
    if (this.closed || this.terminalError !== undefined) {
      return;
    }
    try {
      const response = await this.verifiedSession.request('POST', '/feedback');
      if (response.statusCode !== 200) {
        throw new Error(`AirPlay /feedback returned ${response.statusCode}.`);
      }
      this.scheduleFeedback();
    } catch (error) {
      if (this.closed) {
        return;
      }
      this.terminalError = error instanceof Error ? error : new Error(String(error));
      this.log(`AirPlay RTSP feedback loop stopped: ${this.terminalError.message}`);
      this.onError(this.terminalError);
    }
  }

  private reportError(error: Error): void {
    if (this.closed || this.terminalError !== undefined) {
      return;
    }
    this.terminalError = error;
    if (this.videoKeepAliveTimer !== undefined) {
      clearTimeout(this.videoKeepAliveTimer);
      this.videoKeepAliveTimer = undefined;
    }
    this.log(`AirPlay media data channel failed: ${error.message}`);
    this.onError(error);
  }

  private static readDisplayInfo(body: Uint8Array): AirPlayReceiverDisplayInfo {
    const root = BinaryPlist.parse(body);
    if (!(root instanceof Map)) {
      throw new Error('AirPlay /info response is not a Binary Plist dictionary.');
    }
    const displays = root.get('displays');
    if (!Array.isArray(displays)) {
      throw new Error('AirPlay /info did not advertise any displays.');
    }
    for (const item of displays) {
      if (!(item instanceof Map)) {
        continue;
      }
      const uuid = item.get('uuid');
      const width = item.get('widthPixels');
      const height = item.get('heightPixels');
      const geometry: AirPlayReceiverDisplayInfo = {
        uuid: '',
        width: typeof width === 'number' && Number.isSafeInteger(width) && width > 0 ? width : undefined,
        height: typeof height === 'number' && Number.isSafeInteger(height) && height > 0 ? height : undefined
      };
      if (typeof uuid === 'string' && uuid.trim().length > 0) {
        geometry.uuid = uuid;
        return geometry;
      }
      if (uuid instanceof Uint8Array && uuid.length === 16) {
        const hex = Array.from(uuid, (byte: number) => byte.toString(16).padStart(2, '0')).join('');
        geometry.uuid = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
        return geometry;
      }
      if (typeof uuid === 'number' && Number.isSafeInteger(uuid)) {
        geometry.uuid = `${uuid}`;
        return geometry;
      }
    }
    throw new Error('AirPlay /info displays did not contain a usable display UUID.');
  }

  private static async randomUuid(): Promise<string> {
    const bytes = await HarmonyAirPlayCrypto.randomBytes(16);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    const hex = Array.from(bytes, (byte: number) => byte.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  private static async randomConnectionId(): Promise<number> {
    const bytes = await HarmonyAirPlayCrypto.randomBytes(6);
    let value: number = 0;
    for (const byte of bytes) {
      value = value * 256 + byte;
    }
    return value === 0 ? 1 : value;
  }

  private static requireActive(isActive: () => boolean): void {
    if (!isActive()) {
      throw new Error('AirPlay media-session negotiation was cancelled.');
    }
  }

  private static currentNtpTimestamp(): Uint8Array {
    const milliseconds = Date.now();
    const seconds = Math.floor(milliseconds / 1000) + 2208988800;
    const fraction = Math.floor((milliseconds % 1000) * 0x100000000 / 1000);
    const bytes = new Uint8Array(8);
    bytes[0] = fraction & 0xFF;
    bytes[1] = (fraction >>> 8) & 0xFF;
    bytes[2] = (fraction >>> 16) & 0xFF;
    bytes[3] = (fraction >>> 24) & 0xFF;
    bytes[4] = seconds & 0xFF;
    bytes[5] = (seconds >>> 8) & 0xFF;
    bytes[6] = (seconds >>> 16) & 0xFF;
    bytes[7] = (seconds >>> 24) & 0xFF;
    return bytes;
  }

  private static clearControlKeys(session: AirPlayVerifiedRtspSession): void {
    session.controlKeys.phoneWriteKey.fill(0);
    session.controlKeys.phoneReadKey.fill(0);
    session.controlKeys.sharedSecret.fill(0);
  }
}
