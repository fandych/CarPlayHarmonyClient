export interface RtspRequestHeader {
  name: string;
  value: string;
}

export class RtspRequestEncoder {
  static encode(
    method: string,
    target: string,
    cseq: number,
    body: Uint8Array = new Uint8Array(0),
    headers: RtspRequestHeader[] = []
  ): Uint8Array {
    if (!/^[A-Z]+$/.test(method) || !/^\/[^\r\n ]*$/.test(target) ||
      !Number.isInteger(cseq) || cseq < 1) {
      throw new Error('Invalid RTSP request line or CSeq.');
    }

    const lines = [`${method} ${target} RTSP/1.0`, `CSeq: ${cseq}`];
    for (const header of headers) {
      if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(header.name) ||
        /[\r\n]/.test(header.value)) {
        throw new Error('Invalid RTSP request header.');
      }
      const lowerName = header.name.toLowerCase();
      if (lowerName === 'cseq' || lowerName === 'content-length') {
        throw new Error(`RTSP ${header.name} is managed by the request encoder.`);
      }
      lines.push(`${header.name}: ${header.value}`);
    }
    if (body.length > 0) {
      lines.push(`Content-Length: ${body.length}`);
    }

    const headerBytes = RtspRequestEncoder.encodeAscii(`${lines.join('\r\n')}\r\n\r\n`);
    const request = new Uint8Array(headerBytes.length + body.length);
    request.set(headerBytes);
    request.set(body, headerBytes.length);
    return request;
  }

  private static encodeAscii(text: string): Uint8Array {
    const bytes = new Uint8Array(text.length);
    for (let index = 0; index < text.length; index++) {
      const code = text.charCodeAt(index);
      if (code > 0x7F) {
        throw new Error('RTSP request headers must contain ASCII characters only.');
      }
      bytes[index] = code;
    }
    return bytes;
  }
}
