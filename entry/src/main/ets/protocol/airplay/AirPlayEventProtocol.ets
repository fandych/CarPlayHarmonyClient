import { BinaryPlist, BinaryPlistValue } from './BinaryPlist';

export interface AirPlayHidDevice {
  uuid: string;
  descriptor?: Uint8Array;
}

export interface AirPlayHidContact {
  slot: number;
  x: number;
  y: number;
  down: boolean;
}

export interface AirPlayEventDisplayGeometry {
  width?: number;
  height?: number;
}

export interface AirPlayHidTouchReport {
  kind: 'touch';
  contacts: AirPlayHidContact[];
}

export interface AirPlayHidConsumerReport {
  kind: 'consumer';
  usages: number[];
}

export interface AirPlayHidUnknownReport {
  kind: 'unknown';
}

export type AirPlayHidReportInterpretation =
  | AirPlayHidTouchReport
  | AirPlayHidConsumerReport
  | AirPlayHidUnknownReport;

export interface AirPlayHidReportCommand {
  kind: 'hid-report';
  uuid: string;
  report: Uint8Array;
  descriptor?: Uint8Array;
  displayWidth?: number;
  displayHeight?: number;
}

export interface AirPlayIapMessageCommand {
  kind: 'iap-message';
  data: Uint8Array;
}

export interface AirPlayForceKeyFrameCommand {
  kind: 'force-key-frame';
}

export interface AirPlayUnknownCommand {
  kind: 'unknown';
  commandType: string;
}

export type AirPlayEventCommand =
  | AirPlayHidReportCommand
  | AirPlayIapMessageCommand
  | AirPlayForceKeyFrameCommand
  | AirPlayUnknownCommand;

export interface AirPlayReceiverDisplayInfo extends AirPlayEventDisplayGeometry {
  uuid: string;
}

interface HidItem {
  type: number;
  tag: number;
  value: number;
}

interface ConsumerLayout {
  usages: number[];
  array: boolean;
}

type TouchFormat = 'single' | 'multi';

const MAX_HID_DESCRIPTOR_BYTES = 64 * 1024;
const MAX_HID_REPORT_BYTES = 4096;

export class AirPlayEventProtocol {
  static parseCommand(body: Uint8Array): AirPlayEventCommand {
    const root = BinaryPlist.parse(body);
    if (!(root instanceof Map)) {
      throw new Error('AirPlay event command is not a Binary Plist dictionary.');
    }
    const commandType = root.get('type');
    if (typeof commandType !== 'string' || commandType.length === 0) {
      throw new Error('AirPlay event command does not contain a valid type.');
    }
    if (commandType === 'hidSendReport') {
      const uuid = AirPlayEventProtocol.readUuid(root.get('uuid'));
      const report = root.get('hidReport');
      if (!(report instanceof Uint8Array) || report.length === 0 || report.length > MAX_HID_REPORT_BYTES) {
        throw new Error('AirPlay HID report is missing or outside the supported size.');
      }
      const command: AirPlayHidReportCommand = { kind: 'hid-report', uuid, report: report.slice() };
      return command;
    }
    if (commandType === 'iAPSendMessage') {
      const parameters = root.get('params');
      if (!(parameters instanceof Map)) {
        throw new Error('AirPlay iAP message does not contain a parameters dictionary.');
      }
      const data = parameters.get('data');
      if (!(data instanceof Uint8Array) || data.length === 0 || data.length > MAX_HID_REPORT_BYTES) {
        throw new Error('AirPlay iAP message data is missing or outside the supported size.');
      }
      const command: AirPlayIapMessageCommand = { kind: 'iap-message', data: data.slice() };
      return command;
    }
    if (commandType === 'forceKeyFrame') {
      const command: AirPlayForceKeyFrameCommand = { kind: 'force-key-frame' };
      return command;
    }
    const command: AirPlayUnknownCommand = { kind: 'unknown', commandType };
    return command;
  }

