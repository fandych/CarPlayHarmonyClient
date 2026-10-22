import cert from '@ohos.security.cert';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { util } from '@kit.ArkTS';

function decodeUtf8(input: Uint8Array): string {
  return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(input);
}

function encodeUtf8(input: string): Uint8Array {
  return new util.TextEncoder().encodeInto(input);
}

const MAX_CERTIFICATE_BYTES: number = 1024 * 1024;
const MAX_CHAIN_CERTIFICATES: number = 8;
const PEM_BEGIN: string = '-----BEGIN CERTIFICATE-----';
const PEM_END: string = '-----END CERTIFICATE-----';

export interface MfiCertificateChain {
  leaf: Uint8Array;
  certificates: Uint8Array[];
  serialized: Uint8Array;
  count: number;
  encodingFormat: cert.EncodingFormat;
  encodingName: string;
}

export interface MfiTrustCandidate {
  certificate: cert.X509Cert;
  trustSource: 'system-pkix' | 'user-pinned';
  fingerprintToPersist: string;
}

export interface MfiTrustPromptInfo {
  fingerprint: string;
  subject: string;
  issuer: string;
  pkixFailure: string;
}

export interface ValidatedMfiCertificate {
  candidates: MfiTrustCandidate[];
  certificateCount: number;
  encodingName: string;
}

interface DerTlv {
  tag: number;
  start: number;
  valueOffset: number;
  end: number;
}

const PKCS7_SIGNED_DATA_OID: number[] = [
  0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02
];

export function isPkcs7SignedDataPayload(input: Uint8Array): boolean {
  if (input.length < 15 || input[0] !== 0x30) {
    return false;
  }
  let sequenceLength: number;
  try {
    sequenceLength = readDerSequenceLength(input, 0);
  } catch (_error) {
    return false;
  }
  const headerLength = derSequenceHeaderLength(input, 0);
  if (headerLength < 0 || sequenceLength !== input.length ||
    headerLength + PKCS7_SIGNED_DATA_OID.length > input.length) {
    return false;
  }
  for (let index = 0; index < PKCS7_SIGNED_DATA_OID.length; index++) {
    if (input[headerLength + index] !== PKCS7_SIGNED_DATA_OID[index]) {
      return false;
    }
  }
  return true;
}

export function extractPkcs7CertificateSet(input: Uint8Array): Uint8Array[] {
  const contentInfo = readDerTlv(input, 0, input.length);
  if (contentInfo.tag !== 0x30 || contentInfo.end !== input.length) {
    throw new Error('CMS ContentInfo is not a bounded DER SEQUENCE');
  }
  const contentType = readDerTlv(input, contentInfo.valueOffset, contentInfo.end);
  if (contentType.tag !== 0x06 || !isSignedDataOid(input, contentType)) {
    throw new Error('CMS ContentInfo does not use the SignedData OID');
  }
  const explicitContent = readDerTlv(input, contentType.end, contentInfo.end);
  if (explicitContent.tag !== 0xa0) {
    throw new Error('CMS ContentInfo is missing its explicit SignedData content');
  }
  const signedData = readDerTlv(input, explicitContent.valueOffset, explicitContent.end);
  if (signedData.tag !== 0x30 || signedData.end !== explicitContent.end) {
    throw new Error('CMS SignedData is not a bounded DER SEQUENCE');
  }

  let cursor = signedData.valueOffset;
  const version = readDerTlv(input, cursor, signedData.end);
  if (version.tag !== 0x02) {
    throw new Error('CMS SignedData has no version field');
  }
  cursor = version.end;
  const digestAlgorithms = readDerTlv(input, cursor, signedData.end);
  if (digestAlgorithms.tag !== 0x31) {
    throw new Error('CMS SignedData has no digestAlgorithms SET');
  }
  cursor = digestAlgorithms.end;
  const encapsulatedContent = readDerTlv(input, cursor, signedData.end);
  if (encapsulatedContent.tag !== 0x30) {
    throw new Error('CMS SignedData has no encapContentInfo SEQUENCE');
  }
  cursor = encapsulatedContent.end;

  while (cursor < signedData.end) {
    const field = readDerTlv(input, cursor, signedData.end);
    if (field.tag === 0xa0) {
      const certificates: Uint8Array[] = [];
      let certOffset = field.valueOffset;
      while (certOffset < field.end) {
        if (certificates.length >= MAX_CHAIN_CERTIFICATES) {
          throw new Error(`CMS certificate set exceeds ${MAX_CHAIN_CERTIFICATES} X.509 certificates`);
        }
        const certificate = readDerTlv(input, certOffset, field.end);
        if (certificate.tag === 0x30) {
          certificates.push(input.slice(certificate.start, certificate.end));
        }
        certOffset = certificate.end;
      }
      return certificates;
    }
    if (field.tag === 0x31) {
      break;
    }
    if (field.tag !== 0xa1) {
      throw new Error(`Unexpected CMS SignedData field tag 0x${field.tag.toString(16)}`);
    }
    cursor = field.end;
  }
  return [];
}

