import { BinaryPlist, BinaryPlistValue } from './BinaryPlist';
import { CarPlayInviteProtocol } from './CarPlayInviteProtocol';

export interface AudioMediaSetupParameters {
  streamType: number;
  streamConnectionId: number;
  audioFormat: number;
  audioType: string;
  latencyMs: number;
  supportsHighAccuracyTimestamps: boolean;
  samplesPerFrame?: number;
}

export interface AirPlaySenderMetadata {
  name: string;
  model: string;
  osName: string;
  osBuildVersion: string;
  osVersion: string;
  sourceVersion: string;
}

export class AirPlayMediaStreamPorts {
  readonly streamType: number;
  readonly dataPort: number;
  readonly controlPort: number;

  constructor(streamType: number, dataPort: number, controlPort: number) {
    this.streamType = streamType;
    this.dataPort = dataPort;
    this.controlPort = controlPort;
  }
}

export class AirPlayInitialSetupInfo {
  readonly eventPort: number;
  readonly timingPort: number;
  readonly keepAlivePort: number;
  readonly enabledFeatures: string[];

  constructor(eventPort: number, timingPort: number, keepAlivePort: number, enabledFeatures: string[]) {
    this.eventPort = eventPort;
    this.timingPort = timingPort;
    this.keepAlivePort = keepAlivePort;
    this.enabledFeatures = enabledFeatures;
  }
}

export class AirPlayMediaSetupProtocol {
  static readonly SCREEN_STREAM_TYPE: number = 110;
  static readonly PCM_AUDIO_STREAM_TYPE: number = 100;
  static readonly HIGH_QUALITY_AUDIO_STREAM_TYPE: number = 102;
  static buildInitialSetupBody(
    realBluetoothAddress: string,
    timingPort: number,
    sessionUuid: string,
    correlationUuid: string,
    sender: AirPlaySenderMetadata,
    encrypted: boolean = true
  ): Uint8Array {
    const identity = CarPlayInviteProtocol.createTxtIdentity(realBluetoothAddress);
    AirPlayMediaSetupProtocol.requirePort(timingPort, 'AirPlay timing port');
    AirPlayMediaSetupProtocol.requireUuid(sessionUuid, 'AirPlay session UUID');
    AirPlayMediaSetupProtocol.requireUuid(correlationUuid, 'AirPlay correlation UUID');
    if (sessionUuid.toLowerCase() === correlationUuid.toLowerCase()) {
      throw new Error('AirPlay session and correlation UUIDs must be distinct.');
    }
    AirPlayMediaSetupProtocol.requireSenderMetadata(sender);
    const fields: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    fields.set('deviceID', identity);
    fields.set('macAddress', identity);
    fields.set('name', sender.name);
    fields.set('model', sender.model);
    fields.set('osName', sender.osName);
    fields.set('osBuildVersion', sender.osBuildVersion);
    fields.set('osVersion', sender.osVersion);
    fields.set('sourceVersion', sender.sourceVersion);
    fields.set('timingPort', timingPort);
    fields.set('sessionUUID', sessionUuid.toUpperCase());
    fields.set('sessionCorrelationUUID', correlationUuid.toUpperCase());
    fields.set('statsCollectionEnabled', false);
    fields.set('updateSessionRequest', false);
    fields.set('keepAliveLowPower', true);
    fields.set('features', [
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
    ]);
    if (!encrypted) {
      fields.set('et', 1);
    }
    return BinaryPlist.encode(fields);
  }

  static buildScreenSetupBody(streamConnectionId: number, displayUuid: string): Uint8Array {
    AirPlayMediaSetupProtocol.requireStreamConnectionId(streamConnectionId);
    if (displayUuid.length === 0 || displayUuid.length > 128) {
      throw new Error('AirPlay display UUID is missing or too long.');
    }
    const stream: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    stream.set('type', AirPlayMediaSetupProtocol.SCREEN_STREAM_TYPE);
    stream.set('streamConnectionID', streamConnectionId);
    stream.set('uuid', displayUuid);
    stream.set('latencyMs', 25);
    const root: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    root.set('streams', [stream]);
    return BinaryPlist.encode(root);
  }

