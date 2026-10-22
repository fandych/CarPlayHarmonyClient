import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import asset from '@ohos.security.asset';
import { CarPlaySettings, CarPlayTheme, defaultCarPlaySettings } from '../../app/settings/CarPlaySettings';
import {
  CarPlaySettingsSnapshot, CarPlaySettingsStore, SettingsPersistence, WifiSecretVault
} from '../../app/settings/CarPlaySettingsStore';
import { carPlayDiagnostics } from '../diagnostics/CarPlayDiagnostics';
import { describeFailure } from '../diagnostics/DiagnosticFormat';

function report(stage: string, error: Error): void {
  carPlayDiagnostics.log('settings', `${stage}失败：${describeFailure(error)}`, true);
}

function closeFile(file: fs.File, primaryFailure?: Error): void {
  try {
    fs.closeSync(file);
  } catch (error) {
    if (primaryFailure !== undefined) {
      report('关闭配置文件', error);
    } else {
      throw error instanceof Error ? error : new Error(describeFailure(error));
    }
  }
}

function writeAll(fd: number, bytes: Uint8Array): void {
  let offset = 0;
  while (offset < bytes.length) {
    const count = fs.writeSync(fd, bytes.slice(offset).buffer as ArrayBuffer);
    if (count <= 0) {
      throw new Error('配置文件写入没有进展。');
    }
    offset += count;
  }
}

function readJsonFile(path: string, maximum: number): string {
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  let primaryFailure: Error | undefined = undefined;
  try {
    const size = fs.statSync(file.fd).size;
    if (size <= 0 || size > maximum) {
      throw new Error('配置文件为空或超过允许大小。');
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    while (offset < size) {
      const buffer = new ArrayBuffer(size - offset);
      const count = fs.readSync(file.fd, buffer);
      if (count <= 0) {
        throw new Error('配置文件读取不完整。');
      }
      bytes.set(new Uint8Array(buffer, 0, count), offset);
      offset += count;
    }
    return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes);
  } catch (error) {
    primaryFailure = error instanceof Error ? error : new Error(describeFailure(error));
    throw primaryFailure;
  } finally {
    closeFile(file, primaryFailure);
  }
}

export class FileSettingsPersistence implements SettingsPersistence {
  private readonly path: string;
  constructor(filesDir: string) { this.path = `${filesDir}/carplay-settings-v1.json`; }
  read(): string { return fs.accessSync(this.path) ? readJsonFile(this.path, 32768) : ''; }
  write(record: string): void {
    const temporary = `${this.path}.${util.generateRandomUUID()}.tmp`;
    const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    let failure: Error | undefined = undefined;
    try {
      writeAll(file.fd, new util.TextEncoder().encodeInto(record));
      fs.fsyncSync(file.fd);
    } catch (error) {
      failure = error instanceof Error ? error : new Error(describeFailure(error));
    }
    try {
      closeFile(file, failure);
      if (failure !== undefined) {
        throw failure;
      }
      fs.renameSync(temporary, this.path);
    } catch (error) {
      try {
        if (fs.accessSync(temporary)) {
          fs.unlinkSync(temporary);
        }
      } catch (cleanupError) {
        report('清理未提交的配置文件', cleanupError);
      }
      throw error instanceof Error ? error : new Error(describeFailure(error));
    }
  }
}

interface WifiSecretPayload {
  ssid: string;
  securityType: number;
  password: string;
}