export function parseMfiCertificateChain(input: Uint8Array): MfiCertificateChain {
  if (input.length === 0 || input.length > MAX_CERTIFICATE_BYTES) {
    throw new Error(`MFi certificate payload has invalid size ${input.length}`);
  }
  if (isPkcs7SignedDataPayload(input)) {
    throw new Error('MFi payload is PKCS#7 SignedData; use the CMS parser instead of raw X.509 parsing');
  }
  if (startsWithAscii(input, PEM_BEGIN)) {
    return parsePemCertificateChain(input);
  }
  return parseDerCertificateChain(input);
}

export type MfiPkixTrustDecision = 'prompt-for-pin' | 'already-pinned' | 'reject';

export function classifyMfiPkixTrustFailure(
  message: string,
  fingerprint: string,
  pinnedFingerprints: string[]
): MfiPkixTrustDecision {
  if (!isMfiPinEligiblePkixFailure(message)) {
    return 'reject';
  }
  const normalized = fingerprint.toLowerCase();
  return pinnedFingerprints.some((pin: string): boolean => pin.toLowerCase() === normalized)
    ? 'already-pinned'
    : 'prompt-for-pin';
}

export interface MfiSignatureVerificationResult {
  verified: boolean;
  algorithm: string;
  errors: string[];
}

const MFI_CHALLENGE_SIGNATURE_ALGORITHMS: string[] = [
  'RSA|PKCS1|SHA256',
  'RSA|PKCS1|SHA1',
  'ECC|SHA256',
  'ECC|SHA1',
  'Ed25519'
];

