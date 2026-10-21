import access from '@ohos.bluetooth.access';

// The public ArkTS SDK omits this system API. OS system-app and permission checks are not bypassed.
export function hasSystemBluetoothAddressApi() {
  return typeof access.getLocalAddress === 'function';
}

export function readSystemBluetoothAddress() {
  if (!hasSystemBluetoothAddressApi()) {
    throw new Error('access.getLocalAddress system API is unavailable.');
  }
  const address = access.getLocalAddress();
  if (typeof address !== 'string') {
    throw new Error('access.getLocalAddress did not return a string.');
  }
  return address;
}
