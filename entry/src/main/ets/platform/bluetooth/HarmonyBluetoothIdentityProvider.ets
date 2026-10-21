import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { access } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BluetoothIdentityProvider } from '../network/HarmonyCarPlayInviteServer';
import { CarPlayInviteProtocol } from '../../protocol/airplay/CarPlayInviteProtocol';
import { hasSystemBluetoothAddressApi, readSystemBluetoothAddress } from './SystemBluetoothAddressApi';

export interface SystemBluetoothAccess {
  getState(): access.BluetoothState;
  getLocalAddress?: () => string;
}

export type BluetoothIdentityFailure =
  'permission-denied' | 'bluetooth-off' | 'api-unavailable' | 'system-api-failed' | 'invalid-address' | 'identity-changed';

export class BluetoothIdentityError extends Error {
  readonly kind: BluetoothIdentityFailure;
  readonly code: number | undefined;

  constructor(kind: BluetoothIdentityFailure, message: string, code?: number) {
    super(message);
    this.name = 'BluetoothIdentityError';
    this.kind = kind;
    this.code = code;
  }
}

type PermissionChecker = (permission: Permissions) => boolean;
const LOCAL_MAC_PERMISSION: Permissions = 'ohos.permission.GET_BLUETOOTH_LOCAL_MAC';

class NativeSystemBluetoothAccess implements SystemBluetoothAccess {
  readonly getLocalAddress: (() => string) | undefined;

  constructor() {
    this.getLocalAddress = hasSystemBluetoothAddressApi() ? readSystemBluetoothAddress : undefined;
  }

  getState(): access.BluetoothState {
    return access.getState();
  }
}

export class HarmonyBluetoothIdentityProvider implements BluetoothIdentityProvider {
  private readonly api: SystemBluetoothAccess;
  private readonly granted: PermissionChecker;
  private sessionAddress: string | undefined = undefined;

  constructor(
    tokenId: number,
    api: SystemBluetoothAccess = new NativeSystemBluetoothAccess(),
    granted?: PermissionChecker
  ) {
    this.api = api;
    this.granted = granted ?? ((permission: Permissions): boolean => {
      return abilityAccessCtrl.createAtManager().checkAccessTokenSync(tokenId, permission) ===
        abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    });
  }

  async getStableBluetoothAddress(): Promise<string> {
    if (!this.granted('ohos.permission.ACCESS_BLUETOOTH')) {
      throw new BluetoothIdentityError('permission-denied', 'ACCESS_BLUETOOTH 未授予；请先允许蓝牙权限。');
    }
    if (!this.granted(LOCAL_MAC_PERMISSION)) {
      throw new BluetoothIdentityError('permission-denied',
        'GET_BLUETOOTH_LOCAL_MAC 未授予：这是 system_basic 系统权限，需系统应用身份及获批 profile/ACL，' +
        '不能通过用户权限弹窗获取。');
    }
    if (this.api.getState() !== access.BluetoothState.STATE_ON) {
      throw new BluetoothIdentityError('bluetooth-off', '蓝牙未就绪，不能读取本机稳定蓝牙地址。');
    }
    // The public SDK omits this documented system API. Detection never substitutes for permission checks.
    if (typeof this.api.getLocalAddress !== 'function') {
      throw new BluetoothIdentityError('api-unavailable',
        '当前系统未暴露 access.getLocalAddress 系统接口；需要目标设备厂商支持。');
    }
    let supplied: string;
    try {
      supplied = this.api.getLocalAddress();
    } catch (error) {
      const businessError = error as BusinessError;
      throw new BluetoothIdentityError('system-api-failed',
        `access.getLocalAddress 调用失败：${businessError.message || '系统未提供错误详情'}；` +
        '201 表示权限不足，202 表示非系统应用，801 表示能力不支持。', businessError.code);
    }
    let address: string;
    try {
      address = CarPlayInviteProtocol.createTxtIdentity(supplied.trim()).toUpperCase();
    } catch (error) {
      throw new BluetoothIdentityError('invalid-address',
        '系统未返回合法的本机真实蓝牙地址，或返回了隐私占位值；已拒绝用于 CarPlay。');
    }
    if (this.sessionAddress !== undefined && this.sessionAddress !== address) {
      throw new BluetoothIdentityError('identity-changed', '本机蓝牙身份在会话中发生变化；请断开后重新连接。');
    }
    this.sessionAddress = address;
    return address;
  }
}
