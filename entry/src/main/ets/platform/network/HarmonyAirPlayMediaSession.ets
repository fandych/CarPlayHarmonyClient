import { socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BinaryPlist } from '../../protocol/airplay/BinaryPlist';
import {
  AirPlayInitialSetupInfo,
  AirPlayMediaSetupProtocol,
  AirPlayMediaStreamPorts
} from '../../protocol/airplay/AirPlayMediaSetupProtocol';
import { HarmonyAirPlayCrypto } from '../../protocol/airplay/HarmonyAirPlayCrypto';
import { AirPlayServiceEndpoint } from './HarmonyMdnsBrowser';
import { AirPlayVerifiedRtspSession, HarmonyAirPlayClient } from './HarmonyAirPlayClient';
import { HarmonyAirPlayKeepAliveClient } from './HarmonyAirPlayKeepAliveClient';
import { HarmonyAirPlayTimingServer } from './HarmonyAirPlayTimingServer';

const PLIST_CONTENT_TYPE = 'application/x-apple-binary-plist';
const FEEDBACK_INTERVAL_MS = 1000;

class HarmonyAirPlayVideoDataChannel {
  private readonly client: socket.TCPSocket = socket.constructTCPSocketInstance();
  private readonly host: string;
  private readonly port: number;
  private connected: boolean = false;
  private closed: boolean = false;
  private terminalError: Error | undefined = undefined;
  private readonly errorListener = (error: Error): void => {
    this.terminalError = error;
  };

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
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

  async send(packet: Uint8Array): Promise<void> {
    if (!this.connected || this.closed || this.terminalError !== undefined) {
      throw this.terminalError ?? new Error('AirPlay video data channel is not connected.');
    }
    if (packet.length === 0) {
      throw new Error('AirPlay video packet cannot be empty.');
    }
    const data = new ArrayBuffer(packet.length);
    new Uint8Array(data).set(packet);
    try {
      await this.client.send({ data });
    } catch (error) {
      this.terminalError = error instanceof Error ? error : new Error('AirPlay video packet send failed.');
      throw this.terminalError;
    }
  }

  async close(): Promise<void> {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.connected = false;
    this.client.off('error', this.errorListener);
    try {
      await this.client.close();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`Failed to close AirPlay video data channel: ${detail}`);
    }
  }
}

export class HarmonyAirPlayMediaSession {
  readonly displayUuid: string;
  readonly streamConnectionId: number;
  readonly initialSetupInfo: AirPlayInitialSetupInfo;
  readonly videoPorts: AirPlayMediaStreamPorts;
  private readonly verifiedSession: AirPlayVerifiedRtspSession;
  private readonly timingServer: HarmonyAirPlayTimingServer;
  private readonly videoDataChannel: HarmonyAirPlayVideoDataChannel;
  private readonly keepAliveClient: HarmonyAirPlayKeepAliveClient | undefined;
  private readonly log: (message: string) => void;
  private feedbackTimer: number | undefined = undefined;
  private terminalError: Error | undefined = undefined;
  private closed: boolean = false;

  private constructor(
    displayUuid: string,
    streamConnectionId: number,
    initialSetupInfo: AirPlayInitialSetupInfo,
    videoPorts: AirPlayMediaStreamPorts,
    verifiedSession: AirPlayVerifiedRtspSession,
    timingServer: HarmonyAirPlayTimingServer,
    videoDataChannel: HarmonyAirPlayVideoDataChannel,
    keepAliveClient: HarmonyAirPlayKeepAliveClient | undefined,
    log: (message: string) => void
  ) {
    this.displayUuid = displayUuid;
    this.streamConnectionId = streamConnectionId;
    this.initialSetupInfo = initialSetupInfo;
    this.videoPorts = videoPorts;
    this.verifiedSession = verifiedSession;
    this.timingServer = timingServer;
    this.videoDataChannel = videoDataChannel;
    this.keepAliveClient = keepAliveClient;
    this.log = log;
  }

