import { BinaryPlist, BinaryPlistValue } from './BinaryPlist';

export interface AirPlayAudioProfile {
  streamType: number;
  audioFormat: number;
  audioType: string;
  sampleRate: number;
  latencyMs: number;
  samplesPerFrame: number;
}

interface AudioCandidate {
  streamType: number;
  formatBit: number;
  sampleRate: number;
}

const AUDIO_TYPE_MEDIA = 'media';
const AUDIO_LATENCY_FALLBACK_MS = 250;
const AAC_CANDIDATES: AudioCandidate[] = [
  { streamType: 102, formatBit: 1 << 22, sampleRate: 44100 },
  { streamType: 102, formatBit: 1 << 23, sampleRate: 48000 },
  { streamType: 100, formatBit: 1 << 22, sampleRate: 44100 },
  { streamType: 100, formatBit: 1 << 23, sampleRate: 48000 }
];

export class AirPlayAudioProfileProtocol {
  static readAacCandidates(infoBytes: Uint8Array): AirPlayAudioProfile[] {
    const root = BinaryPlist.parse(infoBytes);
    if (!(root instanceof Map)) {
      throw new Error('AirPlay /info response is not a Binary Plist dictionary.');
    }
    const formatsValue = root.get('audioFormats');
    if (!Array.isArray(formatsValue)) {
      return [];
    }
    const profiles: AirPlayAudioProfile[] = [];
    for (const candidate of AAC_CANDIDATES) {
      for (const value of formatsValue) {
        if (!(value instanceof Map)) {
          continue;
        }
        const audioTypeValue = value.get('audioType');
        if (value.get('type') !== candidate.streamType || typeof audioTypeValue !== 'string' ||
          audioTypeValue.toLowerCase() !== AUDIO_TYPE_MEDIA) {
          continue;
        }
        const outputFormats = value.get('audioOutputFormats');
        if (typeof outputFormats !== 'number' || !Number.isSafeInteger(outputFormats) ||
          (outputFormats & candidate.formatBit) === 0) {
          continue;
        }
        const audioType = audioTypeValue.toLowerCase();
        const profile: AirPlayAudioProfile = {
          streamType: candidate.streamType,
          audioFormat: candidate.formatBit,
          audioType,
          sampleRate: candidate.sampleRate,
          latencyMs: AirPlayAudioProfileProtocol.readLatency(
            root.get('audioLatencies'),
            candidate.streamType,
            audioType
          ),
          samplesPerFrame: 1024
        };
        profiles.push(profile);
      }
    }
    return AirPlayAudioProfileProtocol.uniqueProfiles(profiles);
  }

  private static readLatency(value: BinaryPlistValue | undefined, streamType: number, audioType: string): number {
    if (!Array.isArray(value)) {
      return AUDIO_LATENCY_FALLBACK_MS;
    }
    for (const item of value) {
      if (!(item instanceof Map) || item.get('type') !== streamType || item.get('audioType') !== audioType) {
        continue;
      }
      const outputMicros = item.get('outputLatencyMicros');
      if (typeof outputMicros === 'number' && Number.isSafeInteger(outputMicros) && outputMicros > 0) {
        return Math.max(AUDIO_LATENCY_FALLBACK_MS, Math.floor(outputMicros / 1000));
      }
    }
    return AUDIO_LATENCY_FALLBACK_MS;
  }

  private static uniqueProfiles(profiles: AirPlayAudioProfile[]): AirPlayAudioProfile[] {
    const keys: Set<string> = new Set<string>();
    const unique: AirPlayAudioProfile[] = [];
    for (const profile of profiles) {
      const key = `${profile.streamType}|${profile.audioType}|${profile.audioFormat}`;
      if (!keys.has(key)) {
        keys.add(key);
        unique.push(profile);
      }
    }
    return unique;
  }
}
