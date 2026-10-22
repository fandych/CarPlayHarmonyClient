import { CarPlayInviteProtocol } from '../../protocol/airplay/CarPlayInviteProtocol';

export type CarPlayTheme = 'system' | 'light' | 'dark';

export interface WifiFallbackSettings {
  ssid: string;
  securityType: number;
  channel: number;
}

export interface AirPlayFallbackSettings {
  host: string;
  port: number;
}

export interface CarPlaySettings {
  version: number;
  enabled: boolean;
  theme: CarPlayTheme;
  localBluetoothAddress: string;
  deviceName: string;
  targetDeviceId: string;
  targetDeviceName: string;
  wifi: WifiFallbackSettings;
  airplay: AirPlayFallbackSettings;
}

export function defaultCarPlaySettings(): CarPlaySettings {
  return {
    version: 1,
    enabled: false,
    theme: 'system',
    localBluetoothAddress: '',
    deviceName: 'Harmony CarPlay',
    targetDeviceId: '',
    targetDeviceName: '',
    wifi: { ssid: '', securityType: 2, channel: 0 },
    airplay: { host: '', port: 7000 }
  };
}

function requireObject(value: object, field: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${field} 必须是 JSON 对象。`);
  }
}

export function requireSettingsKeys(value: object, keys: string[], field: string): void {
  requireObject(value, field);
  const actual = Object.keys(value);
  if (actual.length !== keys.length || actual.some((key: string) => !keys.includes(key))) {
    throw new Error(`${field} 包含未知字段或缺少字段；不接受密码、密钥或不支持的配置版本。`);
  }
}

function text(value: string, field: string, limit: number): string {
  if (typeof value !== 'string' || value.length > limit || /[\x00-\x1F\x7F]/.test(value) ||
    utf8ByteLength(value) > limit) {
    throw new Error(`${field} 类型、长度或控制字符不合法。`);
  }
  return value;
}

function utf8ByteLength(value: string): number {
  try {
    return encodeURIComponent(value).replace(/%[0-9a-f]{2}/gi, '_').length;
  } catch {
    throw new Error('配置包含无效的 Unicode 字符。');
  }
}

function integer(value: number, field: string, minimum: number, maximum: number): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${field} 必须是 ${minimum} 到 ${maximum} 之间的整数。`);
  }
  return value;
}

function ipv4(value: string): boolean {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part: string) =>
    /^(0|[1-9]\d{0,2})$/.test(part) && Number(part) <= 255);
}

export function isIpLiteral(value: string): boolean {
  if (ipv4(value)) {
    return true;
  }
  const scoped = value.split('%');
  if (scoped.length > 2 || (scoped.length === 2 && !/^[A-Za-z0-9_.-]{1,32}$/.test(scoped[1]))) {
    return false;
  }
  let address = scoped[0];
  if (address.includes('.')) {
    const separator = address.lastIndexOf(':');
    if (separator < 0 || !ipv4(address.slice(separator + 1))) {
      return false;
    }
    address = `${address.slice(0, separator + 1)}0:0`;
  }
  if (!/^[0-9a-f:]+$/i.test(address) || address.includes(':::')) {
    return false;
  }
  const halves = address.split('::');
  if (halves.length > 2) {
    return false;
  }
  const left = halves[0].length === 0 ? [] : halves[0].split(':');
  const right = halves.length < 2 || halves[1].length === 0 ? [] : halves[1].split(':');
  const groups = left.concat(right);
  return groups.every((group: string) => /^[0-9a-f]{1,4}$/i.test(group)) &&
    (halves.length === 2 ? groups.length < 8 : groups.length === 8);
}

export function validateCarPlaySettings(candidate: CarPlaySettings): CarPlaySettings {
  requireSettingsKeys(candidate, ['version', 'enabled', 'theme', 'localBluetoothAddress', 'deviceName',
    'targetDeviceId', 'targetDeviceName', 'wifi', 'airplay'], '配置');
  if (candidate.version !== 1 || typeof candidate.enabled !== 'boolean' ||
    !['system', 'light', 'dark'].includes(candidate.theme)) {
    throw new Error('不支持的配置版本、开关或主题。');
  }
  const rawAddress = text(candidate.localBluetoothAddress, '本机蓝牙地址', 32).trim();
  let localAddress = '';
  if (rawAddress.length > 0) {
    try {
      localAddress = CarPlayInviteProtocol.createTxtIdentity(rawAddress).toUpperCase();
    } catch {
      throw new Error('本机蓝牙地址格式无效，或使用了零值/隐私占位地址。');
    }
  }
  const deviceName = text(candidate.deviceName, '设备名', 64).trim();
  if (deviceName.length === 0) {
    throw new Error('设备名不能为空。');
  }
  const targetId = text(candidate.targetDeviceId, '接收端标识', 256);
  if (localAddress.length > 0 && targetId.toUpperCase() === localAddress) {
    throw new Error('本机蓝牙地址不能填写成所选车机/接收端的地址。');
  }
  requireSettingsKeys(candidate.wifi, ['ssid', 'securityType', 'channel'], 'Wi-Fi 配置');
  const ssid = text(candidate.wifi.ssid, 'SSID', 32);
  const security = integer(candidate.wifi.securityType, 'Wi-Fi 安全类型', 0, 4);
  if (![0, 2, 3, 4].includes(security)) {
    throw new Error('手动 Wi-Fi 配置不支持 WEP。');
  }
  requireSettingsKeys(candidate.airplay, ['host', 'port'], 'AirPlay 配置');
  const host = text(candidate.airplay.host, 'AirPlay IP', 96).trim();
  if (host.length > 0 && !isIpLiteral(host)) {
    throw new Error('AirPlay 地址必须是 IPv4 或 IPv6 字面地址；不要包含协议、方括号或端口。');
  }
  return {
    version: 1,
    enabled: candidate.enabled,
    theme: candidate.theme,
    localBluetoothAddress: localAddress,
    deviceName,
    targetDeviceId: targetId,
    targetDeviceName: text(candidate.targetDeviceName, '接收端名称', 256),
    wifi: { ssid, securityType: security, channel: integer(candidate.wifi.channel, 'Wi-Fi 信道', 0, 233) },
    airplay: { host, port: integer(candidate.airplay.port, 'AirPlay 端口', 1, 65535) }
  };
}

export function parseCarPlaySettings(json: string): CarPlaySettings {
  if (json.length === 0 || json.length > 16384 || utf8ByteLength(json) > 16384) {
    throw new Error('配置 JSON 为空或超过 16 KiB。');
  }
  let parsed: object;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error('配置 JSON 语法错误；未载入或覆盖任何设置。');
  }
  requireObject(parsed, '配置');
  return validateCarPlaySettings(parsed as CarPlaySettings);
}

export function serializeCarPlaySettings(settings: CarPlaySettings): string {
  return JSON.stringify(validateCarPlaySettings(settings), null, 2);
}

export function validateWifiPassword(settings: CarPlaySettings, password: string): void {
  text(password, 'Wi-Fi 密码', 64);
  if (password.length === 0) {
    return;
  }
  if (settings.wifi.ssid.length === 0 || settings.wifi.securityType === 0) {
    throw new Error('保存 Wi-Fi 密码前必须填写 SSID 并选择加密网络。');
  }
  const length = utf8ByteLength(password);
  const minimum = settings.wifi.securityType === 4 ? 1 : 8;
  if (!(length >= minimum && length <= 63) &&
    !(settings.wifi.securityType !== 4 && /^[0-9a-f]{64}$/i.test(password))) {
    throw new Error('Wi-Fi 密码长度不符合所选安全类型要求。');
  }
}