  static readHidDevices(info: Uint8Array): AirPlayHidDevice[] {
    const root = BinaryPlist.parse(info);
    if (!(root instanceof Map)) {
      throw new Error('AirPlay /info response is not a Binary Plist dictionary.');
    }
    const devices: AirPlayHidDevice[] = [];
    for (const key of ['hidDevices', 'hids', 'hid']) {
      const value = root.get(key);
      if (!Array.isArray(value)) {
        continue;
      }
      for (const item of value) {
        if (!(item instanceof Map)) {
          continue;
        }
        const uuid = AirPlayEventProtocol.tryReadUuid(item.get('uuid'));
        const descriptor = item.get('hidDescriptor');
        if (uuid === undefined || (descriptor !== undefined && !(descriptor instanceof Uint8Array))) {
          continue;
        }
        if (descriptor instanceof Uint8Array && descriptor.length > MAX_HID_DESCRIPTOR_BYTES) {
          throw new Error(`AirPlay HID descriptor for ${uuid} exceeds the supported size.`);
        }
        const device: AirPlayHidDevice = {
          uuid,
          descriptor: descriptor instanceof Uint8Array ? descriptor.slice() : undefined
        };
        devices.push(device);
      }
    }
    return devices;
  }

  static enrichCommand(
    command: AirPlayEventCommand,
    devices: AirPlayHidDevice[],
    geometry: AirPlayEventDisplayGeometry
  ): AirPlayEventCommand {
    if (command.kind !== 'hid-report') {
      return command;
    }
    const device = devices.find((candidate: AirPlayHidDevice) => candidate.uuid === command.uuid);
    const enriched: AirPlayHidReportCommand = {
      kind: 'hid-report',
      uuid: command.uuid,
      report: command.report.slice(),
      descriptor: device?.descriptor?.slice(),
      displayWidth: geometry.width,
      displayHeight: geometry.height
    };
    return enriched;
  }

  static interpretHidReport(report: Uint8Array, descriptor?: Uint8Array): AirPlayHidReportInterpretation {
    if (report.length === 0 || report.length > MAX_HID_REPORT_BYTES) {
      const result: AirPlayHidUnknownReport = { kind: 'unknown' };
      return result;
    }
    if (descriptor !== undefined) {
      const consumer = AirPlayEventProtocol.parseConsumerLayout(descriptor);
      if (consumer !== undefined) {
        const usages = AirPlayEventProtocol.readConsumerUsages(report, consumer);
        if (usages === undefined) {
          const result: AirPlayHidUnknownReport = { kind: 'unknown' };
          return result;
        }
        const result: AirPlayHidConsumerReport = { kind: 'consumer', usages };
        return result;
      }
    }
    const format = descriptor === undefined
      ? undefined
      : AirPlayEventProtocol.touchFormatFromDescriptor(descriptor);
    const resolvedFormat = format ?? (report.length === 5 ? 'single' : report.length >= 12 ? 'multi' : undefined);
    if (resolvedFormat === undefined) {
      if (descriptor === undefined && report.length === 1 && report[0] !== 0) {
        const usages: number[] = [report[0]];
        const result: AirPlayHidConsumerReport = { kind: 'consumer', usages };
        return result;
      }
      const result: AirPlayHidUnknownReport = { kind: 'unknown' };
      return result;
    }
    const contacts = AirPlayEventProtocol.parseTouchReport(report, resolvedFormat);
    if (contacts === undefined) {
      const result: AirPlayHidUnknownReport = { kind: 'unknown' };
      return result;
    }
    const result: AirPlayHidTouchReport = { kind: 'touch', contacts };
    return result;
  }

  static consumerKeyName(usage: number): string | undefined {
    switch (usage) {
      case 0xB0:
        return 'play';
      case 0xB1:
        return 'pause';
      case 0xB3:
        return 'fast-forward';
      case 0xB4:
        return 'rewind';
      case 0xB5:
        return 'next';
      case 0xB6:
        return 'previous';
      case 0xB9:
        return 'stop';
      default:
        return undefined;
    }
  }

  static isTouchDescriptor(descriptor: Uint8Array): boolean {
    return AirPlayEventProtocol.touchFormatFromDescriptor(descriptor) !== undefined;
  }

