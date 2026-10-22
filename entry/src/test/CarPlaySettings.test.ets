import { describe, expect, it } from '@ohos/hypium';
import {
  CarPlaySettings, defaultCarPlaySettings, isIpLiteral, parseCarPlaySettings,
  serializeCarPlaySettings, validateCarPlaySettings, validateWifiPassword
} from '../main/ets/app/settings/CarPlaySettings';
import { CarPlaySettingsStore, SettingsPersistence, WifiSecretVault } from '../main/ets/app/settings/CarPlaySettingsStore';
import {
  chooseAirPlayEndpoint, chooseWifiConfiguration, configuredAirPlay, resolveSessionWifi
} from '../main/ets/app/settings/SettingsFallbacks';
import { ConfiguredBluetoothIdentityProvider } from '../main/ets/platform/bluetooth/ConfiguredBluetoothIdentityProvider';
import { BluetoothIdentityError } from '../main/ets/platform/bluetooth/HarmonyBluetoothIdentityProvider';
import { BluetoothIdentityProvider } from '../main/ets/platform/network/HarmonyCarPlayInviteServer';
import { AccessoryWifiConfiguration } from '../main/ets/protocol/iap2/Iap2SenderSession';
import { AirPlayServiceEndpoint } from '../main/ets/platform/network/HarmonyMdnsBrowser';

class MemorySettingsPersistence implements SettingsPersistence {
  raw: string = '';
  fail: boolean = false;
  writes: number = 0;
  read(): string { return this.raw; }
  write(record: string): void {
    if (this.fail) { throw new Error('disk write failed'); }
    this.raw = record;
    this.writes++;
  }
}
interface StoredPassword { ssid: string; security: number; password: string; }
class MemoryWifiVault implements WifiSecretVault {
  readonly records: Map<string, StoredPassword> = new Map<string, StoredPassword>();
  failRemove: boolean = false;
  wait: Promise<void> | undefined = undefined;
  private sequence: number = 0;
  async add(ssid: string, securityType: number, password: string): Promise<string> {
    if (this.wait !== undefined) { await this.wait; }
    const alias = `CarPlayHarmony.Wifi.v1.00000000-0000-4000-8000-${(++this.sequence).toString().padStart(12, '0')}`;
    this.records.set(alias, { ssid, security: securityType, password });
    return alias;
  }
  async read(alias: string, ssid: string, securityType: number): Promise<string> {
    const stored = this.records.get(alias);
    if (stored === undefined || stored.ssid !== ssid || stored.security !== securityType) {
      throw new Error('secret binding mismatch');
    }
    return stored.password;
  }
  async remove(alias: string): Promise<void> {
    if (this.failRemove) { throw new Error('vault remove failed'); }
    this.records.delete(alias);
  }
}
class FakeIdentity implements BluetoothIdentityProvider {
  address: string | undefined = '10:20:30:AA:BB:CC';
  error: Error | BluetoothIdentityError | undefined = undefined;
  async getStableBluetoothAddress(): Promise<string | undefined> {
    if (this.error instanceof BluetoothIdentityError) { throw this.error; }
    if (this.error instanceof Error) { throw this.error; }
    return this.address;
  }
}
function configured(): CarPlaySettings {
  const settings = defaultCarPlaySettings();
  settings.localBluetoothAddress = '10:20:30:DD:EE:FF';
  settings.deviceName = '我的鸿蒙设备';
  settings.targetDeviceId = 'receiver-id';
  settings.targetDeviceName = 'Test receiver';
  settings.wifi = { ssid: 'Car-AP', securityType: 2, channel: 36 };
  settings.airplay = { host: 'fe80::1%wlan0', port: 7000 };
  return settings;
}
function storeFor(disk: MemorySettingsPersistence, vault: MemoryWifiVault): CarPlaySettingsStore {
  return new CarPlaySettingsStore(disk, vault, () => {});
}
function rejectsJson(json: string): boolean {
  try { parseCarPlaySettings(json); return false; } catch { return true; }
}

