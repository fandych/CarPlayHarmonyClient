import localUnitTest from './LocalUnit.test';
import iap2ProtocolTest from './Iap2Protocol.test';
import airPlayFeaturesTest from './AirPlayFeatures.test';
import rtspRequestEncoderTest from './RtspRequestEncoder.test';
import tlv8Test from './Tlv8.test';
import srp6aClientTest from './Srp6aClient.test';
import carPlayInviteProtocolTest from './CarPlayInviteProtocol.test';
import airPlayMediaPacketCodecTest from './AirPlayMediaPacketCodec.test';
import binaryPlistTest from './BinaryPlist.test';
import airPlayControlCipherTest from './AirPlayControlCipher.test';
import airPlayMediaSetupProtocolTest from './AirPlayMediaSetupProtocol.test';
import harmonyAirPlayTimingServerTest from './HarmonyAirPlayTimingServer.test';
import carPlayDiagnosticsTest from './CarPlayDiagnostics.test';
import harmonySppServerTest from './HarmonySppServer.test';
import harmonyWifiSelectionTest from './HarmonyWifiSelection.test';
import harmonyBluetoothIdentityTest from './HarmonyBluetoothIdentity.test';
import carPlaySettingsTest from './CarPlaySettings.test';
import rtspEventMessageParserTest from './RtspEventMessageParser.test';

export default function testsuite() {
  localUnitTest();
  iap2ProtocolTest();
  airPlayFeaturesTest();
  rtspRequestEncoderTest();
  tlv8Test();
  srp6aClientTest();
  carPlayInviteProtocolTest();
  airPlayMediaPacketCodecTest();
  binaryPlistTest();
  airPlayControlCipherTest();
  airPlayMediaSetupProtocolTest();
  harmonyAirPlayTimingServerTest();
  carPlayDiagnosticsTest();
  harmonySppServerTest();
  harmonyWifiSelectionTest();
  harmonyBluetoothIdentityTest();
  carPlaySettingsTest();
  rtspEventMessageParserTest();
}