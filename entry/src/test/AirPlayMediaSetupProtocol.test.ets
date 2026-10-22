import { describe, it, expect } from '@ohos/hypium';
import {
  AirPlayMediaSetupProtocol,
  AirPlaySenderMetadata
} from '../main/ets/protocol/airplay/AirPlayMediaSetupProtocol';
import { BinaryPlist, BinaryPlistValue } from '../main/ets/protocol/airplay/BinaryPlist';

export default function airPlayMediaSetupProtocolTest(): void {
  describe('AirPlay media SETUP/RECORD protocol', () => {
    it('builds session and screen setup plists using a real Bluetooth identity', 0, () => {
      const sender: AirPlaySenderMetadata = {
        name: 'Harmony CarPlay Sender',
        model: 'PLR-AL00',
        osName: 'HarmonyOS',
        osBuildVersion: 'OpenHarmony-7.0.0',
        osVersion: '26',
        sourceVersion: 'CarPlayHarmonyClient/1.0'
      };
      const initial = BinaryPlist.parse(AirPlayMediaSetupProtocol.buildInitialSetupBody(
        'A1:B2:C3:D4:E5:F6',
        49152,
        '12345678-1234-4ABC-8DEF-123456789ABC',
        '87654321-4321-4CBA-8FED-CBA987654321',
        sender
      )) as Map<string, BinaryPlistValue>;
      expect(initial.get('deviceID') as string).assertEqual('A1:B2:C3:D4:E5:F6');
      expect(initial.get('macAddress') as string).assertEqual('A1:B2:C3:D4:E5:F6');
      expect(initial.get('name') as string).assertEqual(sender.name);
      expect(initial.get('model') as string).assertEqual(sender.model);
      expect(initial.get('timingPort') as number).assertEqual(49152);
      expect((initial.get('features') as BinaryPlistValue[]).length).assertEqual(14);

      const screen = BinaryPlist.parse(AirPlayMediaSetupProtocol.buildScreenSetupBody(
        0x12345678,
        'display-uuid'
      )) as Map<string, BinaryPlistValue>;
      const screenStream = (screen.get('streams') as BinaryPlistValue[])[0] as Map<string, BinaryPlistValue>;
      expect(screenStream.get('type') as number).assertEqual(110);
      expect(screenStream.get('streamConnectionID') as number).assertEqual(0x12345678);
      expect(screenStream.get('uuid') as string).assertEqual('display-uuid');

      let placeholderRejected = false;
      try {
        AirPlayMediaSetupProtocol.buildInitialSetupBody(
          '02:00:00:00:00:00',
          49152,
          '12345678-1234-4ABC-8DEF-123456789ABC',
          '87654321-4321-4CBA-8FED-CBA987654321',
          sender
        );
      } catch {
        placeholderRejected = true;
      }
      expect(placeholderRejected).assertTrue();
    });

    it('builds audio parameters and parses high unsigned stream ports', 0, () => {
      const audio = BinaryPlist.parse(AirPlayMediaSetupProtocol.buildAudioSetupBody({
        streamType: 100,
        streamConnectionId: 12345,
        audioFormat: 1 << 15,
        audioType: 'media',
        latencyMs: 250,
        supportsHighAccuracyTimestamps: true,
        samplesPerFrame: 352
      })) as Map<string, BinaryPlistValue>;
      const audioStream = (audio.get('streams') as BinaryPlistValue[])[0] as Map<string, BinaryPlistValue>;
      expect(audioStream.get('type') as number).assertEqual(100);
      expect(audioStream.get('audioFormat') as number).assertEqual(1 << 15);
      expect(audioStream.get('spf') as number).assertEqual(352);

      const responseStream: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      responseStream.set('type', 110);
      responseStream.set('dataPort', 0x8895);
      responseStream.set('controlPort', 65535);
      const response: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      response.set('streams', [responseStream]);
      const ports = AirPlayMediaSetupProtocol.parseStreamPorts(BinaryPlist.encode(response), 110);
      expect(ports.dataPort).assertEqual(0x8895);
      expect(ports.controlPort).assertEqual(65535);
      expect(BinaryPlist.parse(AirPlayMediaSetupProtocol.buildRecordBody()) instanceof Map).assertTrue();
    });

    it('rejects missing and mismatched SETUP response streams', 0, () => {
      const wrongStream: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      wrongStream.set('type', 100);
      wrongStream.set('dataPort', 1234);
      const root: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      root.set('streams', [wrongStream]);
      let mismatchRejected = false;
      try {
        AirPlayMediaSetupProtocol.parseStreamPorts(BinaryPlist.encode(root), 110);
      } catch {
        mismatchRejected = true;
      }
      expect(mismatchRejected).assertTrue();

      wrongStream.set('type', 110);
      wrongStream.delete('dataPort');
      let missingPortRejected = false;
      try {
        AirPlayMediaSetupProtocol.parseStreamPorts(BinaryPlist.encode(root), 110);
      } catch {
        missingPortRejected = true;
      }
      expect(missingPortRejected).assertTrue();
    });

    it('parses initial SETUP event and keep-alive ports', 0, () => {
      const root: Map<string, BinaryPlistValue> = new Map<string, BinaryPlistValue>();
      root.set('eventPort', 65534);
      root.set('timingPort', 49152);
      root.set('keepAlivePort', 53123);
      root.set('enabledFeatures', ['video', 'audio']);
      const setup = AirPlayMediaSetupProtocol.parseInitialSetupResponse(BinaryPlist.encode(root));
      expect(setup.eventPort).assertEqual(65534);
      expect(setup.timingPort).assertEqual(49152);
      expect(setup.keepAlivePort).assertEqual(53123);
      expect(setup.enabledFeatures.length).assertEqual(2);
    });
  });
}