export async function verifyMfiChallengeSignature(
  publicKey: cryptoFramework.PubKey,
  challenge: Uint8Array,
  signature: Uint8Array
): Promise<MfiSignatureVerificationResult> {
  const inputBlob: cryptoFramework.DataBlob = { data: challenge };
  const signatureBlob: cryptoFramework.DataBlob = { data: signature };
  const errors: string[] = [];
  for (const algorithm of MFI_CHALLENGE_SIGNATURE_ALGORITHMS) {
    try {
      const verifier = cryptoFramework.createVerify(algorithm);
      await verifier.init(publicKey);
      if (await verifier.verify(inputBlob, signatureBlob)) {
        return { verified: true, algorithm, errors };
      }
      errors.push(`${algorithm}: signature mismatch`);
    } catch (error) {
      errors.push(`${algorithm}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { verified: false, algorithm: '', errors };
}

export async function verifyMfiChallengeAndPersistPin(
  publicKey: cryptoFramework.PubKey,
  challenge: Uint8Array,
  signature: Uint8Array,
  fingerprintToPersist: string,
  persistFingerprint?: (fingerprint: string) => Promise<void>
): Promise<MfiSignatureVerificationResult> {
  const result = await verifyMfiChallengeSignature(publicKey, challenge, signature);
  if (!result.verified || fingerprintToPersist.length === 0) {
    return result;
  }
  if (!persistFingerprint) {
    throw new Error('MFi pin persistence callback is unavailable; refusing authentication success');
  }
  await persistFingerprint(fingerprintToPersist);
  return result;
}

export class MfiVerifier {
  private readonly log: (message: string) => void;
  private readonly allowIntermediateDownload: boolean;
  private readonly pinnedFingerprints: string[];
  private readonly requestTrust?: (info: MfiTrustPromptInfo) => Promise<boolean>;
  private readonly persistFingerprint?: (fingerprint: string) => Promise<void>;

  constructor(
    log: (message: string) => void,
    allowIntermediateDownload: boolean = false,
    pinnedFingerprints: string[] = [],
    requestTrust?: (info: MfiTrustPromptInfo) => Promise<boolean>,
    persistFingerprint?: (fingerprint: string) => Promise<void>
  ) {
    this.log = log;
    this.allowIntermediateDownload = allowIntermediateDownload;
    this.pinnedFingerprints = pinnedFingerprints.map((value: string): string => value.toLowerCase());
    this.requestTrust = requestTrust;
    this.persistFingerprint = persistFingerprint;
  }

  async validateAccessoryCertificate(certificatePayload: Uint8Array): Promise<ValidatedMfiCertificate> {
    if (certificatePayload.length === 0) {
      throw new Error('MFi certificate payload is empty');
    }
    this.log(
      `MFi AA01 parameter 0 received: bytes=${certificatePayload.length}, ` +
        `prefix=${hexPrefix(certificatePayload)}`
    );
    let candidateCertificates: cert.X509Cert[] = [];
    let untrustedCertificates: cert.X509Cert[] = [];
    let encodingName: string = '';
    let serializedChain: Uint8Array = certificatePayload;
    if (isPkcs7SignedDataPayload(certificatePayload)) {
      const parser = cert.createCmsParser();
      try {
        await parser.setRawData(certificatePayload, cert.CmsFormat.DER);
        if (parser.getContentType() !== cert.CmsContentType.SIGNED_DATA) {
          throw new Error('CMS ContentInfo is not SignedData');
        }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`MFi PKCS#7 SignedData parsing failed: ${message}`);
      }
      let allCertificateError = '';
      let signerCertificateError = '';
      let certificateSetError = '';
      let contentDataError = '';
      try {
        untrustedCertificates = await parser.getCerts(cert.CmsCertType.ALL_CERTS);
      } catch (error) {
        allCertificateError = error instanceof Error ? error.message : String(error);
        this.log(`CMS getCerts(ALL_CERTS) failed: ${allCertificateError}`);
      }
      let signerCertificates: cert.X509Cert[] = [];
      try {
        signerCertificates = await parser.getCerts(cert.CmsCertType.SIGNER_CERTS);
      } catch (error) {
        signerCertificateError = error instanceof Error ? error.message : String(error);
        this.log(`CMS getCerts(SIGNER_CERTS) failed: ${signerCertificateError}`);
      }
      if (untrustedCertificates.length === 0) {
        let extracted: Uint8Array[] = [];
        try {
          extracted = extractPkcs7CertificateSet(certificatePayload);
        } catch (error) {
          certificateSetError = error instanceof Error ? error.message : String(error);
          this.log(`CMS certificate-set ASN.1 fallback failed: ${certificateSetError}`);
        }
        if (extracted.length > 0) {
          for (const encodedCertificate of extracted) {
            try {
              untrustedCertificates.push(await cert.createX509Cert({
                data: encodedCertificate,
                encodingFormat: cert.EncodingFormat.FORMAT_DER
              }));
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error);
              throw new Error(`MFi CMS certificate-set X.509 parse failed: ${message}`);
            }
          }
          this.log(`CMS certificate-set ASN.1 fallback extracted ${untrustedCertificates.length} certificate(s)`);
        }
      }
      if (untrustedCertificates.length === 0 && signerCertificates.length > 0) {
        untrustedCertificates = signerCertificates;
        this.log('CMS all-certificates extraction unavailable; using signer certificate(s) as chain input');
      }
      if (untrustedCertificates.length === 0 && signerCertificates.length === 0) {
        let contentData = new Uint8Array(0);
        try {
          contentData = await parser.getContentData();
        } catch (error) {
          contentDataError = error instanceof Error ? error.message : String(error);
        }
        if (contentData.length > 0) {
          let embeddedChain: MfiCertificateChain;
          try {
            embeddedChain = parseMfiCertificateChain(contentData);
          } catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            throw new Error(
              `MFi CMS contains no signer certificate; embedded content is not an X.509 chain: ${message}; ` +
                `ALL_CERTS=${allCertificateError || 'empty'}, SIGNER_CERTS=${signerCertificateError || 'empty'}`
            );
          }
          encodingName = `PKCS#7 SignedData/${embeddedChain.encodingName} content`;
          serializedChain = embeddedChain.serialized;
          for (const encodedCertificate of embeddedChain.certificates) {
            try {
              untrustedCertificates.push(await cert.createX509Cert({
                data: encodedCertificate,
                encodingFormat: embeddedChain.encodingFormat
              }));
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error);
              throw new Error(`MFi CMS embedded certificate parse failed: ${message}`);
            }
          }
          const leafCertificate = untrustedCertificates[0];
          if (!leafCertificate) {
            throw new Error('MFi CMS embedded certificate chain has no leaf certificate');
          }
          candidateCertificates = [leafCertificate];
        }
      }
      if (untrustedCertificates.length === 0) {
        throw new Error(
          `MFi CMS certificate extraction failed: ALL_CERTS=${allCertificateError || 'empty'}, ` +
            `SIGNER_CERTS=${signerCertificateError || 'empty'}, ` +
            `certificate-set=${certificateSetError || 'empty'}, ` +
            `getContentData=${contentDataError || 'not required'}`
        );
      }
      if (candidateCertificates.length === 0) {
        candidateCertificates = signerCertificates.length > 0
          ? signerCertificates
          : untrustedCertificates;
      }
      if (!encodingName) {
        encodingName = 'PKCS#7 SignedData';
      }
    } else {
      let chain: MfiCertificateChain;
      try {
        chain = parseMfiCertificateChain(certificatePayload);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`MFi certificate payload format is invalid or unsupported: ${message}`);
      }
      encodingName = chain.encodingName;
      serializedChain = chain.serialized;
      for (const encodedCertificate of chain.certificates) {
        try {
          untrustedCertificates.push(await cert.createX509Cert({
            data: encodedCertificate,
            encodingFormat: chain.encodingFormat
          }));
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          throw new Error(
            `MFi certificate parse failed (${chain.encodingName}, ${encodedCertificate.length} bytes, ` +
              `header=${hexPrefix(encodedCertificate)}): ${message}`
          );
        }
      }
      const leafCertificate = untrustedCertificates[0];
      if (!leafCertificate) {
        throw new Error('MFi certificate chain has no leaf certificate');
      }
      candidateCertificates = [leafCertificate];
    }

    const fingerprint = await sha256Fingerprint(serializedChain);
    this.log(
      `MFi certificate payload parsed: format=${encodingName}, bytes=${serializedChain.length}, ` +
        `certificates=${untrustedCertificates.length}, sha256=${fingerprint}`
    );
    const validationTime = toAsn1Time(new Date());
    const validationParams: cert.CertValidationParams = {
      untrustedCerts: untrustedCertificates,
      trustSystemCa: true,
      date: validationTime,
      validateDate: true,
      allowDownloadIntermediateCa: this.allowIntermediateDownload,
      keyUsage: [cert.KeyUsageType.KEYUSAGE_DIGITAL_SIGNATURE]
    };
    this.log(
      `MFi PKIX uses system CA; AIA intermediate download ${this.allowIntermediateDownload ? 'enabled' : 'disabled'}`
    );
    const validator = cert.createCertChainValidator('PKIX');
    const trustedCandidates: MfiTrustCandidate[] = [];
    const validationErrors: string[] = [];
    for (let index = 0; index < candidateCertificates.length; index++) {
      const item = candidateCertificates[index];
      if (!item) {
        continue;
      }
      this.log(`MFi PKIX candidate ${index}: ${certificateNames(item)}`);
      try {
        await validator.validateCert(item, validationParams);
        trustedCandidates.push({
          certificate: item,
          trustSource: 'system-pkix',
          fingerprintToPersist: ''
        });
      } catch (error) {
        const pkixFailure = error instanceof Error ? error.message : String(error);
        if (!isMfiPinEligiblePkixFailure(pkixFailure)) {
          validationErrors.push(formatPkixFailure(index, pkixFailure, this.allowIntermediateDownload));
          continue;
        }
        const fingerprint = await x509Fingerprint(item);
        const trustDecision = classifyMfiPkixTrustFailure(
          pkixFailure,
          fingerprint,
          this.pinnedFingerprints
        );
        if (trustDecision === 'already-pinned') {
          this.validateUserPinnedCertificateValidity(item, validationTime);
          trustedCandidates.push({
            certificate: item,
            trustSource: 'user-pinned',
            fingerprintToPersist: ''
          });
          this.log(`MFi certificate accepted by exact user-pinned SHA-256 fingerprint ${fingerprint}`);
          continue;
        }
        const prompt = this.requestTrust;
        if (!prompt) {
          validationErrors.push(formatPkixFailure(index, pkixFailure, this.allowIntermediateDownload));
          continue;
        }
        const identity = certificateIdentity(item);
        const approved = await prompt({
          fingerprint,
          subject: identity.subject,
          issuer: identity.issuer,
          pkixFailure: formatPkixFailure(index, pkixFailure, this.allowIntermediateDownload)
        });
        if (!approved) {
          throw new Error(`MFi certificate trust declined for SHA-256 ${fingerprint}`);
        }
        this.validateUserPinnedCertificateValidity(item, validationTime);
        trustedCandidates.push({
          certificate: item,
          trustSource: 'user-pinned',
          fingerprintToPersist: fingerprint
        });
        this.log(`User approved first-use MFi fingerprint ${fingerprint}; challenge signature still required`);
      }
    }
    if (trustedCandidates.length === 0) {
      throw new Error(
        `MFi PKIX validation failed against the system CA (${untrustedCertificates.length} certificate(s), ` +
          `date=${validationTime}, AIA download=${this.allowIntermediateDownload})` +
          `${validationErrors.length > 0 ? `: ${validationErrors.join('; ')}` : ''}` +
          `${this.allowIntermediateDownload ? '' : '; enable optional AIA lookup only for a trusted receiver'}`
      );
    }

    return {
      candidates: trustedCandidates,
      certificateCount: untrustedCertificates.length,
      encodingName
    };
  }

  private validateUserPinnedCertificateValidity(certificate: cert.X509Cert, validationTime: string): void {
    try {
      certificate.checkValidityWithDate(validationTime);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(
        `User-pinned MFi leaf failed certificate validity-date check; not saved or accepted: ${message}`
      );
    }
  }

  async verifyChallenge(validated: ValidatedMfiCertificate, challenge: Uint8Array, signature: Uint8Array):
    Promise<void> {
    if (challenge.length === 0 || signature.length === 0) {
      throw new Error('MFi challenge and signature are required');
    }
    const errors: string[] = [];
    for (let index = 0; index < validated.candidates.length; index++) {
      const candidate = validated.candidates[index];
      if (!candidate) {
        continue;
      }
      const certificate = candidate.certificate;
      const publicKey = certificate.getPublicKey();
      const verification = await verifyMfiChallengeAndPersistPin(
        publicKey,
        challenge,
        signature,
        candidate.fingerprintToPersist,
        this.persistFingerprint
      );
      if (!verification.verified) {
        errors.push(
          `certificate ${index}: no supported challenge signature verified` +
            `${verification.errors.length > 0 ? ` [${verification.errors.join('; ')}]` : ''}`
        );
        continue;
      }
      if (candidate.fingerprintToPersist.length > 0) {
        this.log('MFi fingerprint pinned after successful challenge signature');
      }
      this.log(
        `MFi ${validated.encodingName} ${candidate.trustSource} ` +
          `(${validated.certificateCount} certificate(s)); ` +
          `challenge verified using ${verification.algorithm}`
      );
      return;
    }
    throw new Error(
      `MFi challenge signature verification failed against ${validated.candidates.length} trusted candidate(s)` +
        `${errors.length > 0 ? ` (${errors.join('; ')})` : ''}`
    );
  }

  async verifyAccessory(certificatePayload: Uint8Array, challenge: Uint8Array, signature: Uint8Array):
    Promise<void> {
    const validated = await this.validateAccessoryCertificate(certificatePayload);
    await this.verifyChallenge(validated, challenge, signature);
  }
}

