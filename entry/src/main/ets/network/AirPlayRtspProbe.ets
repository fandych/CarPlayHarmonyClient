import netSocket from '@ohos.net.socket';
import { decodeUtf8, encodeUtf8, toArrayBuffer } from '../protocol/Iap2Codec';
import { AirPlayService } from './AirPlayMdnsDiscovery';

export class AirPlayRtspProbe {
  async probe(service: AirPlayService): Promise<string> {
    const tcp = netSocket.constructTCPSocketInstance();
    const response = await new Promise<string>((resolve, reject) => {
      let settled = false;
      let responseText = '';
      const finish = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timeout);
        tcp.off('message', onMessage);
        tcp.off('error', onError);
        tcp.close()
          .then((): void => {
            if (error) {
              reject(error);
            } else {
              resolve(responseText);
            }
          })
          .catch((closeError: Error): void => {
            const closeMessage = closeError.message;
            reject(new Error(error ? `${error.message}; socket close failed: ${closeMessage}` : `socket close failed: ${closeMessage}`));
          });
      };
      const onMessage = (info: netSocket.SocketMessageInfo): void => {
        responseText += decodeUtf8(new Uint8Array(info.message));
        if (responseText.length > 65536) {
          finish(new Error('AirPlay RTSP response exceeded the 64 KiB safety limit'));
          return;
        }
        if (responseText.includes('\r\n\r\n')) {
          finish();
        }
      };
      const onError = (error: Error): void => finish(error);
      const timeout = setTimeout((): void => finish(new Error('AirPlay RTSP 探测超时')), 5000);
      tcp.on('message', onMessage);
      tcp.on('error', onError);

      const address: netSocket.TCPConnectOptions = {
        address: { address: service.host, port: service.port },
        timeout: 5000
      };
      tcp.connect(address)
        .then((): Promise<void> => {
          const request = encodeUtf8(
            'OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: HarmonyCarPlaySender/26\r\n\r\n'
          );
          const sendOptions: netSocket.TCPSendOptions = { data: toArrayBuffer(request) };
          return tcp.send(sendOptions);
        })
        .catch((error: Error): void => finish(error));
    });
    const statusLine = response.split('\r\n')[0] ?? '空响应';
    return statusLine;
  }
}
