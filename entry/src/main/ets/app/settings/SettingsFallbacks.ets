import { AccessoryWifiConfiguration } from '../../protocol/iap2/Iap2SenderSession';
import { AirPlayServiceEndpoint } from '../../platform/network/HarmonyMdnsBrowser';
import { CarPlaySettings, validateWifiPassword } from './CarPlaySettings';

export function configuredWifi(settings: CarPlaySettings, password: string): AccessoryWifiConfiguration | undefined {
  if (settings.wifi.ssid.length === 0) {
    return undefined;
  }
  validateWifiPassword(settings, password);
  if (settings.wifi.securityType !== 0 && password.length === 0) {
    throw new Error('备用 Wi-Fi 已配置 SSID，但未保存加密网络密码。');
  }
  return { ssid: settings.wifi.ssid, passphrase: password,
    securityType: settings.wifi.securityType, channel: settings.wifi.channel };
}

export function chooseWifiConfiguration(
  automatic: AccessoryWifiConfiguration | undefined,
  manual: AccessoryWifiConfiguration | undefined
): AccessoryWifiConfiguration | undefined {
  if (automatic === undefined || automatic.ssid.length === 0) {
    return manual;
  }
  if (automatic.securityType === 0 || automatic.passphrase.length > 0) {
    return automatic;
  }
  if (manual === undefined) {
    throw new Error('自动 Wi-Fi 配置缺少密码，且没有可用的手动备用信息。');
  }
  if (manual.ssid !== automatic.ssid || manual.securityType !== automatic.securityType) {
    throw new Error('自动网络与备用网络不一致，拒绝将备用密码用于其他网络。');
  }
  return { ssid: automatic.ssid, passphrase: manual.passphrase,
    securityType: automatic.securityType, channel: automatic.channel };
}

export function resolveSessionWifi(
  automatic: AccessoryWifiConfiguration | undefined,
  settings: CarPlaySettings,
  password: string
): AccessoryWifiConfiguration | undefined {
  if (automatic !== undefined && automatic.ssid.length > 0 &&
    (automatic.securityType === 0 || automatic.passphrase.length > 0)) {
    return automatic;
  }
  return chooseWifiConfiguration(automatic, configuredWifi(settings, password));
}

export function configuredAirPlay(settings: CarPlaySettings): AirPlayServiceEndpoint | undefined {
  return settings.airplay.host.length === 0 ? undefined : {
    name: '手动 AirPlay 备用端点', host: settings.airplay.host, port: settings.airplay.port,
    features: undefined, homeKitPairingSupported: undefined
  };
}

export function chooseAirPlayEndpoint(
  iap2: AirPlayServiceEndpoint | undefined,
  mdns: AirPlayServiceEndpoint | undefined,
  manual: AirPlayServiceEndpoint | undefined,
  allowManual: boolean
): AirPlayServiceEndpoint | undefined {
  for (const endpoint of [iap2, mdns]) {
    if (endpoint !== undefined && endpoint.host.length > 0 && endpoint.port > 0 && endpoint.port <= 65535) {
      return endpoint;
    }
  }
  return allowManual ? manual : undefined;
}