  static buildHidSetInputModeCommand(uuid: string, mode: number = 0): Map<string, BinaryPlistValue> {
    if (uuid.length === 0 || uuid.length > 128 || !Number.isInteger(mode) || mode < 0 || mode > 255) {
      throw new Error('AirPlay HID input mode parameters are invalid.');
    }
    const parameters: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    parameters.set('hidInputMode', mode);
    parameters.set('uuid', uuid);
    const command: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    command.set('type', 'hidSetInputMode');
    command.set('params', parameters);
    return command;
  }

  static buildModesChangedCommand(): Map<string, BinaryPlistValue> {
    const appStates: BinaryPlistValue[] = [];
    const app2: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    app2.set('appStateID', 2);
    app2.set('entity', 0);
    appStates.push(app2);
    const app3: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    app3.set('appStateID', 3);
    app3.set('entity', 0);
    appStates.push(app3);
    const app1: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    app1.set('appStateID', 1);
    app1.set('entity', 0);
    app1.set('speechMode', -1);
    appStates.push(app1);

    const resources: BinaryPlistValue[] = [];
    const screen: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    screen.set('resourceID', 1);
    screen.set('entity', 1);
    screen.set('permanentEntity', 1);
    resources.push(screen);
    const audio: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    audio.set('resourceID', 2);
    audio.set('entity', 1);
    audio.set('permanentEntity', 1);
    resources.push(audio);
    const parameters: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    parameters.set('appStates', appStates);
    parameters.set('resources', resources);
    const command: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
    command.set('type', 'modesChanged');
    command.set('params', parameters);
    return command;
  }

  private static readConsumerUsages(report: Uint8Array, layout: ConsumerLayout): number[] | undefined {
    if (layout.usages.length === 0) {
      return undefined;
    }
    if (layout.array) {
      const index = report[0];
      const usage = index === 0 ? undefined : layout.usages[index];
      return usage === undefined || usage === 0 ? [] : [usage];
    }
    const usages: number[] = [];
    for (let index = 0; index < layout.usages.length; index++) {
      const byteIndex = Math.floor(index / 8);
      if (byteIndex >= report.length) {
        break;
      }
      if (((report[byteIndex] >>> (index % 8)) & 1) !== 0 && layout.usages[index] !== 0) {
        usages.push(layout.usages[index]);
      }
    }
    return usages;
  }

  private static parseConsumerLayout(descriptor: Uint8Array): ConsumerLayout | undefined {
    const items = AirPlayEventProtocol.readHidItems(descriptor);
    if (items === undefined) {
      return undefined;
    }
    let usagePage = 0;
    let consumerDepth = 0;
    let usages: number[] = [];
    let usageMinimum: number | undefined = undefined;
    let usageMaximum: number | undefined = undefined;
    for (const item of items) {
      if (item.type === 1 && item.tag === 0) {
        usagePage = item.value;
      } else if (item.type === 2 && item.tag === 0) {
        if (consumerDepth > 0 && usagePage === 0x0C) {
          usages.push(item.value & 0xFFFF);
        }
      } else if (item.type === 2 && item.tag === 1) {
        usageMinimum = item.value & 0xFFFF;
      } else if (item.type === 2 && item.tag === 2) {
        usageMaximum = item.value & 0xFFFF;
      } else if (item.type === 0 && item.tag === 10) {
        if (consumerDepth > 0) {
          consumerDepth++;
        } else if (usagePage === 0x0C && item.value === 1) {
          consumerDepth = 1;
        }
      } else if (item.type === 0 && item.tag === 8) {
        if (consumerDepth > 0 && usagePage === 0x0C && (item.value & 1) === 0) {
          if (usageMinimum !== undefined && usageMaximum !== undefined) {
            if (usageMaximum < usageMinimum || usageMaximum - usageMinimum > 1024) {
              return undefined;
            }
            for (let usage = usageMinimum; usage <= usageMaximum; usage++) {
              usages.push(usage);
            }
          }
          if (usages.length > 0) {
            const layout: ConsumerLayout = { usages, array: (item.value & 2) === 0 };
            return layout;
          }
        }
        usages = [];
        usageMinimum = undefined;
        usageMaximum = undefined;
      } else if (item.type === 0 && item.tag === 12 && consumerDepth > 0) {
        consumerDepth--;
      }
    }
    return undefined;
  }