  static buildAudioSetupBody(parameters: AudioMediaSetupParameters): Uint8Array {
    AirPlayMediaSetupProtocol.requireStreamConnectionId(parameters.streamConnectionId);
    AirPlayMediaSetupProtocol.requireUnsigned(parameters.streamType, 255, 'AirPlay audio stream type');
    AirPlayMediaSetupProtocol.requireUnsigned(parameters.audioFormat, Number.MAX_SAFE_INTEGER, 'AirPlay audio format');
    if (parameters.audioType.length === 0 || !Number.isInteger(parameters.latencyMs) ||
      parameters.latencyMs < 0 || parameters.latencyMs > 2000) {
      throw new Error('AirPlay audio type or latency is invalid.');
    }
    const stream: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    stream.set('type', parameters.streamType);
    stream.set('streamConnectionID', parameters.streamConnectionId);
    stream.set('audioFormat', parameters.audioFormat);
    stream.set('audioType', parameters.audioType);
    stream.set('audioLatencyMs', parameters.latencyMs);
    stream.set('input', false);
    stream.set('supportsRTPPacketRedundancy', false);
    stream.set('supportsHighAccuracyTimestamps', parameters.supportsHighAccuracyTimestamps);
    if (parameters.samplesPerFrame !== undefined) {
      AirPlayMediaSetupProtocol.requireUnsigned(parameters.samplesPerFrame, 65535, 'AirPlay samples per frame');
      stream.set('spf', parameters.samplesPerFrame);
    }
    const root: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    root.set('streams', [stream]);
    return BinaryPlist.encode(root);
  }

  static buildRecordBody(): Uint8Array {
    return BinaryPlist.encode(new Map<string, BinaryPlistValue>());
  }

  static parseStreamPorts(responseBody: Uint8Array, expectedStreamType: number): AirPlayMediaStreamPorts {
    const root = BinaryPlist.parse(responseBody);
    if (!(root instanceof Map)) {
      throw new Error('AirPlay SETUP response is not a Binary Plist dictionary.');
    }
    const streams = root.get('streams');
    if (!Array.isArray(streams)) {
      throw new Error('AirPlay SETUP response does not contain a streams array.');
    }
    let matching: Map<string, BinaryPlistValue> | undefined = undefined;
    for (const item of streams) {
      if (item instanceof Map && item.get('type') === expectedStreamType) {
        matching = item;
        break;
      }
    }
    if (matching === undefined) {
      throw new Error(`AirPlay SETUP response omitted stream type ${expectedStreamType}.`);
    }
    const dataPort = AirPlayMediaSetupProtocol.readPort(matching.get('dataPort'), 'dataPort', true);
    const controlPort = AirPlayMediaSetupProtocol.readPort(matching.get('controlPort'), 'controlPort', false);
    return new AirPlayMediaStreamPorts(expectedStreamType, dataPort, controlPort);
  }

  static parseInitialSetupResponse(responseBody: Uint8Array): AirPlayInitialSetupInfo {
    const root = BinaryPlist.parse(responseBody);
    if (!(root instanceof Map)) {
      throw new Error('AirPlay initial SETUP response is not a Binary Plist dictionary.');
    }
    const eventPort = AirPlayMediaSetupProtocol.readPort(root.get('eventPort'), 'eventPort', false);
    const timingPort = AirPlayMediaSetupProtocol.readPort(root.get('timingPort'), 'timingPort', false);
    const keepAlivePort = AirPlayMediaSetupProtocol.readPort(root.get('keepAlivePort'), 'keepAlivePort', false);
    const features = root.get('enabledFeatures');
    if (features !== undefined && (!Array.isArray(features) ||
      features.some((feature: BinaryPlistValue) => typeof feature !== 'string'))) {
      throw new Error('AirPlay initial SETUP enabledFeatures field is invalid.');
    }
    return new AirPlayInitialSetupInfo(
      eventPort,
      timingPort,
      keepAlivePort,
      features === undefined ? [] : features as string[]
    );
  }

  private static readPort(value: BinaryPlistValue | undefined, label: string, required: boolean): number {
    if (value === undefined || typeof value !== 'number' || !Number.isInteger(value)) {
      if (!required && value === undefined) {
        return 0;
      }
      throw new Error(`AirPlay SETUP ${label} is missing or invalid.`);
    }
    const port = value < 0 && value >= -65535 ? value & 0xFFFF : value;
    if (port < (required ? 1 : 0) || port > 65535) {
      throw new Error(`AirPlay SETUP ${label} is outside the valid port range.`);
    }
    return port;
  }

  private static requirePort(port: number, label: string): void {
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error(`${label} must be between 1 and 65535.`);
    }
  }

  private static requireSenderMetadata(sender: AirPlaySenderMetadata): void {
    const values: string[] = [
      sender.name,
      sender.model,
      sender.osName,
      sender.osBuildVersion,
      sender.osVersion,
      sender.sourceVersion
    ];
    if (values.some((value: string) => value.trim().length === 0 || value.length > 128)) {
      throw new Error('AirPlay sender metadata contains a missing or oversized value.');
    }
  }

  private static requireStreamConnectionId(value: number): void {
    AirPlayMediaSetupProtocol.requireUnsigned(value, Number.MAX_SAFE_INTEGER, 'AirPlay stream connection ID');
    if (value === 0) {
      throw new Error('AirPlay stream connection ID must be nonzero.');
    }
  }

  private static requireUuid(value: string, label: string): void {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
      throw new Error(`${label} must be a canonical UUID.`);
    }
  }

  private static requireUnsigned(value: number, maximum: number, label: string): void {
    if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
      throw new Error(`${label} is outside the supported range.`);
    }
  }
}
