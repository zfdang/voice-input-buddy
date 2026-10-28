# 模块清单

第三方项目及历史技术参考列在 [README References](../README.md#references)，版权、许可证与固定版本记录见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。历史 Apple 音频捕获、PacketLogger 和 HCI helper 的源码与构建目标已删除。实际构建目标以 [Package.swift](../Package.swift) 为准。

## SwiftPM 模块

| 模块 | 作用 |
| --- | --- |
| VoiceInputBuddy | 主 App、设备会话、设置、权限、音频路由与按键映射 |
| AudioExceptionGuard | 音频异常保护的 Objective-C 边界 |
| VoiceInputBuddyTests | 协议、生命周期与产品边界测试 |
| Sparkle | 第三方 macOS 更新框架 |

当前连接适配提供小米 RC001／RC003 和 Google G9N9N；G9N9N 当前仅部分支持语音功能，普通按键映射不支持，见 [独立测试报告](g9n9n-compatibility.md)。GY3LE 可进入连接向导，但没有型号专用协议适配；Siri Remote 可在设备目录中选择，不能继续连接。内部兼容类型不代表对应功能已启用；私有扩展包不参与构建。

## 驱动

VoiceInputBuddyMic.driver 基于固定版本 BlackHole 源码构建，使用独立 Bundle ID、设备 UID 与工厂 UUID。其对应固定版本源码、补丁与许可证通过 Release 的源码链接提供，见 [source-code.md](source-code.md)。

## macOS 系统模块

使用 AppKit、SwiftUI、Foundation、Combine、CoreBluetooth、IOBluetooth、CoreAudio、AudioToolbox、AVFoundation、CoreFoundation、CoreGraphics、CoreImage、ApplicationServices、Carbon、IOKit、Network、Security、CryptoKit、OSLog、ServiceManagement、UniformTypeIdentifiers、Accelerate 及 Darwin 系统接口。系统框架由 macOS 提供，不作为第三方二进制随 PKG 重新分发。停用的统计图表 UI 和 Charts 依赖已删除。

历史记录存储、录音归档、MCP 授权与客户端配置代码已移除；应用不会读写 AI 工具的 MCP 配置。上游私有扩展的条件编译分支已移除，公开兼容接口与未支持设备的 UI 类型仍保留。

## 产品运行边界

手机、Watch、Web Remote 和 Siri Remote 的退休传输、会话编排、空实现、管理 UI 及持久化开关均已移除，不保留旧 API 或格式迁移。Siri Remote 和 GY3LE 仅保留设备目录中的计划支持展示，不启动服务。原兼容模块中的音频信号度量已移入主应用的音频诊断，HID 边沿类型使用主应用的定义。

诊断只写本地日志，没有上传器或待上传队列。`references/` 是忽略的本地研究目录，`dist/` 是忽略的构建输出。

## G9N9N public adapter

`G9N9NProtocol.swift` identifies candidates, parses report 2 Consumer Control usages and descriptor-verified report 1 button indices, checks ATVV capabilities, and distinguishes pairing errors. `BluetoothRemoteBridge` now also hosts G9N9N via explicit opt-in, requiring DIS PnP identity 18D1:9450 and ATVV v1.0 / 16 kHz before readiness; DIS model strings are informational. Audio uses the existing ADPCM decoder and virtual microphone output; driver sources and signing are unchanged. The retired no-op Chromecast package facade has been removed.

Parser implementation is not a support claim: the tested A0 / firmware 26.7 unit sends short single-key and release notifications that never reach public HID callbacks. G9N9N currently has partial voice support; control-button mapping is unsupported.
