# CarDeck 鸿蒙移植方案

## 结论与目标

目标是在鸿蒙设备上复用 CarDeck 现有的无线 CarPlay 发送端协议，让车机继续按现有方式完成蓝牙 iAP2、Wi‑Fi、mDNS、AirPlay 控制/事件、视频和音频接收；平台侧改用鸿蒙的虚拟屏与媒体编码能力，并把车机触摸注入到指定屏幕。

**完整功能的首选交付形态是系统/特权应用，或由设备厂商集成进系统镜像的应用。** 当前本地 SDK 的虚拟屏 API 要求 `ohos.permission.ACCESS_VIRTUAL_SCREEN`；在支持触摸模拟控制器的目标类型上，该能力还要求 `ohos.permission.CONTROL_DEVICE`。但 SDK API 26 已明确标记 phone 目标不支持触摸控制器，故 phone 版本不声明或探测 `CONTROL_DEVICE`。这些系统能力受权限与产品能力控制，普通应用不能假设能通过运行时弹窗获得。虽然受限权限 ACL 可用于调试签名，但官方说明这类调试配置不能直接用于应用市场发布。

因此先做能力 POC，再决定平台分支：

| 目标形态 | 可行性判断 | 能力边界 |
|---|---|---|
| 厂商/系统签名应用，权限与 API 已开放 | **推荐，完整功能有条件可行** | 可验证虚拟屏、目标 Ability 启动、触摸注入和音视频采集的完整链路；仍需按具体 HarmonyOS 设备验证 |
| 普通第三方应用 | **不能承诺完整移植** | 可尝试协议与网络层，但不能依赖其创建虚拟屏或向屏幕注入任意触摸；仅能可靠展示应用自有 UI，无法等价替代 Android 的 Shizuku 路径 |
| OpenHarmony 自有系统镜像/开发板 | **可控性最高** | 可将所需服务/API/权限纳入系统集成；要维护设备级适配及系统版本兼容 |

调研依据是 OpenHarmony 官方当前文档和源码。HarmonyOS NEXT 的 SDK、签名权限与产品 API 不应假定和 OpenHarmony 一致；启动项目时需先指定目标设备、系统版本、SDK/API 版本及签名来源。

## 当前实现状态

当前工程仍处于传输层 POC 阶段，不是完整可用的 CarPlay 客户端：

