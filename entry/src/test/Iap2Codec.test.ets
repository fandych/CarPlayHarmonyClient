import { describe, it, expect } from '@ohos/hypium';
import cryptoFramework from '@ohos.security.cryptoFramework';
import {
  concatBytes,
  decodeIap2Parameters,
  decodeIap2String,
  encodeIap2Control,
  encodeIap2LinkFrame,
  encodeIap2Parameter,
  encodeIap2SyncPayload,
  encodeUtf8,
  Iap2ControlDecoder,
  Iap2LinkDecoder,
  Iap2LinkFrame
} from '../main/ets/protocol/Iap2Codec';
import { Iap2SenderSession, WifiCredentials } from '../main/ets/session/Iap2SenderSession';
import { chachaOpen, chachaSeal } from '../main/ets/crypto/AirPlayStreamCrypto';
import {
  generateEd25519KeyPair,
  generateX25519KeyPair,
  hkdfSha512,
  sha512,
  signEd25519,
  verifyEd25519,
  x25519SharedSecret
} from '../main/ets/airplay/AirPlayCrypto';
import { buildAudioRtpHeader } from '../main/ets/audio/AudioRtpSender';
import {
  modPow,
  padSrpInteger,
  Srp6aSession,
  SRP3072_MODULUS,
  SRP_GENERATOR,
  srpBigIntToBytes,
  srpBytesToBigInt
} from '../main/ets/airplay/Srp6aClient';
import { decodeTlv8, encodeTlv8, Tlv8Item } from '../main/ets/airplay/Tlv8';
import { BinaryPlist, PlistNode } from '../main/ets/airplay/BinaryPlist';
import { AirPlayControlCipher } from '../main/ets/airplay/ControlCipher';
import { AirPlayMediaSession, selectPcmAudioFormat } from '../main/ets/airplay/AirPlayMediaSession';
import { buildAirPlayEventResponse, parseAirPlayEventRequests } from '../main/ets/airplay/AirPlayEventChannel';
import {
  classifyMfiPkixTrustFailure,
  extractPkcs7CertificateSet,
  isPkcs7SignedDataPayload,
  MfiVerifier,
  parseMfiCertificateChain,
  verifyMfiChallengeAndPersistPin
} from '../main/ets/iap2/MfiVerifier';
import {
  AirPlayVideoStreamSender,
  buildAirPlayVideoConfigHeader,
  buildAirPlayVideoFrameHeader,
  buildAvcConfigurationRecord,
  EncodedH264Event,
  buildVideoFrameNonce,
  packH264Nals,
  splitH264NalUnits
} from '../main/ets/airplay/AirPlayVideoStream';
import { appendConnectionLog, MAX_CONNECTION_LOG_LINES } from '../main/ets/session/ConnectionLogBuffer';