export class AssetWifiSecretVault implements WifiSecretVault {
  async add(ssid: string, securityType: number, password: string): Promise<string> {
    const alias = `CarPlayHarmony.Wifi.v1.${util.generateRandomUUID()}`;
    const payload: WifiSecretPayload = { ssid, securityType, password };
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(JSON.stringify(payload)));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    await asset.add(attributes);
    return alias;
  }
  async read(alias: string, ssid: string, securityType: number): Promise<string> {
    const query = this.query(alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const records = await asset.query(query);
    if (records.length !== 1) {
      throw new Error('Wi-Fi 安全密码记录缺失或不唯一。');
    }
    const secret = records[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array)) {
      throw new Error('Wi-Fi 安全密码记录类型不合法。');
    }
    let payload: WifiSecretPayload;
    try {
      payload = JSON.parse(new util.TextDecoder('utf-8', { fatal: true }).decodeToString(secret));
    } catch {
      throw new Error('系统安全密码记录格式损坏，拒绝使用。');
    }
    if (payload === null || typeof payload !== 'object' || payload.ssid !== ssid ||
      payload.securityType !== securityType || typeof payload.password !== 'string') {
      throw new Error('Wi-Fi 安全密码记录与当前网络配置不一致。');
    }
    return payload.password;
  }
  async remove(alias: string): Promise<void> { await asset.remove(this.query(alias)); }
  private query(alias: string): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    return query;
  }
}

class HarmonySettings {
  private context: common.UIAbilityContext | undefined = undefined;
  private store: CarPlaySettingsStore | undefined = undefined;
  private initialization: Promise<void> | undefined = undefined;
  private initialized: boolean = false;
  private platformError: string = '';
  private appliedTheme: string = '';
  private readonly listeners: Set<(snapshot: CarPlaySettingsSnapshot) => void> =
    new Set<(snapshot: CarPlaySettingsSnapshot) => void>();

  initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.appliedTheme = '';
    if (this.initialized) {
      this.notify();
      return Promise.resolve();
    }
    if (this.initialization !== undefined) {
      return this.initialization;
    }
    if (this.store === undefined) {
      this.store = new CarPlaySettingsStore(new FileSettingsPersistence(context.filesDir), new AssetWifiSecretVault(), report);
      this.store.subscribe(() => this.notify());
    }
    const store = this.store;
    const migrateLegacy = !fs.accessSync(`${context.filesDir}/carplay-settings-v1.json`);
    const task = store.load().then(async () => {
      const settings = store.snapshot().settings;
      if (migrateLegacy && settings.targetDeviceId.length === 0) {
        const legacy = preferences.getPreferencesSync(context, { name: 'carplay-settings' });
        const selected = legacy.getSync('targetDeviceId', '');
        if (typeof selected !== 'string') {
          throw new Error('旧版接收端配置类型不合法，请通过配置导入恢复。');
        }
        if (typeof selected === 'string' && selected.length > 0) {
          settings.targetDeviceId = selected;
          await store.save(settings, '');
          carPlayDiagnostics.log('settings', '已迁移旧版接收端选择；未迁移或导出密码。');
        }
      }
      this.initialized = true;
      this.notify();
    }).catch((error: Error) => {
      this.platformError = `初始化配置失败：${describeFailure(error)}`;
      report('初始化配置', error);
      this.initialization = undefined;
      this.notify();
      throw error;
    });
    this.initialization = task;
    return task;
  }

  snapshot(): CarPlaySettingsSnapshot {
    const snapshot = this.store?.snapshot() ?? {
      ready: false, busy: false, error: '', settings: defaultCarPlaySettings(), hasWifiPassword: false,
      trustedMfiFingerprints: []
    };
    snapshot.ready = snapshot.ready && this.initialized;
    snapshot.error = snapshot.error || this.platformError;
    return snapshot;
  }

  subscribe(listener: (snapshot: CarPlaySettingsSnapshot) => void): () => void {
    this.listeners.add(listener);
    listener(this.snapshot());
    return () => { this.listeners.delete(listener); };
  }

  async save(settings: CarPlaySettings, password: string): Promise<void> {
    this.platformError = '';
    carPlayDiagnostics.identifier(settings.deviceName);
    if (settings.wifi.ssid.length > 0) {
      carPlayDiagnostics.identifier(settings.wifi.ssid);
    }
    await this.requireStore().save(settings, password);
    carPlayDiagnostics.log('settings', '配置已持久化；Wi-Fi 密码仅保存在系统 Asset 安全存储。');
  }
  async setEnabled(enabled: boolean): Promise<void> {
    const settings = this.snapshot().settings;
    settings.enabled = enabled;
    await this.save(settings, this.password());
  }
  async setTheme(theme: CarPlayTheme): Promise<void> {
    const settings = this.snapshot().settings;
    settings.theme = theme;
    await this.save(settings, this.password());
  }
  trustedMfiFingerprints(): string[] {
    return this.requireStore().snapshot().trustedMfiFingerprints;
  }
  async addTrustedMfiFingerprint(fingerprint: string): Promise<void> {
    await this.requireStore().addTrustedMfiFingerprint(fingerprint);
    carPlayDiagnostics.log('settings', '已保存车机 MFi 证书 SHA-256 信任指纹；该信任仅保存在本机，不进入配置导出。');
  }
  async removeTrustedMfiFingerprint(fingerprint: string): Promise<void> {
    await this.requireStore().removeTrustedMfiFingerprint(fingerprint);
    carPlayDiagnostics.log('settings', '已撤销一条本机 MFi 证书信任指纹。');
  }
  password(): string { return this.requireStore().password(); }
  async retryInitialization(): Promise<void> {
    this.platformError = '';
    await this.initialize(this.requireContext());
  }

  async exportConfiguration(): Promise<boolean> {
    const json = this.requireStore().exportJson();
    const uris = await new picker.DocumentViewPicker(this.requireContext()).save({
      newFileNames: [`carplay-settings-v1-${Date.now()}.json`], fileSuffixChoices: ['CarPlay settings|.json']
    });
    if (uris.length === 0) {
      return false;
    }
    const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    let failure: Error | undefined = undefined;
    try {
      writeAll(file.fd, new util.TextEncoder().encodeInto(json));
      fs.fsyncSync(file.fd);
    } catch (error) {
      failure = error instanceof Error ? error : new Error(describeFailure(error));
      throw failure;
    } finally {
      closeFile(file, failure);
    }
    carPlayDiagnostics.log('settings', '已导出版本化配置 JSON；不包含密码、密码引用或配对材料。');
    return true;
  }

  async importConfiguration(): Promise<boolean> {
    const uris = await new picker.DocumentViewPicker(this.requireContext()).select({ maxSelectNumber: 1 });
    if (uris.length === 0) {
      return false;
    }
    const json = readJsonFile(uris[0], 16384);
    if (this.store === undefined) {
      throw new Error('配置存储尚未初始化。');
    }
    const recovery = !this.initialized;
    await this.store.importJson(json);
    this.initialized = true;
    this.platformError = '';
    this.notify();
    if (recovery) {
      carPlayDiagnostics.log('settings', '已通过有效配置恢复损坏/不可读的设置；未沿用旧密码引用，旧安全记录未批量删除。');
    }
    carPlayDiagnostics.log('settings', '配置 JSON 已校验并导入；CarPlay 开关已关闭，不自动连接。');
    return true;
  }

  private requireStore(): CarPlaySettingsStore {
    if (this.store === undefined || !this.initialized) {
      throw new Error('配置尚未就绪，不能执行该操作。');
    }
    return this.store;
  }
  private requireContext(): common.UIAbilityContext {
    if (this.context === undefined) {
      throw new Error('应用上下文尚未准备就绪。');
    }
    return this.context;
  }
  private notify(): void {
    const snapshot = this.snapshot();
    if (snapshot.ready && this.context !== undefined && this.appliedTheme !== snapshot.settings.theme) {
      try {
        const mode = snapshot.settings.theme === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
          snapshot.settings.theme === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
            ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
        this.context.getApplicationContext().setColorMode(mode);
        this.appliedTheme = snapshot.settings.theme;
      } catch (error) {
        this.platformError = `主题应用失败：${describeFailure(error)}`;
        snapshot.error = this.platformError;
        report('应用主题', error);
      }
    }
    this.listeners.forEach((listener: (snapshot: CarPlaySettingsSnapshot) => void) => listener(snapshot));
  }
}

export const carPlaySettings = new HarmonySettings();