function readDerTlv(input: Uint8Array, offset: number, limit: number): DerTlv {
  if (offset < 0 || offset + 2 > limit || limit > input.length) {
    throw new Error(`Truncated DER tag/length at offset ${offset}`);
  }
  const tag = input[offset];
  if (tag === undefined || (tag & 0x1f) === 0x1f) {
    throw new Error(`Unsupported DER tag at offset ${offset}`);
  }
  const firstLength = input[offset + 1];
  if (firstLength === undefined) {
    throw new Error(`Missing DER length at offset ${offset + 1}`);
  }
  let headerLength = 2;
  let contentLength = firstLength;
  if (firstLength >= 0x80) {
    const lengthBytes = firstLength & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 4 || offset + 2 + lengthBytes > limit) {
      throw new Error(`Invalid DER length encoding at offset ${offset + 1}`);
    }
    if (input[offset + 2] === 0) {
      throw new Error(`Non-canonical DER length at offset ${offset + 2}`);
    }
    contentLength = 0;
    for (let index = 0; index < lengthBytes; index++) {
      contentLength = contentLength * 256 + (input[offset + 2 + index] ?? 0);
    }
    if (contentLength < 0x80) {
      throw new Error(`Non-canonical DER long-form length at offset ${offset + 1}`);
    }
    headerLength += lengthBytes;
  }
  const valueOffset = offset + headerLength;
  const end = valueOffset + contentLength;
  if (!Number.isSafeInteger(end) || end > limit) {
    throw new Error(`DER element exceeds its container at offset ${offset}`);
  }
  const result: DerTlv = { tag, start: offset, valueOffset, end };
  return result;
}