  private static touchFormatFromDescriptor(descriptor: Uint8Array): TouchFormat | undefined {
    const items = AirPlayEventProtocol.readHidItems(descriptor);
    if (items === undefined) {
      return undefined;
    }
    let usagePage = 0;
    let digitizerPageSeen = false;
    let hasSixteenBitInput = false;
    let fingerCollections = 0;
    for (const item of items) {
      if (item.type === 1 && item.tag === 0) {
        usagePage = item.value;
        if (usagePage === 0x0D) {
          digitizerPageSeen = true;
        }
      } else if (item.type === 1 && item.tag === 7 && item.value === 16 && usagePage === 0x0D) {
        hasSixteenBitInput = true;
      } else if (item.type === 2 && item.tag === 0 && item.value === 0x22 && usagePage === 0x0D) {
        fingerCollections++;
      }
    }
    if (!digitizerPageSeen || !hasSixteenBitInput) {
      return undefined;
    }
    return fingerCollections > 1 ? 'multi' : 'single';
  }

  private static parseTouchReport(report: Uint8Array, format: TouchFormat): AirPlayHidContact[] | undefined {
    if (format === 'single') {
      if (report.length < 5) {
        return undefined;
      }
      const contact: AirPlayHidContact = {
        slot: 0,
        down: (report[0] & 1) !== 0,
        x: AirPlayEventProtocol.readU16Le(report, 1),
        y: AirPlayEventProtocol.readU16Le(report, 3)
      };
      const contacts: AirPlayHidContact[] = [contact];
      return contacts;
    }
    if (report.length < 12) {
      return undefined;
    }
    const contacts: AirPlayHidContact[] = [];
    for (let slot = 0; slot < 2; slot++) {
      const offset = slot * 6;
      const state = report[offset + 1];
      if (state > 1) {
        return undefined;
      }
      const contact: AirPlayHidContact = {
        slot,
        down: state === 1,
        x: AirPlayEventProtocol.readU16Le(report, offset + 2),
        y: AirPlayEventProtocol.readU16Le(report, offset + 4)
      };
      contacts.push(contact);
    }
    return contacts;
  }

  private static readHidItems(descriptor: Uint8Array): HidItem[] | undefined {
    if (descriptor.length === 0 || descriptor.length > MAX_HID_DESCRIPTOR_BYTES) {
      return undefined;
    }
    const items: HidItem[] = [];
    let offset = 0;
    while (offset < descriptor.length) {
      const prefix = descriptor[offset++];
      if (prefix === 0xFE) {
        if (offset + 2 > descriptor.length) {
          return undefined;
        }
        const longSize = descriptor[offset];
        offset += 2;
        if (offset + longSize > descriptor.length) {
          return undefined;
        }
        offset += longSize;
        continue;
      }
      const sizeCode = prefix & 3;
      const size = sizeCode === 3 ? 4 : sizeCode;
      if (offset + size > descriptor.length) {
        return undefined;
      }
      let value = 0;
      for (let index = 0; index < size; index++) {
        value += descriptor[offset + index] * Math.pow(256, index);
      }
      offset += size;
      const item: HidItem = {
        type: (prefix >>> 2) & 3,
        tag: (prefix >>> 4) & 15,
        value
      };
      items.push(item);
    }
    return items;
  }

  private static readUuid(value: BinaryPlistValue | undefined): string {
    const uuid = AirPlayEventProtocol.tryReadUuid(value);
    if (uuid === undefined) {
      throw new Error('AirPlay HID report UUID is missing or invalid.');
    }
    return uuid;
  }

  private static tryReadUuid(value: BinaryPlistValue | undefined): string | undefined {
    if (typeof value === 'string' && value.length > 0 && value.length <= 128) {
      return value;
    }
    if (typeof value === 'number' && Number.isSafeInteger(value)) {
      return `${value}`;
    }
    return undefined;
  }

  private static readU16Le(bytes: Uint8Array, offset: number): number {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }
}
