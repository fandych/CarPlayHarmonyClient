import { BusinessError } from '@kit.BasicServicesKit';

export function describeFailure(error: Error): string {
  const businessError = error as BusinessError;
  return `${error.name || 'Error'} code=${businessError.code ?? 'none'}: ${error.message || String(error)}`;
}

export function isSessionLogName(name: string): boolean {
  return /^session-\d{8}T\d{9}Z-\d+\.log$/.test(name);
}

export function expiredSessionLogs(names: string[], current: string): string[] {
  return orderedSessionLogs(names).filter((name: string) => name !== current).slice(9);
}

export function sessionLogSequence(name: string): number {
  return Number.parseInt(name.slice(name.lastIndexOf('-') + 1), 10);
}

export function orderedSessionLogs(names: string[]): string[] {
  return names.filter((name: string) => isSessionLogName(name))
    .sort((left: string, right: string) => sessionLogSequence(right) - sessionLogSequence(left));
}

export class DiagnosticRedactor {
  private readonly identifiers: Map<string, string> = new Map<string, string>();

  identifier(value: string): string {
    const existing = this.identifiers.get(value);
    if (existing !== undefined) {
      return existing;
    }
    const alias = `peer-${this.identifiers.size + 1}`;
    if (value.length > 0) {
      this.identifiers.set(value, alias);
    }
    return alias;
  }

  redact(message: string): string {
    let result = message;
    this.identifiers.forEach((alias: string, value: string) => {
      result = result.split(value).join(alias);
    });
    result = result.replace(
      /\b(password|passphrase|preSharedKey|psk|privateKey|sharedSecret|proof|token)["']?\s*[:=]\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;，；]+)/gi,
      '$1=[redacted]'
    );
    result = result.replace(/\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b/gi, '[bt-address]');
    result = result.replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, '[ip-address]');
    result = result.replace(/(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]+(?:%[\w.-]+)?/gi, '[ip-address]');
    return result.replace(/[\r\n\0]/g, ' ');
  }
}