function isSignedDataOid(input: Uint8Array, oid: DerTlv): boolean {
  if (oid.end - oid.valueOffset !== 9) {
    return false;
  }
  const value: number[] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02];
  for (let index = 0; index < value.length; index++) {
    if (input[oid.valueOffset + index] !== value[index]) {
      return false;
    }
  }
  return true;
}

interface MfiCertificateIdentity {
  subject: string;
  issuer: string;
}

function certificateIdentity(certificate: cert.X509Cert): MfiCertificateIdentity {
  try {
    const subjectBlob = certificate.getSubjectName(cert.EncodingType.ENCODING_UTF8);
    const subject = decodeUtf8(new Uint8Array(subjectBlob.data)).replace(/\0/g, '').slice(0, 240);
    const issuer = certificate.getIssuerName(cert.EncodingType.ENCODING_UTF8).slice(0, 240);
    return { subject, issuer };
  } catch (error) {
    const failure = error instanceof Error ? error.message : String(error);
    return { subject: `unavailable (${failure})`, issuer: 'unavailable' };
  }
}

function certificateNames(certificate: cert.X509Cert): string {
  const identity = certificateIdentity(certificate);
  return `subject=${identity.subject}; issuer=${identity.issuer}`;
}

export function isMfiPinEligiblePkixFailure(message: string): boolean {
  const normalized = message.toLowerCase();
  return normalized.includes('unable to get local issuer certificate') ||
    normalized.includes('no aia extension found in certificate') ||
    normalized.includes('failed to obtain the certificate issuer') ||
    normalized.includes('untrusted certificate');
}

