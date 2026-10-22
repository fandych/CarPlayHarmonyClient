import { describe, expect, it } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { CarPlaySettingsStore } from '../../../main/ets/app/settings/CarPlaySettingsStore';
import { defaultCarPlaySettings } from '../../../main/ets/app/settings/CarPlaySettings';
import { AssetWifiSecretVault, FileSettingsPersistence } from '../../../main/ets/platform/settings/HarmonySettings';

export default function settingsPersistenceDeviceTest(): void {
  describe('SettingsDevicePersistence', () => {
    it('persists an Asset-protected password and atomically reloads configuration', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const directory = `${context.cacheDir}/carplay-settings-test-${util.generateRandomUUID()}`;
      fs.mkdirSync(directory);
      const path = `${directory}/carplay-settings-v1.json`;
      const disk = new FileSettingsPersistence(directory);
      const vault = new AssetWifiSecretVault();
      const store = new CarPlaySettingsStore(disk, vault, (stage: string, error: Error) => {
        console.error(`Device settings test ${stage}: ${error.name}`);
      });
      let primaryFailure: Error | undefined = undefined;
      try {
        await store.load();
        const settings = defaultCarPlaySettings();
        settings.enabled = true;
        settings.theme = 'dark';
        settings.deviceName = 'Device persistence test';
        settings.wifi = { ssid: 'CarPlay-Settings-Test', securityType: 2, channel: 0 };
        await store.save(settings, 'test-only-password-123');
        expect(disk.read().includes('test-only-password-123')).assertFalse();
        expect(store.exportJson().includes('secretAlias')).assertFalse();
        const reopened = new CarPlaySettingsStore(disk, vault, () => {});
        await reopened.load();
        expect(reopened.snapshot().settings.enabled).assertTrue();
        expect(reopened.snapshot().settings.theme).assertEqual('dark');
        expect(reopened.password()).assertEqual('test-only-password-123');
        await reopened.save(defaultCarPlaySettings(), '');
        const cleared = new CarPlaySettingsStore(disk, vault, () => {});
        await cleared.load();
        expect(cleared.password()).assertEqual('');
        expect(cleared.snapshot().settings.enabled).assertFalse();
      } catch (error) {
        primaryFailure = error instanceof Error ? error : new Error('Native settings persistence failed.');
        throw primaryFailure;
      } finally {
        try {
          const cleanup = new CarPlaySettingsStore(disk, vault, () => {});
          await cleanup.load();
          await cleanup.save(defaultCarPlaySettings(), '');
          if (fs.accessSync(path)) { fs.unlinkSync(path); }
          fs.rmdirSync(directory);
        } catch (error) {
          console.error(`Device settings test cleanup: ${error.name}`);
          if (primaryFailure === undefined) {
            throw error instanceof Error ? error : new Error('Native test cleanup failed.');
          }
        }
      }
    });

    it('rejects invalid imports without changing the existing file', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const directory = `${context.cacheDir}/carplay-settings-test-${util.generateRandomUUID()}`;
      fs.mkdirSync(directory);
      const path = `${directory}/carplay-settings-v1.json`;
      const disk = new FileSettingsPersistence(directory);
      const store = new CarPlaySettingsStore(disk, new AssetWifiSecretVault(), () => {});
      try {
        await store.load();
        const settings = defaultCarPlaySettings();
        settings.theme = 'light';
        await store.save(settings, '');
        const previous = disk.read();
        let rejected = false;
        try { await store.importJson('{"version":999}'); } catch { rejected = true; }
        expect(rejected).assertTrue();
        expect(disk.read()).assertEqual(previous);
        const reopened = new CarPlaySettingsStore(disk, new AssetWifiSecretVault(), () => {});
        await reopened.load();
        expect(reopened.snapshot().settings.theme).assertEqual('light');
      } finally {
        if (fs.accessSync(path)) { fs.unlinkSync(path); }
        fs.rmdirSync(directory);
      }
    });
  });
}
