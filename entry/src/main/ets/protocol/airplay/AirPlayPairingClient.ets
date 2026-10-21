import { HarmonyControllerIdentityStore, ControllerIdentity } from '../../platform/security/HarmonyControllerIdentityStore';
import { HarmonyAirPlayCrypto } from './HarmonyAirPlayCrypto';
import { Srp6aClient } from './Srp6aClient';
import { Tlv8, Tlv8Item } from './Tlv8';

export interface TlvTransport {
  exchange(path: string, body: Uint8Array): Promise<Uint8Array>;
}

export interface ReceiverIdentity {
  pairingId: string;
  publicKey: Uint8Array;
}

export interface AirPlayControlKeys {
  phoneWriteKey: Uint8Array;
  phoneReadKey: Uint8Array;
  sharedSecret: Uint8Array;
}

export class PairSetupClient {
  private readonly identityStore: HarmonyControllerIdentityStore;
  private readonly transport: TlvTransport;
  private readonly log: (message: string) => void;

  constructor(
    identityStore: HarmonyControllerIdentityStore,
    transport: TlvTransport,
    log: (message: string) => void
  ) {
    this.identityStore = identityStore;
    this.transport = transport;
    this.log = log;
  }

  async run(): Promise<ReceiverIdentity> {
    const first = await this.exchange('/pair-setup', [
      { type: Tlv8.TYPE_METHOD, value: new Uint8Array([0]) },
      { type: Tlv8.TYPE_STATE, value: new Uint8Array([1]) }
    ]);
    PairSetupClient.requireState(first, 2, 'pair-setup M2');
    const salt = PairSetupClient.required(first, Tlv8.TYPE_SALT, 'pair-setup M2 salt');
    const serverPublicKey = PairSetupClient.required(first, Tlv8.TYPE_PUBLIC_KEY, 'pair-setup M2 public key');
    const srp = await Srp6aClient.start(salt);
    const proof = await srp.prove(serverPublicKey);

    const second = await this.exchange('/pair-setup', [
      { type: Tlv8.TYPE_STATE, value: new Uint8Array([3]) },
      { type: Tlv8.TYPE_PUBLIC_KEY, value: srp.publicKeyA },
      { type: Tlv8.TYPE_PROOF, value: proof.clientProof }
    ]);
    PairSetupClient.requireState(second, 4, 'pair-setup M4');
    const serverProof = PairSetupClient.required(second, Tlv8.TYPE_PROOF, 'pair-setup M4 proof');
    if (!await proof.verifyServerProof(serverProof)) {
      throw new Error('AirPlay pair-setup server proof verification failed.');
    }
    this.log('AirPlay pair-setup SRP mutual proof verified.');

    const sessionKey = proof.sessionKey;
    const encryptionKey = await HarmonyAirPlayCrypto.hkdfSha512(
      sessionKey,
      PairSetupClient.ascii('Pair-Setup-Encrypt-Salt'),
      PairSetupClient.ascii('Pair-Setup-Encrypt-Info')
    );
    const controllerSignKey = await HarmonyAirPlayCrypto.hkdfSha512(
      sessionKey,
      PairSetupClient.ascii('Pair-Setup-Controller-Sign-Salt'),
      PairSetupClient.ascii('Pair-Setup-Controller-Sign-Info')
    );
    const controller = await this.identityStore.getIdentity();
    const identifier = PairSetupClient.ascii(controller.pairingId);
    const controllerSignature = await this.identityStore.sign(HarmonyAirPlayCrypto.concat(
      controllerSignKey,
      identifier,
      controller.publicKey
    ));
    const encryptedControllerIdentity = await HarmonyAirPlayCrypto.chachaSeal(
      encryptionKey,
      HarmonyAirPlayCrypto.nonceLabel('PS-Msg05'),
      Tlv8.encode([
        { type: Tlv8.TYPE_IDENTIFIER, value: identifier },
        { type: Tlv8.TYPE_PUBLIC_KEY, value: controller.publicKey },
        { type: Tlv8.TYPE_SIGNATURE, value: controllerSignature }
      ])
    );
    const third = await this.exchange('/pair-setup', [
      { type: Tlv8.TYPE_STATE, value: new Uint8Array([5]) },
      { type: Tlv8.TYPE_ENCRYPTED_DATA, value: encryptedControllerIdentity }
    ]);
    PairSetupClient.requireState(third, 6, 'pair-setup M6');
    const encryptedAccessoryIdentity = PairSetupClient.required(
      third,
      Tlv8.TYPE_ENCRYPTED_DATA,
      'pair-setup M6 encrypted identity'
    );
    const accessoryIdentity = Tlv8.decode(await HarmonyAirPlayCrypto.chachaOpen(
      encryptionKey,
      HarmonyAirPlayCrypto.nonceLabel('PS-Msg06'),
      encryptedAccessoryIdentity
    ));
    const receiverId = PairSetupClient.required(
      accessoryIdentity,
      Tlv8.TYPE_IDENTIFIER,
      'pair-setup accessory identifier'
    );
    const receiverKey = PairSetupClient.required(
      accessoryIdentity,
      Tlv8.TYPE_PUBLIC_KEY,
      'pair-setup accessory public key'
    );
    const receiverSignature = PairSetupClient.required(
      accessoryIdentity,
      Tlv8.TYPE_SIGNATURE,
      'pair-setup accessory signature'
    );
    if (receiverKey.length !== 32 || receiverSignature.length !== 64) {
      throw new Error('AirPlay pair-setup accessory identity has invalid key material.');
    }
    const accessorySignKey = await HarmonyAirPlayCrypto.hkdfSha512(
      sessionKey,
      PairSetupClient.ascii('Pair-Setup-Accessory-Sign-Salt'),
      PairSetupClient.ascii('Pair-Setup-Accessory-Sign-Info')
    );
    const signedAccessoryIdentity = HarmonyAirPlayCrypto.concat(
      accessorySignKey,
      receiverId,
      receiverKey
    );
    if (!await HarmonyAirPlayCrypto.verifyEd25519(receiverKey, signedAccessoryIdentity, receiverSignature)) {
      throw new Error('AirPlay pair-setup accessory signature verification failed.');
    }
    this.log('AirPlay pair-setup completed; accessory identity signature verified.');
    return {
      pairingId: PairSetupClient.decodeIdentifier(receiverId),
      publicKey: receiverKey
    };
  }

