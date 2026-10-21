import cryptoFramework from '@ohos.security.cryptoFramework';
import { concatBytes } from '../protocol/Iap2Codec';
import { sha512 } from './AirPlayCrypto';

const MODULUS_HEX: string =
  'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74' +
  '020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437' +
  '4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED' +
  'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05' +
  '98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB' +
  '9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B' +
  'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183' +
  '995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A' +
  '85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7AB' +
  'F5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8' +
  '7602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208' +
  'E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF';

export const SRP3072_MODULUS: bigint = BigInt(`0x${MODULUS_HEX}`);
export const SRP_GENERATOR: bigint = BigInt(5);
const GROUP_BYTES: number = 384;
const USERNAME: Uint8Array = new Uint8Array([
  0x50, 0x61, 0x69, 0x72, 0x2d, 0x53, 0x65, 0x74, 0x75, 0x70
]);
const SETUP_PASSWORD: Uint8Array = new Uint8Array([0x33, 0x39, 0x33, 0x39]);
const COLON: Uint8Array = new Uint8Array([0x3a]);

export class Srp6aSession {
  readonly publicKeyA: Uint8Array;
  private readonly salt: Uint8Array;
  private readonly publicKeyB: Uint8Array;
  private readonly privateExponent: bigint;
  private sessionKey?: Uint8Array;
  private clientProofValue?: Uint8Array;

  private constructor(
    publicKeyA: Uint8Array,
    privateExponent: bigint,
    salt: Uint8Array,
    publicKeyB: Uint8Array
  ) {
    this.publicKeyA = publicKeyA;
    this.privateExponent = privateExponent;
    this.salt = salt.slice();
    this.publicKeyB = publicKeyB.slice();
  }

  static async start(salt: Uint8Array, publicKeyB: Uint8Array): Promise<Srp6aSession> {
    if (salt.length === 0 || publicKeyB.length === 0) {
      throw new Error('SRP salt and server public key are required');
    }
    const random = await cryptoFramework.createRandom().generateRandom(32);
    let privateExponent = srpBytesToBigInt(new Uint8Array(random.data));
    if (privateExponent === BigInt(0)) {
      privateExponent = BigInt(1);
    }
    const publicKeyA = padSrpInteger(modPow(SRP_GENERATOR, privateExponent, SRP3072_MODULUS));
    return new Srp6aSession(publicKeyA, privateExponent, salt, publicKeyB);
  }

  async clientProof(): Promise<Uint8Array> {
    if (this.clientProofValue) {
      return this.clientProofValue.slice();
    }
    const bigB = srpBytesToBigInt(this.publicKeyB);
    if (bigB % SRP3072_MODULUS === BigInt(0)) {
      throw new Error('SRP server public key is invalid');
    }
    const multiplier = srpBytesToBigInt(await sha512(padSrpInteger(SRP3072_MODULUS), padSrpInteger(SRP_GENERATOR)));
    const userPasswordHash = await sha512(concatBytes(USERNAME, COLON, SETUP_PASSWORD));
    const privatePassword = srpBytesToBigInt(await sha512(this.salt, userPasswordHash));
    const scrambling = srpBytesToBigInt(await sha512(this.publicKeyA, padSrpInteger(bigB)));
    const verifier = modPow(SRP_GENERATOR, privatePassword, SRP3072_MODULUS);
    const base = modulo(bigB - multiplier * verifier, SRP3072_MODULUS);
    if (base === BigInt(0)) {
      throw new Error('SRP client public key is invalid');
    }

    const sharedSecret = modPow(base, this.privateExponent + scrambling * privatePassword, SRP3072_MODULUS);
    const key = await sha512(srpBigIntToBytes(sharedSecret));
    const hashN = await sha512(srpBigIntToBytes(SRP3072_MODULUS));
    const hashG = await sha512(srpBigIntToBytes(SRP_GENERATOR));
    const xorHash = new Uint8Array(hashN.length);
    for (let index = 0; index < hashN.length; index++) {
      xorHash[index] = hashN[index] ^ hashG[index];
    }
    const proof = await sha512(
      xorHash,
      await sha512(USERNAME),
      this.salt,
      this.publicKeyA,
      padSrpInteger(bigB),
      key
    );
    this.sessionKey = key;
    this.clientProofValue = proof;
    return proof.slice();
  }

  async verifyServerProof(serverProof: Uint8Array): Promise<boolean> {
    const proof = await this.clientProof();
    const key = this.sessionKey;
    if (!key) {
      throw new Error('SRP session key was not derived');
    }
    const expected = await sha512(this.publicKeyA, proof, key);
    return constantTimeEqual(expected, serverProof);
  }

  getSessionKey(): Uint8Array {
    if (!this.sessionKey) {
      throw new Error('SRP session key is not available before clientProof');
    }
    return this.sessionKey.slice();
  }
}

export function modPow(baseValue: bigint, exponentValue: bigint, modulus: bigint): bigint {
  if (modulus <= BigInt(0) || exponentValue < BigInt(0)) {
    throw new Error('Invalid modular exponentiation arguments');
  }
  let base = modulo(baseValue, modulus);
  let exponent = exponentValue;
  let result = BigInt(1);
  while (exponent > BigInt(0)) {
    if (exponent % BigInt(2) === BigInt(1)) {
      result = (result * base) % modulus;
    }
    exponent = exponent / BigInt(2);
    base = (base * base) % modulus;
  }
  return result;
}

function modulo(value: bigint, modulus: bigint): bigint {
  const remainder = value % modulus;
  return remainder < BigInt(0) ? remainder + modulus : remainder;
}

export function srpBytesToBigInt(bytes: Uint8Array): bigint {
  let value = BigInt(0);
  for (const byte of bytes) {
    value = (value << BigInt(8)) | BigInt(byte);
  }
  return value;
}

export function srpBigIntToBytes(value: bigint): Uint8Array {
  if (value < BigInt(0)) {
    throw new Error('Cannot encode a negative SRP integer');
  }
  let hex = value.toString(16);
  if (hex.length % 2 !== 0) {
    hex = `0${hex}`;
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index++) {
    bytes[index] = parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

export function padSrpInteger(value: bigint): Uint8Array {
  const bytes = srpBigIntToBytes(value);
  if (bytes.length > GROUP_BYTES) {
    throw new Error('SRP integer exceeds the 3072-bit group size');
  }
  const padded = new Uint8Array(GROUP_BYTES);
  padded.set(bytes, GROUP_BYTES - bytes.length);
  return padded;
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  let difference = 0;
  for (let index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}
