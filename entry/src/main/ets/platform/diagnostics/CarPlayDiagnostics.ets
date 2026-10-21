import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import {
  describeFailure, DiagnosticRedactor, expiredSessionLogs, isSessionLogName, orderedSessionLogs, sessionLogSequence
} from './DiagnosticFormat';

const DOMAIN = 0xCA11;
const TAG = 'CarPlayHarmony';

export interface DiagnosticFile {
  append(line: string): void;
  flush(): void;
  close(): void;
}

export interface DiagnosticStorage {
  ensureDirectory(path: string): void;
  names(path: string): string[];
  create(path: string): DiagnosticFile;
  remove(path: string): void;
}

class DiskDiagnosticFile implements DiagnosticFile {
  private readonly file: fs.File;

  constructor(path: string) {
    if (fs.accessSync(path)) {
      throw new Error('Session log already exists; refusing to overwrite it.');
    }
    this.file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
  }

  append(line: string): void {
    const bytes = new util.TextEncoder().encodeInto(line);
    let offset = 0;
    while (offset < bytes.length) {
      const written = fs.writeSync(this.file.fd, bytes.slice(offset).buffer as ArrayBuffer);
      if (written <= 0) {
        throw new Error('Log write made no progress.');
      }
      offset += written;
    }
  }

  flush(): void { fs.fsyncSync(this.file.fd); }
  close(): void { fs.closeSync(this.file); }
}

class DiskDiagnosticStorage implements DiagnosticStorage {
  ensureDirectory(path: string): void {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path);
    }
  }
  names(path: string): string[] { return fs.listFileSync(path); }
  create(path: string): DiagnosticFile { return new DiskDiagnosticFile(path); }
  remove(path: string): void { fs.unlinkSync(path); }
}

export class CarPlayDiagnostics {
  private readonly storage: DiagnosticStorage;
  private directory: string = '';
  private file: DiagnosticFile | undefined = undefined;
  private current: string = '';
  private sequence: number = 0;
  private startedAt: number = 0;
  private redactor: DiagnosticRedactor = new DiagnosticRedactor();
  private storageError: string = '';
  private readonly incompleteSessions: Set<string> = new Set<string>();
  private readonly listeners: Set<(line: string) => void> = new Set<(line: string) => void>();

  constructor(storage: DiagnosticStorage = new DiskDiagnosticStorage()) {
    this.storage = storage;
  }

  initialize(filesDir: string): void {
    if (this.directory.length > 0) {
      return;
    }
    this.directory = `${filesDir}/carplay-logs`;
    try {
      this.storage.ensureDirectory(this.directory);
      this.beginSession();
    } catch (error) {
      this.reportStorageFailure(error);
    }
  }

  subscribe(listener: (line: string) => void): void {
    this.listeners.add(listener);
  }

  identifier(value: string): string {
    return this.redactor.identifier(value);
  }

  beginSession(): void {
    try {
      this.flush();
      if (this.file !== undefined) {
        this.file.close();
        this.file = undefined;
      }
      this.redactor = new DiagnosticRedactor();
      this.storageError = '';
      this.startedAt = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
      const stamp = new Date().toISOString().replace(/[-:.]/g, '');
      const names = this.storage.names(this.directory);
      const previous = orderedSessionLogs(names);
      if (previous.length > 0) {
        this.sequence = Math.max(this.sequence, sessionLogSequence(previous[0]));
      }
      this.current = `session-${stamp}-${++this.sequence}.log`;
      const path = `${this.directory}/${this.current}`;
      this.file = this.storage.create(path);
      const expired = expiredSessionLogs(this.storage.names(this.directory), this.current);
      expired.forEach((name: string) => this.storage.remove(`${this.directory}/${name}`));
      this.log('diagnostics', 'session-start; redacted=true; retention=10; video/audio payloads excluded');
    } catch (error) {
      this.reportStorageFailure(error);
    }
  }

