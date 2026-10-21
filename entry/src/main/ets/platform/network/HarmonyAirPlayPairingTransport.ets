import { RtspRequestHeader } from '../../protocol/airplay/RtspRequestEncoder';
import { TlvTransport } from '../../protocol/airplay/AirPlayPairingClient';
import { HarmonyAirPlayRtspSession } from './HarmonyAirPlayRtspSession';

export class HarmonyAirPlayPairingTransport implements TlvTransport {
  private readonly session: HarmonyAirPlayRtspSession;

  constructor(session: HarmonyAirPlayRtspSession) {
    this.session = session;
  }

  async exchange(path: string, body: Uint8Array): Promise<Uint8Array> {
    if (path !== '/pair-setup' && path !== '/pair-verify') {
      throw new Error(`Unsupported AirPlay pairing endpoint: ${path}.`);
    }
    const headers: RtspRequestHeader[] = [
      { name: 'Content-Type', value: 'application/pairing+tlv8' },
      { name: 'X-Apple-HKP', value: '2' }
    ];
    if (path === '/pair-verify') {
      headers.push({ name: 'X-Apple-PD', value: '1' });
    }
    const response = await this.session.request('POST', path, body, headers);
    if (response.statusCode !== 200) {
      throw new Error(`AirPlay ${path} returned HTTP ${response.statusCode} ${response.reason}.`);
    }
    return response.body;
  }
}
