# 虚拟麦克风设置说明

## 1. 工作原理与设备信息
遥控搭子（Remote Buddy）使用基于 BlackHole v0.7.1 构建的独立双声道虚拟麦克风驱动，设备名称为 **Remote Buddy Mic**，UID 为 `BuddyMic2ch_UID`。
- 遥控搭子会将蓝牙遥控器传来的语音固定输出到 **Remote Buddy Mic**，不提供其他音频输出或 BlackHole 回退。
- 该驱动完全独立，不会替换或影响你电脑上已安装的 BlackHole 或其他音频驱动。

## 2. 安装方法
- 从本项目 GitHub Releases 下载完整安装包（Apple Silicon 芯片下载 `*_macOS_arm64.pkg`，Intel 芯片下载 `*_macOS_intel.pkg`），一次即可同时安装应用与虚拟麦克风驱动，无需单独安装驱动。
- **安装位置**：应用安装在 `/Applications/Remote Buddy.app`，驱动安装在 `/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver`。
- **安装提示**：安装过程需要管理员授权，并会重启系统音频服务（Core Audio），期间播放或录音可能会短暂中断。首次向导会在连接遥控器并测试按键后自动检测驱动与输出是否就绪；如果未检测到设备，请点击“刷新检测”或按提示重启 Mac。

## 3. 在语音输入工具中使用
1. 在微信输入法、豆包、Voice Buddy、网易叭哥说、Typeless 或 macOS 听写等输入工具中，将麦克风设为 **Remote Buddy Mic**，并按首次向导配置好语音快捷键。
2. 如需调整音量大小，可在“遥控器连接”页面按遥控器分别调整麦克风增益。
3. 验证时，请先点击任意可输入的文本框，再按住语音键说话、松开结束（或使用已配置的点按切换模式），确认能够正常识别并输入文字。

## 4. 签名说明与开源源码
当前安装包（PKG）未经过 Apple 公证（Notarized）且未签名；App 与驱动使用项目固定的自签名证书，在线更新包另有本项目 Sparkle 签名验证。对应驱动源码、补丁和许可说明见：https://github.com/zfdang/remote-buddy/blob/main/docs/source-code.md 。

## 5. 如何卸载
如需卸载，请下载通用卸载包（Uninstaller PKG）并用 macOS“安装器”打开。默认会移除 App、虚拟麦克风驱动以及当前用户的设置、日志和缓存（你可以在安装过程中取消勾选删除个人数据）。卸载需要管理员授权并会重启 Core Audio。详见：https://github.com/zfdang/remote-buddy/blob/main/docs/uninstall.md 。
