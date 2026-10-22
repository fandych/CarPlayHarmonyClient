# HarmonyOS API 26 CarPlay sender

An experimental HarmonyOS application that implements parts of a wireless CarPlay sender control path, using the local `cardeck-main` project as a behavior reference. This is not an Apple- or vehicle-manufacturer-certified product.

## Current implementation

- Bluetooth Classic SPP/RFCOMM listener using the iAP2 sender service UUID.
- iAP2 link and CSM frame encoders/stream decoders, fresh SYN/SYN-ACK sequence numbers, pure-SYN-only replies, control-session selection from the synchronization descriptor kind, identification response, system-PKIX or explicitly user-pinned MFi certificate validation with mandatory challenge-signature verification, and Wi-Fi credential parsing.
- Wi-Fi candidate configuration with system user confirmation.
- `_carplay-ctrl._tcp` mDNS advertisement and a small HTTP responder for vehicle invitations.
- `_airplay._tcp` discovery and an RTSP `OPTIONS` reachability probe after a vehicle invitation.
- AirPlay TLV8/binary-plist parsing, SRP-6a Pair-Setup, Ed25519/X25519 Pair-Verify, HKDF-SHA512, ChaCha20-Poly1305, and an encrypted persistent RTSP control channel. Peer signatures are checked against the mDNS public key.
- One-switch session orchestration: start iAP2, verify MFi, automatically request the HarmonyOS-confirmed Wi-Fi join, advertise/discover the control and AirPlay services, wait for the vehicle invitation, then automatically Pair-Setup/Verify and start RTSP.
- After verified Pair-Verify: initial RTSP `SETUP`, resource claim, screen/audio stream `SETUP`, `RECORD`, timing NTP responses, UDP and RTSP feedback keepalives, and an encrypted event channel with RTSP request/response framing.
- First-run safety disclaimer and persistent local settings (device identity, default SSID, AirPlay controller key, app shortcuts, and the selected background-photo URI); Wi-Fi passwords are not persisted.
- Common-map package discovery plus manual bundle-name shortcuts; when a privileged virtual display is active, shortcuts launch there, otherwise they launch on the phone. User-authorized playback capture can feed a negotiated PCM RTP stream.
- Compact connection home with one CarPlay switch and a chronological, bounded, scrollable log; Apps and Settings remain secondary pages.
- Protocol tests for chunked iAP2 parsing, checksums, SYN/SYN-ACK/identification sequence progression, AirPlay SETUP/RECORD plist payloads, timing packets, event RTSP framing, bounded chronological logs, TLV8, binary plist, SRP arithmetic, cryptographic round-trips, encrypted RTSP frames, and RTP headers.

The privileged projection path now creates a native H.264 encoder surface, binds a Harmony virtual display to it, starts selected UIAbilities on that display, and sends encoded frames through the AirPlay type-110 stream with config, encryption, and key-frame handling. The `privileged` product is a build candidate only: both configured products still use the repository's local signing configuration, so the device will grant no system-only permissions until the OEM/system-authorized signing profile and permission allowlist are applied. The normal product continues to fall back to phone-side launching. Runtime video and virtual-display interoperability are not yet validated on the target vehicle. The selected photo is rendered by the projected CarPlay home ability. Installed-app enumeration is not available through the public API path used by this HAP; common map candidates and manual bundle entry remain the supported discovery paths. Playback audio remains user-authorized and manually started; only negotiated PCM RTP is implemented. API 26 `inputEventClient.TouchController` supports a target display ID when `ohos.permission.CONTROL_DEVICE` is granted; AirPlay HID event routing is not yet wired to it.

The MFi challenge response is accepted after either X.509 chain validation against the platform system CA or explicit first-use user pinning, followed by cryptographic challenge-signature verification. If system PKIX fails because the chain is untrusted/incomplete, an extension is unsupported, or digitalSignature KeyUsage is not accepted, the app asks the user to review the leaf certificate's subject, issuer, full SHA-256 fingerprint, and PKIX failure. Approval stores only that exact leaf fingerprint in app Preferences; it does not modify the HarmonyOS system trust store. For an explicitly pinned leaf, the app checks its validity dates directly rather than asking system PKIX to enforce the chain, KeyUsage, or unknown-critical-extension policy. The accessory must still prove possession of the leaf private key by signing the iAP2 challenge on every connection. A new pin is persisted only after that signature succeeds. Expired/not-yet-valid certificates, unsupported certificate/key formats, rejected prompts, failed challenge signatures, and pin-storage failures fail closed. A pin is not Apple/MFi official validation; it can be revoked in **Settings → 会话与显示**. The iAP2 certificate parameter supports raw DER/PEM chains and PKCS#7/CMS SignedData via the API 26 CMS parser; embedded certificates remain untrusted chain-building material unless the user explicitly pins the exact leaf. The ASN.1 fallback extracts certificates from the CMS certificate set when the platform `getCerts(ALL_CERTS)` path is incomplete. Diagnostics distinguish CMS/X.509 parsing failures from PKIX chain failures and challenge-signature failures; they log only payload size, a short header prefix, and a SHA-256 fingerprint, not certificate contents.

If PKIX reports a missing intermediate issuer, **Settings → 会话与显示 → MFi 中间证书 AIA 下载** is an explicit opt-in (off by default). It permits the system validator to fetch an intermediate from the AIA URL embedded in the accessory certificate over HTTP. Downloaded certificates remain untrusted chain-building material; the path must still terminate at the device's system CA. Enable only for a receiver you trust.

