# macOS 开发与驱动

首次构建、为自己的发布生成固定证书及设置 GitHub Secrets，请先阅读 [构建与固定签名证书](build-and-signing.md)。普通本地构建不需要本项目的发布私钥。

SwiftPM 主执行目标为 VoiceInputBuddy。采用公开源码的默认构建，不接受上游私有包环境变量。构建时使用 --disable-keychain，避免公开二进制依赖扫描登录钥匙串。

开发 App：运行 scripts/build-app.sh，输出 dist/Voice Input Buddy.app。首次设置会请求需要的权限，蓝牙权限描述位于 Resources/Info.plist。应用身份为 com.zfdang.voice-input-buddy，设置和系统权限与原产品独立。

虚拟麦克风：scripts/build-driver.sh 固定 BlackHole v0.7.1 的 e2b22aaaba4e507a097131704bf96dabc004d9cf，应用 USB transport 补丁，使用独立工厂 UUID、Bundle ID 和 BuddyMic UID，避免替换 BlackHole 或原 MiRemoteV 驱动。输出 VoiceInputBuddyMic.driver。scripts/build-driver-package.sh 创建系统 HAL 目录安装包，安装需用户明确授权；安装器在安装前的说明页明确提示：新安装或内容变化的驱动需要重启 Core Audio，短暂中断系统全部播放和录音；驱动未变则不重启。安装后刷新失败时提示重启系统。驱动编译禁用 BlackHole 的通道名称格式，确保实际 UID 为 BuddyMic2ch_UID。

应用不会自动修改系统默认音频设备。遥控器连接空闲时不保持音频引擎活动，避免 Core Audio 长期阻止系统自动休眠；语音开始时按需启动，启动期间缓冲语音，语音结束后等待尾音和 Fn 轻点会话处理完成再释放。启动验证及测试音完成后也释放空闲音频。遥控器断开、应用停止、退出、音频配置失败及重连时，只释放或重新绑定应用自身的音频输出；系统默认输入、输出及系统提示音设备保持由用户或系统管理。App 固定使用 Voice Input Buddy Mic（`BuddyMic2ch_UID`），第三方工具的麦克风需选择该设备；没有输出选择或 BlackHole 回退。目标语音快捷键通过向导按工具实际设置配置并验证。

当前发行使用固定自签名证书为 App 和驱动签名，PKG 未签名，不具备 Apple Developer ID，也未公证。证书只生成一次，私钥由 GitHub Secrets 保存；构建时导入 runner 的临时 Keychain，不添加证书信任设置。普通本地开发和 PR 构建仍默认 ad-hoc 签名。更新包另由本项目的 Sparkle Ed25519 密钥签名；push main 自动发布。配置和验收要求见 [releases.md](releases.md)。若以后取得 Developer ID，应加入 Application / Installer 签名和公证。驱动安装卸载仍需真机回归。不会沿用原作者更新密钥、会员后端或发布服务。

手机、Watch、Web Remote 和 Siri Remote 的退休运行逻辑、占位模块与开关已移除，仅保留计划设备的目录展示；Apple 音频捕获、PacketLogger、HCI 辅助进程、上游私有扩展接入分支、历史采集、录音归档与 MCP 已移除。构建成功不代表未支持设备可用。

长录音在请求音频启动时即记录操作代次；启动期间取消后，迟到的音频回调不得重新开麦。启动失败、取消或开麦超时后释放空闲音频。

## 运行时权限变化

输入监控或辅助功能权限撤销时，先停止共享键盘过滤器，再注销 HID 回调并关闭设备。过滤器自身也检查启动权限，不能只依赖设备监听器的检查。HID 清理记录 begin/completed 阶段，便于区分输入过滤与同步 IOKit 关闭的停滞；IOKit 仍在所属主 RunLoop 上清理，不把设备句柄转交给任意后台线程。

系统停用 event tap 的回调只安排后续处理并立即返回。超时或系统用户输入停用通知均在回调外重新检查权限；权限有效时恢复当前端口，权限无效时停止过滤器与设备映射。监听中断用显式状态记录，不依赖界面文案；实际监听与过滤恢复后清除中断状态。端口或恢复代次已改变时，丢弃旧恢复任务。快捷键录制对象继续在析构时注销端口。语音快捷键释放失败时保留 held 状态，不绕过辅助功能权限检查；权限恢复后再尝试释放。