  log(module: string, message: string, error: boolean = false): void {
    const elapsed = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) - this.startedAt;
    const line = `${new Date().toISOString()} +${elapsed}ms ${error ? 'ERROR' : 'INFO'} ` +
      `[${this.current || 'uninitialized'}] [${module}] ${this.redactor.redact(message)}`;
    this.emit(line, error);
    if (this.file === undefined) {
      this.reportStorageFailure(new Error('No writable diagnostic session file.'));
      return;
    }
    try {
      this.file.append(`${line}\n`);
    } catch (failure) {
      this.reportStorageFailure(failure);
    }
  }

  flush(): void {
    if (this.file !== undefined) {
      try {
        this.file.flush();
      } catch (error) {
        this.reportStorageFailure(error);
        throw error instanceof Error ? error : new Error(describeFailure(error));
      }
    }
  }

  sessionNames(): string[] {
    if (this.directory.length === 0) {
      throw new Error('Diagnostic storage is not initialized.');
    }
    return orderedSessionLogs(this.storage.names(this.directory));
  }

  currentSession(): string {
    return this.current;
  }

  failure(): string {
    return this.storageError;
  }

  async exportSession(context: common.UIAbilityContext, name: string): Promise<boolean> {
    if (!isSessionLogName(name)) {
      throw new Error('Invalid diagnostic session name.');
    }
    this.flush();
    const source = fs.openSync(`${this.directory}/${name}`, fs.OpenMode.READ_ONLY);
    let sourceFailure: Error | undefined = undefined;
    try {
      // Pin the source and length before opening Picker; a new connection may rotate history meanwhile.
      const size = fs.statSync(source.fd).size;
      const incomplete = this.incompleteSessions.has(name) ? 'INCOMPLETE-' : '';
      const uris = await new picker.DocumentViewPicker(context).save({
        newFileNames: [`${incomplete}carplay-${name}`],
        fileSuffixChoices: ['CarPlay diagnostic log|.log']
      });
      if (uris.length === 0) {
        this.log('export', 'User cancelled saving diagnostic log.');
        return false;
      }
      const destination = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      let destinationFailure: Error | undefined = undefined;
      try {
        const buffer = new ArrayBuffer(64 * 1024);
        let remaining = size;
        while (remaining > 0) {
          const count = await fs.read(source.fd, buffer, { length: Math.min(remaining, buffer.byteLength) });
          if (count <= 0) {
            throw new Error('Diagnostic snapshot ended before its recorded length.');
          }
          let written = 0;
          while (written < count) {
            const amount = await fs.write(destination.fd, buffer.slice(written, count));
            if (amount <= 0) {
              throw new Error('Diagnostic export write made no progress.');
            }
            written += amount;
          }
          remaining -= count;
        }
        fs.fsyncSync(destination.fd);
      } catch (error) {
        destinationFailure = error instanceof Error ? error : new Error(describeFailure(error));
        throw destinationFailure;
      } finally {
        this.closeExportFile(destination, destinationFailure);
      }
      this.log('export', `Saved diagnostic snapshot bytes=${size}; incomplete=${incomplete.length > 0}.`);
      return true;
    } catch (error) {
      sourceFailure = error instanceof Error ? error : new Error(describeFailure(error));
      throw sourceFailure;
    } finally {
      this.closeExportFile(source, sourceFailure);
    }
  }

  private closeExportFile(file: fs.File, primaryFailure?: Error): void {
    try {
      fs.closeSync(file);
    } catch (error) {
      if (primaryFailure !== undefined) {
        this.log('export', `导出失败后的文件关闭也失败：${describeFailure(error)}`, true);
      } else {
        throw error instanceof Error ? error : new Error(describeFailure(error));
      }
    }
  }

  close(): void {
    try {
      this.flush();
    } catch (error) {
      this.reportStorageFailure(error);
    }
    if (this.file !== undefined) {
      const file = this.file;
      this.file = undefined;
      try {
        file.close();
      } catch (error) {
        this.reportStorageFailure(error);
      }
    }
  }

  private reportStorageFailure(error: Error): void {
    this.incompleteSessions.add(this.current);
    const detail = this.redactor.redact(describeFailure(error));
    if (this.storageError !== detail) {
      this.storageError = detail;
      this.emit(`ERROR [diagnostics] 日志持久化失败，导出可能不完整：${detail}`, true);
    }
  }

  private emit(line: string, error: boolean): void {
    if (error) {
      hilog.error(DOMAIN, TAG, '%{public}s', line);
    } else {
      hilog.info(DOMAIN, TAG, '%{public}s', line);
    }
    this.listeners.forEach((listener: (line: string) => void) => listener(line));
  }
}

export const carPlayDiagnostics = new CarPlayDiagnostics();
