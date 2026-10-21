import { describe, it, expect } from '@ohos/hypium';
import { CarPlayInviteProtocol } from '../main/ets/protocol/airplay/CarPlayInviteProtocol';

export default function carPlayInviteProtocolTest(): void {
  describe('CarPlay control invitation protocol', () => {
    it('parses the connect request and returns HTTP 200', 0, () => {
      const request = CarPlayInviteProtocol.parseRequest(
        'GET /ctrl-int/1/connect HTTP/1.1\r\nAirPlay-Receiver-Device-ID: receiver-1\r\n\r\n'
      );
      expect(request.method).assertEqual('GET');
      expect(request.path).assertEqual('/ctrl-int/1/connect');
      expect(request.receiverDeviceId).assertEqual('receiver-1');
      const response = CarPlayInviteProtocol.ascii(
        'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
      );
      expect(CarPlayInviteProtocol.response(request).toString()).assertEqual(response.toString());
    });

    it('rejects malformed HTTP and placeholder Bluetooth identities', 0, () => {
      let malformedRejected = false;
      let placeholderRejected = false;
      try {
        CarPlayInviteProtocol.parseRequest('GET /ctrl-int/1/connect HTTP/1.1\r\n');
      } catch {
        malformedRejected = true;
      }
      try {
        CarPlayInviteProtocol.createTxtIdentity('02:00:00:00:00:00');
      } catch {
        placeholderRejected = true;
      }
      expect(malformedRejected).assertTrue();
      expect(placeholderRejected).assertTrue();
      expect(CarPlayInviteProtocol.createTxtIdentity('AA:BB:CC:DD:EE:FF'))
        .assertEqual('AA:BB:CC:DD:EE:FF');
    });
  });
}
