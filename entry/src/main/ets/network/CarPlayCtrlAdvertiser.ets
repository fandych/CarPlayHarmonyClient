import common from '@ohos.app.ability.common';
import mdns from '@ohos.net.mdns';
import netSocket from '@ohos.net.socket';
import {
  decodeUtf8,
  encodeUtf8,
  toArrayBuffer
} from '../protocol/Iap2Codec';

export class CarPlayCtrlAdvertiser {
  private readonly context: common.UIAbilityContext;
  private readonly deviceAddress: string;
  private readonly onInvite: () => void;
  private readonly onLog: (message: string) => void;
  private server?: netSocket.TCPSocketServer;
  private serverHandler?: (connection: netSocket.TCPSocketConnection) => void;
  private service?: mdns.LocalServiceInfo;
  private readonly clients: Set<netSocket.TCPSocketConnection> = new Set<netSocket.TCPSocketConnection>();

  constructor(
    context: common.UIAbilityContext,
    deviceAddress: string,
    onInvite: () => void,
    onLog: (message: string) => void
  ) {
    this.context = context;
    this.deviceAddress = deviceAddress;
    this.onInvite = onInvite;
    this.onLog = onLog;
  }

  async start(): Promise<void> {
    if (this.server) {
      return;
    }
    const server = netSocket.constructTCPSocketServerInstance();
    this.server = server;
    try {
      const listenAddress: netSocket.NetAddress = { address: '0.0.0.0', port: 0 };
      await server.listen(listenAddress);
      const boundAddress = await server.getLocalAddress();
      const port = boundAddress.port ?? 0;
      if (port < 1) {
        throw new Error('系统未分配 CarPlay 控制服务端口');
      }

      this.serverHandler = (connection: netSocket.TCPSocketConnection): void => {
        this.handleClient(connection);
      };
      server.on('connect', this.serverHandler);

      const attributes: mdns.ServiceAttribute[] = [
        { key: 'id', value: this.toNumberArray(encodeUtf8(this.deviceAddress)) },
        { key: 'srcvers', value: this.toNumberArray(encodeUtf8('950.7.1')) }
      ];
      const serviceInfo: mdns.LocalServiceInfo = {
        serviceType: '_carplay-ctrl._tcp',
        serviceName: 'sender',
        port,
        serviceAttribute: attributes
      };
      this.service = await mdns.addLocalService(this.context, serviceInfo);
      this.onLog(`已广播 _carplay-ctrl._tcp，端口 ${port}；TXT id=${this.deviceAddress}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      try {
        await this.stop();
      } catch (cleanupError) {
        const cleanupMessage = cleanupError instanceof Error ? cleanupError.message : String(cleanupError);
        throw new Error(`启动 CarPlay 控制广播失败：${message}；清理也失败：${cleanupMessage}`);
      }
      throw new Error(`启动 CarPlay 控制广播失败：${message}`);
    }
  }

  async stop(): Promise<void> {
    const failures: string[] = [];
    const service = this.service;
    this.service = undefined;
    if (service) {
      try {
        await mdns.removeLocalService(this.context, service);
      } catch (error) {
        failures.push(`mDNS 注销失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
    const server = this.server;
    this.server = undefined;
    if (server) {
      if (this.serverHandler) {
        try {
          server.off('connect', this.serverHandler);
        } catch (error) {
          failures.push(`TCP 监听取消失败：${error instanceof Error ? error.message : String(error)}`);
        }
      }
      try {
        await server.close();
      } catch (error) {
        failures.push(`TCP 监听关闭失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
    this.serverHandler = undefined;
    const clients = Array.from(this.clients);
    this.clients.clear();
    for (const client of clients) {
      try {
        await client.close();
      } catch (error) {
        failures.push(`TCP 客户端关闭失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (failures.length > 0) {
      throw new Error(failures.join('；'));
    }
  }

  private handleClient(connection: netSocket.TCPSocketConnection): void {
    this.clients.add(connection);
    let request = '';
    let handled = false;
    const reader = (info: netSocket.SocketMessageInfo): void => {
      if (handled) {
        return;
      }
      request += decodeUtf8(new Uint8Array(info.message));
      if (request.length > 16384) {
        handled = true;
        this.closeClientLogged(connection, reader, '关闭超长控制请求失败');
        return;
      }
      if (!request.includes('\r\n\r\n')) {
        return;
      }
      handled = true;
      const requestLine = request.split('\r\n')[0] ?? '';
      if (requestLine.startsWith('GET /ctrl-int/1/connect')) {
        this.onLog(`车机邀请 AirPlay 控制连接：${requestLine}`);
        this.onInvite();
      } else {
        this.onLog(`收到控制通道请求：${requestLine}`);
      }
      const response = encodeUtf8(
        'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
      );
      const sendOptions: netSocket.TCPSendOptions = { data: toArrayBuffer(response) };
      try {
        connection.send(sendOptions)
        .then((): Promise<void> => this.closeClient(connection, reader))
        .catch((error: Error): void => {
          this.onLog(`控制通道应答失败：${error.message}`);
          this.closeClientLogged(connection, reader, '关闭失败请求连接时出错');
        });
      } catch (error) {
        this.onLog(`控制通道应答失败：${error instanceof Error ? error.message : String(error)}`);
        this.closeClientLogged(connection, reader, '关闭失败请求连接时出错');
      }
    };
    try {
      connection.on('message', reader);
    } catch (error) {
      this.onLog(`订阅控制请求失败：${error instanceof Error ? error.message : String(error)}`);
      this.closeClientLogged(connection, reader, '关闭未订阅连接时出错');
    }
  }

  private async closeClient(
    connection: netSocket.TCPSocketConnection,
    reader: (info: netSocket.SocketMessageInfo) => void
  ): Promise<void> {
    let offError = '';
    try {
      connection.off('message', reader);
    } catch (error) {
      offError = error instanceof Error ? error.message : String(error);
    }
    this.clients.delete(connection);
    try {
      await connection.close();
    } catch (error) {
      const closeError = error instanceof Error ? error.message : String(error);
      throw new Error(offError ? `${offError}; ${closeError}` : closeError);
    }
    if (offError) {
      throw new Error(offError);
    }
  }

  private closeClientLogged(
    connection: netSocket.TCPSocketConnection,
    reader: (info: netSocket.SocketMessageInfo) => void,
    context: string
  ): void {
    void this.closeClient(connection, reader).catch((error: Error): void => {
      this.onLog(`${context}：${error.message}`);
    });
  }

  private toNumberArray(bytes: Uint8Array): number[] {
    const result: number[] = [];
    for (const byte of bytes) {
      result.push(byte);
    }
    return result;
  }
}
