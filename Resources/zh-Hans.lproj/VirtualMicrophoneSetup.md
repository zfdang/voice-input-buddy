# 虚拟麦克风设置

Remote Buddy 使用基于 BlackHole v0.7.1 的独立双声道驱动，设备名称为 **Remote Buddy Mic**，UID 为 `BuddyMic2ch_UID`。它不会替换已有 BlackHole 或上游产品的驱动。

从本项目 GitHub Releases 下载 Apple Silicon 的 `*_macOS_arm64.pkg` 或 Intel 的 `*_macOS_intel.pkg`，一次安装 App 与驱动，无需另行构建驱动。安装位置为 `/Applications/Remote Buddy.app` 和 `/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver`。安装需要管理员授权，会重启 Core Audio 并短暂中断播放或录音；如果设备未加载，刷新检测或按提示重启 Mac。

App 固定输出到 Remote Buddy Mic，不提供其他输出或 BlackHole 回退。首次向导在连接遥控器、测试按键后自动检查驱动与输出，二者就绪才继续。在豆包、微信或其他输入工具中选择 **Remote Buddy Mic** 麦克风，并按向导配置语音快捷键；增益在遥控器连接页按遥控器分别调整。

验证时，在有焦点的文本框中按住语音键说话、松开结束，或使用已配置的点按行为，确认实际识别与文字输入。构建成功及设备检测通过不代表完整硬件验收。

当前 PKG 未签名、未公证；App 与驱动使用固定自签名证书，更新包另有本项目 Sparkle 签名。对应驱动源码、补丁和许可见 https://github.com/zfdang/remote-buddy/blob/main/docs/source-code.md 。本地开发仍可使用 `scripts/build-driver.sh` 和 `scripts/build-driver-package.sh` 构建独立驱动包。

卸载请下载通用卸载器 PKG，用 macOS Installer 打开。默认删除 App、驱动及当前用户设置、日志和缓存；可取消个人数据删除。卸载需要管理员授权并会重启 Core Audio。详见 https://github.com/zfdang/remote-buddy/blob/main/docs/uninstall.md 。