export default function iap2CodecTest() {
  describe('Iap2Codec', () => {
    it('parses control frames split across chunks', 0, () => {
      const body = encodeIap2Parameter(1, encodeUtf8('CarDeck'));
      const encoded = encodeIap2Control(0x5703, body);
      const parser = new Iap2ControlDecoder();
      const first = parser.push(encoded.slice(0, 4));
      expect(first.length).assertEqual(0);
      const frames = parser.push(encoded.slice(4));
      expect(frames.length).assertEqual(1);
      expect(frames[0].messageId).assertEqual(0x5703);
      const parameters = decodeIap2Parameters(frames[0].body);
      expect(parameters.length).assertEqual(1);
      expect(decodeIap2String(parameters[0].value)).assertEqual('CarDeck');
    });

    it('keeps a bounded chronological connection log', 0, () => {
      let lines: string[] = [];
      for (let index = 0; index < MAX_CONNECTION_LOG_LINES + 2; index++) {
        lines = appendConnectionLog(lines, `line-${index}`);
      }
      expect(lines.length).assertEqual(MAX_CONNECTION_LOG_LINES);
      expect(lines[0]).assertEqual('line-2');
      expect(lines[lines.length - 1]).assertEqual(`line-${MAX_CONNECTION_LOG_LINES + 1}`);
    });

    it('parses link frames split across chunks and validates checksum', 0, () => {
      const frame: Iap2LinkFrame = {
        control: 0x40,
        sequence: 99,
        acknowledgement: 7,
        sessionId: 10,
        payload: new Uint8Array([0x10, 0x20, 0x30])
      };
      const encoded = encodeIap2LinkFrame(frame);
      const parser = new Iap2LinkDecoder();
      expect(parser.push(encoded.slice(0, 8)).length).assertEqual(0);
      const parsed = parser.push(encoded.slice(8));
      expect(parsed.length).assertEqual(1);
      expect(parsed[0].sequence).assertEqual(frame.sequence);
      expect(parsed[0].acknowledgement).assertEqual(frame.acknowledgement);
      expect(parsed[0].sessionId).assertEqual(frame.sessionId);
      expect(parsed[0].payload.length).assertEqual(frame.payload.length);

      const corrupted = encoded.slice();
      corrupted[9] = corrupted[9] ^ 0xff;
      expect(new Iap2LinkDecoder().push(corrupted).length).assertEqual(0);
    });

    it('parses bounded DER and PEM MFi certificate-chain containers', 0, () => {
      const derCertificate = new Uint8Array([0x30, 0x03, 0x02, 0x01, 0x00]);
      const single = parseMfiCertificateChain(derCertificate);
      expect(single.encodingName).assertEqual('DER');
      expect(single.count).assertEqual(1);
      expect(single.leaf.length).assertEqual(derCertificate.length);

      const chain = parseMfiCertificateChain(concatBytes(derCertificate, derCertificate));
      expect(chain.count).assertEqual(2);
      expect(chain.serialized.length).assertEqual(derCertificate.length * 2);

      const pem = encodeUtf8(
        '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n' +
          '-----BEGIN CERTIFICATE-----\nBAUG\n-----END CERTIFICATE-----\n'
      );
      const pemChain = parseMfiCertificateChain(pem);
      expect(pemChain.encodingName).assertEqual('PEM');
      expect(pemChain.count).assertEqual(2);

      let malformedRejected = false;
      try {
        parseMfiCertificateChain(new Uint8Array([0x30, 0x82, 0xff]));
      } catch (_error) {
        malformedRejected = true;
      }
      expect(malformedRejected).assertTrue();
    });

    it('recognizes CMS SignedData instead of treating it as a raw X.509 certificate', 0, () => {
      const cmsContainer = new Uint8Array(607);
      cmsContainer.set(new Uint8Array([
        0x30, 0x82, 0x02, 0x5b, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02
      ]));
      expect(isPkcs7SignedDataPayload(cmsContainer)).assertTrue();
      let rawDerParserRejected = false;
      try {
        parseMfiCertificateChain(cmsContainer);
      } catch (error) {
        rawDerParserRejected = error instanceof Error && error.message.includes('PKCS#7 SignedData');
      }
      expect(rawDerParserRejected).assertTrue();
    });

    it('extracts only X.509 sequences from a CMS SignedData certificate set', 0, () => {
      const certificate = new Uint8Array([0x30, 0x03, 0x02, 0x01, 0x00]);
      const signedData = new Uint8Array([
        0x30, 0x2a,
        0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02,
        0xa0, 0x1d,
        0x30, 0x1b,
        0x02, 0x01, 0x01,
        0x31, 0x00,
        0x30, 0x0b, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01,
        0xa0, 0x05, 0x30, 0x03, 0x02, 0x01, 0x00,
        0x31, 0x00
      ]);
      const extracted = extractPkcs7CertificateSet(signedData);
      expect(extracted.length).assertEqual(1);
      expect(extracted[0].length).assertEqual(certificate.length);
      expect(extracted[0][0]).assertEqual(certificate[0]);
    });

    it('requires exact fingerprint pinning and only permits issuer-chain failures', 0, () => {
      const fingerprint = 'a'.repeat(64);
      expect(classifyMfiPkixTrustFailure(
        'unable to get local issuer certificate',
        fingerprint,
        []
      )).assertEqual('prompt-for-pin');
      expect(classifyMfiPkixTrustFailure(
        'unable to get local issuer certificate',
        fingerprint,
        [`${'a'.repeat(63)}b`]
      )).assertEqual('prompt-for-pin');
      expect(classifyMfiPkixTrustFailure(
        'No AIA extension found in certificate',
        fingerprint,
        [fingerprint.toUpperCase()]
      )).assertEqual('already-pinned');
      expect(classifyMfiPkixTrustFailure(
        'unhandled critical extension',
        fingerprint,
        []
      )).assertEqual('prompt-for-pin');
      expect(classifyMfiPkixTrustFailure(
        'key cannot be used for a digital signature',
        fingerprint,
        []
      )).assertEqual('prompt-for-pin');
      expect(classifyMfiPkixTrustFailure(
        'certificate has expired',
        fingerprint,
        [fingerprint]
      )).assertEqual('reject');
    });

    it('verifies Ed25519 without key-name metadata and saves a pin only after success', 0,
      async (): Promise<void> => {
        const generator = cryptoFramework.createAsyKeyGenerator('Ed25519');
        const pair = await generator.generateKeyPair();
        const challenge = new Uint8Array([0x10, 0x20, 0x30, 0x40]);
        const signer = cryptoFramework.createSign('Ed25519');
        await signer.init(pair.priKey);
        const challengeBlob: cryptoFramework.DataBlob = { data: challenge };
        const signature = (await signer.sign(challengeBlob)).data;
        const invalidSignature = signature.slice();
        invalidSignature[0] = (invalidSignature[0] ?? 0) ^ 0xff;
        const savedFingerprints: string[] = [];
        const persist = async (value: string): Promise<void> => {
          savedFingerprints.push(value);
        };
        const fingerprint = 'b'.repeat(64);

        const rejected = await verifyMfiChallengeAndPersistPin(
          pair.pubKey,
          challenge,
          invalidSignature,
          fingerprint,
          persist
        );
        expect(rejected.verified).assertFalse();
        expect(savedFingerprints.length).assertEqual(0);

        const accepted = await verifyMfiChallengeAndPersistPin(
          pair.pubKey,
          challenge,
          signature,
          fingerprint,
          persist
        );
        expect(accepted.verified).assertTrue();
        expect(accepted.algorithm).assertEqual('Ed25519');
        expect(savedFingerprints.length).assertEqual(1);
        expect(savedFingerprints[0] ?? '').assertEqual(fingerprint);
      });

    it('splits Annex-B H.264 and packs length-prefixed NAL units', 0, () => {
      const annexB = new Uint8Array([
        0, 0, 0, 1, 0x67, 0x64, 0, 0x1f,
        0, 0, 1, 0x68, 0xee, 0x06
      ]);
      const units = splitH264NalUnits(annexB);
      expect(units.length).assertEqual(2);
      expect(units[0][0]).assertEqual(0x67);
      expect(units[1][0]).assertEqual(0x68);
      const packed = packH264Nals(units);
      expect(packed.length).assertEqual(15);
      expect(packed[3]).assertEqual(4);
      expect(packed[4]).assertEqual(0x67);
      expect(packed[11]).assertEqual(3);
      expect(packed[12]).assertEqual(0x68);
    });

    it('builds AirPlay H.264 config/frame headers and stable little-endian nonces', 0, () => {
      const sps = new Uint8Array([0x67, 0x64, 0x00, 0x1f, 0xaa]);
      const pps = new Uint8Array([0x68, 0xee, 0x06]);
      const config = buildAvcConfigurationRecord([sps, pps]);
      expect(config[0]).assertEqual(1);
      expect(config[4]).assertEqual(0xff);
      const decodedConfig = splitH264NalUnits(config);
      expect(decodedConfig.length).assertEqual(2);
      expect(decodedConfig[0][0]).assertEqual(0x67);
      expect(decodedConfig[1][0]).assertEqual(0x68);
      const configHeader = buildAirPlayVideoConfigHeader(config.length, 1160, 540);
      expect(configHeader.length).assertEqual(128);
      expect(configHeader[4]).assertEqual(1);
      expect(configHeader[6]).assertEqual(4);
      const frameHeader = buildAirPlayVideoFrameHeader(99, 0);
      expect(frameHeader[0]).assertEqual(99);
      expect(frameHeader[4]).assertEqual(0);
      expect(frameHeader[6]).assertEqual(4);
      const nonce = buildVideoFrameNonce(BigInt(0x010203));
      expect(nonce.length).assertEqual(12);
      expect(nonce[4]).assertEqual(3);
      expect(nonce[5]).assertEqual(2);
      expect(nonce[6]).assertEqual(1);
    });

    it('serializes config before encrypted H.264 frames', 0, async (): Promise<void> => {
      const key = new Uint8Array(32);
      key.fill(0x31);
      const messages: Uint8Array[] = [];
      const sender = new AirPlayVideoStreamSender(
        key,
        1280,
        720,
        async (data: Uint8Array): Promise<void> => {
          messages.push(data);
        },
        (_message: string): void => {}
      );
      const codecConfig = new Uint8Array([
        0, 0, 0, 1, 0x67, 0x64, 0, 0x1f, 0xaa,
        0, 0, 1, 0x68, 0xee, 0x06
      ]);
      const frame = new Uint8Array([0, 0, 0, 1, 0x65, 0x88]);
      const configEvent: EncodedH264Event = {
        type: 'codecConfig',
        data: codecConfig,
        timestampUs: 0,
        flags: 8
      };
      const frameEvent: EncodedH264Event = {
        type: 'frame',
        data: frame,
        timestampUs: 33333,
        flags: 2
      };
      await sender.handleEncoderEvent(configEvent);
      await sender.handleEncoderEvent(frameEvent);
      expect(messages.length).assertEqual(2);
      expect(messages[0][4]).assertEqual(1);
      expect(messages[1][4]).assertEqual(0);
      expect(messages[1][6]).assertEqual(4);
      const header = messages[1].slice(0, 128);
      const decoded = await chachaOpen(key, buildVideoFrameNonce(BigInt(0)), messages[1].slice(128), header);
      expect(decoded.length).assertEqual(6);
      expect(decoded[3]).assertEqual(2);
      expect(decoded[4]).assertEqual(0x65);
    });

    it('routes CMS SignedData into the system CMS parser', 0, async (): Promise<void> => {
      const cmsContainer = new Uint8Array(607);
      cmsContainer.set(new Uint8Array([
        0x30, 0x82, 0x02, 0x5b, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02
      ]));
      let failureMessage = '';
      try {
        await new MfiVerifier((_message: string): void => {}).validateAccessoryCertificate(cmsContainer);
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : String(error);
      }
      expect(
        failureMessage.includes('MFi PKCS#7 SignedData parsing failed') ||
          failureMessage.includes('MFi CMS certificate extraction failed')
      ).assertTrue();
      expect(failureMessage.includes('MFi certificate parse failed')).assertFalse();
    });

    it('classifies X.509 object creation errors as parse failures, not trust failures', 0, async (): Promise<void> => {
      let failureMessage = '';
      try {
        await new MfiVerifier((_message: string): void => {}).verifyAccessory(
          new Uint8Array([0x30, 0x03, 0x02, 0x01, 0x00]),
          new Uint8Array([1]),
          new Uint8Array([1])
        );
      } catch (error) {
        failureMessage = error instanceof Error ? error.message : String(error);
      }
      expect(failureMessage.includes('MFi certificate parse failed')).assertTrue();
      expect(failureMessage.includes('PKIX validation failed')).assertFalse();
    });

    it('uses fresh sequence numbers for SYN, SYN-ACK, and identification', 0, async (): Promise<void> => {
      const sent: Uint8Array[] = [];
      const session = new Iap2SenderSession(
        async (bytes: Uint8Array): Promise<void> => {
          sent.push(bytes);
        },
        (_message: string): void => {},
        (_credentials: WifiCredentials): void => {},
        (_body: Uint8Array): void => {},
        '00:11:22:33:44:55',
        'Harmony CarPlay',
        'test-device'
      );

      await session.start();
      const initialSync = new Iap2LinkDecoder().push(sent[0].slice(6));
      expect(initialSync.length).assertEqual(1);
      expect(initialSync[0].control).assertEqual(0x80);
      expect(initialSync[0].sequence).assertEqual(99);

      const peerSync: Iap2LinkFrame = {
        control: 0x80,
        sequence: 161,
        acknowledgement: 99,
        sessionId: 0,
        payload: encodeIap2SyncPayload(10)
      };
      await session.receive(encodeIap2LinkFrame(peerSync));

      const synAckFrames = new Iap2LinkDecoder().push(sent[1]);
      expect(synAckFrames.length).assertEqual(1);
      expect(synAckFrames[0].control).assertEqual(0xc0);
      expect(synAckFrames[0].sequence).assertEqual(100);
      expect(synAckFrames[0].acknowledgement).assertEqual(161);
      expect(synAckFrames[0].payload[1]).assertEqual(0x7f);
      expect(synAckFrames[0].payload[10]).assertEqual(10);
      expect(synAckFrames[0].payload[11]).assertEqual(0);

      const identificationFrames = new Iap2LinkDecoder().push(sent[2]);
      expect(identificationFrames.length).assertEqual(1);
      expect(identificationFrames[0].sequence).assertEqual(101);
      expect(identificationFrames[0].sessionId).assertEqual(10);
      const controlMessages = new Iap2ControlDecoder().push(identificationFrames[0].payload);
      expect(controlMessages.length).assertEqual(1);
      expect(controlMessages[0].messageId).assertEqual(0x1d00);
      session.cancel();
    });

    it('does not echo SYN-ACK and selects control session by descriptor kind', 0, async (): Promise<void> => {
      const sent: Uint8Array[] = [];
      const session = new Iap2SenderSession(
        async (bytes: Uint8Array): Promise<void> => {
          sent.push(bytes);
        },
        (_message: string): void => {},
        (_credentials: WifiCredentials): void => {},
        (_body: Uint8Array): void => {},
        '00:11:22:33:44:55',
        'Harmony CarPlay',
        'test-device'
      );
      await session.start();

      const peerSyncPayload = encodeIap2SyncPayload(2);
      const nonControlFirstSync = new Uint8Array(peerSyncPayload);
      nonControlFirstSync.set(new Uint8Array([2, 2, 1, 1, 0, 2, 3, 1, 2]), 10);
      const peerSynAck: Iap2LinkFrame = {
        control: 0xc0,
        sequence: 161,
        acknowledgement: 99,
        sessionId: 0,
        payload: nonControlFirstSync
      };
      await session.receive(encodeIap2LinkFrame(peerSynAck));

      expect(sent.length).assertEqual(2);
      const identificationFrames = new Iap2LinkDecoder().push(sent[1]);
      expect(identificationFrames.length).assertEqual(1);
      expect(identificationFrames[0].control).assertEqual(0x40);
      expect(identificationFrames[0].sequence).assertEqual(100);
      expect(identificationFrames[0].sessionId).assertEqual(1);
      const messages = new Iap2ControlDecoder().push(identificationFrames[0].payload);
      expect(messages.length).assertEqual(1);
      expect(messages[0].messageId).assertEqual(0x1d00);
      session.cancel();
    });

    it('builds authenticated AirPlay session and screen SETUP plists', 0, () => {
      const initialSetup = BinaryPlist.decode(AirPlayMediaSession.buildSessionSetupPayload(
        '11:22:33:44:55:66',
        'Harmony CarPlay',
        54321
      ));
      expect(initialSetup.kind).assertEqual('dictionary');
      expect(initialSetup.get('deviceID')?.stringValue).assertEqual('11:22:33:44:55:66');
      expect(initialSetup.get('timingPort')?.integerValue).assertEqual(BigInt(54321));
      expect(initialSetup.get('features')?.arrayValue.some(
        (feature: PlistNode): boolean => feature.stringValue === 'videoPlayback'
      )).assertTrue();

      const videoSetup = BinaryPlist.decode(AirPlayMediaSession.buildVideoSetupPayload(
        '00000000-0000-0000-0000-000000000001',
        BigInt(123456)
      ));
      const streams = videoSetup.get('streams');
      expect(streams?.arrayValue.length).assertEqual(1);
      expect(streams?.arrayValue[0].get('type')?.integerValue).assertEqual(BigInt(110));
      expect(streams?.arrayValue[0].get('streamConnectionID')?.integerValue).assertEqual(BigInt(123456));
    });

    it('declares AirPlay screen and audio resources before stream SETUP', 0, () => {
      const modes = BinaryPlist.decode(AirPlayMediaSession.buildModesChangedPayload());
      expect(modes.get('type')?.stringValue).assertEqual('modesChanged');
      const params = modes.get('params');
      expect(params?.get('appStates')?.arrayValue.length).assertEqual(3);
      expect(params?.get('resources')?.arrayValue.length).assertEqual(2);
      expect(params?.get('resources')?.arrayValue[0].get('resourceID')?.integerValue).assertEqual(BigInt(1));
      expect(params?.get('resources')?.arrayValue[1].get('resourceID')?.integerValue).assertEqual(BigInt(2));
    });

    it('selects a receiver-supported PCM profile and builds its audio SETUP', 0, () => {
      const formatEntry = PlistNode.dictionary(new Map<string, PlistNode>([
        ['type', PlistNode.integer(100)],
        ['audioType', PlistNode.string('media')],
        ['audioOutputFormats', PlistNode.integer(BigInt(1) << BigInt(15))]
      ]));
      const info = PlistNode.dictionary(new Map<string, PlistNode>([
        ['audioFormats', PlistNode.array([formatEntry])]
      ]));
      const selected = selectPcmAudioFormat(info);
      expect(selected?.sampleRate).assertEqual(48000);
      const setup = BinaryPlist.decode(AirPlayMediaSession.buildAudioSetupPayload(
        BigInt(98765),
        selected?.formatBit ?? BigInt(0),
        250
      ));
      const streams = setup.get('streams');
      expect(streams?.arrayValue.length).assertEqual(1);
      expect(streams?.arrayValue[0].get('type')?.integerValue).assertEqual(BigInt(100));
      expect(streams?.arrayValue[0].get('spf')?.integerValue).assertEqual(BigInt(352));
    });

    it('answers AirPlay timing requests and rejects malformed packets', 0, () => {
      const request = new Uint8Array(32);
      request[0] = 0x80;
      request[1] = 0xd2;
      request[3] = 7;
      request.set(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]), 24);
      const response = AirPlayMediaSession.buildTimingResponse(request, 1_700_000_000_123);
      expect(response?.length).assertEqual(32);
      expect(response?.[1]).assertEqual(0xd3);
      expect(response?.[3]).assertEqual(7);
      expect(response?.[8]).assertEqual(1);
      expect(response?.[15]).assertEqual(8);
      expect(response?.[16]).assertEqual(response?.[24]);
      expect(AirPlayMediaSession.buildTimingResponse(new Uint8Array(12), 0)).assertUndefined();
    });

    it('builds a 128-byte AirPlay screen keep-alive frame', 0, () => {
      const keepAlive = AirPlayMediaSession.buildVideoKeepAliveFrame(1_700_000_000_123);
      expect(keepAlive.length).assertEqual(128);
      expect(keepAlive[0]).assertEqual(0);
      expect(keepAlive[4]).assertEqual(2);
    });

    it('reassembles AirPlay event RTSP requests and creates matching replies', 0, () => {
      const wire = encodeUtf8('POST /event RTSP/1.0\r\nCSeq: 4\r\nContent-Length: 3\r\n\r\nabc');
      const headerOnly = parseAirPlayEventRequests(wire.slice(0, wire.length - 3));
      expect(headerOnly.requests.length).assertEqual(0);
      expect(headerOnly.remaining.length).assertEqual(wire.length - 3);

      const complete = parseAirPlayEventRequests(concatBytes(headerOnly.remaining, wire.slice(wire.length - 3)));
      expect(complete.requests.length).assertEqual(1);
      expect(complete.requests[0].method).assertEqual('POST');
      expect(complete.requests[0].target).assertEqual('/event');
      expect(complete.requests[0].cseq).assertEqual(4);
      expect(decodeUtf8(complete.requests[0].body)).assertEqual('abc');
      expect(decodeUtf8(buildAirPlayEventResponse(4))).assertEqual(
        'RTSP/1.0 200 OK\r\nCSeq: 4\r\nContent-Length: 0\r\n\r\n'
      );
    });

    it('builds the CardDeck PCM RTP header', 0, () => {
      const header = buildAudioRtpHeader(0x1234, 0x01020304, true);
      expect(header.length).assertEqual(12);
      expect(header[0]).assertEqual(0x80);
      expect(header[1]).assertEqual(0xe4);
      expect(header[2]).assertEqual(0x12);
      expect(header[3]).assertEqual(0x34);
      expect(header[4]).assertEqual(0x01);
      expect(header[7]).assertEqual(0x04);
      expect(header[8]).assertEqual(0);
    });

    it('uses bounded modular exponentiation for SRP', 0, () => {
      expect(modPow(BigInt(4), BigInt(13), BigInt(497))).assertEqual(BigInt(445));
    });

    it('completes SRP-6a proof verification against a mock peer', 0, async (): Promise<void> => {
      const salt = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
      const passwordHash = await sha512(encodeUtf8('Pair-Setup:3939'));
      const privatePassword = srpBytesToBigInt(await sha512(salt, passwordHash));
      const multiplier = srpBytesToBigInt(await sha512(
        padSrpInteger(SRP3072_MODULUS),
        padSrpInteger(SRP_GENERATOR)
      ));
      const verifier = modPow(SRP_GENERATOR, privatePassword, SRP3072_MODULUS);
      const serverPrivate = BigInt('0x123456789abcdef123456789abcdef');
      const serverPublic = (multiplier * verifier + modPow(SRP_GENERATOR, serverPrivate, SRP3072_MODULUS)) %
        SRP3072_MODULUS;
      const paddedServerPublic = padSrpInteger(serverPublic);
      const session = await Srp6aSession.start(salt, paddedServerPublic);
      const clientProof = await session.clientProof();
      const clientPublic = srpBytesToBigInt(session.publicKeyA);
      const scrambling = srpBytesToBigInt(await sha512(session.publicKeyA, paddedServerPublic));
      const serverShared = modPow(
        (clientPublic * modPow(verifier, scrambling, SRP3072_MODULUS)) % SRP3072_MODULUS,
        serverPrivate,
        SRP3072_MODULUS
      );
      const key = await sha512(srpBigIntToBytes(serverShared));
      const serverProof = await sha512(session.publicKeyA, clientProof, key);
      expect(await session.verifyServerProof(serverProof)).assertTrue();
      const invalidProof = serverProof.slice();
      invalidProof[0] = invalidProof[0] ^ 0xff;
      expect(await session.verifyServerProof(invalidProof)).assertFalse();
    });

    it('round-trips fragmented TLV8 values', 0, () => {
      const longValue = new Uint8Array(300);
      for (let index = 0; index < longValue.length; index++) {
        longValue[index] = index & 0xff;
      }
      const items: Tlv8Item[] = [
        { type: 2, value: longValue },
        { type: 6, value: new Uint8Array([3]) }
      ];
      const decoded = decodeTlv8(encodeTlv8(items));
      const restored = decoded.get(2) ?? new Uint8Array(0);
      expect(restored.length).assertEqual(longValue.length);
      for (let index = 0; index < longValue.length; index++) {
        expect(restored[index]).assertEqual(longValue[index]);
      }
      expect(decoded.get(6)?.[0]).assertEqual(3);
    });

    it('round-trips binary plist dictionaries and arrays', 0, () => {
      const values: Map<string, PlistNode> = new Map<string, PlistNode>();
      values.set('name', PlistNode.string('Harmony'));
      values.set('enabled', PlistNode.boolean(true));
      values.set('port', PlistNode.integer(65535));
      values.set('items', PlistNode.array([
        PlistNode.string('地图'),
        PlistNode.data(new Uint8Array([0, 1, 2, 255]))
      ]));
      const decoded = BinaryPlist.decode(BinaryPlist.encode(PlistNode.dictionary(values)));
      expect(decoded.kind).assertEqual('dictionary');
      expect(decoded.get('name')?.stringValue).assertEqual('Harmony');
      expect(decoded.get('enabled')?.boolValue).assertTrue();
      expect(decoded.get('port')?.integerValue).assertEqual(BigInt(65535));
      const items = decoded.get('items');
      expect(items?.kind).assertEqual('array');
      expect(items?.arrayValue[0].stringValue).assertEqual('地图');
      expect(items?.arrayValue[1].dataValue[3]).assertEqual(255);
    });

    it('round-trips ChaCha20-Poly1305 with AAD', 0, async (): Promise<void> => {
      const key = new Uint8Array(32);
      const nonce = new Uint8Array(12);
      const payload = encodeUtf8('Harmony audio frame');
      const aad = new Uint8Array([0x80, 0x64, 0x00, 0x01]);
      for (let index = 0; index < key.length; index++) {
        key[index] = index;
      }
      for (let index = 0; index < nonce.length; index++) {
        nonce[index] = 11 - index;
      }
      const sealed = await chachaSeal(key, nonce, payload, aad);
      const opened = await chachaOpen(key, nonce, sealed, aad);
      expect(opened.length).assertEqual(payload.length);
      for (let index = 0; index < payload.length; index++) {
        expect(opened[index]).assertEqual(payload[index]);
      }
    });

    it('round-trips chunked encrypted RTSP control frames', 0, async (): Promise<void> => {
      const phoneWrite = new Uint8Array(32);
      const phoneRead = new Uint8Array(32);
      for (let index = 0; index < phoneWrite.length; index++) {
        phoneWrite[index] = index;
        phoneRead[index] = 255 - index;
      }
      const phone = new AirPlayControlCipher(phoneRead, phoneWrite);
      const receiver = new AirPlayControlCipher(phoneWrite, phoneRead);
      const message = new Uint8Array(3000);
      for (let index = 0; index < message.length; index++) {
        message[index] = index & 0xff;
      }
      const encrypted = await phone.encrypt(message);
      expect((await receiver.decrypt(encrypted.slice(0, 500))).length).assertEqual(0);
      const decrypted = await receiver.decrypt(encrypted.slice(500));
      expect(decrypted.length).assertEqual(message.length);
      for (let index = 0; index < message.length; index++) {
        expect(decrypted[index]).assertEqual(message[index]);
      }
    });

    it('derives SHA-512 and HKDF keys through the platform crypto API', 0, async (): Promise<void> => {
      const digest = await sha512(encodeUtf8('abc'));
      expect(digest.length).assertEqual(64);
      const inputKey = new Uint8Array([1, 2, 3, 4]);
      const salt = new Uint8Array([5, 6, 7, 8]);
      const info = new Uint8Array([9, 10, 11]);
      const keyOne = await hkdfSha512(inputKey, salt, info, 32);
      const keyTwo = await hkdfSha512(inputKey, salt, info, 32);
      expect(keyOne.length).assertEqual(32);
      for (let index = 0; index < keyOne.length; index++) {
        expect(keyOne[index]).assertEqual(keyTwo[index]);
      }
    });

    it('signs and verifies Ed25519 messages', 0, async (): Promise<void> => {
      const pair = await generateEd25519KeyPair();
      const message = encodeUtf8('pair-verify test');
      const signature = await signEd25519(pair.privateKeyDer, message);
      expect(await verifyEd25519(pair.publicKeyRaw, message, signature)).assertTrue();
      expect(await verifyEd25519(pair.publicKeyRaw, encodeUtf8('different'), signature)).assertFalse();
    });

    it('derives the same X25519 shared secret', 0, async (): Promise<void> => {
      const left = await generateX25519KeyPair();
      const right = await generateX25519KeyPair();
      const leftSecret = await x25519SharedSecret(left.privateKeyDer, right.publicKeyRaw);
      const rightSecret = await x25519SharedSecret(right.privateKeyDer, left.publicKeyRaw);
      expect(leftSecret.length).assertEqual(32);
      for (let index = 0; index < leftSecret.length; index++) {
        expect(leftSecret[index]).assertEqual(rightSecret[index]);
      }
    });
  });
}
