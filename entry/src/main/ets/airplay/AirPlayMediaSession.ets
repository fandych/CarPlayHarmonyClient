import cryptoFramework from '@ohos.security.cryptoFramework';
import netSocket from '@ohos.net.socket';
import { hkdfSha512 } from './AirPlayCrypto';
import { AirPlayEventChannel, AirPlayEventRequest } from './AirPlayEventChannel';
import { AirPlayRtspClient, AirPlayRtspResponse } from './AirPlayRtspClient';
import { BinaryPlist, PlistNode } from './BinaryPlist';
import { encodeUtf8, toArrayBuffer } from '../protocol/Iap2Codec';
import { AudioRtpSession } from '../audio/AudioRtpSender';

const CONTROLLER_FEATURES: string[] = [
  'uiContext',
  'viewAreas',
  'cornerMasks',
  'focusTransfer',
  'h.264Level5.1',
  'mainBuffered',
  'altScreen',
  'enhancedSiri',
  'hevc',
  'sessionManagement',
  'logTransfer',
  'iAPChannel',
  'vehicleStateProtocol',
  'videoPlayback'
];

export interface AirPlayMediaSessionInfo {
  eventPort: number;
  timingPort: number;
  keepAlivePort: number;
  enabledFeatures: string[];
  displayUuid: string;
  videoDataPort: number;
  videoConnectionId: bigint;
  videoStreamKey: Uint8Array;
  audioSession: AudioRtpSession | undefined;
}

export class AirPlayMediaSession {
  private readonly client: AirPlayRtspClient;
  private readonly receiverHost: string;
  private readonly log: (message: string) => void;
  private videoDataSocket?: netSocket.TCPSocket;
  private videoKeepAliveTimer: number = -1;
  private timingSocket?: netSocket.UDPSocket;
  private timingHandler?: (info: netSocket.SocketMessageInfo) => void;
  private keepAliveSocket?: netSocket.UDPSocket;
  private eventChannel?: AirPlayEventChannel;
  private keepAliveTimer: number = -1;
  private feedbackTimer: number = -1;
  private feedbackPending: boolean = false;
  private feedbackEnabled: boolean = true;
  private running: boolean = false;
  private recorded: boolean = false;

  constructor(client: AirPlayRtspClient, receiverHost: string, log: (message: string) => void) {
    this.client = client;
    this.receiverHost = receiverHost;
    this.log = log;
  }