  private async exchange(path: string, items: Tlv8Item[]): Promise<Map<number, Uint8Array>> {
    const responseBytes = await this.transport.exchange(path, Tlv8.encode(items));
    const response = Tlv8.decode(responseBytes);
    const error = response.get(Tlv8.TYPE_ERROR);
    if (error !== undefined) {
      throw new Error(`${path} returned a pairing error (${PairSetupClient.byteValue(error, 'error')}).`);
    }
    return response;
  }

  static required(values: Map<number, Uint8Array>, type: number, label: string): Uint8Array {
    const value = values.get(type);
    if (value === undefined || value.length === 0) {
      throw new Error(`AirPlay ${label} is missing or empty.`);
    }
    return value;
  }

  static requireState(values: Map<number, Uint8Array>, expected: number, label: string): void {
    const state = PairSetupClient.required(values, Tlv8.TYPE_STATE, `${label} state`);
    if (state.length !== 1 || state[0] !== expected) {
      throw new Error(`AirPlay ${label} returned an unexpected state.`);
    }
  }

  private static byteValue(value: Uint8Array, label: string): number {
    if (value.length !== 1) {
      throw new Error(`AirPlay pairing ${label} field must contain one byte.`);
    }
    return value[0];
  }

  static ascii(value: string): Uint8Array {
    const output = new Uint8Array(value.length);
    for (let index = 0; index < value.length; index++) {
      const code = value.charCodeAt(index);
      if (code > 0x7F) {
        throw new Error('AirPlay pairing identifiers and labels must be ASCII.');
      }
      output[index] = code;
    }
    return output;
  }

  static decodeIdentifier(value: Uint8Array): string {
    let output = '';
    for (const byte of value) {
      if (byte < 0x20 || byte > 0x7E) {
        throw new Error('AirPlay accessory identifier contains unsupported bytes.');
      }
      output += String.fromCharCode(byte);
    }
    return output;
  }
}

export class PairVerifyClient {
  private readonly identityStore: HarmonyControllerIdentityStore;
  private readonly transport: TlvTransport;
  private readonly log: (message: string) => void;

  constructor(
    identityStore: HarmonyControllerIdentityStore,
    transport: TlvTransport,
    log: (message: string) => void
  ) {
    this.identityStore = identityStore;
    this.transport = transport;
    this.log = log;
  }

