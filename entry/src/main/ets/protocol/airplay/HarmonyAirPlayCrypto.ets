import cryptoFramework from '@ohos.security.cryptoFramework';

export interface X25519EphemeralKey {
  privateKey: cryptoFramework.PriKey;
  publicKey: Uint8Array;
}

const ED25519_SPKI_PREFIX: number[] = [0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00];
const X25519_SPKI_PREFIX: number[] = [0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x6E, 0x03, 0x21, 0x00];

export class HarmonyAirPlayCrypto {
  static async randomBytes(length: number): Promise<Uint8Array> {
    if (!Number.isInteger(length) || length < 1) {
      throw new Error('Random byte length must be a positive integer.');
    }
    const random = await cryptoFramework.createRandom().generateRandom(length);
    return random.data;
  }

  static async sha512(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA512');
    await md.update({ data });
    const digest = await md.digest();
    return digest.data;
  }

  static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data });
    const digest = await md.digest();
    return digest.data;
  }

  static async hmacSha512(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC|SHA512');
    const macKey = await generator.convertKey({ data: key });
    const mac = cryptoFramework.createMac('HMAC|SHA512');
    await mac.init(macKey);
    await mac.update({ data });
    return (await mac.doFinal()).data;
  }

  static async hkdfSha512(
    inputKeyMaterial: Uint8Array,
    salt: Uint8Array,
    info: Uint8Array,
    length: number = 32
  ): Promise<Uint8Array> {
    if (!Number.isInteger(length) || length < 1 || length > 255 * 64) {
      throw new Error('HKDF output length is out of range.');
    }
    const actualSalt = salt.length === 0 ? new Uint8Array(64) : salt;
    const pseudorandomKey = await HarmonyAirPlayCrypto.hmacSha512(actualSalt, inputKeyMaterial);
    const blocks: Uint8Array[] = [];
    let previous = new Uint8Array(0);
    let produced = 0;
    for (let counter = 1; produced < length; counter++) {
      previous = await HarmonyAirPlayCrypto.hmacSha512(
        pseudorandomKey,
        HarmonyAirPlayCrypto.concat(previous, info, new Uint8Array([counter]))
      );
      blocks.push(previous);
      produced += previous.length;
    }
    return HarmonyAirPlayCrypto.concat(...blocks).slice(0, length);
  }

  static async chachaSeal(
    key: Uint8Array,
    nonce: Uint8Array,
    plaintext: Uint8Array,
    aad: Uint8Array = new Uint8Array(0)
  ): Promise<Uint8Array> {
    return HarmonyAirPlayCrypto.chacha(key, nonce, plaintext, aad, cryptoFramework.CryptoMode.ENCRYPT_MODE);
  }

  static async chachaOpen(
    key: Uint8Array,
    nonce: Uint8Array,
    ciphertext: Uint8Array,
    aad: Uint8Array = new Uint8Array(0)
  ): Promise<Uint8Array> {
    if (ciphertext.length < 16) {
      throw new Error('ChaCha20-Poly1305 ciphertext is shorter than its authentication tag.');
    }
    return HarmonyAirPlayCrypto.chacha(key, nonce, ciphertext, aad, cryptoFramework.CryptoMode.DECRYPT_MODE);
  }

  static async generateX25519Ephemeral(): Promise<X25519EphemeralKey> {
    const pair = await cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPair();
    return {
      privateKey: pair.priKey,
      publicKey: HarmonyAirPlayCrypto.extractRawPublicKey(pair.pubKey.getEncoded().data, X25519_SPKI_PREFIX)
    };
  }

  static async x25519Shared(
    privateKey: cryptoFramework.PriKey,
    peerPublicKey: Uint8Array
  ): Promise<Uint8Array> {
    HarmonyAirPlayCrypto.requireRawKey(peerPublicKey, 'X25519 public key');
    const encodedPublicKey = HarmonyAirPlayCrypto.wrapRawPublicKey(peerPublicKey, X25519_SPKI_PREFIX);
    const imported = await cryptoFramework.createAsyKeyGenerator('X25519')
      .convertKey({ data: encodedPublicKey }, null);
    const shared = await cryptoFramework.createKeyAgreement('X25519')
      .generateSecret(privateKey, imported.pubKey);
    if (shared.data.length !== 32 || shared.data.every((value: number) => value === 0)) {
      throw new Error('X25519 produced an invalid shared secret.');
    }
    return shared.data;
  }

  static async verifyEd25519(
    publicKey: Uint8Array,
    message: Uint8Array,
    signature: Uint8Array
  ): Promise<boolean> {
    HarmonyAirPlayCrypto.requireRawKey(publicKey, 'Ed25519 public key');
    if (signature.length !== 64) {
      return false;
    }
    const encodedPublicKey = HarmonyAirPlayCrypto.wrapRawPublicKey(publicKey, ED25519_SPKI_PREFIX);
    const imported = await cryptoFramework.createAsyKeyGenerator('Ed25519')
      .convertKey({ data: encodedPublicKey }, null);
    const verifier = cryptoFramework.createVerify('Ed25519');
    await verifier.init(imported.pubKey);
    return verifier.verify({ data: message }, { data: signature });
  }

  static nonceLabel(label: string): Uint8Array {
    const nonce = new Uint8Array(12);
    if (!/^[\x00-\x7F]*$/.test(label) || label.length > 8) {
      throw new Error('AirPlay nonce labels must be at most 8 ASCII characters.');
    }
    for (let index = 0; index < label.length; index++) {
      nonce[index + 4] = label.charCodeAt(index);
    }
    return nonce;
  }

  static nonceCounter(counter: number): Uint8Array {
    if (!Number.isSafeInteger(counter) || counter < 0) {
      throw new Error('AirPlay control nonce counter is out of range.');
    }
    const nonce = new Uint8Array(12);
    let value = counter;
    for (let index = 4; index < 12; index++) {
      nonce[index] = value % 256;
      value = Math.floor(value / 256);
    }
    return nonce;
  }

  static concat(...values: Uint8Array[]): Uint8Array {
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

  private static async chacha(
    key: Uint8Array,
    nonce: Uint8Array,
    input: Uint8Array,
    aad: Uint8Array,
    mode: cryptoFramework.CryptoMode
  ): Promise<Uint8Array> {
    if (key.length !== 32 || nonce.length !== 12) {
      throw new Error('ChaCha20-Poly1305 requires a 32-byte key and 12-byte nonce.');
    }
    const keyObject = await cryptoFramework.createSymKeyGenerator('ChaCha20').convertKey({ data: key });
    const cipher = cryptoFramework.createCipher('ChaCha20-Poly1305');
    const params: cryptoFramework.AeadParamsSpec = {
      algName: 'AeadParamsSpec',
      nonce,
      authenticatedData: aad,
      tagLen: 16
    };
    await cipher.init(mode, keyObject, params);
    return (await cipher.doFinal({ data: input })).data;
  }

  private static extractRawPublicKey(encoded: Uint8Array, prefix: number[]): Uint8Array {
    if (encoded.length === 32) {
      return encoded.slice();
    }
    if (encoded.length !== prefix.length + 32) {
      throw new Error(`Unexpected X25519 public-key encoding length: ${encoded.length}.`);
    }
    for (let index = 0; index < prefix.length; index++) {
      if (encoded[index] !== prefix[index]) {
        throw new Error('Unexpected public-key algorithm encoding.');
      }
    }
    return encoded.slice(prefix.length);
  }

  private static wrapRawPublicKey(raw: Uint8Array, prefix: number[]): Uint8Array {
    return HarmonyAirPlayCrypto.concat(new Uint8Array(prefix), raw);
  }

  private static requireRawKey(value: Uint8Array, label: string): void {
    if (value.length !== 32) {
      throw new Error(`${label} must contain exactly 32 bytes.`);
    }
  }
}