  async start(deviceId: string, deviceName: string, sharedSecret: Uint8Array, info: PlistNode):
    Promise<AirPlayMediaSessionInfo> {
    if (this.running) {
      throw new Error('AirPlay media session is already active');
    }
    if (sharedSecret.length === 0) {
      throw new Error('AirPlay shared secret is missing; refusing to negotiate an unauthenticated media session');
    }
    const normalizedDeviceId = normalizeDeviceId(deviceId);
    this.running = true;
    try {
      const timingPort = await this.startTimingServer();
      const initialSetup = await this.request(
        'SETUP',
        '/setup',
        AirPlayMediaSession.buildSessionSetupPayload(normalizedDeviceId, deviceName, timingPort),
        'initial session SETUP'
      );
      const initialResponse = requireDictionary(initialSetup, 'initial session SETUP');
      const enabledFeatures = readStringArray(initialResponse.get('enabledFeatures'));
      const displayUuid = readDisplayUuid(info);
      if (!enabledFeatures.includes('videoPlayback')) {
        throw new Error(`Receiver did not enable videoPlayback (${enabledFeatures.join(', ') || 'no features'})`);
      }
      const modesChanged = await this.request(
        'POST',
        '/command',
        AirPlayMediaSession.buildModesChangedPayload(),
        'modesChanged resource claim'
      );
      requireSuccess(modesChanged, 'modesChanged resource claim');
      const videoConnectionId = await randomPositiveInt64();
      const videoSetup = await this.request(
        'SETUP',
        '/',
        AirPlayMediaSession.buildVideoSetupPayload(displayUuid, videoConnectionId),
        'video stream SETUP'
      );
      const videoResponse = requireDictionary(videoSetup, 'video stream SETUP');
      const streams = videoResponse.get('streams');
      if (!streams || streams.kind !== 'array' || streams.arrayValue.length === 0) {
        throw new Error('Video SETUP response has no streams array');
      }
      const stream = streams.arrayValue.find((item: PlistNode): boolean =>
        item.kind === 'dictionary' && item.get('type')?.integerValue === BigInt(110)
      );
      if (!stream) {
        throw new Error('Video SETUP response has no type 110 screen stream');
      }
      const videoDataPort = readPort(stream.get('dataPort'));
      if (videoDataPort === 0) {
        throw new Error('Video SETUP response did not include a valid data port');
      }
      await this.openVideoDataPort(videoDataPort);
      const record = await this.request(
        'RECORD',
        '/',
        BinaryPlist.encode(PlistNode.dictionary(new Map<string, PlistNode>())),
        'RECORD'
      );
      requireSuccess(record, 'RECORD');
      this.recorded = true;
      await this.sendVideoKeepAlive();
      this.videoKeepAliveTimer = setInterval((): void => {
        void this.sendVideoKeepAlive().catch((error: Error): void => {
          this.log(`AirPlay screen keep-alive failed: ${error.message}`);
          if (this.videoKeepAliveTimer >= 0) {
            clearInterval(this.videoKeepAliveTimer);
            this.videoKeepAliveTimer = -1;
          }
        });
      }, 1000);
      const videoStreamKey = await hkdfSha512(
        sharedSecret,
        encodeUtf8(`DataStream-Salt${videoConnectionId.toString()}`),
        encodeUtf8('DataStream-Output-Encryption-Key')
      );
      let audioSession: AudioRtpSession | undefined = undefined;
      try {
        audioSession = await this.setupAudioStream(info, sharedSecret);
      } catch (error) {
        this.log(`AirPlay audio SETUP unavailable: ${error instanceof Error ? error.message : String(error)}`);
      }

      const result: AirPlayMediaSessionInfo = {
        eventPort: readPort(initialResponse.get('eventPort')),
        timingPort,
        keepAlivePort: readPort(initialResponse.get('keepAlivePort')),
        enabledFeatures,
        displayUuid,
        videoDataPort,
        videoConnectionId,
        videoStreamKey,
        audioSession
      };
      await this.startKeepAlive(result.keepAlivePort);
      this.startFeedbackLoop();
      if (result.eventPort > 0) {
        const eventChannel = new AirPlayEventChannel(
          (message: string): void => this.log(message),
          (request: AirPlayEventRequest): void => this.handleEventRequest(request)
        );
        this.eventChannel = eventChannel;
        try {
          await eventChannel.connect(this.receiverHost, result.eventPort, sharedSecret);
        } catch (error) {
          this.log(`AirPlay event channel unavailable: ${error instanceof Error ? error.message : String(error)}`);
          this.eventChannel = undefined;
          await eventChannel.close();
        }
      } else {
        this.log('Receiver did not provide an event port; HID return channel is unavailable');
      }
      this.log(
        `AirPlay RTSP session active: video port=${videoDataPort}, event port=${result.eventPort}, ` +
          `timing port=${timingPort}; screen encoder/capture is not attached`
      );
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      try {
        await this.stop();
      } catch (cleanupError) {
        const cleanupMessage = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
        throw new Error(`${message}; media-session cleanup failed: ${cleanupMessage}`);
      }
      throw new Error(`AirPlay media session failed: ${message}`);
    }
  }

