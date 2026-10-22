import wifiManager from '@ohos.wifiManager';
import { WifiCredentials } from '../session/Iap2SenderSession';

export interface WifiConnectionResult {
  ssid: string;
  ipAddress: string;
}

export class WifiCarPlayConnector {
  private pendingNetworkId: number = -1;
  private requestGeneration: number = 0;

  async connect(credentials: WifiCredentials): Promise<WifiConnectionResult> {
    if (credentials.ssid.length === 0 || credentials.ssid.length > 32) {
      throw new Error('车机 Wi-Fi 名称无效');
    }
    const securityType = this.mapSecurityType(credentials.securityType);
    const config: wifiManager.WifiDeviceConfig = {
      ssid: credentials.ssid,
      preSharedKey: credentials.password,
      securityType
    };
    let networkId: number;
    try {
      networkId = await wifiManager.addCandidateConfig(config);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`添加车机 Wi-Fi 候选配置失败：${message}`);
    }
    if (networkId < 0) {
      throw new Error('系统没有接受车机 Wi-Fi 配置');
    }
    const generation = ++this.requestGeneration;
    this.pendingNetworkId = networkId;
    try {
      await wifiManager.connectToCandidateConfigWithUserAction(networkId);
      if (generation !== this.requestGeneration) {
        throw new Error('CarPlay 连接已取消');
      }
      const deadline = Date.now() + 20000;
      while (Date.now() < deadline) {
        if (generation !== this.requestGeneration) {
          throw new Error('CarPlay 连接已取消');
        }
        const linked = await wifiManager.getLinkedInfo();
        if (generation !== this.requestGeneration) {
          throw new Error('CarPlay 连接已取消');
        }
        if (linked.ssid === credentials.ssid && linked.ipAddress !== 0) {
          const result: WifiConnectionResult = {
            ssid: credentials.ssid,
            ipAddress: this.formatIpAddress(linked.ipAddress)
          };
          if (this.pendingNetworkId === networkId && generation === this.requestGeneration) {
            this.pendingNetworkId = -1;
          }
          return result;
        }
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 1000);
        });
      }
      const linked = await wifiManager.getLinkedInfo();
      const actualSsid = linked.ssid.length > 0 ? linked.ssid : '未知网络';
      throw new Error(`20 秒内未确认加入车机热点；当前网络为 ${actualSsid}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (this.pendingNetworkId === networkId && generation === this.requestGeneration) {
        this.pendingNetworkId = -1;
        try {
          await wifiManager.removeCandidateConfig(networkId);
        } catch (cleanupError) {
          const cleanupMessage = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
          throw new Error(`${message}；清理 Wi-Fi 配置失败：${cleanupMessage}`);
        }
      }
      throw new Error(message);
    }
  }

  async cancelPendingJoin(): Promise<void> {
    this.requestGeneration++;
    const networkId = this.pendingNetworkId;
    this.pendingNetworkId = -1;
    if (networkId < 0) {
      return;
    }
    try {
      await wifiManager.removeCandidateConfig(networkId);
    } catch (error) {
      throw new Error(`取消车机 Wi-Fi 加入失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private mapSecurityType(type: number): wifiManager.WifiSecurityType {
    switch (type) {
      case 0:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN;
      case 1:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_WEP;
      case 2:
      case 3:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK;
      case 4:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_SAE;
      default:
        throw new Error(`暂不支持车机 Wi-Fi 安全类型 ${type}`);
    }
  }

  private formatIpAddress(ipAddress: number): string {
    return [
      ipAddress & 0xff,
      (ipAddress >>> 8) & 0xff,
      (ipAddress >>> 16) & 0xff,
      (ipAddress >>> 24) & 0xff
    ].join('.');
  }
}
