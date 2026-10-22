import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';

export interface CarDeckAppSettings {
  disclaimerAccepted: boolean;
  disclaimerVersion: string;
  deviceName: string;
  bluetoothAddress: string;
  deviceUuid: string;
  lastSsid: string;
  keepScreenOn: boolean;
  allowMfiIntermediateDownload: boolean;
  trustedMfiFingerprints: string[];
  favoriteBundles: string[];
  backgroundPhotoUri: string;
}

export class AppSettingsStore {
  private preferences?: preferences.Preferences;

  async load(context: common.UIAbilityContext): Promise<CarDeckAppSettings> {
    try {
      const store = await this.getStore(context);
      const disclaimer = await store.get('disclaimerAccepted', false);
      const disclaimerVersion = await store.get('disclaimerVersion', '');
      const deviceName = await store.get('deviceName', 'Harmony CarPlay');
      const bluetoothAddress = await store.get('bluetoothAddress', '02:00:00:00:00:00');
      const deviceUuid = await store.get('deviceUuid', '');
      const lastSsid = await store.get('lastSsid', '');
      const keepScreenOn = await store.get('keepScreenOn', true);
      const allowMfiIntermediateDownload = await store.get('allowMfiIntermediateDownload', false);
      const trustedMfiFingerprints = await store.get('trustedMfiFingerprints', '');
      const favorites = await store.get('favoriteBundles', '');
      const backgroundPhotoUri = await store.get('backgroundPhotoUri', '');

      const settings: CarDeckAppSettings = {
        disclaimerAccepted: typeof disclaimer === 'boolean' ? disclaimer : false,
        disclaimerVersion: typeof disclaimerVersion === 'string' ? disclaimerVersion : '',
        deviceName: typeof deviceName === 'string' ? deviceName : 'Harmony CarPlay',
        bluetoothAddress: typeof bluetoothAddress === 'string' ? bluetoothAddress : '02:00:00:00:00:00',
        deviceUuid: typeof deviceUuid === 'string' ? deviceUuid : '',
        lastSsid: typeof lastSsid === 'string' ? lastSsid : '',
        keepScreenOn: typeof keepScreenOn === 'boolean' ? keepScreenOn : true,
        allowMfiIntermediateDownload: typeof allowMfiIntermediateDownload === 'boolean'
          ? allowMfiIntermediateDownload : false,
        trustedMfiFingerprints: this.decodeMfiFingerprints(
          typeof trustedMfiFingerprints === 'string' ? trustedMfiFingerprints : ''
        ),
        favoriteBundles: this.decodeBundleNames(typeof favorites === 'string' ? favorites : ''),
        backgroundPhotoUri: typeof backgroundPhotoUri === 'string' ? backgroundPhotoUri : ''
      };
      return settings;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`读取本机设置失败：${message}`);
    }
  }

  async save(context: common.UIAbilityContext, settings: CarDeckAppSettings): Promise<void> {
    try {
      const store = await this.getStore(context);
      await store.put('disclaimerAccepted', settings.disclaimerAccepted);
      await store.put('disclaimerVersion', settings.disclaimerVersion);
      await store.put('deviceName', settings.deviceName);
      await store.put('bluetoothAddress', settings.bluetoothAddress);
      await store.put('deviceUuid', settings.deviceUuid);
      await store.put('lastSsid', settings.lastSsid);
      await store.put('keepScreenOn', settings.keepScreenOn);
      await store.put('allowMfiIntermediateDownload', settings.allowMfiIntermediateDownload);
      await store.put('trustedMfiFingerprints', settings.trustedMfiFingerprints.join('\n'));
      await store.put('favoriteBundles', settings.favoriteBundles.join('\n'));
      await store.put('backgroundPhotoUri', settings.backgroundPhotoUri);
      await store.flush();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`保存本机设置失败：${message}`);
    }
  }

  private async getStore(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (!this.preferences) {
      try {
        this.preferences = await preferences.getPreferences(context, 'cardeck_harmony_settings');
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        throw new Error(`打开设置存储失败：${message}`);
      }
    }
    return this.preferences;
  }

  private decodeBundleNames(serialized: string): string[] {
    if (!serialized) {
      return [];
    }
    const unique: Set<string> = new Set<string>();
    for (const item of serialized.split('\n')) {
      const bundleName = item.trim();
      if (bundleName && bundleName.length <= 255 && !bundleName.includes('|')) {
        unique.add(bundleName);
      }
    }
    return Array.from(unique);
  }

  private decodeMfiFingerprints(serialized: string): string[] {
    const unique: Set<string> = new Set<string>();
    for (const item of serialized.split('\n')) {
      const fingerprint = item.trim().toLowerCase();
      if (/^[0-9a-f]{64}$/.test(fingerprint)) {
        unique.add(fingerprint);
      }
    }
    return Array.from(unique);
  }
}