async function x509Fingerprint(certificate: cert.X509Cert): Promise<string> {
  const encoded = await certificate.getEncoded();
  if (encoded.encodingFormat !== cert.EncodingFormat.FORMAT_DER) {
    throw new Error(`X.509 getEncoded returned unsupported format ${encoded.encodingFormat}`);
  }
  return sha256Fingerprint(encoded.data);
}

function formatPkixFailure(index: number, error: Error | string, aiaEnabled: boolean): string {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes('No AIA extension found in certificate') ||
    message.includes('unable to get local issuer certificate')) {
    return `candidate ${index}: issuer chain is incomplete; the leaf has no usable AIA issuer URL ` +
      `(${aiaEnabled ? 'AIA lookup enabled but no URL was present' : 'AIA lookup disabled'}). ` +
      'Supply the authentic Apple Accessories intermediate certificate; the system CA must still trust its root. ' +
      `System detail: ${message}`;
  }
  return `candidate ${index}: ${message}`;
}

function parseDerCertificateChain(input: Uint8Array): MfiCertificateChain {
  const certificates: Uint8Array[] = [];
  let cursor = 0;
  while (cursor < input.length) {
    if (certificates.length >= MAX_CHAIN_CERTIFICATES) {
      throw new Error(`MFi DER chain exceeds ${MAX_CHAIN_CERTIFICATES} certificates`);
    }
    const totalLength = readDerSequenceLength(input, cursor);
    certificates.push(input.slice(cursor, cursor + totalLength));
    cursor += totalLength;
  }
  if (certificates.length === 0) {
    throw new Error('MFi DER chain contains no certificate');
  }
  const leaf = certificates[0];
  if (!leaf) {
    throw new Error('MFi DER chain is missing its leaf certificate');
  }
  return {
    leaf,
    certificates,
    serialized: input.slice(),
    count: certificates.length,
    encodingFormat: cert.EncodingFormat.FORMAT_DER,
    encodingName: 'DER'
  };
}

