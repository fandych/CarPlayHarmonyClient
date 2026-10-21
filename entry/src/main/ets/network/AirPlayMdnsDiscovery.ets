import mdns from '@ohos.net.mdns';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';

export interface AirPlayService {
  name: string;
  host: string;
  port: number;
  txt: Record<string, string>;
}

export class AirPlayMdnsDiscovery {
  private readonly context: common.UIAbilityContext;
  private discovery?: mdns.DiscoveryService;
  private foundHandler?: (service: mdns.LocalServiceInfo) => void;
  private readonly onService: (service: AirPlayService) => void;
  private readonly onError: (message: string) => void;
  private readonly resolvedNames: Set<string> = new Set<string>();

  constructor(
    context: common.UIAbilityContext,
    onService: (service: AirPlayService) => void,
    onError: (message: string) => void
  ) {
    this.context = context;
    this.onService = onService;
    this.onError = onError;
  }

  start(): void {
    if (this.discovery) {
      return;
    }
    this.discovery = mdns.createDiscoveryService(this.context, '_airplay._tcp');
    this.foundHandler = (service: mdns.LocalServiceInfo): void => {
      if (this.resolvedNames.has(service.serviceName)) {
        return;
      }
      this.resolvedNames.add(service.serviceName);
      mdns.resolveLocalService(this.context, service)
        .then((resolved: mdns.LocalServiceInfo): void => {
          const host = resolved.host?.address ?? '';
          const port = resolved.port ?? 0;
          if (!host || port < 1) {
            this.onError(`mDNS 解析结果缺少主机或端口：${resolved.serviceName}`);
            return;
          }
          const txt: Record<string, string> = {};
          for (const attribute of resolved.serviceAttribute ?? []) {
            txt[attribute.key] = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(attribute.value));
          }
          const airPlayService: AirPlayService = {
            name: resolved.serviceName,
            host,
            port,
            txt
          };
          this.onService(airPlayService);
        })
        .catch((error: Error): void => {
          this.resolvedNames.delete(service.serviceName);
          this.onError(`mDNS 解析失败：${error.message}`);
        });
    };
    this.discovery.on('serviceFound', this.foundHandler);
    this.discovery.startSearchingMDNS();
  }

  stop(): void {
    if (!this.discovery) {
      return;
    }
    if (this.foundHandler) {
      this.discovery.off('serviceFound', this.foundHandler);
    }
    this.discovery.stopSearchingMDNS();
    this.discovery = undefined;
    this.foundHandler = undefined;
    this.resolvedNames.clear();
  }
}
