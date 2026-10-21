import cryptoFramework from '@ohos.security.cryptoFramework';

export async function chachaSeal(
  keyBytes: Uint8Array,
  nonce: Uint8Array,
  plaintext: Uint8Array,
  associatedData: Uint8Array
): Promise<Uint8Array> {
  if (keyBytes.length !== 32 || nonce.length !== 12) {
    throw new Error('ChaCha20-Poly1305 requires a 32-byte key and 12-byte nonce');
  }
  const generator = cryptoFramework.createSymKeyGenerator('ChaCha20');
  const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
  const key = await generator.convertKey(keyBlob);
  const cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
  const params: cryptoFramework.AeadParamsSpec = {
    algName: 'ChaCha20|Poly1305',
    nonce,
    authenticatedData: associatedData,
    tagLen: 16
  };
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
  const data: cryptoFramework.DataBlob = { data: plaintext };
  const sealed = await cipher.doFinal(data);
  return sealed.data;
}

export async function chachaOpen(
  keyBytes: Uint8Array,
  nonce: Uint8Array,
  ciphertextAndTag: Uint8Array,
  associatedData: Uint8Array
): Promise<Uint8Array> {
  if (keyBytes.length !== 32 || nonce.length !== 12) {
    throw new Error('ChaCha20-Poly1305 requires a 32-byte key and 12-byte nonce');
  }
  const generator = cryptoFramework.createSymKeyGenerator('ChaCha20');
  const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
  const key = await generator.convertKey(keyBlob);
  const cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
  const params: cryptoFramework.AeadParamsSpec = {
    algName: 'ChaCha20|Poly1305',
    nonce,
    authenticatedData: associatedData,
    tagLen: 16
  };
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
  const data: cryptoFramework.DataBlob = { data: ciphertextAndTag };
  const opened = await cipher.doFinal(data);
  return opened.data;
}
