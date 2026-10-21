export interface RtspResponse {
  statusCode: number;
  reason: string;
  headers: Map<string, string>;
  body: Uint8Array;
}

const MAX_HEADER_BYTES = 64 * 1024;
const MAX_BODY_BYTES = 2 * 1024 * 1024;

export class RtspResponseParser {
  private buffer: Uint8Array = new Uint8Array(0);

  offer(chunk: Uint8Array): RtspResponse[] {
    this.buffer = RtspResponseParser.concat(this.buffer, chunk);
    const responses: RtspResponse[] = [];
    while (true) {
      const headerEnd = RtspResponseParser.findHeaderEnd(this.buffer);
      if (headerEnd < 0) {
        if (this.buffer.length > MAX_HEADER_BYTES) {
          throw new Error('RTSP response headers exceed the limit.');
        }
        return responses;
      }
      if (headerEnd > MAX_HEADER_BYTES) {
        throw new Error('RTSP response headers exceed the limit.');
      }

      const headersText = RtspResponseParser.decodeAscii(this.buffer.slice(0, headerEnd));
      const lines = headersText.split('\r\n');
      const statusLine = lines.shift() ?? '';
      const statusMatch = /^RTSP\/1\.[0-9] ([0-9]{3})(?: (.*))?$/.exec(statusLine);
      if (statusMatch === null) {
        throw new Error('Malformed RTSP status line.');
      }
      const headers: Map<string, string> = new Map<string, string>();
      for (let index = 0; index < lines.length; index++) {
        const line = lines[index];
        const separator = line.indexOf(':');
        if (separator <= 0) {
          throw new Error('Malformed RTSP response header.');
        }
        const name = line.slice(0, separator).trim().toLowerCase();
        const value = line.slice(separator + 1).trim();
        if (headers.has(name)) {
          headers.set(name, `${headers.get(name)}, ${value}`);
        } else {
          headers.set(name, value);
        }
      }

      const contentLengthText = headers.get('content-length') ?? '0';
      if (!/^\d+$/.test(contentLengthText)) {
        throw new Error('Invalid RTSP Content-Length.');
      }
      const contentLength = Number.parseInt(contentLengthText, 10);
      if (!Number.isInteger(contentLength) || contentLength < 0 || contentLength > MAX_BODY_BYTES) {
        throw new Error('Invalid or excessive RTSP Content-Length.');
      }
      const bodyStart = headerEnd + 4;
      const messageEnd = bodyStart + contentLength;
      if (this.buffer.length < messageEnd) {
        return responses;
      }

      responses.push({
        statusCode: Number.parseInt(statusMatch[1], 10),
        reason: statusMatch[2] ?? '',
        headers,
        body: this.buffer.slice(bodyStart, messageEnd)
      });
      this.buffer = this.buffer.slice(messageEnd);
      if (this.buffer.length === 0) {
        return responses;
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
    const chars: number[] = [];
    for (let index = 0; index < bytes.length; index++) {
      if (bytes[index] > 0x7F) {
        throw new Error('RTSP response headers contain non-ASCII bytes.');
      }
      chars.push(bytes[index]);
    }
    return String.fromCharCode(...chars);
  }

  private static concat(left: Uint8Array, right: Uint8Array): Uint8Array {
    const result = new Uint8Array(left.length + right.length);
    result.set(left);
    result.set(right, left.length);
    return result;
  }
}
