import { common } from '@kit.AbilityKit';
import { mdns } from '@kit.NetworkKit';
import { AirPlayFeatures } from '../../protocol/airplay/AirPlayFeatures';
import { carPlayDiagnostics } from '../diagnostics/CarPlayDiagnostics';

export interface AirPlayServiceEndpoint {
  name: string;
  host: string;
  port: number;
  features: string | undefined;
  homeKitPairingSupported: boolean | undefined;
}

export class HarmonyMdnsBrowser {
  private discovery: mdns.DiscoveryService | undefined = undefined;
  private foundListener: ((serviceInfo: mdns.LocalServiceInfo) => void) | undefined = undefined;
  private readonly reportedNames: Set<string> = new Set<string>();
  private readonly resolvingNames: Set<string> = new Set<string>();
  private generation: number = 0;

  start(
    context: common.UIAbilityContext,
    log: (message: string) => void,
    onEndpoint: (endpoint: AirPlayServiceEndpoint) => void
  ): void {
    if (this.discovery !== undefined) {
      return;
    }
    const generation = ++this.generation;
    try {
      const discovery = mdns.createDiscoveryService(context, '_airplay._tcp');
      this.discovery = discovery;
      this.foundListener = (serviceInfo: mdns.LocalServiceInfo) => {
        if (generation !== this.generation || this.resolvingNames.has(serviceInfo.serviceName)) {
          return;
        }
        carPlayDiagnostics.identifier(serviceInfo.serviceName);
        this.resolvingNames.add(serviceInfo.serviceName);
        mdns.resolveLocalService(context, serviceInfo).then((resolved: mdns.LocalServiceInfo) => {
          this.resolvingNames.delete(serviceInfo.serviceName);
          if (generation !== this.generation) {
            return;
          }
          const host = resolved.host?.address ?? '';
          carPlayDiagnostics.identifier(resolved.serviceName);
          const port = resolved.port ?? 0;
          if (host.length === 0 || port <= 0) {
            log(`忽略不完整的 AirPlay 服务记录：${resolved.serviceName}。`);
            return;
          }
          const endpointKey = `${resolved.serviceName}|${host}|${port}`;
          if (this.reportedNames.has(endpointKey)) {
            return;
          }
          this.reportedNames.add(endpointKey);
          const features = AirPlayFeatures.readFeatureText(resolved.serviceAttribute);
          const pairingSupport = AirPlayFeatures.supportsHomeKitPairing(features);
          const pairingDescription = pairingSupport === undefined ? '未声明/不可解析' :
            pairingSupport ? '支持' : '不支持';
          log(`发现 AirPlay 服务 ${resolved.serviceName}：${host}:${port}；HomeKit 配对能力${pairingDescription}。`);
          try {
            onEndpoint({
              name: resolved.serviceName,
              host,
              port,
              features,
              homeKitPairingSupported: pairingSupport
            });
          } catch (error) {
            const detail = error instanceof Error ? error.message : String(error);
            log(`处理 AirPlay 服务回调失败（${detail}）。`);
          }
        }, (error: Error) => {
          this.resolvingNames.delete(serviceInfo.serviceName);
          if (generation === this.generation) {
            log(`解析 AirPlay 服务失败：${serviceInfo.serviceName}（${error.message}）。`);
          }
        });
      };
      discovery.on('serviceFound', this.foundListener);
      discovery.startSearchingMDNS();
      log('正在车机 Wi-Fi 网络搜索 _airplay._tcp 服务。');
    } catch (error) {
      this.stop(log);
      const detail = error instanceof Error ? error.message : String(error);
      log(`启动 mDNS 服务发现失败；请检查网络能力与系统 mDNS 支持（${detail}）。`);
    }
  }

  stop(log: (message: string) => void): void {
    this.generation++;
    const discovery = this.discovery;
    this.discovery = undefined;
    if (discovery !== undefined) {
      try {
        discovery.stopSearchingMDNS();
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        log(`停止 mDNS 搜索失败（${detail}）。`);
      }
      if (this.foundListener !== undefined) {
        try {
          discovery.off('serviceFound', this.foundListener);
        } catch (error) {
          const detail = error instanceof Error ? error.message : String(error);
          log(`移除 mDNS 监听器失败（${detail}）。`);
        }
      }
    }
    this.foundListener = undefined;
    this.reportedNames.clear();
    this.resolvingNames.clear();
  }
}
