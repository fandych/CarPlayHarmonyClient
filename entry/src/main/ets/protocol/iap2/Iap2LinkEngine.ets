import { Iap2LinkPacket, Iap2LinkPacketData, Iap2LinkStreamParser } from './Iap2LinkPacket';

export type Iap2LinkState = 'idle' | 'negotiating' | 'normal' | 'dead';

interface Iap2SessionDescriptor {
  id: number;
  kind: number;
  version: number;
}

interface Iap2Synchronization {
  maxOutgoing: number;
  maxLength: number;
  retransmissionTimeout: number;
  acknowledgementTimeout: number;
  maxRetransmissions: number;
  maxAcknowledgements: number;
  sessions: Iap2SessionDescriptor[];
}

const INITIAL_SEQUENCE = 99;
const SYNCHRONIZATION_VERSION = 1;
const MARKER = new Uint8Array([0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10]);
const SYNCHRONIZE = 0x80;
const ACKNOWLEDGEMENT = 0x40;
const RESET = 0x10;

function readU16(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function writeU16(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = (value >>> 8) & 0xFF;
  bytes[offset + 1] = value & 0xFF;
}

function nextSequence(sequence: number): number {
  return (sequence + 1) & 0xFF;
}

function concatenate(left: Uint8Array, right: Uint8Array): Uint8Array {
  const output = new Uint8Array(left.length + right.length);
  output.set(left);
  output.set(right, left.length);
  return output;
}

function encodeSynchronization(sync: Iap2Synchronization): Uint8Array {
  const bytes = new Uint8Array(10 + sync.sessions.length * 3);
  bytes[0] = SYNCHRONIZATION_VERSION;
  bytes[1] = sync.maxOutgoing;
  writeU16(bytes, 2, sync.maxLength);
  writeU16(bytes, 4, sync.retransmissionTimeout);
  writeU16(bytes, 6, sync.acknowledgementTimeout);
  bytes[8] = sync.maxRetransmissions;
  bytes[9] = sync.maxAcknowledgements;
  for (let index = 0; index < sync.sessions.length; index++) {
    const session = sync.sessions[index];
    const offset = 10 + index * 3;
    bytes[offset] = session.id;
    bytes[offset + 1] = session.kind;
    bytes[offset + 2] = session.version;
  }
  return bytes;
}

function decodeSynchronization(bytes: Uint8Array | null): Iap2Synchronization | null {
  if (bytes === null || bytes.length < 10 || bytes[0] !== SYNCHRONIZATION_VERSION ||
    (bytes.length - 10) % 3 !== 0) {
    return null;
  }
  const sessions: Iap2SessionDescriptor[] = [];
  for (let offset = 10; offset + 2 < bytes.length; offset += 3) {
    sessions.push({
      id: bytes[offset],
      kind: bytes[offset + 1],
      version: bytes[offset + 2]
    });
  }
  return {
    maxOutgoing: bytes[1],
    maxLength: readU16(bytes, 2),
    retransmissionTimeout: readU16(bytes, 4),
    acknowledgementTimeout: readU16(bytes, 6),
    maxRetransmissions: bytes[8],
    maxAcknowledgements: bytes[9],
    sessions
  };
}

function localSynchronization(sessions?: Iap2SessionDescriptor[]): Iap2Synchronization {
  return {
    maxOutgoing: 4,
    maxLength: 0xFFFF,
    retransmissionTimeout: 4000,
    acknowledgementTimeout: 500,
    maxRetransmissions: 4,
    maxAcknowledgements: 3,
    sessions: sessions === undefined ? [
      { id: 10, kind: 0, version: 2 },
      { id: 11, kind: 2, version: 1 },
      { id: 12, kind: 1, version: 2 }
    ] : sessions
  };
}

export class Iap2LinkEngine {
  state: Iap2LinkState = 'idle';
  onControl: ((bytes: Uint8Array) => void) | undefined = undefined;
  onStateChanged: ((state: Iap2LinkState) => void) | undefined = undefined;

  private readonly writeBytes: (bytes: Uint8Array) => void;
  private readonly parser: Iap2LinkStreamParser = new Iap2LinkStreamParser();
  private transmitSequence: number = INITIAL_SEQUENCE;
  private receiveSequence: number = 0;
  private controlSessionId: number = 10;
  private peerSynchronization: Iap2Synchronization | null = null;

  constructor(writeBytes: (bytes: Uint8Array) => void) {
    this.writeBytes = writeBytes;
  }

  start(): void {
    if (this.state !== 'idle') {
      return;
    }
    this.setState('negotiating');
    this.writeBytes(concatenate(
      MARKER,
      Iap2LinkPacket.encode({
        control: SYNCHRONIZE,
        sequence: this.transmitSequence,
        acknowledgement: this.receiveSequence,
        sessionId: 0,
        payload: encodeSynchronization(localSynchronization())
      })
    ));
  }

  feed(bytes: Uint8Array): void {
    if (this.state === 'dead') {
      return;
    }
    const packets = this.parser.offer(bytes);
    for (let index = 0; index < packets.length; index++) {
      this.handlePacket(packets[index]);
    }
  }

  sendControl(payload: Uint8Array): void {
    if (this.state !== 'normal') {
      throw new Error('iAP2 control session is not ready');
    }
    this.transmitSequence = nextSequence(this.transmitSequence);
    this.writeBytes(Iap2LinkPacket.encode({
      control: ACKNOWLEDGEMENT,
      sequence: this.transmitSequence,
      acknowledgement: this.receiveSequence,
      sessionId: this.controlSessionId,
      payload
    }));
  }

  close(): void {
    this.setState('dead');
  }

  private handlePacket(packet: Iap2LinkPacketData): void {
    if ((packet.control & RESET) !== 0) {
      this.setState('dead');
      return;
    }

    if ((packet.control & SYNCHRONIZE) !== 0) {
      const synchronization = decodeSynchronization(packet.payload);
      if (synchronization === null) {
        return;
      }
      this.peerSynchronization = synchronization;
      const controlSession = synchronization.sessions.find((session: Iap2SessionDescriptor) => session.kind === 0);
      this.controlSessionId = controlSession === undefined ? 10 : controlSession.id;
      this.receiveSequence = packet.sequence;

      if ((packet.control & ACKNOWLEDGEMENT) === 0) {
        const echo = localSynchronization(synchronization.sessions);
        echo.maxOutgoing = 0x7F;
        this.transmitSequence = nextSequence(this.transmitSequence);
        this.writeBytes(Iap2LinkPacket.encode({
          control: SYNCHRONIZE | ACKNOWLEDGEMENT,
          sequence: this.transmitSequence,
          acknowledgement: packet.sequence,
          sessionId: 0,
          payload: encodeSynchronization(echo)
        }));
      } else {
        this.sendAcknowledgement();
        this.setState('normal');
      }
      return;
    }

    if ((packet.control & ACKNOWLEDGEMENT) !== 0) {
      if (this.state === 'negotiating' && this.peerSynchronization !== null) {
        this.setState('normal');
      }
      if (packet.payload !== null && packet.sessionId === this.controlSessionId && this.state === 'normal') {
        this.receiveSequence = packet.sequence;
        this.onControl?.(packet.payload);
        this.sendAcknowledgement();
      }
    }
  }

  private sendAcknowledgement(): void {
    this.writeBytes(Iap2LinkPacket.encode({
      control: ACKNOWLEDGEMENT,
      sequence: this.transmitSequence,
      acknowledgement: this.receiveSequence,
      sessionId: 0,
      payload: null
    }));
  }

  private setState(state: Iap2LinkState): void {
    if (this.state !== state) {
      this.state = state;
      this.onStateChanged?.(state);
    }
  }
}