辅助功能消息超时仅在本进程首次查询时配置一次为 50 毫秒，不修改其他进程，也不逐属性重复配置；首次配置失败时记录一次日志。跨进程辅助功能调用沿用这个超时，输入框树遍历同时受节点数和单调时钟的一秒预算限制，子节点优先级计算也消耗预算。预算阻止开始新的节点；已开始的节点仍需完成其有超时限制的消息，不能将这一秒理解为整项操作的硬截止。

蓝牙未授权时取消重连、释放连接与语音状态，不继续自动连接。应用的正式音频路径接收蓝牙遥控器的 PCM 并写入虚拟音频设备，没有直接采集 Mac 物理麦克风的录音路径；输入工具的麦克风权限由对应第三方应用管理。

已配置遥控器处于扫描或失败重试等待时，每 2 秒查询其系统蓝牙连接状态；只有标识匹配的设备已连接，才取消剩余退避并接入语音服务。该查询不重启广播扫描，也不向离线设备追加连接请求。已绑定 HID 的连接通知或按键活动也会在输入回调结束后触发提前重试。正在连接、初始化、已就绪、断开清理或系统挂起时不重复触发。原有 20 秒扫描兜底和离线失败退避保留，本地日志中的 `BLE WAKE RECOVERY` 记录恢复原因、结果和耗时。真机验收应覆盖遥控器休眠后唤醒、长时间离线后按键、连续按键及 Mac 睡眠恢复。

权限状态模拟测试和构建成功不证明 macOS 在真实撤权时不会挂起。强制关机前未留下线程采样或 panic 栈时，不应把上述加固直接认定为系统死机根因或硬件验收结论。

## 异步操作生命周期

音频启动只在准备队列枚举设备，回到主线程后采用固定输出 UID 并排队配置。停止时直接向音频引擎队列提交释放；旧枚举或启动回调不会释放后续会话的输出，也不会覆盖更新配置的状态。

快捷键录制结果在回调送达时再次检查录制代次。停止、重置或销毁录制器后，排队中的普通按键和独立修饰键结果均作废。HID 映射只有在设备被独占或原始按键过滤器运行时才附加动作；过滤不可用时停止重复与延迟手势动作，保留默认左右方向键的原生直通。

更新源使用独立的临时 URLSession，空闲和总请求超时均为 30 秒。响应头和流式读取均检查 1 MiB 上限，超限时取消该请求。不会修改共享 URLSession 的配置，不增加常驻轮询或逐输入事件的权限查询。

启动前预录音与实时 PCM 使用独立的队列额度：预录音最多 80,000 个采样（5 秒），实时待播放音频最多 8,000 个采样（半秒）。预录音分成不超过半秒的播放块，按原顺序送入播放器，不通过放大实时额度消化积压。Fn 点按停止的排空期限按待播放时长加余量计算，保留取消、输出中断和过期回调隔离。

## 本地开发

需要完整 Xcode 和 Swift 6.2 或更新版本。首次构建会下载 Sparkle 2.9.4。若当前选择 Command Line Tools，可使用 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

```bash
swift build --disable-keychain
swift test --disable-keychain
./scripts/build-app.sh
./scripts/build-driver.sh
```

### 单元测试

