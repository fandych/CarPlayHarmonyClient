import { Iap2Csm, Iap2CsmFrame, Iap2CsmParser, Iap2Param } from '../main/ets/protocol/iap2/Iap2Csm';
import { Iap2SenderSession } from '../main/ets/protocol/iap2/Iap2SenderSession';
import { MfiVerifier, ValidatedMfiCertificate } from '../main/ets/protocol/iap2/MfiVerifier';

export class DeterministicMfiVerifier extends MfiVerifier {
  constructor() {
    super(() => {});
  }

  async validateAccessoryCertificate(payload: Uint8Array): Promise<ValidatedMfiCertificate> {
    if (payload.length === 0) {
      throw new Error('Empty test certificate.');
    }
    return { candidates: [], certificateCount: 1, encodingName: 'test' };
  }

  async verifyChallenge(
    _validated: ValidatedMfiCertificate,
    challenge: Uint8Array,
    signature: Uint8Array
  ): Promise<void> {
    if (challenge.length !== signature.length) {
      throw new Error('Test MFi signature mismatch.');
    }
    for (let index = 0; index < challenge.length; index++) {
      if (challenge[index] !== signature[index]) {
        throw new Error('Test MFi signature mismatch.');
      }
    }
  }
}

export async function deterministicTestRandomBytes(length: number): Promise<Uint8Array> {
  const bytes = new Uint8Array(length);
  for (let index = 0; index < length; index++) {
    bytes[index] = (index + 1) & 0xFF;
  }
  return bytes;
}

export function csmMessages(sent: Uint8Array[]): Iap2CsmFrame[] {
  const frames: Iap2CsmFrame[] = [];
  for (const bytes of sent) {
    frames.push(...new Iap2CsmParser().offer(bytes));
  }
  return frames;
}

export async function authenticateTestAccessory(session: Iap2SenderSession, sent: Uint8Array[]): Promise<void> {
  session.receive(Iap2Csm.encode(0xAA01, Iap2Csm.param(0, new Uint8Array([0x30, 0x01, 0x00]))));
  await session.whenIdle();
  const challengeFrame = csmMessages(sent).find((frame) => frame.messageId === 0xAA02);
  if (challengeFrame === undefined) {
    throw new Error('Test sender did not issue an MFi challenge.');
  }
  const challenge = Iap2Csm.parseParams(challengeFrame.body).find((parameter: Iap2Param) => parameter.id === 0)?.value;
  if (challenge === undefined) {
    throw new Error('Test sender MFi challenge has no parameter payload.');
  }
  session.receive(Iap2Csm.encode(0xAA03, Iap2Csm.param(0, challenge.slice())));
  await session.whenIdle();
}

export function concatenate(parts: Uint8Array[]): Uint8Array {
  let size = 0;
  for (const part of parts) {
    size += part.length;
  }
  const combined = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    combined.set(part, offset);
    offset += part.length;
  }
  return combined;
}
