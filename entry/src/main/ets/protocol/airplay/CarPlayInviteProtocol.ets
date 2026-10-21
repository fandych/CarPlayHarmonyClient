export class CarPlayInviteRequest {
  method: string;
  path: string;
  receiverDeviceId: string | undefined;

  constructor(method: string, path: string, receiverDeviceId: string | undefined) {
    this.method = method;
    this.path = path;
    this.receiverDeviceId = receiverDeviceId;
  }
}

export class CarPlayInviteProtocol {
  static readonly SERVICE_TYPE: string = '_carplay-ctrl._tcp';
  static readonly SERVICE_NAME: string = 'sender';
  static readonly SENDER_VERSION: string = '950.7.1';
  static readonly INVITE_PATH: string = '/ctrl-int/1/connect';

  static parseRequest(header: string): CarPlayInviteRequest {
    if (header.length === 0 || !header.endsWith('\r\n\r\n')) {
      throw new Error('CarPlay invite request is incomplete.');
    }
    const lines = header.slice(0, -4).split('\r\n');
    const requestLine = lines.shift() ?? '';
    const match = /^([A-Z]+) ([^ ]+) HTTP\/1\.[01]$/.exec(requestLine);
    if (match === null) {
      throw new Error('CarPlay invite request line is malformed.');
    }
    let receiverDeviceId: string | undefined = undefined;
    for (const line of lines) {
      const separator = line.indexOf(':');
      if (separator <= 0) {
        throw new Error('CarPlay invite request contains a malformed header.');
      }
      const name = line.slice(0, separator).trim().toLowerCase();
      const value = line.slice(separator + 1).trim();
      if (name === 'airplay-receiver-device-id') {
        if (receiverDeviceId !== undefined || value.length === 0 || /[\r\n\x00]/.test(value)) {
          throw new Error('CarPlay invite contains an invalid receiver device ID.');
        }
        receiverDeviceId = value;
      }
    }
    return new CarPlayInviteRequest(match[1], match[2], receiverDeviceId);
  }

  static response(request: CarPlayInviteRequest): Uint8Array {
    if (request.method === 'GET' && request.path === CarPlayInviteProtocol.INVITE_PATH) {
      return CarPlayInviteProtocol.ascii(
        'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
      );
    }
    return CarPlayInviteProtocol.ascii(
      'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
    );
  }

  static createTxtIdentity(realBluetoothAddress: string): string {
    const normalized = realBluetoothAddress.toLowerCase();
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(normalized) ||
      normalized === '02:00:00:00:00:00' ||
      normalized === '00:00:00:00:00:00' ||
      normalized === 'ff:ff:ff:ff:ff:ff') {
      throw new Error('A real stable Bluetooth address is required for CarPlay service identity.');
    }
    return realBluetoothAddress;
  }

  static ascii(value: string): Uint8Array {
    const bytes = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code > 0x7F) {
        throw new Error('CarPlay control HTTP data must be ASCII.');
      }
      bytes[index] = code;
    }
    return bytes;
  }

  static toNumberArray(bytes: Uint8Array): number[] {
    const values: number[] = [];
    for (const byte of bytes) {
      values.push(byte);
    }
    return values;
  }
}
