import { wifiManager } from '@kit.ConnectivityKit';
import { connection } from '@kit.NetworkKit';
import { AccessoryWifiConfiguration } from '../../protocol/iap2/Iap2SenderSession';
import { describeFailure } from '../diagnostics/DiagnosticFormat';

export function selectSingleWlanNetwork<T>(candidates: T[]): T {
  if (candidates.length !== 1) {
    throw new Error(`无法唯一确认车机 WLAN 网络句柄，WLAN count=${candidates.length}；拒绝绑定默认/蜂窝网络。`);
  }
  return candidates[0];
}

export class HarmonyWifiClient {
  private candidateNetworkId: number = -1;
  private previousNetwork: connection.NetHandle | undefined = undefined;
  private bindingAttempted: boolean = false;
  private closed: boolean = false;
  private inFlight: Promise<void> | undefined = undefined;
  private log: (message: string) => void = () => {};

  connectToAccessory(
    configuration: AccessoryWifiConfiguration,
    isCurrent: () => boolean,
    log: (message: string) => void
  ): Promise<void> {
    if (this.inFlight !== undefined || this.closed) {
      throw new Error('Wi-Fi client is already started or closed.');
    }
    this.log = log;
    const task = this.connect(configuration, isCurrent);
    this.inFlight = task;
    return task;
  }

  private async connect(configuration: AccessoryWifiConfiguration, isCurrent: () => boolean): Promise<void> {
    const securityType = this.mapSecurityType(configuration.securityType);
    if (configuration.ssid.length === 0) {
      throw new Error('车机 Wi-Fi SSID 为空。');
    }
    if (securityType !== wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN && configuration.passphrase.length === 0) {
      throw new Error('车机 Wi-Fi 需要密码，但未收到有效凭据。');
    }
    this.requireCurrent(isCurrent);
    this.log(`添加车机 Wi-Fi 候选网络；security=${configuration.securityType}；不记录凭据。`);
    this.candidateNetworkId = await wifiManager.addCandidateConfig({
      ssid: configuration.ssid,
      preSharedKey: configuration.passphrase,
      securityType
    });
    this.requireCurrent(isCurrent);
    this.log('请求系统加入车机热点，等待用户确认与 WLAN 网络就绪。');
    await wifiManager.connectToCandidateConfigWithUserAction(this.candidateNetworkId);
    this.requireCurrent(isCurrent);

    const deadline = Date.now() + 15000;
    let lastReason = '尚未观察到车机 WLAN';
    let targetNetwork: connection.NetHandle | undefined = undefined;
    while (Date.now() < deadline) {
      this.requireCurrent(isCurrent);
      const linked = await wifiManager.getLinkedInfo();
      if (linked.ssid === configuration.ssid && linked.connState === wifiManager.ConnState.CONNECTED) {
        const networks = await connection.getAllNets();
        const wlan: connection.NetHandle[] = [];
        for (const network of networks) {
          this.requireCurrent(isCurrent);
          const capabilities = await connection.getNetCapabilities(network);
          if (capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            wlan.push(network);
          }
        }
        if (wlan.length > 1) {
          selectSingleWlanNetwork(wlan);
        }
        if (wlan.length === 1) {
          const candidate = selectSingleWlanNetwork(wlan);
          const properties = await connection.getConnectionProperties(candidate);
          const confirmed = await wifiManager.getLinkedInfo();
          if (properties.linkAddresses.length > 0 && confirmed.ssid === configuration.ssid &&
            confirmed.connState === wifiManager.ConnState.CONNECTED) {
            targetNetwork = candidate;
            break;
          }
          lastReason = 'WLAN 地址尚未就绪或关联已变化';
        } else {
          lastReason = '系统尚未提供 WLAN 网络句柄';
        }
      } else {
        lastReason = '系统尚未确认目标 SSID 的已连接状态';
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, 250); });
    }
    this.requireCurrent(isCurrent);
    if (targetNetwork === undefined) {
      throw new Error(`等待车机 WLAN 超时：${lastReason}`);
    }
    this.previousNetwork = await connection.getAppNet();
    this.requireCurrent(isCurrent);
    this.bindingAttempted = true;
    await connection.setAppNet(targetNetwork);
    this.requireCurrent(isCurrent);
    const bound = await connection.getAppNet();
    const capabilities = await connection.getNetCapabilities(bound);
    const confirmed = await wifiManager.getLinkedInfo();
    if (bound.netId !== targetNetwork.netId ||
      !capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ||
      confirmed.ssid !== configuration.ssid || confirmed.connState !== wifiManager.ConnState.CONNECTED) {
      throw new Error('应用网络绑定未保持在已确认的车机 WLAN 上。');
    }
    this.requireCurrent(isCurrent);
    this.log('已核验目标 SSID、唯一 WLAN 句柄、接口地址及应用绑定；未使用默认网络推断。');
  }

  async stop(): Promise<void> {
    this.closed = true;
    if (this.inFlight !== undefined) {
      try {
        await this.inFlight;
      } catch (error) {
        this.log(`Wi-Fi 操作已结束/取消：${describeFailure(error)}`);
      }
    }
    const errors: string[] = [];
    if (this.bindingAttempted && this.previousNetwork !== undefined) {
      try {
        await connection.setAppNet(this.previousNetwork);
        this.bindingAttempted = false;
        this.log('已恢复连接前的应用网络绑定。');
      } catch (error) {
        errors.push(`恢复原应用网络绑定：${describeFailure(error)}`);
      }
    }
    if (this.candidateNetworkId >= 0) {
      try {
        await wifiManager.removeCandidateConfig(this.candidateNetworkId);
        this.candidateNetworkId = -1;
        this.log('已移除本次添加的车机候选网络。');
      } catch (error) {
        errors.push(`移除候选网络：${describeFailure(error)}`);
      }
    }
    if (errors.length > 0) {
      throw new Error(errors.join('; '));
    }
  }

  private requireCurrent(isCurrent: () => boolean): void {
    if (this.closed || !isCurrent()) {
      throw new Error('车机 Wi-Fi 连接已取消。');
    }
  }

  private mapSecurityType(type: number): wifiManager.WifiSecurityType {
    switch (type) {
      case 0:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN;
      case 1:
        throw new Error('HarmonyOS 候选网络不支持车机使用的 WEP 加密。');
      case 2:
      case 3:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK;
      case 4:
        return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_SAE;
      default:
        throw new Error(`不支持车机 Wi-Fi 安全类型 ${type}。`);
    }
  }
}
