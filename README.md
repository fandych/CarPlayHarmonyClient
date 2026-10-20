# HarmonyOS API 26 CarPlay sender

An experimental HarmonyOS application that implements parts of a wireless CarPlay sender control path, using the local `cardeck-main` project as a behavior reference. This is not an Apple- or vehicle-manufacturer-certified product.

## Current implementation

- Bluetooth Classic SPP/RFCOMM listener using the iAP2 sender service UUID.
- iAP2 link and CSM frame encoders/stream decoders, fresh SYN/SYN-ACK sequence numbers, pure-SYN-only replies, control-session selection from the synchronization descriptor kind, identification response, a strict MFi X.509 chain/challenge-signature verification path, and Wi-Fi credential parsing.
- Wi-Fi candidate configuration with system user confirmation.
- `_carplay-ctrl._tcp` mDNS advertisement and a small HTTP responder for vehicle invitations.
- `_airplay._tcp` discovery and an RTSP `OPTIONS` reachability probe after a vehicle invitation.
- AirPlay TLV8/binary-plist parsing, SRP-6a Pair-Setup, Ed25519/X25519 Pair-Verify, HKDF-SHA512, ChaCha20-Poly1305, and an encrypted persistent RTSP control channel. Peer signatures are checked against the mDNS public key.
- After verified Pair-Verify: initial RTSP `SETUP`, resource claim, screen/audio stream `SETUP`, `RECORD`, timing NTP responses, UDP and RTSP feedback keepalives, and an encrypted event channel with RTSP request/response framing.
- First-run safety disclaimer and persistent local settings (device identity, default SSID, AirPlay controller key, app shortcuts, and the selected background-photo URI); Wi-Fi passwords are not persisted.
- Common-map package discovery (CarDeck's Gaode/Baidu/Tencent candidates) plus manual bundle-name shortcuts; launch remains on the phone. User-authorized playback capture can feed a negotiated PCM RTP stream, and the system photo picker provides a local background preview.
- Protocol tests for chunked iAP2 parsing, checksums, SYN/SYN-ACK/identification sequence progression, AirPlay SETUP/RECORD plist payloads, timing packets, event RTSP framing, TLV8, binary plist, SRP arithmetic, cryptographic round-trips, encrypted RTSP frames, and RTP headers.

The current screen path negotiates the type-110 stream, connects its TCP data port, and sends screen keepalive headers, but has no H.264 encoder or screen source attached and does not send video frames. PCM capture/transport works only when the receiver advertises the supported type-100 `media` format and the user grants capture; AAC and vehicle interoperability are unverified. The background photo is shown locally and its system-picker URI is stored, not sent to the car. Common map discovery is a fixed list plus manual package entry, not full installed-app enumeration; shortcuts launch on the phone.

The MFi challenge response is accepted only after X.509 chain validation against the platform system trust store, certificate validity checks, and cryptographic challenge-signature verification. Diagnostics distinguish payload-format/X.509 parsing failures from PKIX chain failures and signature failures; they log only the payload size, a short header prefix, and a SHA-256 fingerprint, not the certificate body. This path builds but has not been verified against a real receiver certificate. If the device lacks an applicable MFi trust anchor or the certificate format/algorithm is unsupported, iAP2 stops without sending authentication-success or bypassing validation. AirPlay Pair-Setup/Verify remains a separate user-triggered path.

## Remaining gaps

This project is not yet an end-to-end CarPlay projection sender. It does not encode or send H.264 video, and its event channel only logs receiver requests; it does not implement the complete HID/touch return path. PCM audio forwarding is conditional on receiver format support and capture authorization. RTSP session negotiation or an open data port is not proof that a screen is being projected.

### API 26 parity boundaries

| CardDeck feature | HarmonyOS API 26 status |
| --- | --- |
| Bluetooth SPP/RFCOMM and mDNS | Public SDK interfaces exist; implemented control-path prototype, physical interoperability unverified. |
| Wi-Fi candidate join | Public user-action flow exists; implemented; system confirmation required. |
| Playback audio capture | User-authorized PCM capture can feed an AirPlay type-100 RTP/ChaCha stream when `/info` advertises supported PCM `media` audio. AAC and real receiver playback remain unverified. |
| Installed-app launcher | Four common map bundle names are probed and users can enter others; ordinary apps cannot enumerate every installed app. Launch is on the phone only. |
| Trusted virtual displays / launch on a virtual display | `ACCESS_VIRTUAL_SCREEN` is `system_basic`; ordinary apps cannot request it. Settings can check whether the current HAP token has the permission, but this does not create a virtual screen. |
| User-authorized screen recording | API 26 `AVScreenCaptureRecorder` can record a user-selected screen/window to a file descriptor. It does not expose a live H.264 frame/surface stream for AirPlay; recording and later reading an MP4 is not real-time projection. |
| Global screen capture / privileged capture | Direct `CAPTURE_SCREEN` is `system_core`; ordinary apps cannot request it. This remains distinct from the user-selected file recorder above. |
| Global media-session metadata | Listing other apps' AV sessions requires system-level `MANAGE_MEDIA_RESOURCES[_FOR_PUBLIC]`. |
| Cross-app touch injection / Shizuku shell | No public API 26 equivalent is available to this ordinary application. |

The AirPlay controller's persistent identity private key is stored in app-private preferences and system application backup/restore is disabled to prevent copying that identity to another device. Unsupported features are surfaced as gaps, not simulated. Vehicle compatibility and the system permission behavior must still be validated on physical hardware.

## Build

The target and compatible SDK are configured as `26.0.0`. In DevEco Studio, build the `default` product for the `entry` module. On the current Windows development setup, the equivalent command is:

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap -p product=default -p module=entry -p mode=debug
```

The resulting HAP is under `entry\build\default\outputs\default\`.

## Test setup

1. Pair the phone with the vehicle in HarmonyOS Bluetooth settings before starting the app.
2. Start **启动蓝牙监听** and grant Bluetooth permission when prompted.
3. After the car connects, the log should show the negotiated control session and `已发送 iAP2 IDENTIFICATION_START`. If no `0x1D01` follows within 8 seconds, the app logs an identification timeout; this points to a remaining vehicle/link negotiation issue rather than a completed CarPlay session.
4. If the vehicle needs the phone's actual Bluetooth MAC in iAP2 or the control-service TXT record, enter it in **发送端身份**. HarmonyOS does not expose a universally usable local Bluetooth MAC to an ordinary application; the default placeholder may be rejected by a vehicle.
5. When the iAP2 exchange supplies a hotspot configuration, confirm the SSID and password and tap **加入车机热点**. The current version also permits manual SSID/password entry. Joining uses HarmonyOS's user-action Wi-Fi flow.
6. Complete AirPlay Pair-Setup/Verify, then tap **建立 RTSP 媒体会话**. A real Bluetooth device address and an `/info` display UUID are required. The screen stream currently sends keepalive headers only; no H.264 frames are available.
7. Keep the app in the foreground while validating. Check the session log for the vehicle's control invitation, discovered AirPlay endpoint, RTSP SETUP/RECORD, and event/timing status.
8. In **应用**, common map packages are probed automatically; add other packages manually. Shortcuts launch on the phone only. In **设置**, playback capture needs system authorization; when a compatible PCM stream was negotiated, captured media is sent to that receiver stream.
9. In **设置**, select a background image to save its picker URI and preview it locally. Use **检测系统授权** to check whether the installed HAP token has `ACCESS_VIRTUAL_SCREEN`; this ordinary HAP cannot request it.

Do not test while driving. A successful HAP build, Bluetooth connection, mDNS result, or RTSP response is not proof of CarPlay compatibility; validate on a stationary vehicle and keep the vehicle's normal navigation as a fallback.
