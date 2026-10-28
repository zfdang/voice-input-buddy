# G9N9N 真机调试记录

## 2026-10-28：普通按键独立排查

本轮样机的系统身份为 Google Inc.、VID/PID `18D1:9450`、DIS 型号 `A0`、固件 `26.7`，与下文 10 月 19 日的 A3 / 26.0 样机分开记录。主机为 macOS 15.8.1（24H32），已安装 App 为 26.10.26 / 497。

**当前确认：单键及松开事件没有到达公开 IOHID 回调；双键组合可以到达。尚未抓到 HID 转交之前的蓝牙原始包，不能将“固件发送短包”写成已证实根因。**

### 测试方法和实际结果

先检查 App 日志：输入监控和辅助功能均已授权。既有 Google HID 报告均为两个有效索引的 3 字节报告，后续缺少松开，触发八秒 missing-release 兜底。操作者明确确认这些报告来自按要求进行的双键操作，不能算单键通过。

独立诊断程序起初打开失败，错误为 `kIOReturnExclusiveAccess`；这时 App 持有独占连接，该次无输入不计为测试结果。退出 App 后，独立程序打开成功、匹配设备成功、输入监控授权正常，使用非独占模式同时记录原始 report 和 element value 回调。不运行 App 的解析、映射、按键注入或缺失松开定时器。

| 轮次 | 操作者确认完成的操作 | 独立接口结果 |
| --- | --- | --- |
| 第一轮 | 静置；上键单独短按三次，间隔两秒；按住返回再按上，保持一秒；先松上，两秒后松返回；全松后等十秒 | 仅在组合时收到一次 `01 03 0B`（上＋返回），无单键及松开 report；同时收到上和返回的 element 按下值 |
| 第二轮 | 上键单独保持三秒后松开；等待五秒；上＋返回同时保持三秒后全松开；等待五秒 | 再次只收到组合 `01 03 0B`，无单键及松开 report；并行每 200 ms 主动读取 input report，观察到的读取均为成功但长度为零 |

组合 report 时间分别为 UTC `05:20:24`、`05:22:36`（新加坡时间 13:20:24、13:22:36）。第二次相同组合没有新的 element value 边沿，不能据此声称组合没有到达；原始 report 回调确实再次到达。丢失松开时，系统保留旧的 element 状态，也会影响后续相同值是否产生边沿。

本轮测试结束后停止独立观测及轮询，重新启动原安装路径的 Voice Input Buddy。未替换已安装 App、签名、权限或驱动。

### 描述符及结论边界

系统公开的 report 1 描述符与项目 `indexedConsumerDescriptor` 完全一致：两个 8 位数组索引，加 report ID，共 3 字节；`MaxInputReportSize=3`。索引 `03` 对应上键，`0B` 对应返回键，组合解析正确。

- Apple [IOHIDElementPrivate::processReport 源码](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDElementPrivate.cpp) 对非变长元素检查实际 bit 数是否小于描述符 report 大小；短包可能在这里失去元素／原始报告回调。这与观测相符，但公开源码不等于本机完整二进制调用链的测量。
- 注册表 `IOReportLegend` 中的 **IOHIDDevice Input Report Errors** 是统计通道的名称。Apple [IOHIDDevice::createReporters 源码](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.cpp) 在设备初始化时建立该栏目；栏目存在不是错误计数增加的证据。本轮没有读取到实际错误计数。
- 系统日志确实曾标记 `HIDBadBehavior`，同一次重连也短暂出现 `HIDGoodBehavior`。标签不能独立证明报文长度、具体错误原因或永久黑名单。
- 未获取到丢失报告的实际字节，不能声称单键一定发送 2 字节、松开一定发送 1～2 字节，也不能排除 macOS 蓝牙层转换问题、样机固件行为或连接问题。
- 此次 ATVV 协商日志为 `version=256 codec=2 frame=160`。用户确认语音可用；本轮未重新验收音质、丢包率、长会话或休眠重连，不能泛化为全部通过。

### 公开蓝牙接口与下一步

退出 App 期间，独立 CoreBluetooth 程序通过已连接的 ATVV 服务找到唯一 Chromecast 候选并连接，分别调用 `discoverServices(nil)` 和明确请求 `1812`。两次均成功，但可见服务中没有 HID `1812`；可见 UUID 为：

```text
180A, 180F, 1813
AB5E0001-5A21-4F05-BC7D-AF01F617B664
F000BBC0-0451-4000-B000-000000000000
6C6F6701-5A21-4F05-BC7D-AF01F617B664
D343BFC0-5A21-4F05-BC7D-AF01F617B664
```

