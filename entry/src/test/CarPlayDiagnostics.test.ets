import { describe, expect, it } from '@ohos/hypium';
import {
  describeFailure, DiagnosticRedactor, expiredSessionLogs, isSessionLogName, orderedSessionLogs
} from '../main/ets/platform/diagnostics/DiagnosticFormat';
import {
  CarPlayDiagnostics, DiagnosticFile, DiagnosticStorage
} from '../main/ets/platform/diagnostics/CarPlayDiagnostics';
import { BusinessError } from '@kit.BasicServicesKit';

class MemoryDiagnosticFile implements DiagnosticFile {
  lines: string[] = [];
  closed: boolean = false;
  flushCount: number = 0;
  failWrites: boolean = false;
  failFlush: boolean = false;

  append(line: string): void {
    if (this.closed || this.failWrites) {
      throw new Error('Simulated storage full.');
    }
    this.lines.push(line);
  }
  flush(): void {
    if (this.failFlush) {
      throw new Error('Simulated fsync failure.');
    }
    this.flushCount++;
  }
  close(): void { this.closed = true; }
}

class MemoryDiagnosticStorage implements DiagnosticStorage {
  files: Map<string, MemoryDiagnosticFile> = new Map<string, MemoryDiagnosticFile>();
  ensureDirectory(path: string): void {}
  names(path: string): string[] {
    return Array.from(this.files.keys()).map((key: string) => key.slice(key.lastIndexOf('/') + 1));
  }
  create(path: string): DiagnosticFile {
    if (this.files.has(path)) {
      throw new Error('Refusing overwrite.');
    }
    const file = new MemoryDiagnosticFile();
    this.files.set(path, file);
    return file;
  }
  remove(path: string): void { this.files.delete(path); }
  current(name: string): MemoryDiagnosticFile {
    const file = this.files.get(`/test/carplay-logs/${name}`);
    if (file === undefined) {
      throw new Error('Missing test log.');
    }
    return file;
  }
}

export default function carPlayDiagnosticsTest(): void {
  describe('CarPlay diagnostics', () => {
    it('retains the first and last event beyond the 250-line UI limit', 0, () => {
      const storage = new MemoryDiagnosticStorage();
      const journal = new CarPlayDiagnostics(storage);
      journal.initialize('/test');
      for (let index = 0; index < 501; index++) {
        journal.log('test', `event-${index}`);
      }
      journal.flush();
      const file = storage.current(journal.currentSession());
      expect(file.lines.length).assertEqual(502);
      expect(file.lines[1]).assertContain('event-0');
      expect(file.lines[501]).assertContain('event-500');
      expect(file.flushCount > 0).assertTrue();
      journal.close();
      expect(file.closed).assertTrue();
    });

    it('keeps ten whole sessions and recovers ordering across a restart', 0, () => {
      const storage = new MemoryDiagnosticStorage();
      const first = new CarPlayDiagnostics(storage);
      first.initialize('/test');
      const oldest = first.currentSession();
      first.log('test', 'oldest session');
      first.close();
      const second = new CarPlayDiagnostics(storage);
      second.initialize('/test');
      for (let index = 0; index < 11; index++) {
        second.beginSession();
        second.log('test', `attempt-${index}`);
      }
      expect(second.sessionNames().length).assertEqual(10);
      expect(second.sessionNames().includes(oldest)).assertFalse();
      expect(second.sessionNames()[0]).assertEqual(second.currentSession());
      expect(storage.current(second.currentSession()).lines[1]).assertContain('attempt-10');
      second.close();
    });

    it('reports write failures to UI listeners instead of claiming complete storage', 0, () => {
      const storage = new MemoryDiagnosticStorage();
      const journal = new CarPlayDiagnostics(storage);
      const observed: string[] = [];
      journal.subscribe((line: string) => { observed.push(line); });
      journal.initialize('/test');
      storage.current(journal.currentSession()).failWrites = true;
      journal.log('test', 'not persisted');
      expect(journal.failure()).assertContain('Simulated storage full');
      expect(observed.some((line: string) => line.includes('日志持久化失败'))).assertTrue();
      journal.close();
    });

    it('redacts identifiers, credentials and addresses without losing error codes', 0, () => {
      const redactor = new DiagnosticRedactor();
      const alias = redactor.identifier('Private receiver name');
      const text = redactor.redact('Private receiver name 12:34:56:78:90:AB 192.168.4.1 fe80::abcd%wlan0 ' +
        'password="hidden wifi password" sharedSecret=private proof=secret code=2900003\r\nforged');
      expect(text.includes('Private receiver name')).assertFalse();
      expect(text.includes('hidden wifi password')).assertFalse();
      expect(text.includes('secret')).assertFalse();
      expect(text.includes('192.168.4.1')).assertFalse();
      expect(text.includes('fe80::abcd')).assertFalse();
      expect(text.includes('12:34:56:78:90:AB')).assertFalse();
      expect(text.includes('\n')).assertFalse();
      expect(text).assertContain(alias);
      expect(text).assertContain('code=2900003');
    });

    it('surfaces fsync failures and still closes the log file', 0, () => {
      const storage = new MemoryDiagnosticStorage();
      const journal = new CarPlayDiagnostics(storage);
      journal.initialize('/test');
      const file = storage.current(journal.currentSession());
      file.failFlush = true;
      let message = '';
      try {
        journal.flush();
      } catch (error) {
        message = error.message;
      }
      expect(message).assertContain('Simulated fsync failure');
      expect(journal.failure()).assertContain('Simulated fsync failure');
      journal.close();
      expect(file.closed).assertTrue();
    });

    it('retains the current session even if the wall clock moves backwards', 0, () => {
      const names: string[] = [];
      for (let index = 1; index <= 11; index++) {
        names.push(`session-20261021T100000000Z-${index}.log`);
      }
      const current = 'session-20251021T100000000Z-12.log';
      names.push(current, 'settings.json', '../session-20261021T100000000Z-1.log');
      const expired = expiredSessionLogs(names, current);
      expect(expired.length).assertEqual(2);
      expect(expired.includes(current)).assertFalse();
      expect(expired.includes('settings.json')).assertFalse();
      expect(orderedSessionLogs(names)[0]).assertEqual(current);
      expect(isSessionLogName('../session-20261021T100000000Z-1.log')).assertFalse();
    });

    it('redacts JSON credentials with escaped quotes', 0, () => {
      const redactor = new DiagnosticRedactor();
      const text = redactor.redact('{"preSharedKey":"hidden\\"password with spaces","proof":"private-proof"}');
      expect(text.includes('hidden')).assertFalse();
      expect(text.includes('password with spaces')).assertFalse();
      expect(text.includes('private-proof')).assertFalse();
      expect(text).assertContain('[redacted]');
    });

    it('preserves a native BusinessError code and message', 0, () => {
      const error: BusinessError = { name: 'BusinessError', code: 2900003, message: 'Bluetooth disabled' };
      expect(describeFailure(error)).assertContain('2900003');
      expect(describeFailure(error)).assertContain('Bluetooth disabled');
    });
  });
}