function readDerSequenceLength(input: Uint8Array, offset: number): number {
  if (offset + 2 > input.length || input[offset] !== 0x30) {
    throw new Error(`MFi certificate payload is not a DER SEQUENCE at offset ${offset} (${hexPrefix(input, offset)})`);
  }
  const firstLength = input[offset + 1];
  if (firstLength === undefined) {
    throw new Error('MFi DER sequence is missing its length');
  }
  if (firstLength < 0x80) {
    const totalLength = 2 + firstLength;
    if (offset + totalLength > input.length) {
      throw new Error('MFi DER sequence length exceeds the payload');
    }
    return totalLength;
  }
  const lengthBytes = firstLength & 0x7f;
  if (lengthBytes === 0 || lengthBytes > 4 || offset + 2 + lengthBytes > input.length) {
    throw new Error(`MFi DER sequence has invalid length encoding (${lengthBytes} length bytes)`);
  }
  if (input[offset + 2] === 0) {
    throw new Error('MFi DER sequence uses a non-canonical leading zero length');
  }
  let contentLength = 0;
  for (let index = 0; index < lengthBytes; index++) {
    contentLength = contentLength * 256 + (input[offset + 2 + index] ?? 0);
  }
  if (contentLength < 0x80) {
    throw new Error('MFi DER sequence uses a non-canonical long-form length');
  }
  const headerLength = 2 + lengthBytes;
  const totalLength = headerLength + contentLength;
  if (offset + totalLength > input.length || !Number.isSafeInteger(totalLength)) {
    throw new Error('MFi DER sequence length exceeds the payload bounds');
  }
  return totalLength;
}

