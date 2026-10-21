import cryptoFramework from '@ohos.security.cryptoFramework';

const N_HEX: string =
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

const N: bigint = BigInt(`0x${N_HEX}`);
const G: bigint = BigInt(5);
const MODULUS_BYTES = 384;
const IDENTIFIER = ascii('Pair-Setup');
const PASSWORD = ascii('3939');
const COLON = new Uint8Array([0x3A]);

export interface Srp6aCryptoProvider {
  randomBytes(length: number): Promise<Uint8Array>;
  sha512(data: Uint8Array): Promise<Uint8Array>;
}

class HarmonySrp6aCryptoProvider implements Srp6aCryptoProvider {
  async randomBytes(length: number): Promise<Uint8Array> {
    return (await cryptoFramework.createRandom().generateRandom(length)).data;
  }

  async sha512(data: Uint8Array): Promise<Uint8Array> {
    const digest = cryptoFramework.createMd('SHA512');
    await digest.update({ data });
    return (await digest.digest()).data;
  }
}

const DEFAULT_CRYPTO_PROVIDER: Srp6aCryptoProvider = new HarmonySrp6aCryptoProvider();

function ascii(value: string): Uint8Array {
  const output = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code > 0x7F) {
      throw new Error('SRP identifiers and passwords must be ASCII.');
    }
    output[index] = code;
  }
  return output;
}

function concat(...values: Uint8Array[]): Uint8Array {
  let length = 0;
  for (const value of values) {
    length += value.length;
  }
  const output = new Uint8Array(length);
  let offset = 0;
  for (const value of values) {
    output.set(value, offset);
    offset += value.length;
  }
  return output;
}

export interface Srp6aSession {
  publicKeyA: Uint8Array;
  prove(serverPublicKeyB: Uint8Array): Promise<Srp6aProof>;
}

export interface Srp6aProof {
  clientProof: Uint8Array;
  sessionKey: Uint8Array;
  verifyServerProof(serverProof: Uint8Array): Promise<boolean>;
}

export class Srp6aClient {
  static async start(
    salt: Uint8Array,
    crypto: Srp6aCryptoProvider = DEFAULT_CRYPTO_PROVIDER
  ): Promise<Srp6aSession> {
    if (salt.length === 0) {
      throw new Error('SRP salt must not be empty.');
    }
    const aBytes = await crypto.randomBytes(32);
    if (aBytes.length !== 32) {
      throw new Error('SRP random provider returned an invalid private value.');
    }
    const privateA = Srp6aClient.toBigInt(aBytes);
    const publicKeyA = Srp6aClient.toFixedBytes(Srp6aClient.modPow(G, privateA, N), MODULUS_BYTES);
    return {
      publicKeyA,
      prove: async (serverPublicKeyB: Uint8Array): Promise<Srp6aProof> => {
        if (serverPublicKeyB.length === 0 || serverPublicKeyB.length > MODULUS_BYTES) {
          throw new Error('SRP server public key has an invalid length.');
        }
        const b = Srp6aClient.toBigInt(serverPublicKeyB);
        if (b % N === BigInt(0)) {
          throw new Error('SRP server public key is invalid.');
        }
        const paddedB = Srp6aClient.toFixedBytes(b, MODULUS_BYTES);
        const multiplier = Srp6aClient.toBigInt(await Srp6aClient.sha512(crypto,
          concat(
            Srp6aClient.toFixedBytes(N, MODULUS_BYTES),
            Srp6aClient.toFixedBytes(G, MODULUS_BYTES)
          )
        ));
        const scramblingParameter = Srp6aClient.toBigInt(await Srp6aClient.sha512(crypto,
          concat(publicKeyA, paddedB)
        ));
        const innerPasswordHash = await Srp6aClient.sha512(crypto,
          concat(IDENTIFIER, COLON, PASSWORD)
        );
        const x = Srp6aClient.toBigInt(await Srp6aClient.sha512(crypto,
          concat(salt, innerPasswordHash)
        ));
        const verifier = Srp6aClient.modPow(G, x, N);
        const base = ((b - multiplier * verifier) % N + N) % N;
        if (base === BigInt(0)) {
          throw new Error('SRP server public key produced a zero base.');
        }
        const sharedSecret = Srp6aClient.modPow(base, privateA + scramblingParameter * x, N);
        const sessionKey = await Srp6aClient.sha512(crypto, Srp6aClient.toMinimalBytes(sharedSecret));
        const hashN = await Srp6aClient.sha512(crypto, Srp6aClient.toMinimalBytes(N));
        const hashG = await Srp6aClient.sha512(crypto, Srp6aClient.toMinimalBytes(G));
        const hashXor = new Uint8Array(hashN.length);
        for (let index = 0; index < hashN.length; index++) {
          hashXor[index] = hashN[index] ^ hashG[index];
        }
        const clientProof = await Srp6aClient.sha512(crypto, concat(
          hashXor,
          await Srp6aClient.sha512(crypto, IDENTIFIER),
          salt,
          publicKeyA,
          paddedB,
          sessionKey
        ));
        return {
          clientProof,
          sessionKey,
          verifyServerProof: async (serverProof: Uint8Array): Promise<boolean> => {
            const expected = await Srp6aClient.sha512(crypto,
              concat(publicKeyA, clientProof, sessionKey)
            );
            return Srp6aClient.constantTimeEqual(expected, serverProof);
          }
        };
      }
    };
  }

  private static modPow(base: bigint, exponent: bigint, modulus: bigint): bigint {
    let result = BigInt(1);
    let factor = base % modulus;
    let power = exponent;
    while (power > BigInt(0)) {
      if ((power & BigInt(1)) === BigInt(1)) {
        result = (result * factor) % modulus;
      }
      factor = (factor * factor) % modulus;
      power >>= BigInt(1);
    }
    return result;
  }

  private static async sha512(crypto: Srp6aCryptoProvider, input: Uint8Array): Promise<Uint8Array> {
    const digest = await crypto.sha512(input);
    if (digest.length !== 64) {
      throw new Error('SRP SHA-512 provider returned an invalid digest.');
    }
    return digest;
  }

  private static toBigInt(bytes: Uint8Array): bigint {
    let hex = '';
    for (const byte of bytes) {
      hex += byte.toString(16).padStart(2, '0');
    }
    return BigInt(hex.length === 0 ? '0' : `0x${hex}`);
  }

  private static toMinimalBytes(value: bigint): Uint8Array {
    if (value < BigInt(0)) {
      throw new Error('Cannot encode a negative SRP value.');
    }
    const hex = value.toString(16).padStart(2, '0');
    const normalized = hex.length % 2 === 0 ? hex : `0${hex}`;
    const bytes = new Uint8Array(normalized.length / 2);
    for (let index = 0; index < bytes.length; index++) {
      bytes[index] = Number.parseInt(normalized.slice(index * 2, index * 2 + 2), 16);
    }
    return bytes;
  }

  private static toFixedBytes(value: bigint, length: number): Uint8Array {
    const bytes = Srp6aClient.toMinimalBytes(value);
    if (bytes.length > length) {
      throw new Error('SRP integer exceeds its fixed-width encoding.');
    }
    const output = new Uint8Array(length);
    output.set(bytes, length - bytes.length);
    return output;
  }

  private static constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) {
      return false;
    }
    let difference = 0;
    for (let index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference === 0;
  }

}
