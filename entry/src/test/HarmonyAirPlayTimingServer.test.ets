import { describe, it, expect } from '@ohos/hypium';
import { HarmonyAirPlayTimingServer } from '../main/ets/platform/network/HarmonyAirPlayTimingServer';

export default function harmonyAirPlayTimingServerTest(): void {
  describe('Harmony AirPlay timing server', () => {
    it('echoes the client transmit timestamp and returns an NTP timesync response', 0, () => {
      const request = new Uint8Array(32);
      request[0] = 0x80;
      request[1] = 0xD2;
      request[3] = 7;
      request.set([1, 2, 3, 4, 5, 6, 7, 8], 24);
      const response = HarmonyAirPlayTimingServer.buildTimeSyncResponse(request, 1700000000123);
      expect(response !== undefined).assertTrue();
      expect(response?.length as number).assertEqual(32);
      expect(response?.[0] as number).assertEqual(0x80);
      expect(response?.[1] as number).assertEqual(0xD3);
      expect(response?.[3] as number).assertEqual(7);
      expect(Array.from(response?.slice(8, 16) as Uint8Array).join(',')).assertEqual('1,2,3,4,5,6,7,8');
      expect(Array.from(response?.slice(16, 20) as Uint8Array).join(',')).assertEqual('101,83,241,0');
      expect(Array.from(response?.slice(24, 28) as Uint8Array).join(',')).assertEqual('101,83,241,0');
    });

    it('rejects malformed requests', 0, () => {
      const malformed = new Uint8Array(32);
      malformed[0] = 0x80;
      malformed[1] = 0xD2;
      malformed[3] = 6;
      expect(HarmonyAirPlayTimingServer.buildTimeSyncResponse(malformed, 1) === undefined).assertTrue();
      malformed[3] = 7;
      expect(HarmonyAirPlayTimingServer.buildTimeSyncResponse(malformed, -1) === undefined).assertTrue();
    });
  });
}
