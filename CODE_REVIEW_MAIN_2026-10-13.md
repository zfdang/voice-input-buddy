# Voice Input Buddy：main 全项目代码审查

审查日期：2026 年 10 月 13 日（Asia/Singapore）。

审查基线：`main`，提交 `0f342072277f33d1afa24b7e50b9be4220106d68`，PR #25 合并后的版本。本轮从当前源码和实际验证重新得出结论，没有将之前的报告当作发现依据。报告中的行号均对应这个提交；后续 main 的变动不包含在本轮结论中。

## 结论

确认 **4 项可操作问题：3 项 P2、1 项 P3**。没有确认 P0/P1 问题，也没有证据能够把之前那次 macOS 卡死归因到一个具体调用。构建和现有测试通过，并不消除下面这些未被现有测试覆盖的边界。

本轮只审查和记录，**未修复生产代码**。临时复现测试已移除；报告是唯一新增的跟踪文件。没有安装/卸载软件或驱动，没有修改权限、登录启动或系统默认音频设备。

| 编号 | 优先级 | 问题 | 证据强度 |
| --- | --- | --- | --- |
| F1 | P2 | cmux 进程退出后的标准输出读取不受超时约束 | 原函数抽取后的独立运行复现 |
| F2 | P2 | 常用短语导入先完整读取文件，再检查 4 MB 上限 | 明确的生产调用顺序 |
| F3 | P2 | 配置导入接受重复应用 UUID，绑定查找会指向错误记录 | 真实 AppSettings 导入路径复现 |
| F4 | P3 | 本地测试更新源入口仍可进入 Release 路径 | Release 优化编译复现 + 生产调用点核对 |

P2 表示应修正的正确性、阻塞或资源边界问题；P3 表示较低优先级的产品边界问题。没有将可疑但未证实的情形升级为高优先级缺陷。

## F1：cmux 的超时没有覆盖标准输出读取