- 主页已拆分为 CarPlay 标题、状态、记住开启意图的开关，以及主题/设置/日志/关于四个入口。只连接用户选择的已配对设备；同时支持主动连接车机 `…caff` 服务和监听手机 `…cafe` 服务等待 DiPlay 回连，首个有效连接接管会话，取消后的迟到 socket 会关闭。状态仍区分蓝牙通道和真正投屏，失败保留系统错误码。
- 日志在 Ability 初始化时持久化，UI 仅缓存最近 250 条，文件保留最近 10 次完整会话；可导出当前或历史会话的一致快照。密码、密钥、地址及已注册的设备标识会脱敏，不记录媒体内容；持久化或导出失败有显式提示。开发工具入口为 `tools/Export-CarPlayLogs.ps1`，受调试包沙箱访问权限约束。
- iAP2 会话会解析车机 `0x1D01` 声明的收发消息列表，仅在清单不排除时请求旧版 `0x5702/0x5703` Wi-Fi 配置；对 `0x6800 StartHID` 会回 `0x6801`。MFi 挑战按接收端类型尝试 20/32/16 或 32/20/16 字节，并在拒绝/超时后切换长度。已接入系统身份读取结果：合法地址用于新版 `0x4300` 和收到 `0x4301` 后的 `0x4E0E`，地址不可用则明确阻塞，绝不伪造。
- 新增 Binary Plist 解析器和 RTSP 响应分帧器；发现 AirPlay 端点后会发起一次 `/info` 能力查询。该查询只是连通性/协议探测，不代表建立 CarPlay 媒体会话。
- `_airplay._tcp` 解析现保留 TXT `features` 位图并识别 HomeKit 配对能力 bit 38；TXT 缺失、重复或格式异常时标记为未知，避免错误降级为“不支持”。RTSP HomeKit 配对只由收到车机邀请后触发，不因单纯发现 AirPlay 服务而自动启动。
- AirPlay 配对现有 SRP-6a、HomeKit pair-setup M1/M3/M5、pair-verify、HUKS Ed25519 控制器身份及持久 RTSP 连接传输实现。配件公钥/ID 会按端点地址保存，并由 HUKS 控制器身份签名校验；已有记录时走 pair-verify 快路径。pair-verify 后会在同一 RTSP 连接启用控制加密；普通 `pairAndVerify` 仍会在返回配对结果后关闭连接，媒体流程则使用可管理的 verified-session 保留连接。普通 phone 应用当前无法自动读取真实蓝牙地址；仅在用户配置本人真实地址后才可发布邀请服务，尚未用真车验证该路径。
- 已加入严格 TLV8 编解码，包含 255 字节分片合并、重复字段分隔和截断输入拒绝，并接入 pair-setup/pair-verify 状态机。SRP、TLV 和配对目前只有协议/构建测试，HUKS 运行行为与真实接收端密钥编码仍需真机验证。
- 新增 `_carplay-ctrl._tcp` mDNS/TCP 邀请服务与 `/ctrl-int/1/connect` HTTP 请求处理；TXT `id` 只接受合法的蓝牙地址。`ConfiguredBluetoothIdentityProvider` 优先调用带权限检查的系统 provider，无法读取时才使用用户保存的本人手机真实地址；拒绝零值、占位值和会话中途身份变化。手动来源会明确记录，不能宣称普通应用已自动核验地址所有权。
- 车机 Wi-Fi 绑定不再直接使用 `getDefaultNet()`：等待目标 SSID 关联、唯一 WLAN 句柄和接口地址，绑定后再次核验；多 WLAN 无法唯一确认时拒绝猜测。停止时等待在途操作结束，分别清理候选配置、恢复原应用网络绑定并报告错误。
- 新增媒体 wire codec：H.264 Annex-B/长度前缀 NAL 归一化、avcC 配置、128 字节屏幕流配置/帧/keepalive 封装、帧 ChaCha AAD/nonce，以及大端 PCM RTP/ChaCha 封包；有协议单测。视频流密钥按 `DataStream-Salt<streamConnectionID>` / `DataStream-Output-Encryption-Key` 从 pair-verify shared secret 派生，只在内存使用并在会话关闭时清零。收到车机邀请后，通过同一加密 RTSP 连接执行 `/info`、初始 SETUP、屏幕 SETUP、视频 TCP 数据口连接和 RECORD；维持 RTSP feedback 与视频数据口 keep-alive，视频数据口发送串行化以避免并发帧/心跳交错。初始 SETUP 返回事件端口时，按方向派生 HomeKit Events 密钥并连接 TCP 事件通道，分帧解析请求/应答，只确认请求（回显合法 CSeq）；事件命令目前仅确认，不处理触摸/HID 或 CarPlay 控制语义。新增 NAPI 屏幕采集模块，使用系统 `OH_AVScreenCapture` 的 H.264 编码输出；用户需主动点击“开始投屏”并通过系统屏幕采集授权，界面提示会采集当前显示器上其他应用可见内容且可随时停止。采集缓冲区队列有界，溢出会显式终止投屏；处理 codec data、分片和 Annex-B/长度前缀 NAL 后发送加密帧，只有首帧成功发送后状态才进入“投屏中”。采集授权、设备编码回调格式、车机解码和实机画面仍未验收，不能据 HAP 构建或协议测试宣称已经可正常投屏。
- 已补充 `0x4301 CarPlayStartSession` 解析：提取 AirPlay IP/端口和新协议无线组中的 Wi-Fi 参数；收到热点参数后加入 Wi-Fi，绑定成功后可用 iAP2 端点或 mDNS 端点探测 RTSP。
- `GET_NETWORK_INFO` 已加入权限声明和运行时权限请求。此前的普通签名 HAP 已安装并在 PLR-AL00 启动，真机确认单开关、状态和滚动日志页面正常显示；早期探测显示虚拟屏能力未授予，且 phone 目标不支持触摸控制器。曾用本机签名材料和 ACL profile 验证 HAP 代码签名及权限签名，但设备拒绝安装该包（错误 `9568322`：应用来源不受信任），因此尚未验证 ACL 权限是否授予；本地签名材料现已从工作树移除。
- 历史 `phoneDebug` 构建和权限签名验证不代表当前配置。本轮读取的产品为 `default`，使用既有 `localCerts` 签名；未修改用户签名配置或凭据。核验现有 profile 的 APL 为 `normal`，应用特征为 `hos_normal_app`，ACL 不含 `GET_BLUETOOTH_LOCAL_MAC`。
- 当前模块目标类型为 `phone`。本轮不依赖独立虚拟屏；已移除无用途且影响普通安装的 `ACCESS_VIRTUAL_SCREEN` 请求和创建探测。未声明 `CONTROL_DEVICE`。本轮 default HAP 已成功覆盖安装并启动；设备重连后的实际身份检测日志明确报告 `GET_BLUETOOTH_LOCAL_MAC` 未授予，未取得真实地址。HDC 系统参数返回 `OpenHarmony-7.0.0.105`，不将历史系统版本记录当作本轮结果。
- 真机蓝牙探测已运行：系统报告 9 个已配对设备，但均未建立 iAP2 RFCOMM 连接；当前未连接 CarPlay 车机，因此 iAP2 后续交换、Wi-Fi 入网、mDNS 和 RTSP 均未实测。
- 本机真实蓝牙地址对应系统接口 `access.getLocalAddress()`，不是 Socket 的远端 `getDeviceId()`。公开 SDK 不包含该系统方法的 ArkTS 声明；实现使用有类型声明的小型 JS 兼容边界检测方法是否存在，调用前仍严格核验两项权限，完全保留系统应用身份与权限检查。当前签名不足以自动读取；用户后续明确允许填写本机真实地址作为备用，不再因缺少系统权限而无条件阻断该配置路径。
- AirPlay 屏幕流 `SETUP/RECORD`、视频 TCP 数据口、`DataStream` 输出密钥、事件通道及用户授权的 `OH_AVScreenCapture` 编码采集现已接入控制器生命周期，并区分等待首帧与实际投屏。PLR-AL00 上 Hypium 测试实际运行 3 项并全部通过（Ability 基础测试及设置/Asset 持久化）；这些测试没有覆盖采集授权、编码输出、CarPlay 接收端或画面解码。当前尚未连接车机，故 iAP2、Wi-Fi 入网、mDNS、配对、授权弹窗、首帧发送和真实投屏均未验收；phone 目标也没有虚拟屏画面源或触摸回控。协议协商和测试 HAP 通过不等于真机投屏，不得将当前阶段描述为完整 CarPlay 支持。

