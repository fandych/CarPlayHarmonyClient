import {
  CarPlaySettings, defaultCarPlaySettings, parseCarPlaySettings, requireSettingsKeys,
  serializeCarPlaySettings, validateCarPlaySettings, validateWifiPassword
} from './CarPlaySettings';

export interface SettingsPersistence {
  read(): string;
  write(record: string): void;
}

export interface WifiSecretVault {
  add(ssid: string, securityType: number, password: string): Promise<string>;
  read(alias: string, ssid: string, securityType: number): Promise<string>;
  remove(alias: string): Promise<void>;
}

interface SettingsRecord {
  settings: CarPlaySettings;
  secretAlias: string;
}

export interface CarPlaySettingsSnapshot {
  ready: boolean;
  busy: boolean;
  error: string;
  settings: CarPlaySettings;
  hasWifiPassword: boolean;
}

export class CarPlaySettingsStore {
  private configuration: CarPlaySettings = defaultCarPlaySettings();
  private secret: string = '';
  private alias: string = '';
  private ready: boolean = false;
  private busy: boolean = false;
  private error: string = '';
  private readonly persistence: SettingsPersistence;
  private readonly vault: WifiSecretVault;
  private readonly report: (stage: string, error: Error) => void;
  private readonly listeners: Set<(snapshot: CarPlaySettingsSnapshot) => void> =
    new Set<(snapshot: CarPlaySettingsSnapshot) => void>();

  constructor(persistence: SettingsPersistence, vault: WifiSecretVault, report: (stage: string, error: Error) => void) {
    this.persistence = persistence;
    this.vault = vault;
    this.report = report;
  }

  subscribe(listener: (snapshot: CarPlaySettingsSnapshot) => void): () => void {
    this.listeners.add(listener);
    listener(this.snapshot());
    return () => { this.listeners.delete(listener); };
  }

  snapshot(): CarPlaySettingsSnapshot {
    return { ready: this.ready, busy: this.busy, error: this.error,
      settings: validateCarPlaySettings(this.configuration), hasWifiPassword: this.secret.length > 0 };
  }

  password(): string {
    if (!this.ready) {
      throw new Error('配置尚未成功载入，不能读取 Wi-Fi 密码。');
    }
    return this.secret;
  }

  async load(): Promise<void> {
    this.begin();
    this.ready = false;
    try {
      const raw = this.persistence.read();
      let next = defaultCarPlaySettings();
      let alias = '';
      let password = '';
      if (raw.length > 0) {
        if (raw.length > 32768) {
          throw new Error('本地配置记录过大。');
        }
        const record: SettingsRecord = JSON.parse(raw);
        requireSettingsKeys(record, ['settings', 'secretAlias'], '本地配置记录');
        next = validateCarPlaySettings(record.settings);
        if (typeof record.secretAlias !== 'string' ||
          (record.secretAlias.length > 0 && !/^CarPlayHarmony\.Wifi\.v1\.[0-9a-f-]{36}$/.test(record.secretAlias))) {
          throw new Error('本地密码引用不合法。');
        }
        alias = record.secretAlias;
        if (alias.length > 0) {
          password = await this.vault.read(alias, next.wifi.ssid, next.wifi.securityType);
          validateWifiPassword(next, password);
        }
      }
      this.configuration = next;
      this.alias = alias;
      this.secret = password;
      this.ready = true;
    } catch (error) {
      this.fail('载入配置', error);
      throw error instanceof Error ? error : new Error('配置载入失败。');
    } finally {
      this.end();
    }
  }

  async save(settings: CarPlaySettings, password: string): Promise<void> {
    if (!this.ready) {
      throw new Error('配置未载入，拒绝覆盖现有文件；请先处理载入错误。');
    }
    const next = validateCarPlaySettings(settings);
    validateWifiPassword(next, password);
    this.begin();
    let newAlias = '';
    let committed = false;
    const oldAlias = this.alias;
    try {
      const unchanged = next.wifi.ssid === this.configuration.wifi.ssid &&
        next.wifi.securityType === this.configuration.wifi.securityType && password === this.secret;
      newAlias = unchanged ? oldAlias : password.length === 0 ? '' :
        await this.vault.add(next.wifi.ssid, next.wifi.securityType, password);
      const record: SettingsRecord = { settings: next, secretAlias: newAlias };
      this.persistence.write(JSON.stringify(record));
      this.configuration = next;
      this.secret = password;
      this.alias = newAlias;
      committed = true;
      if (oldAlias.length > 0 && oldAlias !== newAlias) {
        try {
          await this.vault.remove(oldAlias);
        } catch (error) {
          this.fail('配置已保存，但旧密码清理', error);
        }
      }
    } catch (error) {
      if (!committed && newAlias.length > 0 && newAlias !== oldAlias) {
        try {
          await this.vault.remove(newAlias);
        } catch (cleanupError) {
          this.report('回滚新密码记录', cleanupError);
        }
      }
      this.fail('保存配置', error);
      throw error instanceof Error ? error : new Error('配置保存失败。');
    } finally {
      this.end();
    }
  }

  exportJson(): string {
    if (!this.ready) {
      throw new Error('配置尚未载入，不能导出。');
    }
    return serializeCarPlaySettings(this.configuration);
  }

  async importJson(json: string): Promise<void> {
    const next = parseCarPlaySettings(json);
    next.enabled = false;
    if (!this.ready) {
      this.begin();
      try {
        const record: SettingsRecord = { settings: next, secretAlias: '' };
        this.persistence.write(JSON.stringify(record));
        this.configuration = next;
        this.secret = '';
        this.alias = '';
        this.ready = true;
      } catch (error) {
        this.fail('导入恢复配置', error);
        throw error instanceof Error ? error : new Error('配置恢复失败。');
      } finally {
        this.end();
      }
      return;
    }
    const password = next.wifi.ssid === this.configuration.wifi.ssid &&
      next.wifi.securityType === this.configuration.wifi.securityType ? this.secret : '';
    await this.save(next, password);
  }

  private begin(): void {
    if (this.busy) {
      throw new Error('另一个配置操作尚未结束。');
    }
    this.busy = true;
    this.error = '';
    this.notify();
  }
  private end(): void { this.busy = false; this.notify(); }
  private fail(stage: string, error: Error): void {
    this.error = `${stage}失败：${error.message}`;
    this.report(stage, error);
  }
  private notify(): void {
    const snapshot = this.snapshot();
    this.listeners.forEach((listener: (snapshot: CarPlaySettingsSnapshot) => void) => listener(snapshot));
  }
}