  async stop(): Promise<void> {
    this.running = false;
    if (this.keepAliveTimer >= 0) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = -1;
    }
    if (this.feedbackTimer >= 0) {
      clearTimeout(this.feedbackTimer);
      this.feedbackTimer = -1;
    }
    if (this.videoKeepAliveTimer >= 0) {
      clearInterval(this.videoKeepAliveTimer);
      this.videoKeepAliveTimer = -1;
    }
    const failures: string[] = [];
    const eventChannel = this.eventChannel;
    this.eventChannel = undefined;
    if (eventChannel) {
      try {
        await eventChannel.close();
      } catch (error) {
        failures.push(`event channel: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (this.recorded) {
      this.recorded = false;
      try {
        await this.request(
          'TEARDOWN',
          '/',
          BinaryPlist.encode(PlistNode.dictionary(new Map<string, PlistNode>())),
          'TEARDOWN'
        );
      } catch (error) {
        failures.push(`RTSP teardown: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (this.timingSocket) {
      const socket = this.timingSocket;
      this.timingSocket = undefined;
      if (this.timingHandler) {
        try {
          socket.off('message', this.timingHandler);
        } catch (error) {
          failures.push(`timing listener: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
      this.timingHandler = undefined;
      try {
        await socket.close();
      } catch (error) {
        failures.push(`timing socket: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (this.keepAliveSocket) {
      const socket = this.keepAliveSocket;
      this.keepAliveSocket = undefined;
      try {
        await socket.close();
      } catch (error) {
        failures.push(`keep-alive socket: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    const videoSocket = this.videoDataSocket;
    this.videoDataSocket = undefined;
    if (videoSocket) {
      try {
        await videoSocket.close();
      } catch (error) {
        failures.push(`video data socket: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join('; '));
    }
  }

  static buildSessionSetupPayload(deviceId: string, deviceName: string, timingPort: number): Uint8Array {
    if (timingPort < 1 || timingPort > 65535) {
      throw new Error('AirPlay timing server must have a bound UDP port before SETUP');
    }
    const features: PlistNode[] = CONTROLLER_FEATURES.map((feature: string): PlistNode =>
      PlistNode.string(feature)
    );
    const fields: Map<string, PlistNode> = new Map<string, PlistNode>([
      ['deviceID', PlistNode.string(normalizeDeviceId(deviceId))],
      ['macAddress', PlistNode.string(normalizeDeviceId(deviceId))],
      ['name', PlistNode.string(deviceName.trim() || 'Harmony CarPlay')],
      ['model', PlistNode.string('HarmonyOS')],
      ['osName', PlistNode.string('HarmonyOS')],
      ['osBuildVersion', PlistNode.string('API 26')],
      ['osVersion', PlistNode.string('26')],
      ['sourceVersion', PlistNode.string('26.0')],
      ['timingPort', PlistNode.integer(timingPort)],
      ['sessionUUID', PlistNode.string(createUuid())],
      ['sessionCorrelationUUID', PlistNode.string(createUuid())],
      ['statsCollectionEnabled', PlistNode.boolean(false)],
      ['updateSessionRequest', PlistNode.boolean(false)],
      ['keepAliveLowPower', PlistNode.boolean(true)],
      ['features', PlistNode.array(features)]
    ]);
    return BinaryPlist.encode(PlistNode.dictionary(fields));
  }

  static buildVideoSetupPayload(displayUuid: string, connectionId: bigint): Uint8Array {
    if (!displayUuid || connectionId <= BigInt(0)) {
      throw new Error('Video SETUP requires a receiver display UUID and positive stream connection ID');
    }
    const stream = PlistNode.dictionary(new Map<string, PlistNode>([
      ['type', PlistNode.integer(110)],
      ['streamConnectionID', PlistNode.integer(connectionId)],
      ['uuid', PlistNode.string(displayUuid)],
      ['latencyMs', PlistNode.integer(25)]
    ]));
    return BinaryPlist.encode(PlistNode.dictionary(new Map<string, PlistNode>([
      ['streams', PlistNode.array([stream])]
    ])));
  }

  static buildAudioSetupPayload(
    connectionId: bigint,
    formatBit: bigint,
    latencyMs: number
  ): Uint8Array {
    if (connectionId <= BigInt(0) || (formatBit !== (BigInt(1) << BigInt(15)) &&
      formatBit !== (BigInt(1) << BigInt(11))) || latencyMs < 1 || latencyMs > 2000) {
      throw new Error('Invalid PCM audio SETUP parameters');
    }
    const stream = PlistNode.dictionary(new Map<string, PlistNode>([
      ['type', PlistNode.integer(100)],
      ['streamConnectionID', PlistNode.integer(connectionId)],
      ['audioFormat', PlistNode.integer(formatBit)],
      ['audioType', PlistNode.string('media')],
      ['audioLatencyMs', PlistNode.integer(latencyMs)],
      ['input', PlistNode.boolean(false)],
      ['supportsRTPPacketRedundancy', PlistNode.boolean(false)],
      ['supportsHighAccuracyTimestamps', PlistNode.boolean(false)],
      ['spf', PlistNode.integer(352)]
    ]));
    return BinaryPlist.encode(PlistNode.dictionary(new Map<string, PlistNode>([
      ['streams', PlistNode.array([stream])]
    ])));
  }

  static buildModesChangedPayload(): Uint8Array {
    const appStates: PlistNode[] = [
      PlistNode.dictionary(new Map<string, PlistNode>([
        ['appStateID', PlistNode.integer(2)],
        ['entity', PlistNode.integer(0)]
      ])),
      PlistNode.dictionary(new Map<string, PlistNode>([
        ['appStateID', PlistNode.integer(3)],
        ['entity', PlistNode.integer(0)]
      ])),
      PlistNode.dictionary(new Map<string, PlistNode>([
        ['appStateID', PlistNode.integer(1)],
        ['entity', PlistNode.integer(0)],
        ['speechMode', PlistNode.integer(-1)]
      ]))
    ];
    const resources: PlistNode[] = [
      PlistNode.dictionary(new Map<string, PlistNode>([
        ['resourceID', PlistNode.integer(1)],
        ['entity', PlistNode.integer(1)],
        ['permanentEntity', PlistNode.integer(1)]
      ])),
      PlistNode.dictionary(new Map<string, PlistNode>([
        ['resourceID', PlistNode.integer(2)],
        ['entity', PlistNode.integer(1)],
        ['permanentEntity', PlistNode.integer(1)]
      ]))
    ];
    return BinaryPlist.encode(PlistNode.dictionary(new Map<string, PlistNode>([
      ['type', PlistNode.string('modesChanged')],
      ['params', PlistNode.dictionary(new Map<string, PlistNode>([
        ['appStates', PlistNode.array(appStates)],
        ['resources', PlistNode.array(resources)]
      ]))]
    ])));
  }

  static buildTimingResponse(request: Uint8Array, nowMillis: number): Uint8Array | undefined {
    if (request.length < 32 || (request[0] >>> 6) !== 2 || request[1] !== 0xd2 ||
      request[2] !== 0 || request[3] !== 7) {
      return undefined;
    }
    const response = new Uint8Array(32);
    response[0] = 0x80;
    response[1] = 0xd3;
    response[2] = 0;
    response[3] = 7;
    response.set(request.slice(24, 32), 8);
    const ntpTime = createNtpTimestamp(nowMillis);
    response.set(ntpTime, 16);
    response.set(ntpTime, 24);
    return response;
  }

  static buildVideoKeepAliveFrame(nowMillis: number): Uint8Array {
    const header = new Uint8Array(128);
    header[4] = 2;
    const timestamp = createNtpTimestamp(nowMillis);
    for (let index = 0; index < timestamp.length; index++) {
      header[8 + index] = timestamp[timestamp.length - 1 - index];
    }
    return header;
  }

  private async startTimingServer(): Promise<number> {
    const socket = netSocket.constructUDPSocketInstance();
    const handler = (info: netSocket.SocketMessageInfo): void => {
      const request = new Uint8Array(info.message);
      const response = AirPlayMediaSession.buildTimingResponse(request, Date.now());
      if (!response) {
        this.log(`Ignoring invalid AirPlay timing packet (${request.length} bytes)`);
        return;
      }

      const options: netSocket.UDPSendOptions = {
        data: toArrayBuffer(response),
        address: { address: info.remoteInfo.address, port: info.remoteInfo.port }
      };
      void socket.send(options).catch((error: Error): void => {
        this.log(`AirPlay timing response failed: ${error.message}`);
      });
    };
    try {
      socket.on('message', handler);
      await socket.bind({ address: '0.0.0.0', port: 0 });
      const localAddress = await socket.getLocalAddress();
      const localPort = localAddress.port;
      if (typeof localPort !== 'number' || localPort < 1) {
        throw new Error('System did not allocate a timing UDP port');
      }
      this.timingSocket = socket;
      this.timingHandler = handler;
      return localPort;
    } catch (error) {
      try {
        socket.off('message', handler);
      } catch (cleanupError) {
        this.log(`AirPlay timing listener cleanup failed: ${cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError)}`);
      }
      try {
        await socket.close();
      } catch (cleanupError) {
        this.log(`AirPlay timing socket cleanup failed: ${cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError)}`);
      }
      throw new Error(`Unable to start AirPlay timing service: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private async openVideoDataPort(port: number): Promise<void> {
    const socket = netSocket.constructTCPSocketInstance();
    try {
      await socket.connect({
        address: { address: this.receiverHost, port },
        timeout: 5000
      });
      this.videoDataSocket = socket;
      this.log(`AirPlay screen data TCP connected: ${this.receiverHost}:${port}`);
    } catch (error) {
      try {
        await socket.close();
      } catch (cleanupError) {
        this.log(`AirPlay screen TCP cleanup failed: ${cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError)}`);
      }
      throw new Error(`Unable to connect screen data port: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private async sendVideoKeepAlive(): Promise<void> {
    const socket = this.videoDataSocket;
    if (!socket || !this.recorded) {
      return;
    }
    const header = AirPlayMediaSession.buildVideoKeepAliveFrame(Date.now());
    const options: netSocket.TCPSendOptions = { data: toArrayBuffer(header) };
    await socket.send(options);
  }

  private async setupAudioStream(info: PlistNode, sharedSecret: Uint8Array): Promise<AudioRtpSession | undefined> {
    const format = selectPcmAudioFormat(info);
    if (!format) {
      this.log('Receiver /info has no supported PCM media-audio format; audio RTP will remain disabled');
      return undefined;
    }
    const connectionId = await randomPositiveInt64();
    const audioLatencyMs = readAudioLatency(info, format.sampleRate);
    const response = await this.request(
      'SETUP',
      '/',
      AirPlayMediaSession.buildAudioSetupPayload(connectionId, format.formatBit, audioLatencyMs),
      'audio stream SETUP'
    );
    const root = requireDictionary(response, 'audio stream SETUP');
    const streams = root.get('streams');
    if (!streams || streams.kind !== 'array') {
      throw new Error('Audio SETUP response has no streams array');
    }
    const audio = streams.arrayValue.find((item: PlistNode): boolean =>
      item.kind === 'dictionary' && item.get('type')?.integerValue === BigInt(100)
    );
    const dataPort = readPort(audio?.get('dataPort'));
    if (!audio || dataPort === 0) {
      throw new Error('Audio SETUP response has no type 100 data port');
    }
    const streamKey = await hkdfSha512(
      sharedSecret,
      encodeUtf8(`DataStream-Salt${connectionId.toString()}`),
      encodeUtf8('DataStream-Output-Encryption-Key')
    );
    this.log(`AirPlay PCM audio stream negotiated: ${format.sampleRate}Hz → UDP ${dataPort}`);
    return {
      host: this.receiverHost,
      dataPort,
      controlPort: readPort(audio.get('controlPort')),
      streamKey,
      sampleRate: format.sampleRate
    };
  }

  private handleEventRequest(request: AirPlayEventRequest): void {
    let commandSummary = '';
    if (request.body.length > 0) {
      try {
        const command = BinaryPlist.decode(request.body);
        if (command.kind === 'dictionary') {
          commandSummary = ` fields=${Array.from(command.dictionaryValue.keys()).join(',')}`;
        }
      } catch (error) {
        commandSummary = ` plistError=${error instanceof Error ? error.message : String(error)}`;
      }
    }
    this.log(
      `AirPlay event ${request.method} ${request.target} cseq=${request.cseq} body=${request.body.length}B${commandSummary}`
    );
  }

  private async startKeepAlive(port: number): Promise<void> {
    if (port === 0) {
      this.log('Receiver did not advertise a keep-alive UDP port');
      return;
    }
    const socket = netSocket.constructUDPSocketInstance();
    try {
      await socket.bind({ address: '0.0.0.0', port: 0 });
      this.keepAliveSocket = socket;
      this.keepAliveTimer = setInterval((): void => {
        void this.sendKeepAlive(port).catch((error: Error): void => {
          this.log(`AirPlay UDP keep-alive failed: ${error.message}`);
        });
      }, 5000);
      await this.sendKeepAlive(port);
    } catch (error) {
      try {
        await socket.close();
      } catch (cleanupError) {
        this.log(`AirPlay keep-alive socket cleanup failed: ${cleanupError instanceof Error ?
          cleanupError.message : String(cleanupError)}`);
      }
      this.keepAliveSocket = undefined;
      throw new Error(`Unable to start AirPlay keep-alive: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private async sendKeepAlive(port: number): Promise<void> {
    const socket = this.keepAliveSocket;
    if (!socket || !this.running) {
      return;
    }
    const bytes = await cryptoFramework.createRandom().generateRandom(4);
    const options: netSocket.UDPSendOptions = {
      data: toArrayBuffer(new Uint8Array(bytes.data)),
      address: { address: this.receiverHost, port }
    };
    await socket.send(options);
  }

  private startFeedbackLoop(): void {
    const run = async (): Promise<void> => {
      this.feedbackTimer = -1;
      if (!this.running || this.feedbackPending) {
        return;
      }
      this.feedbackPending = true;
      try {
        const response = await this.client.request(
          'POST',
          '/feedback',
          new Uint8Array(0),
          { contentType: 'application/x-apple-binary-plist' }
        );
        if (response.statusCode !== 200) {
          this.log(`AirPlay feedback returned ${response.statusLine}`);
          this.feedbackEnabled = false;
        }
      } catch (error) {
        this.log(`AirPlay feedback failed: ${error instanceof Error ? error.message : String(error)}`);
        this.feedbackEnabled = false;
      } finally {
        this.feedbackPending = false;
        if (this.running && this.feedbackEnabled) {
          this.feedbackTimer = setTimeout((): void => {
            void run();
          }, 1000);
        }
      }
    };
    this.feedbackTimer = setTimeout((): void => {
      void run();
    }, 1000);
  }

  private async request(method: string, path: string, body: Uint8Array, label: string):
    Promise<AirPlayRtspResponse> {
    const response = await this.client.request(method, path, body, {
      contentType: 'application/x-apple-binary-plist'
    });
    requireSuccess(response, label);
    return response;
  }
}

function requireDictionary(response: AirPlayRtspResponse, label: string): PlistNode {
  const value = BinaryPlist.decode(response.body);
  if (value.kind !== 'dictionary') {
    throw new Error(`${label} response is not a binary plist dictionary`);
  }
  return value;
}

function requireSuccess(response: AirPlayRtspResponse, label: string): void {
  if (response.statusCode !== 200) {
    throw new Error(`${label} rejected: ${response.statusLine}`);
  }
}

function readPort(node: PlistNode | undefined): number {
  if (!node || node.kind !== 'integer') {
    return 0;
  }
  return Number(node.integerValue & BigInt(0xffff));
}

export interface PcmAudioFormat {
  formatBit: bigint;
  sampleRate: number;
}

export function selectPcmAudioFormat(info: PlistNode): PcmAudioFormat | undefined {
  const formats = info.get('audioFormats');
  if (!formats || formats.kind !== 'array') {
    return undefined;
  }
  let supports48k = false;
  let supports44k = false;
  for (const entry of formats.arrayValue) {
    if (entry.kind !== 'dictionary' || entry.get('type')?.integerValue !== BigInt(100) ||
      entry.get('audioType')?.stringValue !== 'media') {
      continue;
    }
    const output = entry.get('audioOutputFormats');
    if (!output || output.kind !== 'integer') {
      continue;
    }
    supports48k ||= (output.integerValue & (BigInt(1) << BigInt(15))) !== BigInt(0);
    supports44k ||= (output.integerValue & (BigInt(1) << BigInt(11))) !== BigInt(0);
  }
  if (supports48k) {
    return { formatBit: BigInt(1) << BigInt(15), sampleRate: 48000 };
  }
  if (supports44k) {
    return { formatBit: BigInt(1) << BigInt(11), sampleRate: 44100 };
  }
  return undefined;
}

function readAudioLatency(info: PlistNode, sampleRate: number): number {
  const latencies = info.get('audioLatencies');
  if (!latencies || latencies.kind !== 'array') {
    return 250;
  }
  const selected = latencies.arrayValue.find((entry: PlistNode): boolean =>
    entry.kind === 'dictionary' &&
    entry.get('type')?.integerValue === BigInt(100) &&
    entry.get('audioType')?.stringValue === 'media'
  );
  const outputLatency = selected?.get('outputLatencyMicros');
  if (!outputLatency || outputLatency.kind !== 'integer') {
    return 250;
  }
  const milliseconds = Number(outputLatency.integerValue) / 1000;
  if (!Number.isFinite(milliseconds) || milliseconds < 0) {
    return 250;
  }
  return Math.max(32, Math.min(2000, Math.round(milliseconds + (sampleRate === 44100 ? 30 : 0))));
}

function readStringArray(node: PlistNode | undefined): string[] {
  if (!node || node.kind !== 'array') {
    return [];
  }
  return node.arrayValue
    .filter((item: PlistNode): boolean => item.kind === 'string')
    .map((item: PlistNode): string => item.stringValue);
}

function readDisplayUuid(info: PlistNode): string {
  const displays = info.get('displays');
  if (!displays || displays.kind !== 'array' || displays.arrayValue.length === 0) {
    throw new Error('AirPlay /info did not provide a display descriptor; refusing to invent a display UUID');
  }
  const display = displays.arrayValue[0];
  if (display.kind !== 'dictionary') {
    throw new Error('AirPlay /info displays[0] is not a dictionary');
  }
  const uuid = display.get('uuid') ?? display.get('UUID');
  if (!uuid) {
    throw new Error('AirPlay /info display descriptor has no UUID');
  }
  if (uuid.kind === 'string' && uuid.stringValue.length > 0) {
    return uuid.stringValue;
  }
  if (uuid.kind === 'integer') {
    return uuid.integerValue.toString();
  }
  if (uuid.kind === 'data' && uuid.dataValue.length === 16) {
    const hex = Array.from(uuid.dataValue).map((value: number): string =>
      value.toString(16).padStart(2, '0')
    ).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  throw new Error('AirPlay /info display UUID has an unsupported type or length');
}

function normalizeDeviceId(value: string): string {
  const normalized = value.trim().toUpperCase();
  if (!/^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/.test(normalized) ||
    normalized === '02:00:00:00:00:00') {
    throw new Error('AirPlay session requires a real Bluetooth device address; replace the placeholder in Settings');
  }
  return normalized;
}

async function randomPositiveInt64(): Promise<bigint> {
  const blob = await cryptoFramework.createRandom().generateRandom(8);
  const random = new Uint8Array(blob.data);
  let value = BigInt(0);
  for (const byte of random) {
    value = (value << BigInt(8)) | BigInt(byte);
  }
  value &= (BigInt(1) << BigInt(63)) - BigInt(1);
  return value === BigInt(0) ? BigInt(1) : value;
}

function createUuid(): string {
  const digits: string[] = [];
  for (let index = 0; index < 32; index++) {
    digits.push(Math.floor(Math.random() * 16).toString(16));
  }
  digits[12] = '4';
  const variant = Number.parseInt(digits[16], 16);
  digits[16] = ((variant & 3) | 8).toString(16);
  const raw = digits.join('').toUpperCase();
  return `${raw.slice(0, 8)}-${raw.slice(8, 12)}-${raw.slice(12, 16)}-${raw.slice(16, 20)}-${raw.slice(20)}`;
}

function createNtpTimestamp(nowMillis: number): Uint8Array {
  const seconds = Math.floor(nowMillis / 1000) + 2208988800;
  const fraction = Math.floor(((nowMillis % 1000) * 0x100000000) / 1000);
  const result = new Uint8Array(8);
  writeBe32(result, 0, seconds);
  writeBe32(result, 4, fraction);
  return result;
}

function writeBe32(target: Uint8Array, offset: number, value: number): void {
  target[offset] = (value >>> 24) & 0xff;
  target[offset + 1] = (value >>> 16) & 0xff;
  target[offset + 2] = (value >>> 8) & 0xff;
  target[offset + 3] = value & 0xff;
}