## 本机蓝牙身份：接口、权限与使用

- 华为公开文档：[蓝牙 access 模块](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-bluetooth-access)。公开方法列表不能据此推断普通应用能读取本机硬件地址。
- 对应的公开系统接口依据：[OpenHarmony access.getLocalAddress](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-connectivity-kit/js-apis-bluetooth-access-sys.md#accessgetlocaladdress11)。该接口要求 `ACCESS_BLUETOOTH` 与 `GET_BLUETOOTH_LOCAL_MAC`；系统可返回 201（权限不足）、202（非系统应用）、801（不支持）等错误。
- 华为本机 SDK 的 `toolchains/lib/PermissionDefinitions.json` 将 `GET_BLUETOOTH_LOCAL_MAC` 标为 `grantMode=system_grant`、`availableLevel=system_basic`、`availableType=SYSTEM`。权限弹窗不能将普通应用变成系统应用。
- 系统/厂商集成版本需在获得匹配的系统应用身份、设备信任及批准的权限 profile 后，声明 `{"name":"ohos.permission.GET_BLUETOOTH_LOCAL_MAC"}`，并确认实际 token 授权。当前普通 phone 包不默认请求该受限权限，以免破坏现有可安装性；不通过修改本地签名文件或伪造授权解决。
- 在界面点“检测身份”即可单独检查，不必连接车机。结果进入状态卡和完整日志；成功时只显示“身份已读取并校验”，不输出真实地址。
- 实现依次检查授权、蓝牙就绪、系统方法存在性、系统调用结果、MAC 格式与占位值、同一会话身份稳定性。不存在接口、未授权或被系统拒绝均有不同错误；同一身份传入 iAP2 和邀请服务。

## 设置、主题与序列化

- **本机身份**：可保存本人手机的真实蓝牙地址和发送端设备名。系统读取成功时优先使用系统结果；未取得时允许手填。不能填写车机地址、占位地址或假地址。设置中的修改保存后于下次连接生效，连接期间禁止修改连接参数。
- **其他备用信息**：目标已配对接收端、车机 Wi-Fi SSID/安全类型/信道/密码、AirPlay IPv4/IPv6 地址和端口。SSID 或 AirPlay IP 留空即不启用对应备用。完整自动配置始终优先；仅在缺失或协商等待超时后使用备用，不绕过 iAP2、真实邀请或配对。自动密码缺失时只允许为同一 SSID 和安全类型补充密码。
- **开关意图**：保存 `enabled`，与实际会话状态分开。失败不会把偏好自动改为关闭；每次应用启动最多尝试恢复一次，权限/目标/身份缺失时显示阻塞原因，不循环重连或自动弹权限。关闭开关会立即停止会话；停止应用/Ability 不清除已保存的开启意图。
- **主题**：跟随系统、浅色、深色，默认跟随系统。通过应用颜色模式及 base/dark 资源统一应用于所有页面，重启仍保留。
- **存储**：非秘密配置及安全密码引用保存在应用私有 `carplay-settings-v1.json`，写临时文件、刷盘后原子替换。Wi-Fi 密码使用系统 Asset 服务保护并绑定 SSID/安全类型，不放入配置文件、日志或普通 JSON 导出；不回退到明文密码存储。旧版接收端偏好仅在首次迁移时读取。
- **导入/导出**：设置页通过系统文件选择器处理版本化 JSON。导入上限 16 KiB，校验版本、字段集合、UTF-8 字节长度、真实 MAC 格式、IP 字面地址和数值范围。导入无效文件不改原配置；成功导入会关闭开关，只有同一网络才保留本地原密码，新网络需补填。设置文件损坏时可通过“导入配置恢复”显式恢复，不静默替换为默认值，不沿用损坏的密码引用。
- 导出会包含用户配置的设备/网络标识，但不含密码、密码引用、私钥或配对证明；应谨慎分享。密码和系统授权不能靠导入 JSON 获得。

配置 JSON 示例（所有字段均有版本化定义，密码不在此结构中）：

```json
{
  "version": 1,
  "enabled": false,
  "theme": "system",
  "localBluetoothAddress": "",
  "deviceName": "Harmony CarPlay",
  "targetDeviceId": "",
  "targetDeviceName": "",
  "wifi": { "ssid": "", "securityType": 2, "channel": 0 },
  "airplay": { "host": "", "port": 7000 }
}
```

## 本地构建配置与敏感文件

签名私钥、签名材料、本机凭据文档及带本机签名数据的根构建配置不应提交。仓库提供不含签名信息的 `build-profile.example.json5`；首次克隆且本地配置不存在时：

```powershell
if (-not (Test-Path '.\build-profile.json5')) {
  Copy-Item '.\build-profile.example.json5' '.\build-profile.json5'
}
```

随后通过 DevEco Studio 配置本机签名；不要覆盖已有本机配置，也不要提交证书、私钥或密码。忽略文件和后续删除不会清除历史提交中的秘密。若远程历史已包含签名材料，应另行更换凭据并由仓库所有者处理历史；不能未经确认强推。

## 日志导出与开发验证

1. 应用内选择“当前”或历史会话后点“导出”，通过系统文件选择器保存 `.log`。用户取消不会被当作导出成功；导出快照不会截断仍在写入的会话。
2. Windows 开发工具拉取：

   ```powershell
   .\tools\Export-CarPlayLogs.ps1 -OutputDirectory 'C:\CarPlayDiagnostics'
   ```

   可选传入 `-HdcPath`、`-Device`、`-BundleName`。脚本使用 HDC 官方调试包 `shell -b` 挂载，读取已持久化会话的精确字节快照，同时保存 `CarPlayHarmony` 标签当前保留的 hilog 缓冲区。不会声称恢复已经轮转的系统日志；非调试包、沙箱权限不足或设备离线会明确失败。
3. 完整指本应用所有已记录的连接阶段、协议消息类型/长度、错误和生命周期，不等同于全设备日志、原始抓包、配对秘密或屏幕录制。存储错误与进程突然终止可能导致缺失末尾事件，应保留错误提示一起分析。
4. 构建与单元测试使用已安装的 hvigor：

   ```powershell
   hvigorw --mode module -p product=default -p module=entry@default assembleHap
   hvigorw --mode module -p product=default -p module=entry@default -p unitTestMode=true test
   ```

   未配置 PATH 时使用 DevEco Studio 下 `tools\hvigor\bin\hvigorw.bat`，并配置 `DEVECO_SDK_HOME` 与 `JAVA_HOME`。本轮 69 项现有及新增测试通过；新增回归覆盖超 250 条日志、10 会话保留、磁盘/刷盘失败、脱敏、双向竞争/取消、WLAN 唯一性以及系统蓝牙身份授权/错误/协议传递。JS 系统接口兼容边界另验证 4 项分支。开发脚本已在原手机拉取并按字节数核验 10 个会话文件及应用标签 hilog。单元测试使用注入的系统接口，不等于实机获得了系统权限；应用内系统文件保存器的最终保存结果仍需单独确认。本轮在 PLR-AL00 上实际安装并运行 signed `ohosTest` HAP：Hypium 3 项通过、0 失败，覆盖 Ability 基础测试与设置/Asset 持久化；不覆盖 CarPlay 接收端或屏幕采集/编码链路。

## 现有协议基线

协议目标是**不改车机侧线上格式**，仅替换 Android 平台适配：

1. **蓝牙控制面**：RFCOMM 承载 iAP2 链路和 CSM；保留链路序号、ACK/窗口、身份识别、MFi 挑战、热点凭据 `0x5703`、AirPlay 端点 `0x4301`、HID 消息等原有语义。SPP 回调是字节流，收包必须继续使用 iAP2 framing，不能假设一次回调等于一帧。
2. **网络发现与会话**：保留 `_carplay-ctrl._tcp` 发布、`_airplay._tcp` 发现、车机 `/ctrl-int/1/connect` 邀请驱动配对，以及迟到的 `0x4301` 更新端点的状态机。
3. **AirPlay 控制/事件**：复用 RTSP、Binary Plist、SRP/HomeKit 配对、设备身份、事件通道、反馈心跳和 `VirtualIap2Link`。不同车机的 pre-HomeKit、MFi 挑战长度、IPv4/IPv6 地址和第二条 iAP2 隧道行为均保持现有分流，不能简化成单一车型假设。
4. **媒体数据面**：复用 H.264 配置/帧头、128 字节屏幕流头、加密/nonce、数据口心跳；复用 RTP/ChaCha 音频封装及当前 PCM 每包 352 个采样帧、SSRC=0 等已经实测的参数。
5. **HID 输入**：协议侧仍生成与现有触摸/媒体键 HID 报告一致的报文。平台适配层负责把坐标按虚拟屏分辨率、方向及当前布局映射为鸿蒙触摸事件。

协议移植时以仓库实现和 `docs/PROTOCOL-NOTES.md` 为行为基线，特别是 `SessionController` 的连接时序、`Iap2LinkEngine` 的链路协商、`AirPlayClient` 的配对与多通道生命周期、`VirtualIap2Link` 的 MIB3 第二链路。不能只做“字段格式相同”的静态移植：邀请时序、取消、迟到端点、心跳、重连及资源退役也是协议兼容的一部分。

## 鸿蒙 API 能力映射

| CarDeck 现有职责 | 鸿蒙适配方向 | 状态/限制 |
|---|---|---|
| RFCOMM iAP2 | `@kit.ConnectivityKit` Bluetooth Socket 的 SPP/RFCOMM：按 iAP2 SDP 服务 UUID 建连、收发原始字节 | 官方公开 SPP API，需 `ohos.permission.ACCESS_BLUETOOTH`。必须先用目标车机验证服务 UUID、配对状态、收包分片和连接保活 |
| 车机热点 | WLAN candidate network API；尽量使用应用维度候选网络，避免意外改动系统默认网络 | 官方文档支持应用维度候选网络，且可与系统 WLAN 配置隔离；API 需要 `ohos.permission.SET_WIFI_INFO`。WEP 不支持 candidate config，目标设备上的入网、路由及多网络套接字选择需 POC |
| mDNS / Bonjour | `@kit.NetworkKit` mDNS 注册、发现和解析；Socket Kit TCP/UDP | 官方有对应 API。需验证 `_carplay-ctrl._tcp` TXT/端口、服务刷新、绑定目标热点及 IPv6 link-local scope |
| TCP/UDP AirPlay 与媒体流 | `@kit.NetworkKit` Socket Kit；保留 RTSP 控制、事件 TCP、视频 TCP、音频 UDP 的独立连接和读写线程 | 公共网络能力可承载；需要验证切前后台、热点丢失及应用生命周期下连接的保活/恢复 |
| 虚拟屏创建与销毁 | `@ohos.display` `createVirtualScreen` / `destroyVirtualScreen`，屏幕 Surface 绑定到虚拟屏 | 当前 phone 目标被 SDK 标记为 API 不可用；普通签名 HAP 也无法获授 `ACCESS_VIRTUAL_SCREEN` 并被设备拒绝安装。需厂商/系统集成及支持该 API 的设备类型 |
| 在虚拟屏启动 Ability | `UIAbilityContext.startAbility(want, { displayId })` | API 文档提供 `displayId` 选项；这只说明可指定显示屏，不代表普通应用可创建屏、任意第三方 Ability 都支持目标显示屏，也不保证商业 HarmonyOS 设备开放该能力 |
| 触摸回注 | 在支持该 API 的系统/特权目标上，使用 SDK API 26 `@ohos.multimodalInput.inputEventClient` 的 `TouchController.touchDown/touchMove/touchUp`，按 `displayId` 构造触点 | 当前 phone 目标被 SDK 标记为 API 不可用，因此 phone 包不声明 `CONTROL_DEVICE` 或执行触摸探测；其他目标类型需厂商/系统集成后单独验证 |
| H.264 编码 | AVCodec Kit 原生 surface 输入模式，封装为 N-API/ArkTS 可调用的媒体适配器 | 官方提供硬件视频编码 surface 模式；需验证虚拟屏输出 Surface 能否直接连接编码器输入 Surface，无法直连时测量一次 GPU 合成/拷贝的成本 |
| 音频采集与编码 | Harmony 音频采集/编码 API 独立适配 | **待 POC**：确认是否能按现有 Android AudioPlaybackCapture 语义采集其他应用播放音频、授权 UX 与后台限制；不能将麦克风采集等同于系统播放音频采集 |
| 设备身份 | 适配 iAP2/AirPlay 需要的设备名、蓝牙地址及连接端点 | **待 POC/高风险**：Bluetooth Socket 文档说明 `getDeviceId()` 为隐私保护返回虚拟 MAC。不能直接假设它可替代 CarDeck 依赖的真实稳定蓝牙地址；应从目标系统权限/API 与车机侧校验确认 |

目标设备 API 版本为 26。普通签名真机探测显示当前签名未获授 `ACCESS_VIRTUAL_SCREEN`；加入受限权限请求后，普通签名 HAP 安装被系统拒绝。曾用本机 ACL profile 验证签名，但目标设备以“不受信任的应用来源”拒绝安装，因此尚不能宣称真机权限已授予。当前模块目标是 phone，SDK 将虚拟屏和触摸控制器 API 均标记为不可用；应用使用用户授权的当前显示器采集，不依赖虚拟屏，也不声明 `CONTROL_DEVICE`。完整显示/回控能力仍需取得设备可接受的安装/信任路径，并适配支持这些 API 的目标类型。

## 推荐架构

```text
┌──────────────────── HarmonyOS / OpenHarmony ────────────────────┐
│ ArkTS：会话状态机、权限/生命周期、UI、mDNS、Wi-Fi 与 Socket 调度 │
│                                                                  │
│ Protocol Core：iAP2/CSM/TLV、AirPlay/RTSP/bplist、配对、媒体封包 │
│   └─ 优先使用纯数据结构与字节数组；网络/时钟/随机数/加密通过接口注入 │
│                                                                  │
│ Native Adapter（N-API/C++）：密码算法、AVCodec、Surface 与高吞吐收发 │
│                                                                  │
│ Privileged Display/Input Broker（系统签名/厂商集成）             │
│   ├─ 创建并回收虚拟屏；将目标 Ability 启动到 displayId            │
│   ├─ 屏幕输出 Surface → H.264 编码器输入 Surface                  │
│   └─ 触摸坐标换算 → 注入到指定虚拟屏                              │
└──────────────────────────────────────────────────────────────────┘
         │ Bluetooth RFCOMM / Wi‑Fi / mDNS / AirPlay
         ▼
      CarPlay 车机
```

### 模块边界

- **协议核心**：以 ArkTS/TypeScript 实现状态机与 wire 编解码；对高成本密码原语，可封装成可测试的 C++/N-API 模块。不要把 ArkTS、C++ 和 UI 生命周期耦合进 iAP2/AirPlay 状态机。
- **传输抽象**：定义可取消、可关闭的 RFCOMM 字节流、TCP 字节流、UDP 数据报及 mDNS 服务接口。读线程/任务、超时与会话代次必须由统一生命周期管理；取消连接时关闭底层 socket，不能只清 UI 状态。
- **Harmony 协调器**：按照现有 `SessionController` 的事件顺序组织连接，不将平台回调直接改写协议顺序。Wi-Fi 只确认目标 SSID/网络后绑定；mDNS 在可用网络上注册/发现；AirPlay invite 才触发配对。
- **显示/输入代理**：与协议层分进程或至少分模块；仅它持有屏幕创建、Ability 放置和输入注入权限。虚拟屏需有创建—绑定 Surface—启动目标 Ability—输入映射—停止 Ability—销毁屏幕的闭环，异常退出后也要回收系统资源。
- **媒体管线**：优先尝试虚拟屏合成输出直接喂给 AVCodec Surface 编码器，避免 CPU 回读。编码分辨率按 H.264 4:2:0 对齐偶数；在旋转、resize 时同时更新显示尺寸、编码参数、触摸变换及接收端声明。

## 首轮 POC（Go/No-Go 门）

先在**最终目标设备和最终签名类型**上做最小验证。模拟器、开发者签名或 OpenHarmony 开发板通过，不代表商业 HarmonyOS 设备上权限可用。

1. **权限门**：普通签名 HAP 请求 `ACCESS_VIRTUAL_SCREEN` 后安装失败；使用提供的 ACL profile 后，本机验证代码签名和权限签名成功，但 PLR-AL00 仍以不受信任来源拒绝安装。phone 目标上的虚拟屏和触摸控制器 API 均被 SDK 标记为不可用；需先解决安装信任路径，并选择支持这些 API 的目标类型，之后才能验证完整显示链路。
2. **显示门**：创建一块横屏虚拟屏，将一个自有 Ability 指定到该 `displayId`；再启动一个目标第三方应用验证它是否真的绘制在该屏。检查尺寸、密度、方向、焦点、黑屏/息屏、应用退到后台后的存活行为。
3. **编码门**：创建 AVCodec surface 输入，验证虚拟屏最终合成画面能以目标 H.264 profile、分辨率和帧率进入编码器。连续采集至少 10 分钟，检查掉帧、内存/图形资源增长、屏幕 resize 和编码器销毁重建。
4. **输入门**：从指定屏幕注入单指点击、长按、滑动，以及目标应用需要的多指手势；验证事件落到正确 display/window，坐标边缘、旋转和地图屏 resize 均正确。
5. **传输门**：完成 iAP2 RFCOMM 连通性、目标 UUID、Bluetooth 身份字段、热点 candidate config、Socket 路由、mDNS 发布/发现的最小互通。特别检查真实/虚拟 MAC 对 `0x4300/0x4E0E` 与 AirPlay `deviceID` 的影响。
6. **音频门**：确认能采集目标应用播放音频并编码为车机实际协商格式；若只能采集麦克风或仅采集自有应用，产品范围需明确降级。

**Go 条件**：系统权限可在目标设备稳定获得；目标 Ability 能进入虚拟屏；Surface 编码链路可持续运行；触摸注入按屏幕正确命中；iAP2 所需身份和车机 Wi-Fi 网络可用。任一前四项失败，不能宣称达成“鸿蒙自建虚拟屏 + 任意应用投屏 + 车机触摸回控”。

## 实施阶段

### 阶段 A：建立跨平台协议核心

1. 按纯逻辑单元拆分：iAP2 framing/link/CSM、消息 TLV、mDNS/RTSP 消息模型、Binary Plist、配对密钥派生、视频/音频头封装、HID 报告编解码。
2. 创建跨平台 golden vectors：用 Android 现有实现生成固定输入/输出样本，ArkTS/C++ 实现必须逐字节一致；敏感密钥只用于测试向量，不写入日志。
3. 以测试覆盖取消、乱序/迟到消息、重复 SYN、窗口边界、NUL 填充地址、IPv6 link-local、旧版 `et=NONE`、MIB3 隧道及不同 MFi 长度。
4. 维持本仓库 Android 实现为协议参照；除非发现真实互通证据，不在鸿蒙移植中顺手“统一”既有车型差异。

### 阶段 B：鸿蒙传输适配

1. 先打通 RFCOMM 原始双向字节流和 iAP2 链路测试，再接完整 CSM 会话。
2. 接入 mDNS 和 WLAN candidate network；优先保留应用维度隔离连接，并确保所有 AirPlay socket 实际走车机热点网络。
3. 使用循环缓冲处理任意 SPP/TCP 分片；长驻读循环可取消、可通过 socket close 唤醒；控制、事件、视频 TCP 与音频 UDP 分别管理。
4. 记录 Bluetooth peer ID、设备身份、广告 TXT `id`、AirPlay `deviceID` 的取值来源。真实 MAC 不可用时，不要静默以虚拟地址冒充；先用 DiPlay/WinPlay 和一台目标真车验证兼容。

### 阶段 C：系统显示/输入/媒体代理

1. 由系统签名代理创建虚拟屏，尺寸与密度沿用 CarDeck 的画布比例；虚拟屏独立资源要保存 owner/session ID，防止会话异常退出后孤儿屏残留。
2. 通过 `StartOptions.displayId` 启动测试应用并验证多 Ability 切换、回到桌面、地图屏 resize。只有自有 UI 可行时，不能把该阶段标成第三方应用支持。
3. 接通虚拟屏输出 Surface 和 AVCodec 输入 Surface；若 API 不允许直接共享 Surface，评估 GPU 合成/拷贝路径并测端到端延迟和功耗后再选。
4. 将车机 HID 坐标按“通告视图 → 流画布 → 目标屏内容”逐层变换，再以指定 screen ID 注入触摸。保持单指/多指状态机与 DOWN/MOVE/UP 配对，取消和断连时释放所有按下状态。
5. 音频采集与视频编码分开验收；连接建立时序仍按“屏幕 SETUP → 数据口 → RECORD → 视频起流 → 音频 SETUP → 补发 RECORD”执行。

### 阶段 D：端到端兼容与发布

1. 先用 DiPlay 做快速回归，再用至少一台 Audi MIB3 真车验证；如声明支持老车，再单独验 pre-HomeKit、IPv6-only 和 AES-128-CTR 连续密钥流。
2. 覆盖车机主动邀请、迟到 `0x4301`、Wi-Fi 切换/断开、蓝牙重连、立即取消、前后台切换、屏幕锁定/熄屏及系统进程被杀后的清理。
3. 逐项验收三类独立保活（UDP keepAlive、RTSP `/feedback`、屏幕数据口 keepAlive），及 MIB3 第二 iAP2 隧道触发点与反向传输方向。
4. 以日志验证设备身份、协商 audioType/采样格式、VideoConfig 头字段、首帧时间、触摸屏幕 ID 和会话 teardown 原因；敏感密钥和配对材料不得落日志。

## 兼容性与风险清单

| 风险 | 影响 | 处理/退出条件 |
|---|---|---|
| phone 上的虚拟屏 API 不可用，且普通签名不能获授 `ACCESS_VIRTUAL_SCREEN` | 普通应用不能自建等价显示；请求权限还会导致 HAP 安装失败 | ACL 签名与权限签名可本地验证，但 PLR-AL00 拒绝该应用来源；仍需解决设备信任，随后还需厂商/系统集成及支持的目标类型 |
| API 26 phone 目标不支持触摸控制器 | phone 版本不能将车机触摸回控到目标显示屏 | phone 包不声明 `CONTROL_DEVICE`，也不执行无效的触摸 API 探测；需在支持该 API 的系统/特权目标上另行验证 |
| HarmonyOS NEXT 与 OpenHarmony API/权限不等价 | 开发板可行但量产机不可用 | 按具体 Harmony 设备和最终签名做 POC；所有系统 API 建 capability adapter |
| Ability 对 displayId 的实际支持存在应用差异 | 屏创建成功但第三方应用仍在主屏或拒绝启动 | 选定导航/媒体/设置等目标应用做逐类测试；记录白名单与不支持应用 |
| Surface 与 AVCodec surface 连接方式未知 | 可能需要额外拷贝，增加延迟/功耗 | POC 先确定 Surface 互通；端到端延迟、帧率和温升未达标即调整架构 |
| WLAN candidate config 的设备实现及绑定行为 | 控制 socket 走错网或网络被系统切换 | 同时验证 SSID、路由、mDNS 可见性、AirPlay TCP/UDP 真实出接口；WEP 为独立回退项 |
| 真实 Bluetooth MAC 不可见/被随机化 | 接收端按 `deviceID` 过滤或 iAP2 身份校验失败 | 取得设备侧合法身份 API或使用厂商接口；不能靠固定假 MAC 掩盖 |
| 播放音频采集权限/后台策略 | 车机无声 | 独立 POC；不可采集其他应用音频时明确不支持系统媒体回传 |
| iAP2/MFi/CarPlay 互通差异 | 某些车机拒绝配对或早拆会话 | 继续按车型能力、挑战记忆、迟到消息和协议笔记分流；以真车日志为依据 |

## 接口与代码落点建议

Android Folder: `C:\Users\fandych\Desktop\cardeck-main`
Android Server(DiPlay) Folder: `C:\Users\fandych\Desktop\DiPlay-main`

建议先不改 Android 目录结构；鸿蒙项目单独建仓或独立模块，避免把 ArkTS/原生 ABI 依赖混入 Android 构建。

| 新模块 | CarDeck 参照 |
|---|---|
| `protocol/iap2` | `iap2/Iap2LinkEngine.kt`、`iap2/Iap2Csm.kt`、`iap2/Iap2SenderSession.kt` |
| `protocol/airplay` | `airplay/AirPlayClient.kt`、`airplay/PairingClients.kt`、`airplay/VirtualIap2Link.kt` |
| `protocol/media` | `video/VideoSender.kt`、`audio/AudioSender.kt` |
| `platform/harmony/bluetooth` | `bt/`、`iap2/` 传输接口 |
| `platform/harmony/network` | `net/` 中 Wi‑Fi、mDNS、Socket 适配 |
| `platform/harmony/display` | `launcher/VirtualLauncher.kt`、`render/DualDisplayComposer.kt` |
| `platform/harmony/input` | `input/TouchRouter.kt`、`shizuku/CarInputServiceImpl.kt` 的平台职责替代 |
| `app/session` | `SessionController.kt` 的生命周期和会话状态机 |

## 官方资料

- [OpenHarmony：虚拟屏开发指引（仅系统应用）](https://github.com/openharmony/docs/blob/master/en/application-dev/displaymanager/virtualScreen-guideline-sys.md)
- [OpenHarmony：Screen System API（创建/绑定/销毁虚拟屏）](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-arkui/js-apis-screen-sys.md)
- [OpenHarmony：受限权限与 ACL](https://github.com/openharmony/docs/blob/master/en/application-dev/security/AccessToken/declare-permissions-in-acl.md)
- [OpenHarmony：Input Event Injection System API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-input-kit/js-apis-inputeventclient-sys.md)
- [OpenHarmony：Bluetooth SPP/RFCOMM 指引](https://github.com/openharmony/docs/blob/master/en/application-dev/connectivity/bluetooth/spp-development-guide.md)
- [OpenHarmony：Bluetooth Socket API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-connectivity-kit/js-apis-bluetooth-socket.md)
- [OpenHarmony：WLAN API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-connectivity-kit/js-apis-wifiManager.md)
- [OpenHarmony：mDNS 指引](https://github.com/openharmony/docs/blob/master/en/application-dev/network/net-mdns.md)
- [OpenHarmony：UIAbilityContext / StartOptions](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-ability-kit/js-apis-inner-application-uiAbilityContext.md)
- [OpenHarmony：AVCodec 视频编码](https://github.com/openharmony/docs/blob/master/en/application-dev/media/avcodec/video-encoding.md)


## Refs

- HARMONY.md