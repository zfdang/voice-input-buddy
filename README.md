# Voice Input Buddy

**简体中文** | [English](README.en.md)

Voice Input Buddy（语音搭子）把遥控器变成电脑上的语音输入按钮。拿起遥控器，按下说话、松开结束，就能在当前输入框中使用你喜欢的输入法或听写工具。

[产品官网](https://voice.zfdang.com) · [下载](https://github.com/zfdang/voice-input-buddy/releases)

当前支持 **macOS 14 及以上版本**，包括 Apple Silicon 和 Intel Mac。Windows 支持正在规划中。

## 能做什么

- 用遥控器麦克风进行语音输入，减少对电脑键盘和内置麦克风的依赖。
- 把遥控器按键映射成快捷键、应用操作或常用语。常用语内容不随界面语言切换，可自由混写中英文。
- 选择语音输入工具，配置按住说话或点按开始／结束的触发方式。
- 在一个向导中完成系统权限、麦克风驱动、设备连接和输入工具设置。

应用不采集使用统计，不保存录音或文本历史，不上传日志。语音识别和文本整理交给所选输入工具，其联网行为由该工具的设置决定。

## 工作原理

```text
遥控器麦克风 → 蓝牙音频 → Voice Input Buddy → 虚拟麦克风 → 输入法／听写工具
遥控器语音键 → Voice Input Buddy → 触发工具的语音快捷键 → 当前输入框
```

Voice Input Buddy 接收遥控器音频，解码后送入虚拟麦克风，同时将按键动作转换成目标工具需要的快捷键。它负责连接硬件与输入工具，本身不运行语音识别模型。实时文字、识别速度和自动修正效果取决于所选工具。

## 如何使用

从 [Releases](https://github.com/zfdang/voice-input-buddy/releases) 下载 `Voice_Input_Buddy_*.pkg`。一个安装包包含 App 和虚拟麦克风驱动。

1. 安装后打开 `/Applications/Voice Input Buddy.app`。
2. 按设置向导授予蓝牙、输入监控和辅助功能权限。首次默认跟随系统语言，可在第一步选择中文或英文。
3. 选择并连接遥控器、测试按键，等待驱动检查与固定输出准备就绪，再在输入工具中选择 **Voice Input Buddy Mic** 虚拟麦克风。App 自动使用该设备，不需要选择输出，也不回退到 BlackHole 或扬声器。
4. 在“输入法集成”中配置语音快捷键，通过向导测试。
5. 打开文本输入框，按住遥控器语音键说话、松开结束。使用 Typeless 等单击触发的工具，可在设置中调整开始／结束行为。

普通按键在“按键映射”中配置；需要重新检查环境时，在“设置”顶部重新运行向导。

安装需要管理员授权；首次安装或驱动变化、修复时会短暂中断音频，驱动未变化的升级会跳过音频服务重启。当前安装包未经过 Apple 公证，系统可能阻止安装。详见 [安装与发布说明](docs/releases.md)。

## 支持哪些设备

| 设备 | 当前支持情况 |
| --- | --- |
| 小米蓝牙遥控器 2／2 Pro | RC001 = 2，RC003 = 2 Pro，均包含 ATVV 协议与按键适配。2 Pro 按键已本地验证，音频由用户确认正常；2 的完整音频流程仍需单独验收 |
| Google Chromecast Voice Remote（G9N9N） | 已实现公开 ATVV v1.0／16kHz 音频和 Consumer Control 按键接入；真机验证待完成，兼容款需分别验证 |
| Google TV Streamer Voice Remote（GY3LE） | 计划支持；尚未完成适配与真机验证 |
| Apple Siri Remote | 计划支持；尚未完成适配与真机验证 |

设备范围限定为以上四项。Google 硬件型号依据 [Google 官方监管信息](https://support.google.com/product-documentation/answer/4541589?hl=en)。第三方兼容款必须单独验证，商品标注“兼容 G9N9N”不代表已经支持。

遥控器需支持对应的蓝牙按键与音频协议，不能仅凭“可以蓝牙配对”判断兼容。

## 支持哪些输入法与工具

| 输入工具 | 集成方式 |
| --- | --- |
| 微信输入法 | 专用配置向导入口，配合虚拟麦克风与语音快捷键 |
| 豆包输入法 | 专用配置向导入口，支持按住与点按触发设置 |
| 网易叭哥说 | 专用配置向导入口，配置语音快捷键与麦克风 |
| Typeless | 配置其语音快捷键及开始／结束行为 |
| VoiceCursor | 独立入口，配置虚拟麦克风与自定义语音快捷键 |
| macOS 听写 | 系统自带，无需安装第三方工具；快捷键设为“按两下 🌐 键”，按住遥控器时连按两次 Fn 开始，松开后按一次 Fn 结束 |
| 其他语音输入工具 | 使用“其他工具”配置自定义快捷键 |

目标工具需要能够接收虚拟麦克风音频，并支持可以触发的语音快捷键。每个工具的版本和设置可能不同，请通过向导实际测试；配置入口不代表所有版本都已验证兼容。

## 更多信息

- [界面与常见问题](docs/interface.md)
- [官网与部署](docs/website.md)
- [开发与构建](docs/development.md)
- [构建与固定签名证书](docs/build-and-signing.md)
- [发布与安装包说明](docs/releases.md)
- [架构与产品范围](docs/architecture.md)
- [隐私与验证记录](docs/privacy-and-testing.md)
- [源码来源](docs/provenance.md)、[GPL-3.0-only 许可证](LICENSE)、[第三方声明](THIRD_PARTY_NOTICES.md)

## 下载与卸载

Apple Silicon 选择 `*_macOS_arm64.pkg`，Intel 选择 `*_macOS_intel.pkg`。每份包含 App 和 **Voice Input Buddy Mic** 驱动。

卸载时下载通用的 `Voice_Input_Buddy_Uninstaller_*_macOS_universal.pkg`（Apple Silicon / Intel 共用），通过 macOS Installer 打开。默认删除 App、驱动和当前用户设置、日志、缓存；取消勾选个人数据删除选项即可保留设置与日志。系统固定的“安装”按钮实际执行卸载，不安装程序。需要管理员认证，音频服务会短暂重启。详见[卸载说明](docs/uninstall.md)。

## References

| 项目 / 模块 | 用途 |
| --- | --- |
| [remote-mic-app](https://github.com/HD838A/remote-mic-app) | 遥控器连接、音频桥接、按键映射与界面的代码基础 |
| [remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub) | 小米 ATVV 协议、ADPCM 解码和 HID 映射参考 |
| [vibe-mote](https://github.com/Tilkmilk/vibe-mote) | Google TV／Chromecast 遥控器 HID 按键、ATVV 语音协议与第三方兼容款差异的参考（Windows 实现） |
| [ATVVoice](https://github.com/b0o/ATVVoice) | 已验证 G9N9N 的 Linux ATVV 实现；能力协商、音频同步与会话保活参考 |
| [mi-remote-mapper](https://github.com/81199000/mi-remote-mapper) | macOS CoreBluetooth、HID 和虚拟音频输出参考；未作为 G9N9N 真机验收依据 |
| [mi-ao](https://github.com/fanxeon/mi-ao) | macOS ATVV 协议、解码与能力验证参考；Google 遥控器仍需真机验证 |
| [mi_remote_control](https://github.com/godarrenw/mi_remote_control) | 按键动作、应用预设与故障排查的设计参考 |
| [open-voice-bridge](https://github.com/nijez/open-voice-bridge) | 设备能力建模与语音链路诊断的设计参考 |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 | 虚拟麦克风驱动 |
| [MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) | USB transport 回环音频设备的兼容设计参考 |
| [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.4 | macOS 应用内更新，验证一体安装包的签名 |
| [codex-siri-remote](https://github.com/luobosibing2/codex-siri-remote) | Apple 遥控器 HID 与触摸行为的历史参考 |
| [SiriRemoteForge](https://github.com/HOLODATA-COM/SiriRemoteForge) | Apple 遥控器音频与 PacketLogger 格式的历史参考 |
| [iRemote A2854](https://github.com/DaviBaum/iRemote-A2854) | Apple 遥控器诊断与授权流程的历史参考 |
| [Opus](https://www.opus-codec.org/) | Apple 遥控器音频兼容代码涉及的编解码器；当前安装包不包含其动态库 |

历史兼容代码的引用不代表当前支持 Apple 遥控器。系统框架和内部模块详见 [模块清单](docs/modules.md)，各模块版本、版权及许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。