function derSequenceHeaderLength(input: Uint8Array, offset: number): number {
  if (offset + 2 > input.length || input[offset] !== 0x30) {
    return -1;
  }
  const firstLength = input[offset + 1];
  if (firstLength === undefined) {
    return -1;
  }
  if (firstLength < 0x80) {
    return 2;
  }
  const lengthBytes = firstLength & 0x7f;
  if (lengthBytes === 0 || lengthBytes > 4 || offset + 2 + lengthBytes > input.length) {
    return -1;
  }
  return 2 + lengthBytes;
}

function parsePemCertificateChain(input: Uint8Array): MfiCertificateChain {
  const text = decodeAscii(input);
  const certificates: Uint8Array[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    while (cursor < text.length && isAsciiWhitespace(text.charCodeAt(cursor))) {
      cursor++;
    }
    if (cursor >= text.length) {
      break;
    }
    if (certificates.length >= MAX_CHAIN_CERTIFICATES || !text.startsWith(PEM_BEGIN, cursor)) {
      throw new Error(`MFi PEM chain has invalid certificate framing at character ${cursor}`);
    }
    const end = text.indexOf(PEM_END, cursor + PEM_BEGIN.length);
    if (end < 0) {
      throw new Error('MFi PEM certificate is missing its END marker');
    }
    const blockEnd = end + PEM_END.length;
    certificates.push(encodeUtf8(`${text.slice(cursor, blockEnd)}\n`));
    cursor = blockEnd;
  }
  if (certificates.length === 0) {
    throw new Error('MFi PEM chain contains no certificates');
  }
  const first = certificates[0];
  if (!first) {
    throw new Error('MFi PEM chain is missing its leaf certificate');
  }
  return {
    leaf: first,
    certificates,
    serialized: input.slice(),
    count: certificates.length,
    encodingFormat: cert.EncodingFormat.FORMAT_PEM,
    encodingName: 'PEM'
  };
}

function startsWithAscii(input: Uint8Array, prefix: string): boolean {
  if (input.length < prefix.length) {
    return false;
  }
  for (let index = 0; index < prefix.length; index++) {
    if (input[index] !== prefix.charCodeAt(index)) {
      return false;
    }
  }
  return true;
}

function decodeAscii(input: Uint8Array): string {
  let value = '';
  for (const byte of input) {
    if (byte > 0x7f) {
      throw new Error('MFi PEM payload contains non-ASCII bytes');
    }
    value += String.fromCharCode(byte);
  }
  return value;
}

function isAsciiWhitespace(code: number): boolean {
  return code === 9 || code === 10 || code === 13 || code === 32;
}

function hexPrefix(input: Uint8Array, offset: number = 0): string {
  const end = Math.min(input.length, offset + 8);
  let value = '';
  for (let index = offset; index < end; index++) {
    value += (input[index] ?? 0).toString(16).padStart(2, '0');
  }
  return value || 'empty';
}

function toAsn1Time(date: Date): string {
  const year = date.getUTCFullYear();
  const yearText = year >= 2050
    ? year.toString().padStart(4, '0')
    : (year % 100).toString().padStart(2, '0');
  return yearText +
    (date.getUTCMonth() + 1).toString().padStart(2, '0') +
    date.getUTCDate().toString().padStart(2, '0') +
    date.getUTCHours().toString().padStart(2, '0') +
    date.getUTCMinutes().toString().padStart(2, '0') +
    date.getUTCSeconds().toString().padStart(2, '0') +
    'Z';
}

async function sha256Fingerprint(input: Uint8Array): Promise<string> {
  try {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: input });
    const result = await digest.digest();
    let fingerprint = '';
    for (const byte of result.data) {
      fingerprint += byte.toString(16).padStart(2, '0');
    }
    return fingerprint;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Unable to compute MFi certificate diagnostic fingerprint: ${message}`);
  }
}