位置：[KeyboardInjector.swift:1740](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/Input/KeyboardInjector.swift#L1740)，尤其是 1759 行的进程等待与 1770 行的 `readDataToEndOfFile()`。

`runCmuxCommand` 先等待主进程退出，退出后再同步读取标准输出直到 EOF。超时只约束 `completion.wait`，不约束后面的读取。若 CLI 启动了继承 stdout 的子进程，主进程虽然已经退出，管道仍未关闭，读取会持续等待。另一个方向是 stdout 较大时，在父进程开始读取前就填满管道，CLI 可能被误判为执行超时。

**已复现的情形**：从当前文件原样抽取运行函数，仅调整访问修饰及承载类型，在隔离 Swift 程序中使用：

```text
executable: /bin/sh
arguments: -c "/bin/sleep 3 & printf done"
timeout: 0.5 秒
实测耗时: 约 3.008 秒
timedOut: false
terminationStatus: 0
```

这说明主进程已正常退出，超时也未触发，但调用仍被后续管道读取拖住。将继承 stdout 的子进程换成长时间运行的程序，阻塞时间可继续增长。本轮没有运行无限挂起进程，也没有证明正常版本的 cmux 一定会产生这个情形。

影响是卡住共享 `application-focus` 串行队列，使后续应用聚焦/输入框定位任务无法推进；不能据此推断整个 macOS 会死机。

**建议**：启动后异步读取 stdout，并对整个事务共用一个截止时间；限制累计输出大小。在超时、取消、主进程退出但 EOF 未到时关闭读取端并完成事务。不要以等待整个进程结束后才开始读管道的方式实现超时。补“子进程继承输出管道”和“大输出”两类测试。

## F2：常用短语的大小限制没有保护文件读取

位置：[CommonPhraseSettingsView.swift:330](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/CommonPhrases/CommonPhraseSettingsView.swift#L330)、[CommonPhraseStore.swift:149](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/CommonPhrases/CommonPhraseStore.swift#L149)。

用户从导入对话框选中 `.json` 后，界面同步执行：

```swift
try store.importData(Data(contentsOf: url))
```

`importData` 的 `data.count <= 4_000_000` 检查发生在文件已经完整读入之后。文件类型过滤不等于大小限制。较大的 JSON 文件会先带来与文件大小相关的内存和同步 I/O 成本，然后才被拒绝，可能导致界面停顿或内存压力。

这是直接由生产调用顺序确认的问题；**没有通过读取巨型文件、制造内存耗尽或系统卡顿来验证**。一般配置导入已有 `ConfigurationFileReader` 的限量读取，短语导入没有复用同等保护。

**建议**：为短语导入采用最多读取上限加一字节的 reader，并允许指定 4,000,000 字节限制；超过上限即拒绝。不要只检查文件 metadata，因为文件可能在检查后增长。将文件读取/解析移出 UI 主线程，在完成时更新界面。测试应验证读取阶段就被截断，而不只是验证已经生成的巨大 `Data` 被 Store 拒绝。

## F3：导入应用配置没有校验 UUID 唯一性

位置：[AppSettings.ConfigurationTransfer.swift:213](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/Settings/AppSettings.ConfigurationTransfer.swift#L213)、同文件 252 行，以及 [AppSettings.ButtonMappings.swift:62](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/Settings/AppSettings.ButtonMappings.swift#L62)。

导入器逐条校验应用名、bundle identifier、路径和快捷键，但没有校验 `customApplicationProfiles` 的 ID 是否唯一。两条合法记录可以共用同一 UUID，并被一起持久化。绑定、修改和删除以 UUID 定位，其中 `customApplicationProfile(id:)` 返回第一个匹配项。

**已复现**：使用当前 main 的真实 `AppSettings` 和隔离的 UserDefaults suite，导出后重新导入：

```text
记录 First:  id = 同一个 UUID，bundleIdentifier = review.first
记录 Second: id = 同一个 UUID，bundleIdentifier = review.second
导入后记录数: 2
唯一 ID 数: 1
按该 ID 查找: review.first
```

两个记录都通过现有条目级验证；选择第二个应用的 ID 仍会解析为第一个应用。SwiftUI 的 `ForEach` 同样依赖唯一 ID，但本轮没有实际操作其界面，**不声称已经复现 SwiftUI 崩溃**。已确认的问题是配置身份歧义与错误查找结果。

**建议**：在写入任何设置之前验证 UUID 唯一性，拒绝重复记录或采用明确的去重策略，并通过现有导入提示报告。不要为开发阶段不存在的历史用户添加迁移兼容层，也不要静默换 ID 而让原绑定失去对应关系。测试覆盖同 ID/不同应用、同 ID/相同内容，以及绑定目标的一致性。

## F4：Release 仍接受本地测试更新源

位置：[UpdateInformationStore.swift:42](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/Updates/UpdateInformationStore.swift#L42)、[VoiceInputBuddyApp.swift:842](https://github.com/zfdang/voice-input-buddy/blob/0f342072277f33d1afa24b7e50b9be4220106d68/Sources/VoiceInputBuddy/App/VoiceInputBuddyApp.swift#L842)、同文件 1044 行。

`testInjectedFeed` 检查 `VOICE_INPUT_BUDDY_UI_TEST_MODE` 等环境变量，但它及两个生产调用点没有 `#if DEBUG` 限制。只要启用预发行检查并提供匹配的环境变量，就能绕过通常的 HTTPS 官方源选择，返回 `http://127.0.0.1:<port>/appcast-*.xml`。

**已复现**：原样抽取当前的 resolver/版本解析代码，以 `swiftc -O` 编译且未定义 DEBUG，传入：

```text
VOICE_INPUT_BUDDY_UI_TEST_MODE=1
VOICE_INPUT_BUDDY_UI_TEST_FEED_URL=http://127.0.0.1:8765/appcast-arm64.xml
VOICE_INPUT_BUDDY_UI_TEST_VERSION=v26-10-13.099
includePreRelease=true
返回: http://127.0.0.1:8765/appcast-arm64.xml
```

生产 Sparkle delegate 会返回这个 URL，信息检查路径也使用它。本轮没有下载或安装测试更新。环境变量由本地启动环境控制，且 **Sparkle 的更新包签名检查没有被绕过**，因此不能把这个问题描述为未签名代码执行漏洞。风险是测试配置泄露到公开版、更新检查来源偏离正式产品边界。

**建议**：将测试 resolver 及其调用点限定在 DEBUG，或使用独立测试入口。补 Release 条件下环境变量不能改写更新源的验证；不要削弱现有 Ed25519 验证。

## 非阻塞清理项

这些项目没有被计入上面的 4 个功能问题：

1. `AppSettings.ConfigurationTransfer.swift` 的 `portableLocalSnapshot()` 与 `applyPortableLocalSnapshot(_:)` 在 Sources/Tests 中没有调用点。后者直接覆盖多项设置，其注释引用的内存准备/恢复 journal 调用方目前不存在。建议删除无调用的入口与对应过时说明；不把内部未暴露函数直接认定为外部配置注入漏洞。
2. 两种语言都重复声明 `onboarding.voice_tool.guide.select_microphone`：英文 714/894 行，中文 713/893 行，且值不同。当前 plist 解析成功，最终取后面的值，尚未发现实际显示错误；建议每个 key 只保留一份，并增加重复声明检查。仅比较解析后 key 集合发现不了这个问题。
3. `docs/development.md:94` 仍将 `totalButtonPressCount`、`totalVoiceDuration`、`voiceSessionRanking` 列为已恢复访问控制的属性；Sources 中已没有这些成员。应更新文档，但这不意味着应用仍在收集统计。

## 审查覆盖与已核实的边界

当前 Sources 有 **159 个 Swift 文件、43,189 行 Swift**。审查包含目录/依赖盘点、危险操作索引、关键调用链的定向静态检查、现有测试及独立复现；不是对每一行或所有第三方依赖做形式化证明。

| 范围 | 本轮检查重点 | 结论与边界 |
| --- | --- | --- |
| 启动、退出、单实例、登录启动 | flock、进程检查、退出清理、SMAppService、测试模式门控 | 主 App 未发现新的确定性崩溃路径；锁失败时的进程枚举 fallback 不等同于严格跨进程互斥保证 |
| 输入监控与辅助功能 | event tap 回调、延迟恢复代次、共享过滤器、撤权清理、中断状态、按键释放 | 显式中断状态已接入；两种停用通知都在回调外检查权限；失败释放保留 latch，没有复用旧文案判断恢复 |
| HID 与手势 | report 路由、设备归属、重复/长按/双击、原生直通、watchdog、reset | 8 秒 watchdog 由硬件 report 续期，是丢失松键与超长按住之间的取舍；真机 report 节奏未验证，不把自动 repeat 当作硬件存活证据 |
| 蓝牙与协议 | generation、未授权/断电/reset、重连、ATT 写队列、帧解析、待启动音频归属 | 未授权分支取消重连并结束语音；写队列有容量/超时；静态和测试没有确认跨设备会话被误接管的新问题 |
| 音频输出与恢复 | configure rollback、engine queue、pending buffer/drain、HAL 变更合并、默认设备 | 失败配置与 stop/drain 的记账有现有回归覆盖；正式路径未发现写系统默认输入/输出的调用；实际驱动故障和 AVAudioEngine 异常未实测 |
| 输入工具、聚焦、常用短语 | 输入源切换、目标就绪、AX 查询预算、敏感输入元数据、剪贴板恢复 | 确认 F1/F2；目标内容不被读取来判断粘贴成功，日志不应被解释为第三方输入文本已验收 |
| 配置与存储 | 限量读取、gain/identifier/path 校验、统一绑定、损坏备份、应用身份 | 一般配置有 2 MiB reader；确认 F3；没有把未安装应用可携带配置误报为任意路径执行 |
| 向导、资源与本地化 | 步骤门槛、工具可见性、指导图选择、缩放/缓存、完成状态 | 资源验证通过；未做全页面视觉点击验收；发现重复本地化声明但解析后 key 集合一致 |
| 日志与隐私 | 文件权限、轮转/保留、记录内容、上传入口、网络调用 | 未发现可执行的新增遥测上传端点；文本日志保留轮转保护；flock/磁盘 I/O 仍可能等待，不能将其当成严格实时组件 |
| 更新与发布 | feed 选择、Sparkle 签名、版本、不可变 Release、Pages artifact | 确认 F4；签名测试通过；main 自动发布是已授权产品行为，不列为缺陷 |
| 安装与卸载 | 固定路径、bundle 身份检查、用户态数据清理、登录项注销、架构 | fixture 检查通过；未在本机执行安装/卸载；uninstall 的 coreaudiod 重启失败仍可能要求人工重启，不能仅凭 fixture 证明所有真实 Installer UI 路径 |
| 驱动与第三方 | BlackHole 固定 revision、本项目补丁、独立 UID/factory、架构与资源、来源说明 | 本地构建 arm64 驱动及 UID/name getter harness 通过；未将其加载进 Core Audio，也没有对上游 BlackHole/Sparkle 的全部实现逐行独立审计 |
| 实验性辅助目标 | IPC token、回环绑定、帧上限、候选连接/握手超时、HCI 生命周期 | helper 回环测试通过；音频管线显式 unavailable；它没有被当作正式支持的 Siri Remote 语音能力来验收 |
| 静态网站 | 本地入口、语言/下载链接、Pages feed 部署校验 | 检查发布链路与静态页面源；未检查线上 DNS、实际浏览器渲染或公开下载链路的实时可用性 |

## 本轮验证

环境：macOS 15.8.1（24H32），Apple Silicon；Xcode 26.3（17C529），Apple Swift 6.2.4。Swift 命令设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

| 验证 | 结果 |
| --- | --- |
| `swift test --disable-keychain` | 163 个测试 / 19 个套件通过，无编译告警 |
| `swift build -c release --disable-keychain` | 通过，无编译告警 |
| `test-release-metadata.py`、`test-release-sources.py` | 通过 |
| `test-common-phrases.py`、`test-dependency-checkout.py` | 通过 |
| `test-app-bundle.py`、`test-installation-actions.py` | 分别 5 / 4 个 fixture 测试通过 |
| `test-appcast.py`、`test-pages-update-feeds.py` | 分别 2 / 7 个测试通过 |
| `test-update-signature.py` | 正确签名、错误密钥、被篡改包三种场景通过 |
| arm64 `build-driver.sh` + `test-driver-identity.py` | 构建通过；固定/格式化两种命名 getter 检查通过 |
| BlackHole checkout + 本项目 patch 验证 | 通过，固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf` |
| helper 构建 + `test-helper-ipc.py` | 构建通过；2 个真实回环测试通过，未请求音频采集 |
| `verify-onboarding-resources.py Resources` | 21 张设置/设备图通过 |
| 两种 Localizable.strings plist/key 检查 | 解析通过，各 1188 个解析后 key，集合一致；原文重复声明另列于清理项 |
| 临时 AppSettings 导入复现 | 1 个隔离测试通过，证明重复 UUID 被接受；临时测试已删除 |
| cmux/Release feed 独立复现 | 上述 F1/F4 结果成立；没有连接实际更新源或安装包 |

编译与测试日志位于本机 `/tmp/buddy-full-review-*.log`；cmux 与 feed 复现源码分别为 `/tmp/buddy-cmux-timeout-probe.swift`、`/tmp/buddy-release-feed-probe.swift`。这些是临时验证材料，不作为产品源码或 Release 附件。

## 修复顺序与验收建议

优先修复 F1/F2，给可能阻塞或分配大量资源的操作建立真正的边界；随后修复 F3，保证导入后身份唯一；F4 应在公开版测试入口清理中处理。三个清理项可以独立整理，避免与功能修复混在一起。

后续实机验收仍需要单独覆盖：运行中撤销/恢复输入监控和辅助功能，方向键与语音键长按超过 10 秒，蓝牙断开/关闭权限时的录音与松键，Mac 睡眠唤醒、驱动移除和重连，微信/豆包/VoiceCursor 的实际文本输入，Intel 安装与卸载。**本轮没有主动重现曾经导致强制重启的撤权操作，也没有确认或排除那次系统卡死的唯一根因。**
