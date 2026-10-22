import { describe, it, expect } from '@ohos/hypium';
import { AirPlayEventProtocol } from '../main/ets/protocol/airplay/AirPlayEventProtocol';
import { BinaryPlist, BinaryPlistValue } from '../main/ets/protocol/airplay/BinaryPlist';

export default function airPlayEventProtocolTest(): void {
  describe('AirPlay event and HID protocol', () => {
    it('parses HID reports and iAP event messages', 0, () => {
      const hid: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      hid.set('type', 'hidSendReport');
      hid.set('uuid', '1');
      hid.set('hidReport', new Uint8Array([1, 2, 3, 4, 5]));
      const parsedHid = AirPlayEventProtocol.parseCommand(BinaryPlist.encode(hid));
      expect(parsedHid.kind).assertEqual('hid-report');
      if (parsedHid.kind === 'hid-report') {
        expect(parsedHid.uuid).assertEqual('1');
        expect(Array.from(parsedHid.report).join(',')).assertEqual('1,2,3,4,5');
      }

      const parameters: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      parameters.set('data', new Uint8Array([0xFF, 0x55, 0x02]));
      const iap: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      iap.set('type', 'iAPSendMessage');
      iap.set('params', parameters);
      const parsedIap = AirPlayEventProtocol.parseCommand(BinaryPlist.encode(iap));
      expect(parsedIap.kind).assertEqual('iap-message');
      if (parsedIap.kind === 'iap-message') {
        expect(Array.from(parsedIap.data).join(',')).assertEqual('255,85,2');
      }
    });

    it('maps consumer array reports using the advertised HID usage order', 0, () => {
      const descriptor = new Uint8Array([
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
        0x09, 0x00, 0x09, 0xB0, 0x09, 0xB1, 0x09, 0xB3,
        0x09, 0xB4, 0x09, 0xB5, 0x09, 0xB6, 0x09, 0xB9,
        0x15, 0x00, 0x25, 0x08, 0x75, 0x08, 0x95, 0x01,
        0x81, 0x00, 0xC0
      ]);
      const parsed = AirPlayEventProtocol.interpretHidReport(new Uint8Array([5]), descriptor);
      expect(parsed.kind).assertEqual('consumer');
      if (parsed.kind === 'consumer') {
        expect(parsed.usages[0]).assertEqual(0xB5);
      }
      expect(AirPlayEventProtocol.consumerKeyName(0xB5)).assertEqual('next');
    });

    it('maps consumer variable reports as a usage bit field', 0, () => {
      const descriptor = new Uint8Array([
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
        0x09, 0xB0, 0x09, 0xB1, 0x09, 0xB5, 0x09, 0xB6,
        0x09, 0xB9, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
        0x95, 0x05, 0x81, 0x02, 0xC0
      ]);
      const parsed = AirPlayEventProtocol.interpretHidReport(new Uint8Array([0x04]), descriptor);
      expect(parsed.kind).assertEqual('consumer');
      if (parsed.kind === 'consumer') {
        expect(parsed.usages[0]).assertEqual(0xB5);
      }
    });

    it('parses single- and multi-contact absolute touch reports', 0, () => {
      const singleDescriptor = new Uint8Array([
        0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x09, 0x22,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xC0
      ]);
      const single = AirPlayEventProtocol.interpretHidReport(
        new Uint8Array([1, 0x34, 0x12, 0x78, 0x56]),
        singleDescriptor
      );
      expect(single.kind).assertEqual('touch');
      if (single.kind === 'touch') {
        expect(single.contacts[0].x).assertEqual(0x1234);
        expect(single.contacts[0].y).assertEqual(0x5678);
        expect(single.contacts[0].down).assertTrue();
      }

      const multiDescriptor = new Uint8Array([
        0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x09, 0x22, 0x09, 0x22,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xC0
      ]);
      const multi = AirPlayEventProtocol.interpretHidReport(
        new Uint8Array([0, 1, 0x34, 0x12, 0x78, 0x56, 0, 0, 0xBC, 0x9A, 0xF0, 0xDE]),
        multiDescriptor
      );
      expect(multi.kind).assertEqual('touch');
      if (multi.kind === 'touch') {
        expect(multi.contacts.length).assertEqual(2);
        expect(multi.contacts[1].x).assertEqual(0x9ABC);
        expect(multi.contacts[1].y).assertEqual(0xDEF0);
        expect(multi.contacts[1].down).assertFalse();
      }
    });

    it('builds the receiver resource and touch-mode commands', 0, () => {
      const modes = AirPlayEventProtocol.buildModesChangedCommand();
      expect(modes.get('type') as string).assertEqual('modesChanged');
      const parameters = modes.get('params') as Map<string, BinaryPlistValue>;
      expect((parameters.get('resources') as BinaryPlistValue[]).length).assertEqual(2);
      const touch = AirPlayEventProtocol.buildHidSetInputModeCommand('1');
      expect(touch.get('type') as string).assertEqual('hidSetInputMode');
      const touchParameters = touch.get('params') as Map<string, BinaryPlistValue>;
      expect(touchParameters.get('uuid') as string).assertEqual('1');
    });
  });
}
