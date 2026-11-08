# 卸载 Remote Buddy

从 GitHub Releases 下载 `Remote_Buddy_Uninstaller_vYY-MM-DD.NNN_macOS_universal.pkg`，Apple Silicon 和 Intel 使用同一份包。最新版卸载器同时支持旧版 Voice Input Buddy 和新版 Remote Buddy；迁移时无需寻找旧卸载器。卸载旧版后再安装新版。它只有卸载脚本，没有架构相关的可执行程序或安装载荷。

双击包，使用 macOS Installer 按介绍、卸载范围和组件选项页继续。**系统按钮显示“安装 / Install”，点击后实际删除程序和驱动，不会安装软件。** 个人数据删除选项默认勾选，取消勾选即可保留。结束页明确显示卸载完成。系统的安装成功提示表示卸载脚本执行成功。

默认“彻底卸载”会退出应用、注销登录项、移除 `/Applications/Remote Buddy.app` 和 `/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver`，并删除当前用户的设置、日志、缓存和保存的窗口状态。仅删除这些明确归属于本项目的位置：

- `~/Library/Preferences/com.zfdang.remote-buddy.plist`
- `~/Library/Application Support/RemoteBuddy`
- `~/Library/Logs/RemoteBuddy`
- `~/Library/Caches/com.zfdang.remote-buddy`
- `~/Library/Saved Application State/com.zfdang.remote-buddy.savedState`

取消勾选个人数据删除选项仅删除 App 和驱动。系统目录删除需要 macOS 管理员认证；取消认证不会删除文件。驱动移除后重启 Core Audio，会短暂中断播放或录音；若无法重启，按错误提示重启 Mac。其他用户的个人数据、原 remote-mic / MiRemoteV 驱动及其他音频驱动不在卸载范围内。

卸载器同时处理旧版 `Voice Input Buddy.app`、`VoiceInputBuddyMic.driver` 及其个人数据，并校验本项目的 Bundle ID；不会删除源码仓库、下载的安装包或开发目录中的 App 副本。系统登录项可能保留停用的历史记录，隐私授权列表可能保留失效条目，可在系统设置中手工移除；不修改系统 TCC 数据库。

开发：`scripts/build-uninstaller.sh`，只构建一个通用包，无需指定 `BUILD_ARCH`。运行不需要 Xcode、Python 或原 App。卸载 PKG 未签名、未公证，与 App 安装包的发行限制相同。

验证：`python3 scripts/test-installation-actions.py` 使用临时目录测试身份拒绝、符号链接拒绝、重复卸载、旧文件名清理和个人数据删除；不会删除真实安装。可用 `installer -showChoicesXML -pkg <卸载包> -target /` 查看选项，不执行卸载。