不能依靠此次公开 CoreBluetooth 服务发现绕过 HID 接收路径；主动 IOHID 读取也未获得可用按键状态。下一步使用 Apple [PacketLogger](https://developer.apple.com/bluetooth/) 取得本机蓝牙 HCI/ATT 报文，核对同一 HID report 特征的单键、组合、部分松开及全松开通知。GATT 通知通常不包含 IOHID 回调中的 report ID，比较长度时必须依据 Report Reference 对齐，不能把两层字节数直接混用。没有完整特征对应关系、按键操作和原始通知时，继续保留根因未确认的状态。

PacketLogger 随 Apple Additional Tools for Xcode 分发，下载需要 Apple 账户登录；排查开始时本机未找到已安装的工具。按 Apple [Bluetooth for macOS 的说明](https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth) 准备日志环境。原始抓包只在本地分析，公开记录只保留必要的脱敏协议字段，不提交设备地址、序列号或其他蓝牙设备的流量。

#### PacketLogger 准备进度（2026-10-28）

- 操作者从 Apple 官网下载并挂载 Additional Tools for Xcode 16.3。包内 PacketLogger 版本为 `2024.03.18`，最低系统版本为 macOS 14；签名严格验证通过。已复制至 `~/Applications/PacketLogger.app`，无需改动项目 App 或驱动。
- 首次打开的 PacketLogger 运行于磁盘映像启动产生的 App Translocation 路径。窗口虽显示 Live，但没有 HCI/ACL 数据。系统日志明确记录 `PacketLogger authenticated`、`Starting Live Logging`，随后报 **Bluetooth Profile Required**；该次不是有效的设备抓包。已点击 Stop，只有停止连接产生的 Note。
- 从 Apple 官方 Profiles and Logs 页下载说明及 `Bluetooth_macOS.mobileconfig`。系统安装预览显示 AppleCare Profile Signing Certificate；内容为三项蓝牙／固件诊断日志设置，包含 private-data logging，不是证书信任设置。
- 已向操作者说明该描述文件会开启全机详细蓝牙日志、可能包含其他设备标识及部分通信内容，操作者明确选择安装并自行重启。系统设置随后确认 **Bluetooth Logging for macOS / 3 settings** 已安装（标识 `com.apple.bluetooth.logging`）。Apple 官方说明要求安装后重启；当前等待手动重启，尚未获得原始包证据。

重启后续测顺序：

1. 从 `~/Applications/PacketLogger.app` 打开工具，新建本机 trace；先确认实际出现 HCI/ACL 数据，不能把 Live 标签当作采集成功。
2. 停止项目 App 的独占 HID 连接及语音会话，确认目标遥控器连接，尽可能只筛选该设备；测试只按普通键，不按语音键。
3. 记录单独上键、上＋返回、先松一键及全部松开的准确阶段，对照 ATT 通知的 handle、Report Reference、实际 payload 长度和公开 IOHID 回调。若数据被隐藏或无法确定特征归属，应保留证据边界。
4. 原始 trace 保存到仓库外的本地诊断目录。测试结束后停止抓包、恢复原 App，并移除本次安装的 Bluetooth Logging for macOS 描述文件，核对恢复结果。Apple 说明该描述文件三天后自动失效，但不依赖自动失效代替测试后的移除。

### 可复用的诊断入口

先退出 Voice Input Buddy，确保设备已连接；在已获输入监控／蓝牙权限的终端运行：

```sh
# 默认 300 秒，可指定 0～3600 秒之间的正数；只匹配 18D1:9450。
swift scripts/diagnose-g9n9n-hid.swift 60
# 可选：每 200 ms 主动读取 input report；这只是诊断，不是产品轮询方案。
swift scripts/diagnose-g9n9n-hid.swift 60 --poll
# 只发现服务；不订阅、不写特征、不接收音频。
swift scripts/diagnose-g9n9n-services.swift
```

无权限、独占打开失败、无匹配设备或服务发现未完成，都不能作为设备不发送的证据。HID 工具日志只包含目标 VID/PID 的描述符、有限长度按键报告、元素值及计数，不打印设备地址、序列号或音频。测试后退出工具并重新打开原安装 App。

验证：`swift build --disable-keychain` 成功；默认 Command Line Tools 的 `swift test --disable-keychain` 因缺少 `Testing` 模块失败，切换完整 Xcode 后执行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-keychain`，569 个测试、97 个套件通过。两项工具另行编译检查并在本机执行；这些验证不代表普通单键已修复。

## 2026-10-19：首次真机调试

日期：2026-10-19。样机以 Chromecast Remote 连接 macOS；这是一台样机的结果，不代表所有 G9N9N 或第三方兼容款。

## 结果

本轮完成了设备识别修复、HID 格式适配和固定签名测试构建。设备可以建立连接并完成 ATVV 能力协商，但**尚未通过完整真机验收**。停止测试时，普通按键的单键对应关系、松开事件和稳定性仍未确认；不能将配对成功或向导进入下一步视为验收通过。

| 检查项 | 观察与结论 |
| --- | --- |
| 设备身份 | Google Inc.；VID/PID `18D1:9450`；DIS 型号 `A3`；硬件 `CR PVT/MP`；固件／软件 `26.0` |
| 连接与 ATVV | 通知订阅、能力交换成功；ATVV v1.0，16 kHz ADPCM，帧大小 240 |
| 加密 | 未独立测量链路加密状态。读取／订阅成功且没有认证错误，不等于证明未加密 |
| 普通按键 | 确实接收过原始报文；未得到可重复的单键三次按下／松开结果 |
| 语音链路 | 观察到语音启动／停止和解码后的音频包；未验证可懂度及端到端输出 |
| 虚拟麦克风 | 卸载旧版时驱动被移除；已重建安装包，尚未重新安装，输出设备不可用 |
| 权限与签名 | 固定签名构建的升级前后 designated requirement 一致；一次升级后输入监控及辅助功能权限保留 |
| 长会话、休眠及重连 | 未完成验收；重新配对成功不等于覆盖这些场景 |

完整公开协议字段及能力交换字节见[开发说明](development.md#g9n9n-first-hardware-inspection-2026-10-19)。不提交设备地址、序列号、原始个人配置、签名私钥或密码。

## 代码修复

1. 取消 DIS 型号字符串必须等于 `G9N9N` 的限制。样机实际报告 `A3`；现在要求同一 BLE 外设的 PnP 身份 `18D1:9450` 与受支持的 ATVV 能力共同通过，型号只作信息展示。
2. 保留 report 2 的 16 位 Consumer Control usage 解码，新增与实测描述符完全匹配的 report 1 索引格式。该格式含两个 8 位索引；零表示槽位释放。未知描述符、非法索引或长度不按这一格式猜测解码。增加输入源 usage `0x0089`。
3. 增加有长度上限的 Google 遥控器原始 HID 日志，便于分清原始输入、解析结果与按键边沿；不记录语音内容。
4. 增加显式使用已有固定证书的本地构建入口，验证 App 和驱动签名并清理临时钥匙串，不改变证书信任。普通本地／PR 构建仍默认临时签名。方法见[构建与签名](build-and-signing.md)。

## 按键排查过程与证据边界

- 先前严格型号检查导致初始化失败；修复后设备连接和 ATVV 协商成功，向导第三步也确实收到过实体按键。
- 测试序列为：上、下、左、右、确定、返回、主页、音量＋、音量－、静音、YouTube、Netflix、信源、电源，每键短按三次。该轮没有取得完整对应的原始记录，不能给出全键通过结论。
- 多轮隔离的上键测试中，记录到 `01 04 07`、`01 05 04`、`01 06 05` 等 report 1 报文；按描述符对应“下＋确定”“左＋下”“右＋左”。部分序列缺少全部释放报告，最终由八秒缺失松开保护释放。
- 操作者随后说明，确定键与方向环有同时按下的情况，且感觉同时按键时更容易产生输入。因此组合报文本身可能对应真实操作，不能单凭它们判定映射错误或硬件故障；应重新做严格隔离的单键和组合键对照。
- 最小公开 IOHID 诊断能打开该设备，但对应测试窗口没有收到事件。独立 Karabiner-EventViewer 也未得到三次上键的完整对应记录；它接收过少量输入值及原始记录，不能描述为完全没有输入。
- Karabiner 对这台设备的 Modify events 为关闭状态；没有证据确认是它拦截了输入。最后一轮 EventViewer 在读取结果前已退出，该轮不计作有效验收。
- 取出电池后重新装入、忽略设备再配对均已尝试。重新配对最终成功，随后仍未取得稳定单键及松开结果。
- 按 Google 官方步骤尝试恢复出厂设置时，操作者反馈未成功；未确认恢复出厂完成。官方步骤见 [Chromecast 遥控器重置说明](https://support.google.com/chromecast/answer/10070837?hl=en)。

排查中临时加入的逐设备报告接收实验及独立诊断入口没有改善结果，已移除，不纳入最终实现。现有证据不足以区分样机硬件、固件、操作方式与 macOS 兼容性因素。

## 构建与验证

- `swift build --disable-keychain` 成功。
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-keychain`：526 个测试、88 个套件通过。
- 本地固定签名构建测试 5 项、bundle 签名测试 1 项、release 签名测试 12 项通过。
- 固定签名 App 与驱动构建及签名验证通过；最终运行及授权仅针对 `dist/Voice Input Buddy.app`。签名升级前后要求一致；没有改变系统证书信任。
- 编译和自动测试不能替代真机验收。上述结果不声明所有按键、音质、链路加密或休眠重连已通过。

## 下一轮复测

1. 用已知正常的 Google TV／另一台主机确认样机的单键与松开行为，或更换已知正常样机作对照；先确认重置和重新配对确实完成。
2. 保持同一签名、同一 `dist` 路径，先静置五秒，再逐键短按三次。避免碰到确定键及相邻方向；分别记录按下、松开、重复、长按和刻意组合按键。
3. 独立 EventViewer 与本程序分开捕获，记录每轮起止和实际动作，不将退出、无完整记录的轮次计作通过。
4. 恢复虚拟麦克风驱动后再验证语音可懂度、启动／停止、长会话、休眠及断线恢复；需要独立证据才能确认链路加密。