export default function carPlaySettingsTest(): void {
  describe('Serialized CarPlay settings', () => {
    it('defaults to disabled system theme without a fabricated address', 0, () => {
      const settings = defaultCarPlaySettings();
      expect(settings.enabled).assertFalse();
      expect(settings.theme).assertEqual('system');
      expect(settings.localBluetoothAddress).assertEqual('');
      expect(settings.wifi.ssid).assertEqual('');
    });
    it('round trips the versioned configuration and normalizes the manual MAC', 0, () => {
      const settings = configured();
      settings.enabled = true;
      settings.theme = 'dark';
      settings.localBluetoothAddress = '10:20:30:dd:ee:ff';
      const result = parseCarPlaySettings(serializeCarPlaySettings(settings));
      expect(result.version).assertEqual(1);
      expect(result.enabled).assertTrue();
      expect(result.theme).assertEqual('dark');
      expect(result.deviceName).assertEqual('我的鸿蒙设备');
      expect(result.localBluetoothAddress).assertEqual('10:20:30:DD:EE:FF');
      expect(result.airplay.host).assertEqual('fe80::1%wlan0');
    });
    it('rejects invalid root shapes, unknown versions and secret injection', 0, () => {
      for (const json of ['null', '[]', '"settings"', '{}', 'not-json',
        serializeCarPlaySettings(configured()).replace('"version": 1', '"version": 2'),
        serializeCarPlaySettings(configured()).replace('"enabled": false', '"enabled": "true"'),
        serializeCarPlaySettings(configured()).replace('"version": 1', '"version": 1, "password": "secret"')]) {
        expect(rejectsJson(json)).assertTrue();
      }
    });
    it('rejects placeholders, a remote address used as local, bad ports and overlong SSIDs', 0, () => {
      const values = ['02:00:00:00:00:00', '00:00:00:00:00:00', 'FF:FF:FF:FF:FF:FF'];
      for (const address of values) {
        const settings = configured();
        settings.localBluetoothAddress = address;
        let invalid = false;
        try { validateCarPlaySettings(settings); } catch { invalid = true; }
        expect(invalid).assertTrue();
      }
      const settings = configured();
      settings.targetDeviceId = settings.localBluetoothAddress;
      expect(rejectsJson(JSON.stringify(settings))).assertTrue();
      settings.targetDeviceId = 'receiver';
      settings.airplay.port = 65536;
      expect(rejectsJson(JSON.stringify(settings))).assertTrue();
      settings.airplay.port = 7000;
      settings.wifi.ssid = '汉'.repeat(11);
      expect(rejectsJson(JSON.stringify(settings))).assertTrue();
    });
    it('accepts IP literals and rejects URLs, invalid groups and ambiguous addresses', 0, () => {
      for (const host of ['192.168.1.1', '::1', 'fe80::1%wlan0', '2001:db8:1:2:3:4:5:6', '::ffff:192.168.1.1']) {
        expect(isIpLiteral(host)).assertTrue();
      }
      for (const host of ['999.1.1.1', '01.2.3.4', 'https://192.168.1.1', '192.168.1.1:7000',
        '[::1]', '1:2:3', '1::2::3', '1:2:3:4:5:6:7:8::', 'fe80::1%']) {
        expect(isIpLiteral(host)).assertFalse();
      }
    });
    it('does not accept a PSK that is too short or a password for an open network', 0, () => {
      const settings = configured();
      let short = false;
      try { validateWifiPassword(settings, 'short'); } catch { short = true; }
      expect(short).assertTrue();
      settings.wifi.securityType = 0;
      let open = false;
      try { validateWifiPassword(settings, 'long-password'); } catch { open = true; }
      expect(open).assertTrue();
    });
    it('persists intent/theme across restart without plaintext passwords in JSON', 0, async () => {
      const disk = new MemorySettingsPersistence();
      const vault = new MemoryWifiVault();
      const first = storeFor(disk, vault);
      await first.load();
      const settings = configured();
      settings.enabled = true;
      settings.theme = 'dark';
      await first.save(settings, 'private-wifi-password');
      expect(disk.raw.includes('private-wifi-password')).assertFalse();
      expect(first.exportJson().includes('secretAlias')).assertFalse();
      expect(first.exportJson().includes('password')).assertFalse();
      const second = storeFor(disk, vault);
      await second.load();
      expect(second.snapshot().settings.enabled).assertTrue();
      expect(second.snapshot().settings.theme).assertEqual('dark');
      expect(second.password()).assertEqual('private-wifi-password');
    });
    it('keeps snapshot objects isolated from the committed configuration', 0, async () => {
      const store = storeFor(new MemorySettingsPersistence(), new MemoryWifiVault());
      await store.load();
      store.snapshot().settings.wifi.ssid = 'mutated';
      expect(store.snapshot().settings.wifi.ssid).assertEqual('');
    });
    it('does not replace a malformed stored record with successful-looking defaults', 0, async () => {
      const disk = new MemorySettingsPersistence();
      disk.raw = '{"invalid":true}';
      const store = storeFor(disk, new MemoryWifiVault());
      let failed = false;
      try { await store.load(); } catch { failed = true; }
      expect(failed).assertTrue();
      expect(store.snapshot().ready).assertFalse();
      expect(store.snapshot().error.length > 0).assertTrue();
      expect(disk.writes).assertEqual(0);
    });
    it('rolls back a newly added secret when the atomic settings write fails', 0, async () => {
      const disk = new MemorySettingsPersistence();
      const vault = new MemoryWifiVault();
      const store = storeFor(disk, vault);
      await store.load();
      await store.save(configured(), 'first-password');
      const before = disk.raw;
      disk.fail = true;
      const next = configured();
      next.deviceName = 'not committed';
      let failed = false;
      try { await store.save(next, 'second-password'); } catch { failed = true; }
      expect(failed).assertTrue();
      expect(disk.raw).assertEqual(before);
      expect(store.password()).assertEqual('first-password');
      expect(store.snapshot().settings.deviceName).assertEqual('我的鸿蒙设备');
      expect(vault.records.size).assertEqual(1);
    });
    it('can explicitly recover a corrupt file from validated JSON without reusing secrets', 0, async () => {
      const disk = new MemorySettingsPersistence();
      disk.raw = '{"corrupt":true}';
      const store = storeFor(disk, new MemoryWifiVault());
      let loadFailed = false;
      try { await store.load(); } catch { loadFailed = true; }
      expect(loadFailed).assertTrue();
      const next = configured();
      next.enabled = true;
      await store.importJson(serializeCarPlaySettings(next));
      expect(store.snapshot().ready).assertTrue();
      expect(store.snapshot().settings.enabled).assertFalse();
      expect(store.password()).assertEqual('');
      expect(store.snapshot().settings.deviceName).assertEqual('我的鸿蒙设备');
    });
    it('rejects invalid imports without overwriting settings or secrets', 0, async () => {
      const disk = new MemorySettingsPersistence();
      const store = storeFor(disk, new MemoryWifiVault());
      await store.load();
      await store.save(configured(), 'private-password');
      const before = disk.raw;
      let failed = false;
      try { await store.importJson('{"version":999}'); } catch { failed = true; }
      expect(failed).assertTrue();
      expect(disk.raw).assertEqual(before);
      expect(store.password()).assertEqual('private-password');
    });
    it('imports without auto-connecting and never reuses a password for a different SSID', 0, async () => {
      const disk = new MemorySettingsPersistence();
      const vault = new MemoryWifiVault();
      const store = storeFor(disk, vault);
      await store.load();
      await store.save(configured(), 'private-password');
      const next = configured();
      next.enabled = true;
      next.wifi.ssid = 'Different-AP';
      await store.importJson(serializeCarPlaySettings(next));
      expect(store.snapshot().settings.enabled).assertFalse();
      expect(store.password()).assertEqual('');
      expect(vault.records.size).assertEqual(0);
    });
    it('preserves the current password when importing the same network configuration', 0, async () => {
      const store = storeFor(new MemorySettingsPersistence(), new MemoryWifiVault());
      await store.load();
      await store.save(configured(), 'private-password');
      await store.importJson(store.exportJson());
      expect(store.password()).assertEqual('private-password');
    });
    it('rejects overlapping saves rather than losing updates', 0, async () => {
      const vault = new MemoryWifiVault();
      let release: () => void = () => {};
      vault.wait = new Promise<void>((resolve) => { release = resolve; });
      const store = storeFor(new MemorySettingsPersistence(), vault);
      await store.load();
      const first = store.save(configured(), 'private-password');
      let blocked = false;
      try { await store.save(defaultCarPlaySettings(), ''); } catch { blocked = true; }
      expect(blocked).assertTrue();
      release();
      await first;
      expect(store.snapshot().settings.wifi.ssid).assertEqual('Car-AP');
    });
    it('reports failure to remove an old encrypted secret after a committed save', 0, async () => {
      const vault = new MemoryWifiVault();
      const store = storeFor(new MemorySettingsPersistence(), vault);
      await store.load();
      await store.save(configured(), 'first-password');
      vault.failRemove = true;
      await store.save(configured(), 'second-password');
      expect(store.password()).assertEqual('second-password');
      expect(store.snapshot().error).assertContain('旧密码清理');
    });
  });

  describe('Configured information precedence', () => {
    it('prefers automatic identity over a configured manual address', 0, async () => {
      const provider = new ConfiguredBluetoothIdentityProvider(new FakeIdentity(), '10:20:30:DD:EE:FF', () => {});
      expect(await provider.getStableBluetoothAddress()).assertEqual('10:20:30:AA:BB:CC');
      expect(provider.identitySource()).assertEqual('system');
    });
    it('uses the manual identity only for an explicitly classified automatic failure', 0, async () => {
      const automatic = new FakeIdentity();
      automatic.error = new BluetoothIdentityError('permission-denied', 'local MAC permission missing');
      const logs: string[] = [];
      const provider = new ConfiguredBluetoothIdentityProvider(automatic, '10:20:30:DD:EE:FF',
        (line: string) => { logs.push(line); });
      expect(await provider.getStableBluetoothAddress()).assertEqual('10:20:30:DD:EE:FF');
      expect(provider.identitySource()).assertEqual('manual');
      expect(logs.length > 0).assertTrue();
      expect(logs.join('').includes('10:20:30:DD:EE:FF')).assertFalse();
    });
    it('does not hide unexpected errors or Bluetooth-off with a manual identity', 0, async () => {
      const automatic = new FakeIdentity();
      const provider = new ConfiguredBluetoothIdentityProvider(automatic, '10:20:30:DD:EE:FF', () => {});
      const failures: (Error | BluetoothIdentityError)[] = [new Error('unexpected'),
        new BluetoothIdentityError('bluetooth-off', 'off'), new BluetoothIdentityError('identity-changed', 'changed')];
      for (const error of failures) {
        automatic.error = error;
        let failed = false;
        try { await provider.getStableBluetoothAddress(); } catch { failed = true; }
        expect(failed).assertTrue();
      }
    });
    it('rejects a mid-session switch from manual to a different system identity', 0, async () => {
      const automatic = new FakeIdentity();
      automatic.error = new BluetoothIdentityError('permission-denied', 'missing');
      const provider = new ConfiguredBluetoothIdentityProvider(automatic, '10:20:30:DD:EE:FF', () => {});
      await provider.getStableBluetoothAddress();
      automatic.error = undefined;
      let changed = false;
      try { await provider.getStableBluetoothAddress(); } catch { changed = true; }
      expect(changed).assertTrue();
    });
    it('uses valid automatic Wi-Fi even if an unused manual fallback is incomplete', 0, () => {
      const automatic: AccessoryWifiConfiguration = { ssid: 'AutoAP', passphrase: 'auto-password', securityType: 2, channel: 1 };
      expect(resolveSessionWifi(automatic, configured(), '') === automatic).assertTrue();
    });
    it('fills a missing automatic password only for the same network/security type', 0, () => {
      const automatic: AccessoryWifiConfiguration = { ssid: 'Car-AP', passphrase: '', securityType: 2, channel: 36 };
      const manual: AccessoryWifiConfiguration = { ssid: 'Car-AP', passphrase: 'manual-password', securityType: 2, channel: 0 };
      expect(chooseWifiConfiguration(automatic, manual)?.passphrase).assertEqual('manual-password');
      manual.ssid = 'Other-AP';
      let failed = false;
      try { chooseWifiConfiguration(automatic, manual); } catch { failed = true; }
      expect(failed).assertTrue();
    });
    it('keeps manual AirPlay disabled before discovery timeout and prioritizes valid automatic endpoints', 0, () => {
      const manual = configuredAirPlay(configured());
      const mdns: AirPlayServiceEndpoint = {
        name: 'auto', host: '192.168.1.1', port: 7000, features: undefined, homeKitPairingSupported: true
      };
      expect(chooseAirPlayEndpoint(undefined, undefined, manual, false)).assertUndefined();
      expect(chooseAirPlayEndpoint(undefined, undefined, manual, true) === manual).assertTrue();
      expect(chooseAirPlayEndpoint(undefined, mdns, manual, true) === mdns).assertTrue();
      const invalid: AirPlayServiceEndpoint = { name: 'late', host: '192.168.1.2', port: 0,
        features: undefined, homeKitPairingSupported: undefined };
      expect(chooseAirPlayEndpoint(invalid, mdns, manual, false) === mdns).assertTrue();
    });
  });
}
