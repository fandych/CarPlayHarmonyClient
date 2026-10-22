import { BluetoothIdentityProvider } from '../network/HarmonyCarPlayInviteServer';
import { BluetoothIdentityError } from './HarmonyBluetoothIdentityProvider';
import { CarPlayInviteProtocol } from '../../protocol/airplay/CarPlayInviteProtocol';

export type BluetoothIdentitySource = 'system' | 'manual' | 'unavailable';

export class ConfiguredBluetoothIdentityProvider implements BluetoothIdentityProvider {
  private readonly automatic: BluetoothIdentityProvider;
  private readonly manualAddress: string;
  private readonly log: (message: string) => void;
  private source: BluetoothIdentitySource = 'unavailable';
  private selectedAddress: string | undefined = undefined;

  constructor(automatic: BluetoothIdentityProvider, manualAddress: string, log: (message: string) => void) {
    this.automatic = automatic;
    this.manualAddress = manualAddress.length === 0 ? '' :
      CarPlayInviteProtocol.createTxtIdentity(manualAddress).toUpperCase();
    this.log = log;
  }

  identitySource(): BluetoothIdentitySource { return this.source; }

  async getStableBluetoothAddress(): Promise<string> {
    let address: string;
    let source: BluetoothIdentitySource;
    try {
      const supplied = await this.automatic.getStableBluetoothAddress();
      if (supplied === undefined) {
        throw new BluetoothIdentityError('api-unavailable', '系统未提供本机蓝牙身份。');
      }
      address = CarPlayInviteProtocol.createTxtIdentity(supplied).toUpperCase();
      source = 'system';
    } catch (error) {
      if (!(error instanceof BluetoothIdentityError) || error.kind === 'identity-changed' ||
        error.kind === 'bluetooth-off' || this.manualAddress.length === 0) {
        throw error instanceof Error ? error : new Error(`系统身份读取失败：${JSON.stringify(error)}`);
      }
      this.log(`系统身份读取不可用：${error.kind} code=${error.code ?? 'none'}: ${error.message}；` +
        '改用用户保存的本机真实地址，不写入日志。');
      address = this.manualAddress;
      source = 'manual';
    }
    if (this.selectedAddress !== undefined && address !== this.selectedAddress) {
      throw new BluetoothIdentityError('identity-changed', '本次会话的系统/手动蓝牙身份不一致；请断开后重新连接。');
    }
    this.selectedAddress = address;
    this.source = source;
    return address;
  }
}
