import { nonce64 } from './AirPlayCrypto';
import { chachaOpen, chachaSeal } from '../crypto/AirPlayStreamCrypto';
import { concatBytes } from '../protocol/Iap2Codec';

const MAX_OUTGOING_PAYLOAD: number = 1422;
const MAX_INCOMING_PAYLOAD: number = 0xffff;
const TAG_BYTES: number = 16;

export class AirPlayControlCipher {
  private readonly readKey: Uint8Array;
  private readonly writeKey: Uint8Array;
  private readCounter: number = 0;
  private writeCounter: number = 0;
  private receiveBuffer: Uint8Array = new Uint8Array(0);

  constructor(readKey: Uint8Array, writeKey: Uint8Array) {
    if (readKey.length !== 32 || writeKey.length !== 32) {
      throw new Error('AirPlay control keys must each be 32 bytes');
    }
    this.readKey = readKey.slice();
    this.writeKey = writeKey.slice();
  }

  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    const frames: Uint8Array[] = [];
    let offset = 0;
    while (offset < plaintext.length) {
      const chunk = plaintext.slice(offset, Math.min(offset + MAX_OUTGOING_PAYLOAD, plaintext.length));
      const header = new Uint8Array([chunk.length & 0xff, (chunk.length >>> 8) & 0xff]);
      const encrypted = await chachaSeal(this.writeKey, nonce64(this.writeCounter), chunk, header);
      frames.push(header, encrypted);
      this.writeCounter++;
      offset += chunk.length;
    }
    return concatBytes(...frames);
  }

  async decrypt(chunk: Uint8Array): Promise<Uint8Array> {
    if (this.receiveBuffer.length + chunk.length > 1024 * 1024) {
      this.receiveBuffer = new Uint8Array(0);
      throw new Error('Encrypted AirPlay control input exceeded the 1 MiB safety limit');
    }
    this.receiveBuffer = concatBytes(this.receiveBuffer, chunk);
    const plaintext: Uint8Array[] = [];
    while (this.receiveBuffer.length >= 2) {
      const length = this.receiveBuffer[0] | (this.receiveBuffer[1] << 8);
      if (length > MAX_INCOMING_PAYLOAD) {
        this.receiveBuffer = new Uint8Array(0);
        throw new Error(`Invalid encrypted AirPlay control frame length ${length}`);
      }
      const frameLength = 2 + length + TAG_BYTES;
      if (this.receiveBuffer.length < frameLength) {
        break;
      }
      const header = this.receiveBuffer.slice(0, 2);
      const encrypted = this.receiveBuffer.slice(2, frameLength);
      plaintext.push(await chachaOpen(this.readKey, nonce64(this.readCounter), encrypted, header));
      this.readCounter++;
      this.receiveBuffer = this.receiveBuffer.slice(frameLength);
    }
    return concatBytes(...plaintext);
  }
}
