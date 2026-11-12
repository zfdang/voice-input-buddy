# T1-Remote 真机调试与协议核对记录

本文档记录 `T1-Remote` 飞鼠全键盘蓝牙语音遥控器（含同方案 OEM 兼容款，例如外观一致的白色/银灰/黑色双面飞鼠全键盘遥控器）在 macOS 上的硬件特征、HID 报告结构、ATVV 语音协议与适配边界。

## 实测硬件标识（首台样机）

- **设备名称**：`T1-Remote`（OEM 兼容款可能更改广播名）
- **Manufacturer String**：`shenzhen_xingwei`
- **DIS Model Number**：`hid_mouse`
- **DIS PnP ID (`0x2A50`)**：VID `0x620A`、PID `0x0407`
- **GATT 服务**：标准 HID over GATT（`0x1812`）、Battery（`0x180F / 0x2A19`）、Device Information（`0x180A`）及 Android TV Voice Service（ATVV，`AB5E0001-5A21-4F05-BC7D-AF01F617B664`）
- **配对组合键**：同时长按 **Home + Back**，指示灯进入慢闪蓝牙配对状态（若配套 2.4G 接收器使用则是 OK + Back；macOS 通过蓝牙直连）。

> 兼容性开放原则：`T1-Remote` 公版芯片及白牌/贴牌款可能修改 VID/PID、蓝牙广播名或厂商字符串，因此程序仅将这些字段作为已知默认识别条件；在“添加设备”流程选定 T1 时也会接纳未知名称但完整支持 ATVV v1.0 16kHz IMA-ADPCM 的兼容设备，并通过 `UserKeyMapping` 与非独占 `HIDRemoteMonitor` 匹配兼容身份。

## HID 报文结构（非独占打开）

在 macOS 上，`IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice)` 会返回 `kIOReturnNotPrivileged`（可能受内置键盘/飞鼠复合接口权限限制）。Remote Buddy 使用**非独占** `IOHIDDeviceOpen(kIOHIDOptionsTypeNone)` 读取原始报告，并结合系统 `UserKeyMapping` 与事件拦截完成控制：

| Report ID | 功能 | 说明 |
| --- | --- | --- |
| `1` | 正面导航/菜单、语音按住槽位、背面 QWERTY 全键盘 | 标准 8 字节 Keyboard 报告；`0xAA` 为语音标志位；目前仅映射 `0x65`（Menu），正面方向键 `0x4F/0x50/0x51/0x52`、确认 `0x28` 与背面字母/修饰组合键均直接放行原生输入，避免劫持背面全键盘 Enter/方向键 |
| `2` | 正面多媒体控制键与语音 Search | `0x0224` 返回、`0x0223` 主页、`0x00E2` 静音、`0x00E9` 音量+、`0x00EA` 音量-；语音键按下时同时触发 `0x0221`（AC Search，macOS 默认呼出 Spotlight） |
| `3` | 系统电源键 | bit 0 (`0x01`) 对应 System Power Down（HID Usage Page `0x01`, Usage `0x81`），未抑制时会导致 Mac 熄屏休眠 |
| `4` | 空中飞鼠 | 光标移动/左键直接交由 macOS 原生鼠标驱动处理，解码层返回 `.ignore`，不影响按住中的按键状态 |
| `0x5A` | 厂商私有传感器/状态报文 | 解码层返回 `.ignore` |

### `UserKeyMapping` 映射策略（防止 Spotlight 弹窗与误熄屏）

1. **抑制 Spotlight 搜索与 0xAA**：无论全局语音触发键设定为何种模式，Connected 时均将 `0x000C_0000_0221` 与 `0x0007_0000_00AA` 重映射为空（`0x0`）。
2. **抑制电源键黑屏**：开启“自定义按键”后，将 `0x0001_0000_0081` 重映射为 F20（`0x0007_0000_006F`），并由键盘拦截/监听链路还原为 `.power` 按键动作；关闭自定义按键或退出 App 时自动恢复原始映射。

## ATVV 语音链路特性

- **写入特性**：Capabilities / Control 写入使用 `.withoutResponse`。
- **解码参数**：ATVV v1.0、16 kHz IMA-ADPCM、`highFirst`（`lowNibbleFirst = false`）。
- **挂断保护（`MIC_CLOSE` + `MIC_EXTEND`）**：实测作者手头的 T1 样机在第一次按下语音键后会直接发送 ATVV `STREAM START`（`0x04`）开启持续收音，**第一次松开语音键会上报 `0xAA` 释放但不会发 `AUDIO_STOP` 控制包**（按一下开始、再按一下结束的开关模式）；再次按下语音键时会发送 `0x08` 与 Report 2（部分状态还带 `0xAA`）。因此 Host 不在第一次 `0xAA` 释放边沿提前关麦，而是在收到录音中的 `0x08` 时主动下发 `MIC_CLOSE` 结束录音（同时立即取消后续保活并启动 5 秒超时兜底，防止设备未回 `0x00` 导致长驻收音），在持续收音时每 10 秒下发 `MIC_EXTEND`（最多 30 次、约 5 分钟上限后自动关麦），并将 T1 的停播后尾音屏蔽窗口放宽至 `0.8s` 防止幽灵重启。期间 Host 侧会全程维持虚拟语音键按下直到 `STREAM STOP（0x00）` 或超时结束，从而兼容只支持长按触发的输入工具。

## 已验证范围与限制

- 已通过实机抓包与调试工具核对：`T1-Remote`（`0x620A:0x0407`）蓝牙配对、电量读取、Report 1/2/3/4/`0x5A` 报文、Spotlight 抑制、ATVV 16 kHz ADPCM 音频帧，以及“按一下松开说话 → 再按一下停止”的全链路兼容微信输入法等长按语音工具。
- 未包含且保留开放：不同批次贴牌克隆款的实机 HID 描述符差异，以及 2.4GHz USB Dongle 模式（当前适配针对蓝牙直连模式）。