测试按数据持久化、输入事件、异步操作生命周期、权限状态、音频状态和协议边界组织。新增行为应同时覆盖成功、失败、取消及旧回调送达后的结果，不能只检查实现是否调用了某个方法。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-code-coverage --disable-keychain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release --disable-keychain
```

覆盖率报告位于 `.build/debug/codecov/VoiceInputBuddy.json`。按文件检查未覆盖的行为，尤其是错误处理与资源释放；文件覆盖率包含系统适配代码，不能把模拟状态机的通过当作真实系统权限或硬件操作的验证。

异步边界测试使用可控调度器，显式送达已经取消的旧回调，不依赖睡眠等待。权限轮询、快捷键发送与输入目标测试注入状态和事件接收器，不修改真实权限、发送系统按键或切换其他应用。常用语插入测试注入目标与按键接口，剪贴板事务只使用测试专用 pasteboard，不读取或修改系统通用剪贴板；持久化和文件锁测试使用独立 UserDefaults 域及临时目录，不读取或修改用户的应用设置。结构化诊断测试仅验证本地日志；没有诊断上传和待上传事件存储。

所有映射键盘事件统一排除隐式导航标志：小米遥控器原生 Home 实测带有 `0x800100` 标志，其中包含 Fn，且不一定带数字键盘标志。普通按键、内置／自定义快捷键、独立修饰键、应用切换器和滚动动作不继承硬件状态中的 Fn／数字键盘导航标志，仍保留 Shift、Control、Option、Command 等实际修饰键；只有映射明确配置 Fn 时才在生成事件中加入 Fn。媒体键本身使用空修饰键，不合并原始 Home 状态；无需改写的原生方向键仍按原事件透传。语音 Fn 使用独立路径，保持其按住和松开行为。`MAPPED KEY EVENT` 与 `SHORTCUT SEQUENCE phase=event` 记录实际提交的键码、边沿和修饰键标志；`submitted` 不代表目标应用已经响应。回归测试覆盖原生 Home 状态下的完整选择／取消序列、普通映射键、内置快捷键和显式 Fn 映射，修复后的切换器显示和确认仍需实机复测。

开发 App 位于 `dist/Voice Input Buddy.app`，驱动位于 `dist/VoiceInputBuddyMic.driver`。App 构建按架构使用独立的 `.build/app-arm64` 与 `.build/app-x86_64` 目录，避免 SwiftPM 缓存混用。Release 与一体安装包的复现步骤见 [发布流程](releases.md)。

本地 `scripts/build-app.sh` 与发布 workflow 共用 Git 版本计算：最近提交在 Asia/Singapore 的日期与完整历史提交数生成 `vYY-MM-DD.NNN`。设置页显示该标记；macOS 的数字版本及构建号分别写入 `CFBundleShortVersionString` 与 `CFBundleVersion`。本地源码有未提交修改时，版本仍对应当前 HEAD，不能把它当作正式发布源码标识。

可选的本地完整源码归档脚本（不作为 Release 附件上传）要求工作区干净（包括暂存、未暂存和未跟踪文件），以保证 HEAD 源码与构建输入一致。忽略目录中的开发输出不会纳入源码包。

测试需要完整 Xcode 提供的 Swift Testing；如遇 `No such module Testing`，设置上面的 `DEVELOPER_DIR`。仅当受限执行环境报 `sandbox-exec: sandbox_apply: Operation not permitted` 时，可在该环境中使用 `swift build --disable-keychain --disable-sandbox`；正常本地与 CI 构建不需要关闭 SwiftPM 沙箱。

App 打包先在临时目录组装全新的 bundle，资源检查和签名成功后再替换 `dist` 中的 App。重复构建不会保留已移除的资源或框架；打包失败时保留上一份 App。可运行 `python3 scripts/test-app-bundle.py` 验证这两条行为。

配置导入保留本机已有的设备档案映射。跨 Mac 导入时，导出文件中当前选中设备的按键映射会应用到本机当前选中设备；尚未配对时作为默认映射保存。其他无法对应到本机设备的映射会显示导入提示，不会悄悄接受后失效。导出统一使用当前格式 2，不读取旧格式；缺少选择信息时不猜测未知设备档案的对应关系。

已删除停用的上游硬件公告数据层、占位服务地址和空面板；新增设备支持通过本项目的发行说明公布。

SwiftPM 使用 Swift 6.2 工具链，语言模式暂为 Swift 5。这是现有并发边界的迁移状态，并不代表已经通过 Swift 6 严格并发检查。切换语言模式需要单独审查事件 tap、蓝牙回调、音频队列和 MainActor 的隔离，不能以一次 manifest 修改代替并发验证。历史 Apple 音频捕获、PacketLogger 与 HCI helper 已移除；CI 只构建当前产品。

HID 原始映射在改写前一次性原子写入 `~/Library/Application Support/VoiceInputBuddy/HIDMappingRecovery.json`。记录绑定本机启动会话；UUID 不可用时用系统启动时间识别，同样无法识别或写入失败时拒绝改写 HID。离线或恢复失败时保留记录，下次重连/启动继续恢复；不恢复到用户后来主动更改的映射。

Fn 释放最多尝试四次，重试间隔为 1、2、4 秒。耗尽后以失败结果回答配置等待方，保持未释放状态并阻止映射切换；恢复辅助功能权限后可重试释放。旧音频的隔离状态与 Fn 清理完成分离，避免用户切换模式时等待一个尚未到来的遥控器停止通知。音频排空取消、停止及销毁都会回答等待方一次；排空由完成回调与看门狗共同处理。

微信／豆包等指定输入法的遥控器 Fn 长按由 App 控制：小米原生语音键先中和，再切换输入法并确认 TIS 选择状态，在主运行循环中保留至少 50ms 的激活处理时间，最后提交软件 Fn down。选择等待上限 500ms，若在截止前选中则额外允许最多 50ms 稳定时间；等待中松开、取消或超时均不提交 down。激活期间的蓝牙 PCM 暂存，成功触发后再送往现有虚拟麦克风。遥控器停止负责 Fn up 和输入法会话结束，不依赖全局 flagsChanged 能否收到松开。辅助功能权限或小米中和映射不可用时拒绝启动，避免重新走存在时序竞争的硬件路径。

激活等待沿用主循环当前的具体 mode（包括 event tracking），不运行仅用于注册源的 `.common` 伪 mode。工具在录音中更换时暂存映射刷新，等所有语音会话与按键清理结束后再应用。

软件语音键带独立事件标记，全局输入法监听器不再重复认领这些 Fn 事件；普通键盘 Fn 和现有点按转换仍保留原有处理。语音键成功提交后，松开、断开、停止监听均保留当前输入法，不自动切回；Fn up 只表示录音结束，不表示输入法已把异步识别结果提交到文本框。只有未发出语音键的启动失败或取消会撤销输入法切换，且不会覆盖用户主动选择的输入法。诊断中的 source_activation 表示输入法选择已确认，VOICE KEY 的 event_submitted 只表示按键已提交，均不是微信输入法实际开始录音的确认。Issue #36 的实机复测应在 Chrome 文本框中从非微信输入法开始，验证第一次按住、连续按住／松开、等待中快速松开及窗口切换，无需先多按几次。

HID 设备发现仅用受支持的 VendorID／ProductID 组合。IOHIDManager 不会按 Product 名称过滤；只有 Product 名称的 OR 条件会匹配无关设备，碰到其他工具独占的键盘后导致整个 manager 打开失败。不得以名称匹配补充底层 HID 发现；蓝牙名称识别仍由设备接入策略处理。

事件 tap 的非独占降级模式无法可靠区分相同键码的设备。为避免遥控器快速点击在 HID 释放后才送达的原生 down 造成两次动作，保留 180 毫秒的待匹配 down/up；这也存在同窗口内误吞物理键盘同键码的取舍。不能单用 held 计数过滤，否则会恢复快速点击重复动作的问题。残留 held 状态设置 30 秒上限；独占 HID 路径优先，降级路径仍需实际设备验收。

蓝牙 `.withResponse` 命令采用有界串行队列，成功 ACK 才发下一条；错误或五秒超时清队列并重连。入队成功只表示接受命令，ATVV 通知才确认实际音频流。

共享日志器不再创建持久化的公开诊断上传队列；没有配置上传服务。运行日志以 UTF-8 文本保存在 `~/Library/Logs/VoiceInputBuddy/`，无需公钥或解密工具，用户可以自行查看；每个文件限制为 10 MiB，达到上限会在当前会话内轮转，最多保留五份旧日志，跳过仍在使用的日志及符号链接。日志不保存录音或识别正文，也不会上传。菜单“显示日志”会先刷新日志，再定位到当前 `.log` 文件。常用语 JSON 由 `scripts/generate-common-phrases.py` 从 Markdown 编辑源生成，打包测试校验生成资源确实存在。

向导第六步的每种输入工具包含五个设置步骤，第三个为输入工具自身的麦克风选择；macOS 听写包含四个步骤：打开听写、把快捷键设为“按两下 🌐 键”、选择麦克风来源、清空微信 App 的 Fn 快捷键。它需要系统 🌐 键用于听写，所以不包含“去除系统 Fn 占用”。三个听写步骤使用 2026-10-25 从本机系统设置截取并标注的真实浅色 JPG：开启听写、双击 🌐 快捷键、Voice Input Buddy Mic 麦克风来源；深色界面回退到同一真实截图。首次开启须确认系统隐私提示，并等待所需语言支持下载完成。语音搭子按住遥控器时连按两次 Fn 开始听写，松开并送完音频后按一次 Fn 结束；设置指引不要求手动勾选确认；查看每个步骤后可进入第七步实际测试，步骤完成标记仅表示用户已查看，不表示已检测第三方设置。第七步仅根据按键、声音和文字结果判断通过，不再重复询问设置。豆包和微信的菜单、语音设置、麦克风六张浅色截图于 2026-10-12 从本机安装版本截取并标注，使用 JPG 保存，显示时整图按原比例缩放。VoiceCursor 的快捷键和麦克风使用本机浅色截图。新增 JPG 长边最多 1600 像素，并压缩文件大小。加载和打包校验支持 JPG、JPEG、PNG；优先匹配当前主题，再回退浅色。既有深色截图保持不变；新增截图只有真实浅色版本时，深色界面使用浅色截图回退。微信 App 快捷键及未安装工具的截图保留原素材。

说明图片在固定显示区内按原比例缩放，整图显示，不采用超出区域的放大和偏移裁剪；同时关闭图片命中测试，确保不会挡住步骤按钮。Debug 构建可在现有向导截图模式中设置 `VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_INTERACTIVE=1`，使用隔离设置打开输入工具页面，最多停留五分钟以进行真实鼠标验证；Release 构建不会启用此交互模式。

## 源码组织

主应用继续使用一个 SwiftPM executable target；`Sources/VoiceInputBuddy/` 按功能划分：

| 目录 | 职责 |
| --- | --- |
| App | 应用入口、菜单栏、生命周期；Coordination 保存应用状态及跨功能编排，Testing 保存隔离截图工具 |
| Devices | 蓝牙、HID、设备识别、遥控器连接与事件 |
| Audio | 音频路由、输出、缓冲、设备和会话恢复 |
| Input | 按键注入、映射、快捷键与输入目标 |
| Integrations | 输入工具能力、输入源和 deep link |
| Onboarding | 向导各步骤、输入工具指南、测试状态机及原生文本编辑器 |
| Settings | 配置持久化、导入校验、设置页面及共享呈现组件 |
| CommonPhrases | 常用语存储、插入、设置及浮层 |
| Updates | 更新信息与本地化更新界面 |
| Diagnostics | 本地日志与诊断；没有历史统计数据模型或上传队列 |
| Support | 本地化、链接；UnavailableFeatures 仅保留计划中的 Siri Remote 能力边界 |

`BridgeAppModel` 保留唯一的应用状态和初始化入口，行为按连接、音频、按键和权限分入同一类型的功能扩展。`AppSettings` 保留唯一的 UserDefaults 所有者，向导配置、按键映射、导入校验和持久化各自组织。`SettingsView` 与 `OnboardingView` 保留原来的 SwiftUI 状态及 view identity，页面、指南、生命周期和呈现组件分开维护；没有创建重复的状态对象。

跨文件扩展需要的成员使用模块内部可见性，文件内独用的辅助实现仍为 private；没有新增 public API，也未增加 target 或模块依赖。新增功能应放到对应目录，避免再把页面与硬件操作混入入口文件。

跨文件扩展所需的 internal setter 并不是独立模块边界；同一 target 的任何文件技术上都能写它们。仅在主文件写入的属性继续使用 private(set)，例如 corruptedSettingKeys。页面应通过状态所有者的操作方法请求变化，避免直接改写连接、音频和向导状态。若以后需要更强的编译期隔离，应将状态与操作一起封装到独立服务或 target，不能把目录拆分当作这种隔离。

向导专用的焦点 modifier 直接在导航页面使用，不再给整个模块的 View 增加扩展方法。

本地资源定位根据 Package.swift 与 Resources 目录查找，不依赖源码所在层级。打包资源检查递归扫描整个 Sources/VoiceInputBuddy，以覆盖位于 Integrations 等其他功能目录的向导截图引用；同时检查 Onboarding 源码仍存在，没有源码时直接失败，不能静默跳过。`scripts/test-app-bundle.py` 用隔离的编译/签名 fixture 验证嵌套指南缺图时保留已有 App，不需要安装真实驱动。

### Remote device scope

The product device list is limited to Xiaomi Bluetooth Remote 2 / 2 Pro, Google
Chromecast Voice Remote (G9N9N), Google TV Streamer Voice Remote (GY3LE), and
Apple Siri Remote. `RemoteSetupDevice` defines this scope; it does not grant
connection support. All four entries can be selected. Continue advances Xiaomi and both Google choices to
connection setup; Siri remains on the device page with an unsupported notice.
The GY3LE setup entry does not admit it through the G9N9N adapter. G9N9N connection
validation remains mandatory; its public adapter is implemented with hardware acceptance pending. The
validated Xiaomi admission catalog remains separate, so a planned Google model
cannot accidentally connect through the Xiaomi bridge. Third-party replacement
remotes need individual validation.

型号、兼容性和配对说明见[遥控器说明](remote-device-preparation.md)，素材维护见 [artwork.md](artwork.md)，官方外观参考见[示意图说明](../Resources/RemoteIllustrations/README.md)。

小米 DIS 型号 RC001 对应遥控器 2，RC003 对应遥控器 2 Pro；两款使用相同的普通按键布局，语音键单独处理。小米与 G9N9N 当前均解码为 16 kHz PCM，经固定虚拟麦克风输出；使用 ATVV 服务不代表某个新型号已经通过验证。

### Google remote compatibility acceptance

G9N9N and GY3LE identify the two Google product targets, not every replacement
sold under those names. Original units and third-party replacements follow the
same capability checks. Device names, printed labels, DIS model numbers, and
VID/PID are identification hints, not proof of origin or working audio.

Before enabling a Google adapter, validate these independently:

- HID descriptor and observed press/release reports, including the voice key;
  do not assume every replacement uses the same three-byte report layout.
- ATVV service `AB5E0001-5A21-4F05-BC7D-AF01F617B664` and its transmit,
  audio, and control characteristics (`AB5E0002`, `AB5E0003`, `AB5E0004`
  with the same UUID suffix), including write and notification access.
- Negotiated protocol version, codec, sample rate, frame size, and usable
  decoded PCM. Finding a service alone does not establish audio support.
- User-initiated start/stop, long-session keepalive, release or stop behavior,
  trailing audio, and delivery through the existing virtual microphone.
- Sleep/wake, reconnect, and simultaneous system HID and GATT operation on macOS.
- At least one original reference unit and any replacement unit separately;
  record manufacturer/model/firmware and observed capabilities without claiming
  all batches from the same seller are equivalent.

Distinguish buttons-only, audio-only, full support, unsupported codec, and
connection/authentication errors. An `Insufficient Authentication` error is an
incomplete probe: ask for normal system pairing and retry discovery after the
link is secured. Do not classify an inaccessible service as absent, label a
unit counterfeit, or switch to the computer microphone while claiming remote
audio works. This integration uses public APIs without driver injection or private app access.

[vibe-mote's hardware notes](https://github.com/Tilkmilk/vibe-mote#九遥控器怎么挑原装--兼容款--山寨)
report different ATVV behavior across two G9N9N-labelled replacements. These are
Windows observations and research references, not macOS acceptance evidence or
confirmation of GY3LE compatibility.

### Unsupported remote integrations

The public macOS connection flow admits Xiaomi RC001/RC003 and G9N9N. Phone, watch,
Web Remote and Siri Remote have no supported setup entry. G9N9N uses the public ATVV and HID pipeline;
GY3LE is not admitted as a G9N9N device.
Their runtime adapters, session orchestration, management panels, compatibility modules and persisted switches have been removed. Planned physical devices remain catalog-only.
Historical PacketLogger and HCI helpers have been removed from the source tree and CI.
Persisted unsupported device profiles never receive a Xiaomi mapping illustration.
Screenshot fixture entry points are debug-only.

Debug interactive onboarding previews can set `VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_INTERACTIVE_STEP=remoteAvailability` to start at device selection (the default remains `voiceTool`).

### G9N9N implementation boundary

The public bridge opts into G9N9N candidate discovery. An advertised name is only
an initial filter: the same peripheral must report DIS PnP VID/PID 18D1:9450,
and the negotiated protocol must be v1.0 with 16 kHz ADPCM and a bounded frame
size. The DIS model string is informational, never an admission condition. PnP
and capability discovery can finish in either order. Authentication failures request normal macOS pairing;
failed discovery is not treated as proof that the service is absent.

Audio remains headerless v1.0 ADPCM with high-nibble-first decoding and AUDIO_SYNC
predictor restoration. MIC_EXTEND uses the stream ID every ten seconds while
streaming. Existing generation checks, reconnect backoff, output readiness,
voice ownership and tail draining apply to Google sessions as well as Xiaomi.
Google voice shortcuts are synthesized in the app; they do not depend on a
Xiaomi hardware Fn mapping. Physical recording follows the remote's ATVV start
and stop notifications; input tools may use the existing Fn tap conversion.

HID report 2 Consumer Control usages are translated to the common mapping engine,
including mute, YouTube and Netflix. Default HID enumeration uses exact VID/PID
pairs only. Google reports are accepted only for a bound physical fingerprint
whose BLE bridge is ready after DIS and capability confirmation. Enabling Google
never bypasses Xiaomi power suppression; a failed suppression excludes both the
standard Xiaomi ID and its saved replacement IDs from discovery. Other report
layouts, protocols or codecs still require additional evidence/adapters.
Power and input-source keys can use infrared and are excluded from the public
Bluetooth mapping canvas until supported reports are captured.

Hardware acceptance is pending: test an original unit and each replacement
separately for pairing, microphone samples, stop/tail, long sessions, HID/GATT
coexistence, sleep/wake and reconnect. Automated tests cannot establish these.

### Adding compatible remote identities

The connection page's Add new device action opens onboarding at device selection,
preserving existing profiles, mappings and input-tool integration. When the selected
family reaches BLE readiness, optional DIS PnP ID (0x2A50) metadata is compared with
read-only Bluetooth HID enumeration. Automatic association requires one physical
fingerprint and a matching system name. Ambiguous or missing metadata leaves a
manual Associate button device picker in the connection step; it never opens all
keyboards to learn IDs. Normal connection and button validation remain required.

Nonstandard VID/PID pairs are saved with the selected profile and used for future
HID matching. Standard pairs only bind the fingerprint, without another whitelist
entry. Removing or replacing a profile removes its old whitelist entry. Xiaomi
replacement IDs also participate in Fn mapping and power suppression; Google IDs
do not. Updating the mapper's ID list restores owned mappings before replacing it.
A saved ID chooses a transport candidate, not a new protocol adapter or a claim
that every Chromecast-branded replacement works.


### Connection groups and fixed microphone output

The connection page uses one group per saved remote: identity, image, connection
state and gain. Add new device is a prominent page-header action. Gains persist
in the remote profile and BLE decoding resolves gain from the reporting bridge's
Bluetooth identity, independently of the currently selected settings card.
Portable configuration retains explicit per-profile gains, validating bounds
and mapping the source selection to the destination selection.

All sources share the fixed `BuddyMic2ch_UID` output (Voice Input Buddy Mic).
Output selection and remembered/alternate-device fallback have been removed.
Startup and recovery retain their generation guards and use that UID even when
hardware enumeration returns another microphone or speaker. The driver panel
shows the shared output name. Onboarding follows connection, button validation,
then automatic driver/output validation. The driver step stays visible in both
navigation directions; Continue is enabled only when both driver and output are
ready. Installation/restart recovery remains available on failure.

### 运行稳定性与常用语插入

常用语在普通原生空选区文本框中使用 `AXSelectedText`。终端、Web/Electron 及不支持直接写入的安全可编辑目标改用临时剪贴板粘贴；不读取目标文本。事务的校验回调和写入通过 main queue 串行执行，原剪贴板在独立后台队列读取，2 秒超时后不执行写入；迟到的快照也不能重新发起粘贴。目标 AX 验证在后台 queryQueue 完成，并在写入剪贴板前、发送 Cmd+V 前复核焦点和安全状态。剪贴板所有 item/type 的数据最多暂存 32 MiB；不可读、拒绝访问或超出上限时不替换原内容。发送粘贴后等待 750ms，再核对 changeCount 并恢复各项格式；检测到新的 copy 时不恢复旧数据。主队列清理任务持有事务直到恢复完成，面板关闭不会丢失清理。系统不提供跨进程原子粘贴/恢复和目标消费确认，卡顿应用可能错过短语；也不承诺剪贴板管理器不会观察到临时内容。模糊的 AX IPC 失败不会自动重试为粘贴，避免重复插入。安全输入、敏感字段和无法验证的非终端目标不会发送粘贴。

所有离线蓝牙设备共用一个广播扫描器，连接仍由各设备自己的 manager 管理。无响应写入尊重 `canSendWriteWithoutResponse`，排队和等待均有上限；断连回调丢失后由 5 秒看门狗重启连接。测试覆盖队列流控、失效回调、帧索引、输入源不可用和 Fn 取消/关闭时序，但不能替代真实设备、休眠唤醒及输入法验收。

会员、宏、私有功能占位实现及其不可用设置入口已移除，配置不再包含宏动作字段。向导的助手提示词使用实际界面流程，不提供不存在的自动配置 CLI。Appcast 保留受 1 MiB 上限保护的流式读取；异步字节迭代不会必然产生每字节一次的任务调度，不能据此改为无界全量下载。

The `VoicePipelineIntegrationTests` suite drives the Fn-tap session through the
production playback admission and chunking policies with 12k, 32k and 80k sample
pre-rolls, verifies drain timing, and delivers stale completion callbacks after a
new session starts. `SessionInputIntegrationTests` exercises input-source
activation completing across session and screen suspension. Both replace keyboard
injection and audio hardware scheduling; real remote reconnect, HAL routing and
external dictation still require hardware acceptance.

Compact window checks: the settings window fits the current screen's visible
frame on opening and screen changes. Settings keep a readable
980×732 scrollable canvas. Onboarding uses the actual viewport height with
independently scrolling content, so its navigation remains visible; only width
may scroll when space is smaller. Debug preview
rendering accepts `VOICE_INPUT_BUDDY_SETTINGS_SCREENSHOT_SIZE=720x500` and
`VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_SIZE=720x500`; set
`VOICE_INPUT_BUDDY_SCREENSHOT_SCROLL_TO_END=1` to verify bottom/right navigation
remains reachable. Preview fixtures do not start remote or audio hardware.

Hold-to-repeat is represented by the `repeatSingleClick` action in the long-press binding, using the existing per-device binding persistence and portable configuration format. Navigation, volume, and Power buttons default to this value; Back defaults to no long-press action. Power repeats Delete, while Back sends Escape once. The mapping cards display these values explicitly. The HID runtime uses the configured hold value instead of a repeat-capable button allowlist; repeat starts at 350 ms and executes the current single-press action until release. Independent long-press actions retain the 550 ms threshold. Double-click recognition remains available and is cancelled when a held press starts repeating, avoiding a trailing click on release. Timer tokens reject stale repeat callbacks after release or reset. The repeat marker is rejected outside a long-press binding during import.

### G9N9N first hardware inspection (2026-10-19)

Public CoreBluetooth reads on the connected reference unit returned:

- Name: `Chromecast Remote`; manufacturer: `Google Inc.`
- DIS model: `A3`; hardware revision: `CR PVT/MP`; firmware/software: `26.0`.
- DIS PnP bytes: `01 D1 18 50 94 10 01` (VID/PID `18D1:9450`).
- ATVV service: `AB5E0001-5A21-4F05-BC7D-AF01F617B664`.
- Transmit characteristic `0002`: properties `0x04` (write without response).
  Audio `0003` and control `0004`: properties `0x10` (notify).
- Both notifications enabled successfully. Capability request
  `0A 01 00 00 03 03` returned `0B 01 00 02 03 00 F0 01 00 1A`:
  ATVV v1.0, codec mask `0x02`, interaction `0x03`, frame size 240, 16 kHz ADPCM.
- No authentication/encryption error occurred during these reads, subscriptions,
  or the capability exchange. Link encryption was **not independently measured**;
  notification properties and successful access do not prove an unencrypted link.

The previous exact `G9N9N` DIS model check rejected this unit's `A3` before
initialization completed. Admission now uses PnP identity and negotiated audio
capabilities; missing or differing model strings do not reject a remote.
The HID descriptor also exposes report ID 1 with two 8-bit array indices
(logical range 1–17), rather than report ID 2 with 16-bit usages. The adapter
recognizes this exact descriptor before decoding indexed reports; unknown
descriptors are not interpreted as this format. Index zero releases a slot.
The descriptor lists input usage `0x0089`, alongside the previously documented
variant using `0x0189`.

This inspection does not yet establish correct physical button mappings, intelligible
microphone audio, end-to-end stop behavior, long sessions, or sleep/wake acceptance.
See the [hardware debugging record](g9n9n-hardware-debugging.md) for the completed
test attempts, evidence limits, signing checks, and next acceptance steps.
