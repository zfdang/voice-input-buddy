# macOS 自动发布

`.github/workflows/release.yml` 在 main 收到提交时运行，包括人工合并 PR。PR 本身也会测试、构建安装包供检查，但不会创建 Release。流程不会合并任何 PR。

## 版本

版本格式为 `vYY-MM-DD.NNN`，例如 `v26-10-11.001`，示例不是当前最新版。日期来自发布提交的 committer 时间，使用 Asia/Singapore 时区；序号为 `git rev-list --count HEAD`，包括可达的合并提交，只取末三位，不足三位补零。例如 1、11、113 分别得到 001、011、113。不是每日重置计数。同一提交重跑得到同一版本；已存在 Release 不覆盖。历史必须完整，因此 checkout 使用 fetch-depth: 0。例如 999、1000、1001、12345 的显示尾号分别为 999、000、001、345。显示尾号只用于区分版本，不用于更新排序。实际最新版以 [Releases](https://github.com/zfdang/remote-buddy/releases/latest) 为准。

App 的 CFBundleShortVersionString 为数字日期（例如 26.10.11），CFBundleVersion 为提交总数；安装包内部使用数字日期加提交总数。Git tag、Release 标题与下载文件采用完整 `vYY-MM-DD.NNN` 格式。

## 更新摘要

每次 workflow 先生成同一份版本变更，再供两种架构的 appcast 和 GitHub Release 使用。App 的“检查更新”从 appcast 的 description 读取这份摘要。Release 使用带类型标志的统一变更列表，不再附加安装、签名和源码依赖说明链接，保留完整变化链接。

基线是当前发布提交第一父链上最近的已发布正式 Release；排除草稿、预发布、当前提交标签和其他分支的 Release。变更列表遍历该版本范围内所有分支的非 merge commit，每个 commit 一条，使用其提交标题和 commit 链接，按提交时间从旧到新排列；不再以 PR 标题代替内部提交。squash 合并后只能展示实际保留的 squash commit。没有已发布基线时列出首次发布变化，未发布的 Git tag 不截断摘要。历史不完整或已发布标签无法解析时停止生成，避免静默遗漏变化。重跑已有 Release 仍不覆盖其内容。

## 安装包与源码

- `Remote_Buddy_vYY-MM-DD.NNN_macOS_arm64.pkg` / `*_macOS_intel.pkg`：App 与驱动的一体安装包。
- `Remote_Buddy_Uninstaller_vYY-MM-DD.NNN_macOS_universal.pkg`：Apple Silicon / Intel 共用的脚本卸载包。
- `Remote_Buddy_vYY-MM-DD.NNN_sources.tar.gz`：包含本项目源码、打补丁后 BlackHole 驱动源码（`vendor/BlackHole`）与固定版本 Sparkle 源码（`vendor/Sparkle`）的完整源码归档（遵循 GPL-3.0 对应源码要求）。
- `appcast-arm64.xml` / `appcast-intel.xml`：对应架构的更新源，作为可恢复发布产物保留在 Release 中。

Release 提供上述安装包、源码归档与两份更新源，不额外上传 SHA 文件或 TXT 更新摘要。第三方固定版本源码及构建说明见 [source-code.md](source-code.md)。

安装包按 arm64 和 x86_64（文件名 intel）分别提供，要求 macOS 14 或更新版本。App 安装在 `/Applications/Remote Buddy.app`，驱动安装在 `/Library/Audio/Plug-Ins/HAL/RemoteBuddyMic.driver`。程序展示名称仍为 Remote Buddy；发布文件名使用下划线，App 目录保留空格，内部可执行文件为 RemoteBuddy。安装需要管理员授权；仅在首次安装、驱动内容变化或修复损坏的驱动时刷新 Core Audio，短暂中断播放和录音。安装前后会验证驱动签名并比较内容指纹，而非只比较版本号；驱动未变化的重装和 App 升级不会重启音频服务，重新签名的时间戳不影响判断。安装包不自动开启任何系统隐私授权，也不自动启动 App。

旧开发版本若放在其他目录，应退出旧版并改用 `/Applications/Remote Buddy.app`，避免同时运行两个副本。首次安装和更新后请核对系统权限。完成设置后，更新首次启动默认打开通用页；权限与麦克风状态卡会提示缺少的授权或驱动，点击后进入修复页面。

一体安装包在当前系统卷安装时，将 App 目录及普通资源交给已登录的桌面用户，方便后续手动替换；但 Sparkle 的 `Autoupdate` 实体可执行文件保留 root 归属。自签名证书没有 Apple Team ID，Sparkle 的 PKG 更新安全检查要求这个助手归 root 所有且位于 App 内；整个 App 都归普通用户会使更新在启动安装器之前失败，界面可显示 `SUSparkleErrorDomain (4005)`。调整归属不修改文件访问模式、签名或系统隐私授权；普通用户拥有助手的父目录，因此仍可删除／替换整个 App。驱动仍由 root 管理，安装器仍需管理员授权，单独安装驱动不改变现有 App 的归属。无人登录或安装到其他卷时保留系统默认归属，不猜测目标用户。其他用户仍受 `/Applications` 的系统写入权限限制；App 归属变更不意味着所有用户都能无授权替换全局应用。

main 自动发布使用固定自签名证书为 App 和驱动签名，PKG 未经 Developer ID Installer 签名和 Apple 公证。安装与签名限制在本文说明；Release 保留变更摘要和完整变化链接，系统仍可能阻止安装。此流程没有关闭 Gatekeeper、添加受信任根证书、修改证书信任设置或复用上游发布密钥。Developer ID 签名与公证需要后续配置本项目自己的凭据。

## 固定发布签名身份

证书生成、备份及自己的 GitHub 仓库配置步骤见 [构建与固定签名证书](build-and-signing.md)。

证书和私钥只生成一次，后续每个架构、每个 Release 都复用同一份。公开证书位于 `scripts/signing/release-certificate.pem`；其 SHA-1 指纹为 `68D4550C06E7AF5EFCA5CDB454967F7B0E97F9A0`，有效期至 2036-10-10。指纹用于选择签名身份；证书本身使用 RSA 3072 和 SHA-256。证书、Bundle ID 和 designated requirement 共同保持应用跨版本身份，不把身份绑定到每次变化的程序内容哈希。

仓库 Secrets：

- `MACOS_SIGNING_P12_BASE64`：带私钥的、密码加密的 PKCS#12 文件，以 Base64 编码保存。
- `MACOS_SIGNING_P12_PASSWORD`：PKCS#12 导出密码。

两者都由 `gh secret set` 通过标准输入上传。私钥、PKCS#12 和密码不得进入 Git、产物或日志，应另行安全备份。Base64 不是加密。不要在构建中生成新证书，或用同名的新证书替代丢失的原证书。

只有 main 的 push 构建导入身份；PR 构建不读取这两个 Secrets，仍使用 ad-hoc 签名。`release-signing-keychain.py setup` 先校验 Secrets 中的证书与仓库公开证书一致，再创建 runner 的临时 Keychain，仅允许签名工具读取私钥。`CODE_SIGN_IDENTITY` 指定证书指纹，`CODE_SIGN_KEYCHAIN` 指定临时 Keychain。此 Keychain 仅临时加入搜索列表，供签名身份查找和证书链构建，不添加任何证书信任设置；签名结束后 `always()` 尝试恢复搜索列表、删除 Keychain，清理失败仅告警并保留状态供重试，不阻断已完成的构建。导入用的 PKCS#12 文件在 setup 结束时立即删除。活动状态存在时拒绝重复 setup，保留原 Keychain 与环境变量。缺少 Secrets、证书不匹配或签名失败均停止发布，不降级到 ad-hoc 签名。

打包前，`verify-release-signing.py` 校验 App 和驱动确实由固定证书签名，并具有绑定各自 Bundle ID 与证书指纹的固定 designated requirement。Sparkle 的更新包签名仍使用独立的 `SPARKLE_PRIVATE_KEY`，职责不同，不替换它。

首次安装此固定身份的版本时可能需要重新授予输入监控和辅助功能权限。跨版本权限保留仍需真机验收：在固定证书签名的版本 A 中授予权限，再正常升级到同一证书签名的版本 B，确认系统权限检查、遥控器按键和语音输入均可用。签名校验成功不代表这条升级路径已经验收。

## 本地复现

使用完整 Xcode（Swift 6.2 或更新版本）并先提交发布源码，确保源码归档与二进制一致：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
set -a
source <(scripts/release-metadata.sh)
set +a
swift test --disable-keychain
export BUILD_ARCH=arm64 # Intel: x86_64
scripts/build-app.sh
scripts/build-driver.sh
scripts/build-uninstaller.sh
scripts/build-release-package.sh
scripts/verify-release-package.sh
```

本地 App 构建默认仅构建宿主架构；Release workflow 以 matrix 分别构建两种架构并验证。GitHub runner 固定 macos-15 和 Xcode 26.2。构建/测试任务仅有读取权限；只有 main 的发布任务拥有创建 Release 所需的 contents: write。

## 应用内更新

Sparkle 从 `https://remote.zfdang.com/appcast-arm64.xml` 或 `appcast-intel.xml` 检查正式版本。应用内置
`SUPublicEDKey`，下载的 PKG 必须通过对应 Ed25519 公钥验证，才会开始安装。
通过菜单或设置中的“检查更新”可以手动触发；默认也进行后台检查。
版本比较使用递增的 CFBundleVersion（完整 Git 提交计数），显示采用完整发布标签。

main 的发布构建从仓库 Actions Secret `SPARKLE_PRIVATE_KEY` 读取签名私钥，
仓库 Variable `SPARKLE_PUBLIC_KEY` 必须与内置公钥完全一致。私钥只通过标准输入
传递给 Sparkle sign_update；不会写入源码、日志、发布资产或 PR 构建。
签名后使用 CryptoKit 与应用公钥独立验证，再生成对应架构的 appcast XML。更新源上传到 Actions 的 `website-update-feeds` 产物，并作为发布资产保留在 Release 中。若 Release 已存在，发布流程不会覆盖已发布的安装包或更新源，确保签名与已发布包严格一致；Pages 工作流部署时直接使用已发布 Release 的更新源。
PR 构建只测试和打包，不接触签名私钥、不部署更新源。

Release 成功后 Pages workflow 优先从该次发布的 Actions 产物部署两份 appcast XML；若产物不可用或单独更新网页，按顺序通过 Actions 产物、Release 附件、近期构建产物、本地预置源以及线上运行源回退获取，并验证版本和包地址仍匹配最新 Release。若更新源因历史异常丢失，可通过 `scripts/rebuild-pages-update-feeds.py` 从已发布的安装包与签名手动重建并上传至 Release。旧 Actions 产物过期不影响网站与更新部署；验证失败时停止部署，保留线上站点。PKG 地址指向
GitHub Releases；安装同时更新 App 和驱动，需要管理员授权，并可能短暂重启音频。
这不是静默安装，也不代替 Apple Developer ID 签名和公证。

因品牌与域名迁移（旧域名 `voice.zfdang.com` 停用并迁移至 `remote.zfdang.com`），改名前内置旧更新域名或未配置更新源的历史版本（如 `v26-11-08.567` 及更早版本）无法自动获取后续更新，需手动从官网或 GitHub 下载并安装一次新 PKG。
开发目录中的 ad-hoc App 无法代表完整安装流程，验收应从 `/Applications` 中
通过 PKG 安装的版本升级到后续版本。发布前必须实测管理员授权、升级后重启、
驱动可用性和系统权限；不得仅凭构建通过宣称完整升级已验证。

尚未发布预览通道；启用预览检查时，缺失预览源会回退到正式更新源。
不要随意更换密钥。PKG 更新无法通过普通更新自动轮换遗失的签名密钥，
必须安全备份，并在确需更换时安排用户重新安装。

通用卸载包以 `Remote_Buddy_Uninstaller_vYY-MM-DD.NNN_macOS_universal.pkg` 发布，只有脚本而没有安装载荷。Release matrix 只在 arm64 任务中生成它，避免两份同名产物。

新 App 使用各自的更新源，开发阶段不维护旧 universal feed。arm64 feed 标注 Sparkle 的 [arm64 硬件要求](https://sparkle-project.org/documentation/api-reference/Classes/SUAppcastItem.html)，Intel feed 指向 Intel 包。

应用的更新摘要直接读取 appcast 中的说明，不再生成或下载独立的 `.en.txt` / `.zh.txt` 文件。

## 更新界面的语言与版本

菜单“检查更新”及检查、结果、下载、准备安装和错误提示均使用应用内选定的语言（中文、英文或跟随系统），切换语言后无需重新启动。当前版本、新版本及可获得的本次检查结果均显示完整发布版本和 Git 提交计数，例如 `v26-10-12.070（Git 提交数：70）`。

界面通过 Sparkle 的公开 `SPUUserDriver` 接口实现；检查来源、更新签名校验、下载和安装仍由 Sparkle 处理。“查看更新内容”打开项目的 GitHub Releases。

发现更新时，首次确认按钮为“升级并重启”，说明下载及所需的管理员授权完成后会自动安装并重启。本次明确确认仅用于当前升级流程：准备完成时直接通知 Sparkle 继续安装，不再显示第二次“安装并重启”确认；取消下载、授权取消导致流程结束、出错或重新检查更新后不沿用这次确认。恢复之前暂缓或后台准备的更新时，仍需确认“安装并重启”。

恢复更新的“安装并重启”确认和等待退出时的重试提示使用浮动面板，切换到其他应用后仍可见，并允许显示在全屏空间。下载、解压和实际安装的进度窗口保持普通层级；稍后安装或关闭确认后隐藏面板。升级验收时分别在显示和隐藏 Dock 图标的状态下点击“升级并重启”，再切换到其他应用（含全屏窗口），完成管理员密码或指纹授权后，确认无需手动切换或再次点击即可继续安装并重启。同时验证授权取消后不会继续安装，以及恢复暂缓更新时仍显示确认，选择“稍后安装”后不再遮挡其他窗口。这条真实授权与升级路径需要实际操作，自动测试仅覆盖流程选择、确认失效、面板配置和阶段切换。

升级后首次启动保留完成检测、HID 恢复和完成提示。默认打开通用页，由权限与麦克风状态卡承接权限修复入口，不再因权限缺失自动切换页面；原有专用于自动跳转的 `UPDATE PERMISSION_REPAIR` 日志也随之移除。在主窗口顶部显示约 6 秒的完成提示，随后自动消失。提示不拦截窗口操作，不弹出需要点击关闭的完成对话框。Debug 设置页截图可用 `REMOTE_BUDDY_SETTINGS_SCREENSHOT_COMPLETED_UPDATE_VERSION=v26-10-15.215` 预览此提示。

Debug 构建可设置 `REMOTE_BUDDY_UPDATE_UI_PREVIEW=checking`（也支持 `found`、`current`、`error`、`ready`）和 `REMOTE_BUDDY_UPDATE_UI_LANGUAGE=en` 来查看隔离的更新界面样例。此预览不联网、不检查权限、不安装更新，不修改用户设置，并在两分钟后结束；Release 构建不包含此入口。
