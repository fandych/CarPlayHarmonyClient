import { AirPlayControlKeys } from './AirPlayPairingClient';
import { HarmonyAirPlayCrypto } from './HarmonyAirPlayCrypto';

export interface AirPlayControlCipherCrypto {
  seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array>;
  open(key: Uint8Array, nonce: Uint8Array, ciphertext: Uint8Array, aad: Uint8Array): Promise<Uint8Array>;
}

export class HarmonyAirPlayControlCipherCrypto implements AirPlayControlCipherCrypto {
  seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
    return HarmonyAirPlayCrypto.chachaSeal(key, nonce, plaintext, aad);
  }

  open(key: Uint8Array, nonce: Uint8Array, ciphertext: Uint8Array, aad: Uint8Array): Promise<Uint8Array> {
    return HarmonyAirPlayCrypto.chachaOpen(key, nonce, ciphertext, aad);
  }
}

export class AirPlayControlCipher {
  private static readonly MAX_WRITE_CHUNK: number = 1422;
  private static readonly MAX_READ_FRAME: number = 65535;
  private static readonly MAX_READ_BUFFER: number = 1024 * 1024;
  private static readonly TAG_SIZE: number = 16;
  private readonly readKey: Uint8Array;
  private readonly writeKey: Uint8Array;
  private readonly crypto: AirPlayControlCipherCrypto;
  private readCounter: number = 0;
  private writeCounter: number = 0;
  private readBuffer: Uint8Array = new Uint8Array(0);

  constructor(
    keys: AirPlayControlKeys,
    crypto: AirPlayControlCipherCrypto = new HarmonyAirPlayControlCipherCrypto()
  ) {
    if (keys.phoneReadKey.length !== 32 || keys.phoneWriteKey.length !== 32) {
      throw new Error('AirPlay control encryption requires two 32-byte directional keys.');
    }
    this.readKey = keys.phoneReadKey.slice();
    this.writeKey = keys.phoneWriteKey.slice();
    this.crypto = crypto;
  }

  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    const frames: Uint8Array[] = [];
    let offset = 0;
    while (offset < plaintext.length) {
      const chunk = plaintext.slice(offset, Math.min(offset + AirPlayControlCipher.MAX_WRITE_CHUNK, plaintext.length));
      const header = new Uint8Array([
        chunk.length & 0xFF,
        (chunk.length >>> 8) & 0xFF
      ]);
      const sealed = await this.crypto.seal(
        this.writeKey,
        HarmonyAirPlayCrypto.nonceCounter(this.writeCounter),
        chunk,
        header
      );
      if (sealed.length !== chunk.length + AirPlayControlCipher.TAG_SIZE) {
        throw new Error('AirPlay control cipher returned an invalid ciphertext frame.');
      }
      frames.push(header, sealed);
      this.writeCounter++;
      offset += chunk.length;
    }
    return AirPlayControlCipher.concat(...frames);
  }

  async decrypt(fragment: Uint8Array): Promise<Uint8Array> {
    if (fragment.length + this.readBuffer.length > AirPlayControlCipher.MAX_READ_BUFFER) {
      throw new Error('AirPlay control receive buffer exceeds the supported limit.');
    }
    this.readBuffer = AirPlayControlCipher.concat(this.readBuffer, fragment);
    const plaintextFrames: Uint8Array[] = [];
    let offset = 0;
    while (this.readBuffer.length - offset >= 2) {
      const length = this.readBuffer[offset] | (this.readBuffer[offset + 1] << 8);
      if (length > AirPlayControlCipher.MAX_READ_FRAME) {
        throw new Error(`AirPlay control frame length ${length} exceeds the supported limit.`);
      }
      const frameEnd = offset + 2 + length + AirPlayControlCipher.TAG_SIZE;
      if (this.readBuffer.length < frameEnd) {
        break;
      }
      const aad = this.readBuffer.slice(offset, offset + 2);
      const encrypted = this.readBuffer.slice(offset + 2, frameEnd);
      const plaintext = await this.crypto.open(
        this.readKey,
        HarmonyAirPlayCrypto.nonceCounter(this.readCounter),
        encrypted,
        aad
      );
      if (plaintext.length !== length) {
        throw new Error('AirPlay control cipher decrypted a frame with an invalid length.');
      }
      plaintextFrames.push(plaintext);
      this.readCounter++;
      offset = frameEnd;
    }
    this.readBuffer = this.readBuffer.slice(offset);
    return AirPlayControlCipher.concat(...plaintextFrames);
  }

  private static concat(...values: Uint8Array[]): Uint8Array {
    let length = 0;
    values.forEach((value: Uint8Array) => length += value.length);
    const output = new Uint8Array(length);
    let offset = 0;
    values.forEach((value: Uint8Array) => {
      output.set(value, offset);
      offset += value.length;
    });
    return output;
  }
}