  static async establish(
    context: common.UIAbilityContext,
    endpoint: AirPlayServiceEndpoint,
    realBluetoothAddress: string,
    log: (message: string) => void
  ): Promise<HarmonyAirPlayMediaSession> {
    const client = new HarmonyAirPlayClient();
    const verifiedSession = await client.openVerifiedSession(context, endpoint, log);
    const timingServer = new HarmonyAirPlayTimingServer(log);
    let videoDataChannel: HarmonyAirPlayVideoDataChannel | undefined = undefined;
    let keepAliveClient: HarmonyAirPlayKeepAliveClient | undefined = undefined;
    try {
      const infoResponse = await verifiedSession.request('GET', '/info');
      if (infoResponse.statusCode !== 200) {
        throw new Error(`Verified AirPlay /info request returned ${infoResponse.statusCode}.`);
      }
      const displayUuid = HarmonyAirPlayMediaSession.readDisplayUuid(infoResponse.body);
      const timingPort = await timingServer.start();
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
          correlationUuid
        ),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      if (initialResponse.statusCode !== 200) {
        throw new Error(`AirPlay initial SETUP returned ${initialResponse.statusCode}.`);
      }
      const initialSetupInfo = AirPlayMediaSetupProtocol.parseInitialSetupResponse(initialResponse.body);
      if (initialSetupInfo.keepAlivePort > 0) {
        keepAliveClient = new HarmonyAirPlayKeepAliveClient(endpoint.host, initialSetupInfo.keepAlivePort, (error) => {
          log(`AirPlay UDP keep-alive failed: ${error.message}`);
        });
        await keepAliveClient.start();
      } else {
        log('AirPlay initial SETUP omitted keepAlivePort; no UDP keep-alive was started.');
      }

      const screenResponse = await verifiedSession.request(
        'SETUP',
        '/',
        AirPlayMediaSetupProtocol.buildScreenSetupBody(connectionId, displayUuid),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      if (screenResponse.statusCode !== 200) {
        throw new Error(`AirPlay screen SETUP returned ${screenResponse.statusCode}.`);
      }
      const videoPorts = AirPlayMediaSetupProtocol.parseStreamPorts(
        screenResponse.body,
        AirPlayMediaSetupProtocol.SCREEN_STREAM_TYPE
      );
      videoDataChannel = new HarmonyAirPlayVideoDataChannel(endpoint.host, videoPorts.dataPort);
      await videoDataChannel.connect();

      const recordResponse = await verifiedSession.request(
        'RECORD',
        '/',
        AirPlayMediaSetupProtocol.buildRecordBody(),
        [{ name: 'Content-Type', value: PLIST_CONTENT_TYPE }]
      );
      if (recordResponse.statusCode !== 200) {
        throw new Error(`AirPlay RECORD returned ${recordResponse.statusCode}.`);
      }
      const mediaSession = new HarmonyAirPlayMediaSession(
        displayUuid,
        connectionId,
        initialSetupInfo,
        videoPorts,
        verifiedSession,
        timingServer,
        videoDataChannel,
        keepAliveClient,
        log
      );
      mediaSession.scheduleFeedback();
      log(`AirPlay screen session active: display=${displayUuid}, dataPort=${videoPorts.dataPort}.`);
      return mediaSession;
    } catch (error) {
      const cleanupErrors: string[] = [];
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
      const detail = error instanceof Error ? error.message : String(error);
      if (cleanupErrors.length > 0) {
        log(`AirPlay media-session rollback errors: ${cleanupErrors.join('; ')}`);
      }
      throw new Error(`Failed to establish AirPlay screen session: ${detail}`);
    }
  }

  async sendVideoPacket(packet: Uint8Array): Promise<void> {
    if (this.closed) {
      throw new Error('AirPlay media session is closed.');
    }
    if (this.terminalError !== undefined) {
      throw this.terminalError;
    }
    await this.videoDataChannel.send(packet);
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
    const errors: string[] = [];
    if (this.keepAliveClient !== undefined) {
      try {
        await this.keepAliveClient.stop();
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
    }
  }

  private static readDisplayUuid(body: Uint8Array): string {
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
      if (typeof uuid === 'string' && uuid.trim().length > 0) {
        return uuid;
      }
      if (uuid instanceof Uint8Array && uuid.length === 16) {
        const hex = Array.from(uuid, (byte: number) => byte.toString(16).padStart(2, '0')).join('');
        return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
      }
      if (typeof uuid === 'number' && Number.isSafeInteger(uuid)) {
        return `${uuid}`;
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
    const bytes = await HarmonyAirPlayCrypto.randomBytes(4);
    const value = bytes[0] * 0x1000000 + bytes[1] * 0x10000 + bytes[2] * 0x100 + bytes[3];
    return value === 0 ? 1 : value;
  }
}