  async run(receiver: ReceiverIdentity): Promise<AirPlayControlKeys> {
    if (receiver.publicKey.length !== 32 || receiver.pairingId.length === 0) {
      throw new Error('A verified accessory identity is required for AirPlay pair-verify.');
    }
    const ephemeral = await HarmonyAirPlayCrypto.generateX25519Ephemeral();
    const firstResponse = await this.exchange('/pair-verify', [
      { type: Tlv8.TYPE_STATE, value: new Uint8Array([1]) },
      { type: Tlv8.TYPE_PUBLIC_KEY, value: ephemeral.publicKey }
    ]);
    PairSetupClient.requireState(firstResponse, 2, 'pair-verify M2');
    const receiverEphemeral = PairSetupClient.required(
      firstResponse,
      Tlv8.TYPE_PUBLIC_KEY,
      'pair-verify M2 ephemeral public key'
    );
    const encryptedAccessoryProof = PairSetupClient.required(
      firstResponse,
      Tlv8.TYPE_ENCRYPTED_DATA,
      'pair-verify M2 encrypted accessory proof'
    );
    const sharedSecret = await HarmonyAirPlayCrypto.x25519Shared(ephemeral.privateKey, receiverEphemeral);
    const encryptionKey = await HarmonyAirPlayCrypto.hkdfSha512(
      sharedSecret,
      PairSetupClient.ascii('Pair-Verify-Encrypt-Salt'),
      PairSetupClient.ascii('Pair-Verify-Encrypt-Info')
    );
    const accessoryProof = Tlv8.decode(await HarmonyAirPlayCrypto.chachaOpen(
      encryptionKey,
      HarmonyAirPlayCrypto.nonceLabel('PV-Msg02'),
      encryptedAccessoryProof
    ));
    const receiverId = PairSetupClient.required(
      accessoryProof,
      Tlv8.TYPE_IDENTIFIER,
      'pair-verify M2 accessory identifier'
    );
    const receiverSignature = PairSetupClient.required(
      accessoryProof,
      Tlv8.TYPE_SIGNATURE,
      'pair-verify M2 accessory signature'
    );
    if (PairSetupClient.decodeIdentifier(receiverId) !== receiver.pairingId ||
      !await HarmonyAirPlayCrypto.verifyEd25519(
        receiver.publicKey,
        HarmonyAirPlayCrypto.concat(receiverEphemeral, receiverId, ephemeral.publicKey),
        receiverSignature
      )) {
      throw new Error('AirPlay pair-verify accessory identity verification failed.');
    }

    const controller: ControllerIdentity = await this.identityStore.getIdentity();
    const identifier = PairSetupClient.ascii(controller.pairingId);
    const controllerSignature = await this.identityStore.sign(HarmonyAirPlayCrypto.concat(
      ephemeral.publicKey,
      identifier,
      receiverEphemeral
    ));
    const encryptedControllerProof = await HarmonyAirPlayCrypto.chachaSeal(
      encryptionKey,
      HarmonyAirPlayCrypto.nonceLabel('PV-Msg03'),
      Tlv8.encode([
        { type: Tlv8.TYPE_IDENTIFIER, value: identifier },
        { type: Tlv8.TYPE_SIGNATURE, value: controllerSignature }
      ])
    );
    const secondResponse = await this.exchange('/pair-verify', [
      { type: Tlv8.TYPE_STATE, value: new Uint8Array([3]) },
      { type: Tlv8.TYPE_ENCRYPTED_DATA, value: encryptedControllerProof }
    ]);
    PairSetupClient.requireState(secondResponse, 4, 'pair-verify M4');
    this.log('AirPlay pair-verify completed; encrypted control keys are ready.');
    return {
      sharedSecret,
      phoneWriteKey: await HarmonyAirPlayCrypto.hkdfSha512(
        sharedSecret,
        PairSetupClient.ascii('Control-Salt'),
        PairSetupClient.ascii('Control-Write-Encryption-Key')
      ),
      phoneReadKey: await HarmonyAirPlayCrypto.hkdfSha512(
        sharedSecret,
        PairSetupClient.ascii('Control-Salt'),
        PairSetupClient.ascii('Control-Read-Encryption-Key')
      )
    };
  }

  private async exchange(path: string, items: Tlv8Item[]): Promise<Map<number, Uint8Array>> {
    const responseBytes = await this.transport.exchange(path, Tlv8.encode(items));
    const response = Tlv8.decode(responseBytes);
    const error = response.get(Tlv8.TYPE_ERROR);
    if (error !== undefined) {
      throw new Error(`${path} returned a pairing error (${error.length === 1 ? error[0] : 'invalid'}).`);
    }
    return response;
  }
}