On the currently tested receiver, the PKCS#7 CMS contains one Apple Accessories leaf certificate with issuer `Apple Accessories Certification Authority - 00000002`, but that leaf has no AIA issuer URL. Consequently the device reports `unable to get local issuer certificate`; enabling AIA cannot fix this certificate. The first-use fingerprint prompt allows a user to make an informed, explicit decision for that receiver without pretending the certificate is system/MFi-verified. Matching the text in the issuer/subject field is never used as authentication.

## Remaining gaps

The video pipeline and secondary-display launcher are implemented but have not passed hardware validation; a successful build or RTSP `RECORD` is not proof that the vehicle is displaying decoded frames. The event channel currently handles receiver key-frame requests but not the complete HID/touch return path. Audio forwarding is PCM-only, depends on receiver format support and user capture authorization, and is not yet verified with a vehicle.

### API 26 parity boundaries

| CardDeck feature | HarmonyOS API 26 status |
| --- | --- |
| Bluetooth SPP/RFCOMM and mDNS | Public SDK interfaces exist; implemented control-path prototype, physical interoperability unverified. |
| Wi-Fi candidate join | Public user-action flow exists; implemented; system confirmation required. |
| Playback audio capture | User-authorized PCM capture can feed an AirPlay type-100 RTP/ChaCha stream when `/info` advertises supported PCM `media` audio. AAC and real receiver playback remain unverified. |
| Installed-app launcher | Manual favorites and common map shortcuts are supported. Full installed-app enumeration is not used because the API requires an enterprise permission unavailable in this deployment. Launch targets the active CarPlay display only when the system grants virtual-screen access, otherwise the phone. |
| Virtual display and projected app launch | Uses `display.createVirtualScreen` and `StartOptions.displayId`; both require `ACCESS_VIRTUAL_SCREEN` authorization. The code is capability-gated and needs OEM/system signing and allowlisting on the target device. |
| Live H.264 projection | Uses the API 26 native VideoEncoder input surface as the virtual-display output; encoded buffers feed the encrypted type-110 screen stream. The direct path does not use the file-only `AVScreenCaptureRecorder`; device/receiver interoperability remains unverified. |
| Global screen capture | `CAPTURE_SCREEN` is `system_core` and is not used by this virtual-display path. Capturing arbitrary existing displays remains a separate privileged capability. |
| Global media-session metadata | Listing other apps' AV sessions requires system-level `MANAGE_MEDIA_RESOURCES[_FOR_PUBLIC]`. |
| Cross-app touch injection | API 26 `inputEventClient.TouchController` accepts a target `displayId` and requires `ohos.permission.CONTROL_DEVICE`. The manifest requests/probes it; `INPUT_MONITORING` and `INTERCEPT_INPUT_EVENT` only monitor/intercept and do not replace it. AirPlay HID event routing is not yet wired to the touch controller. |

The AirPlay controller's persistent identity private key is stored in app-private preferences and system application backup/restore is disabled to prevent copying that identity to another device. Unsupported features are surfaced as gaps, not simulated. Vehicle compatibility and the system permission behavior must still be validated on physical hardware.

## Build

The target and compatible SDK are configured as `26.0.0`. The `default` product keeps the normal HAP path; `privileged` builds the same native/video capability candidate with system-permission checks. A product name does not grant privileges: the OEM/system-authorized signing profile and allowlist must be supplied outside the repository and used to sign the privileged HAP.

Build the ordinary product:

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap -p product=default -p module=entry -p mode=debug
```

Build the privileged candidate:

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' assembleHap -p product=privileged -p module=entry -p mode=debug
```

The resulting HAP is under `entry\build\default\outputs\default\`.

## Test setup

1. Pair the phone with the vehicle in HarmonyOS Bluetooth settings before starting.
2. Turn on the **CarPlay** switch and grant Bluetooth permission when prompted.
3. The log should show the iAP2 control session and `IDENTIFICATION_START`. If system PKIX cannot build the MFi issuer chain, review the displayed certificate identity and full fingerprint; only approve if you intentionally trust that exact receiver. The challenge signature must still validate before credentials are accepted or a new pin is saved.
4. When iAP2 supplies the car hotspot, approve HarmonyOS's Wi-Fi candidate prompt. Cancelling it stops this connection attempt; it does not bypass the system confirmation.
5. Keep the app in the foreground. After the car's `_carplay-ctrl._tcp` invitation and AirPlay service are both seen, pairing and RTSP SETUP/RECORD run automatically. With the OEM-authorized privileged HAP, a virtual display should be created and H.264 frames should appear in the log; otherwise the app reports the missing capability and keeps the control session separate.
6. Turn off the switch to stop Bluetooth, discovery, advertisement, AirPlay sockets, media timers, and authorized audio capture.
7. In **设置**, use the MFi AIA intermediate option only for a receiver you trust; it is off by default, and downloaded intermediates still require a system-CA trust anchor. Manual Wi-Fi join remains a recovery option after MFi authentication.
8. In **应用**, common map packages are probed automatically and other bundles can be entered manually. While a virtual display is active, launch buttons target that display; the projected home uses the saved background URI. Without the system permission, buttons continue to open apps on the phone.

Do not test while driving. A successful HAP build, Bluetooth connection, mDNS result, or RTSP response is not proof of CarPlay compatibility; validate on a stationary vehicle and keep the vehicle's normal navigation as a fallback.
