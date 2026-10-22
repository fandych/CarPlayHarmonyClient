export interface RtspEventMessage {
  kind: 'request' | 'response';
  method: string;
  target: string;
  headers: Map<string, string>;
  body: Uint8Array;
}

const MAX_HEADER_BYTES = 64 * 1024;
const MAX_BODY_BYTES = 2 * 1024 * 1024;
const MAX_BUFFER_BYTES = MAX_HEADER_BYTES + MAX_BODY_BYTES;

export class RtspEventMessageParser {
  private buffer: Uint8Array = new Uint8Array(0);

  offer(chunk: Uint8Array): RtspEventMessage[] {
    if (this.buffer.length + chunk.length > MAX_BUFFER_BYTES) {
      throw new Error('AirPlay event channel receive buffer exceeds the supported limit.');
    }
    this.buffer = RtspEventMessageParser.concat(this.buffer, chunk);
    const messages: RtspEventMessage[] = [];
    while (true) {
      const headerEnd = RtspEventMessageParser.findHeaderEnd(this.buffer);
      if (headerEnd < 0) {
        if (this.buffer.length > MAX_HEADER_BYTES) {
          throw new Error('AirPlay event channel headers exceed the limit.');
        }
        return messages;
      }
      if (headerEnd > MAX_HEADER_BYTES) {
        throw new Error('AirPlay event channel headers exceed the limit.');
      }

      const lines = RtspEventMessageParser.decodeAscii(this.buffer.slice(0, headerEnd)).split('\r\n');
      const firstLine = lines.shift() ?? '';
      const responseMatch = /^RTSP\/1\.[0-9] ([0-9]{3})(?: .*)?$/.exec(firstLine);
      const requestMatch = /^([A-Z]+) (\S+) RTSP\/1\.[0-9]$/.exec(firstLine);
      if (responseMatch === null && requestMatch === null) {
        throw new Error('Malformed AirPlay event channel start line.');
      }

      const headers = new Map<string, string>();
      for (const line of lines) {
        const separator = line.indexOf(':');
        if (separator <= 0) {
          throw new Error('Malformed AirPlay event channel header.');
        }
        const name = line.slice(0, separator).trim().toLowerCase();
        const value = line.slice(separator + 1).trim();
        headers.set(name, headers.has(name) ? `${headers.get(name)}, ${value}` : value);
      }
      const contentLengthText = headers.get('content-length') ?? '0';
      if (!/^\d+$/.test(contentLengthText)) {
        throw new Error('Invalid AirPlay event channel Content-Length.');
      }
      const contentLength = Number.parseInt(contentLengthText, 10);
      if (!Number.isInteger(contentLength) || contentLength < 0 || contentLength > MAX_BODY_BYTES) {
        throw new Error('AirPlay event channel body exceeds the limit.');
      }
      const bodyStart = headerEnd + 4;
      const messageEnd = bodyStart + contentLength;
      if (this.buffer.length < messageEnd) {
        return messages;
      }

      messages.push({
        kind: responseMatch === null ? 'request' : 'response',
        method: requestMatch?.[1] ?? '',
        target: requestMatch?.[2] ?? '',
        headers,
        body: this.buffer.slice(bodyStart, messageEnd)
      });
      this.buffer = this.buffer.slice(messageEnd);
      if (this.buffer.length === 0) {
        return messages;
      }
    }
  }

  private static findHeaderEnd(bytes: Uint8Array): number {
    for (let index = 0; index + 3 < bytes.length; index++) {
      if (bytes[index] === 13 && bytes[index + 1] === 10 &&
        bytes[index + 2] === 13 && bytes[index + 3] === 10) {
        return index;
      }
    }
    return -1;
  }

  private static decodeAscii(bytes: Uint8Array): string {
    const chunks: string[] = [];
    for (const byte of bytes) {
      if (byte > 0x7F) {
        throw new Error('AirPlay event channel headers contain non-ASCII bytes.');
      }
    }
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      chunks.push(String.fromCharCode(...bytes.slice(offset, offset + 8192)));
    }
    return chunks.join('');
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const result = new Uint8Array(left.length + right.length);
    result.set(left);
    result.set(right, left.length);
    return result;
  }
}
