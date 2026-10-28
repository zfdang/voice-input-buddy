# 遥控器型号、素材与兼容性

设备范围为小米蓝牙遥控器 2／2 Pro、Google G9N9N、Google GY3LE、Apple Siri Remote 四项，均可在向导中选择。小米和两款 Google 选项可进入连接页；Siri Remote 点击继续时仍留在设备选择页并提示尚未支持。GY3LE 的设置入口不代表已完成型号专用协议适配。**G9N9N 当前仅部分支持语音功能，普通按键映射不支持**；实测原因和适用范围见 [独立测试报告](g9n9n-compatibility.md)。

## 官方外观资料与应用素材

| 设备 | 官方图片／按键资料 | 应用内素材 |
| --- | --- | --- |
| Chromecast Voice Remote（G9N9N） | [Google 外观与按键图](https://support.google.com/chromecast/answer/10116742?hl=en) | `Resources/ChromecastG9N9NIllustration.png` |
| Google TV Streamer Voice Remote（GY3LE） | [Google 外观与按键图](https://support.google.com/chromecast/answer/15323195?hl=en)、[商品页](https://store.google.com/product/google_tv_streamer_remote?hl=en-US) | `Resources/GoogleStreamerGY3LEIllustration.png` |
| Apple Siri Remote | [Apple 第三代 USB-C 外观图](https://support.apple.com/en-us/111844)、[型号识别](https://support.apple.com/en-au/103233) | `Resources/SiriRemoteA2854Illustration.png` |

官方图片仅作为链接参考，不复制进安装包。新增素材是原创、无品牌标志的透明背景示意图，按项目 GPL-3.0-only 分发；可编辑 SVG 源文件位于 `Resources/RemoteIllustrations/`。示意图不是照片，也不按实际尺寸比例绘制。

Apple 素材以第三代 USB-C A2854 为外观基准（[Apple 官方型号信息](https://www.apple.com/kr-edu/shop/product/mw5g3kh/a/siri-remote)）。它不代表其他 Siri Remote 代际的按键布局或音频协议已得到支持。正式适配前仍需固定实际样机型号。

## 小米硬件型号与支持范围

| 商品名称 | 蓝牙 DIS 硬件型号 | 当前状态 |
| --- | --- | --- |
| 小米蓝牙遥控器 2 | RC001 | 已包含 ATVV 语音和普通按键适配；完整音频验收待完成 |
| 小米蓝牙遥控器 2 Pro | RC003 | 已本地验证连接和按键；音频已由用户确认正常 |

RC001／RC003 是设备型号，不是协议或商品版本号。两款使用同一套普通按键映射与项目示意图，语音键单独处理；实际固件和第三方兼容款仍需分别验证。ATVV 是 Android TV Voice over BLE，不是 Google 原装遥控器独有，小米也使用它。当前小米与 G9N9N 音频均解码为 16kHz PCM，再送入同一个虚拟麦克风；新增遥控器不需要改麦克风驱动。

## 两款 Google 遥控器的共同点与区别

两款都具有方向环、确认、返回、主页、语音、音量、静音、电源和两个应用快捷键。都以蓝牙连接播放器，并可通过红外控制部分电视／音响功能。GY3LE 官方兼容 Google TV Streamer 及旧 Chromecast with Google TV 4K／HD，但这不是 Mac 协议兼容性证明。上述功能和布局依据表中 Google 官方资料。

| 项目 | G9N9N | GY3LE |
| --- | --- | --- |
| 音量键位置 | 右侧 | 正面右列长条摇杆 |
| 语音键位置 | 方向环下第一排右侧 | 正面左列第二颗 |
| 底部右键 | 输入源 | 自定义键 |
| 寻找遥控器 | 官方按键资料未列出该功能 | 支持响铃；背面有发声孔，不是麦克风接口 |
| Mac HID 报文与按键边沿 | 实测单键及松开短报告无法交付，普通按键映射不支持 | 待本项目真机验证 |
| Mac ATVV 能力／编码／会话 | v1.0／16kHz 语音链路已实测可用；完整生命周期仍待验收 | 待本项目真机验证 |

示意图短标签：H = 主页，M = 静音，MIC = 语音，YT／NF = 应用快捷键，IN = 输入源，星形 = 自定义键。Apple 的 TV 表示电视／控制中心键，右侧窄条表示 Siri 键。

Google 商品页把 Play/Pause 列入功能，但官方布局说明没有单独列出播放／暂停实体键。因此不据此添加未经确认的独立按键位置或 HID 码。

## 兼容性验收边界

配对成功、设备名称、型号标签或 VID/PID 相同，都不能证明按键与音频完整可用。原装设备和第三方兼容款必须分别检查 HID 描述符、按下／松开报告、ATVV 能力与音频解码，以及长会话、休眠重连和 HID／GATT 共存。认证失败不等于服务缺失；应完成正常系统配对后再检查。不同型号不能因使用相同语音服务就共享未经验证的按键或音频参数。

详细验收条件见[开发说明](development.md#google-remote-compatibility-acceptance)。[vibe-mote](https://github.com/Tilkmilk/vibe-mote) 和 [ATVVoice](https://github.com/b0o/ATVVoice) 是协议研究参考，不将它们的 Windows／Linux 验证当作本项目的 macOS 验收。

## G9N9N 适配

仅接受同一外设的 DIS PnP 身份 `18D1:9450` 和 ATVV v1.0／16kHz 能力确认都通过的语音设备；DIS 型号只作信息展示，先后样机报告 `A3` 和 `A0`。A0／固件 26.7 的语音键和麦克风已实测可用，但普通按键单键及松开通知只有一个索引字节，短于描述符要求的两个槽位，无法到达应用；**当前不支持 G9N9N 普通按键映射**。

代码中仍有 Consumer Control report 2 和已知 report 1 索引格式的解析器，这不代表控制功能已通过验收。设置时可同时按 OK＋上完成初始验证，后续再按返回＋上，累计收到三个不同按键后继续语音设置；每组后全部松开。双键检查不能当作普通按键映射验收通过。设置完成后提供实验性 OK＋任意方向键发送 Enter，需开启映射并独占设备，尚待真机验收。详见 [功能范围与独立测试报告](g9n9n-compatibility.md) 及 [调试过程](g9n9n-hardware-debugging.md)。未知 VID/PID、未知报文不会因商品页面写着兼容而自动获得支持。GY3LE 的公开资料与未确认参数见 [GY3LE 调研](gy3le-public-research.md)。


## 添加兼容遥控器

设备连接页的“添加新设备”会从设备选择步骤打开向导，保留已有设备、按键映射和输入工具配置。
设备身份及音频能力通过确认后，利用公开 DIS PnP ID（0x2A50）和只读蓝牙 HID 元数据关联按键设备；
自动关联要求 VID/PID、唯一物理指纹和系统名称一致。缺少元数据或存在歧义时，可在连接步骤点击
“按键未识别？关联兼容遥控器”手动选择，随后继续原有按键验证。

非标准 VID/PID 在关联成功时立即随设备配置保存，以后参与扫描；标准 ID 只关联指纹，不重复加入白名单。
删除或重新关联设备会移除旧 ID。Google 按键只有在对应 BLE 设备通过身份和能力确认、处于就绪状态时才解析。
启用 Google 不会绕过小米电源键保护；抑制失败时，小米标准 ID 和兼容 ID 均不进入监听。
保存 ID 不会改变音频协议要求，未知身份、编解码器和 HID 报文仍需独立适配及真机验收。

## 输入法候选框与遥控器按键

如果拼音、五笔或 Rime 等输入法的候选框正在显示，请先选词确认，或按 Escape 取消本次预编辑，再启动语音输入。候选框打开时，方向键和 Return 通常用于选词；遥控器映射成这些键时也会执行输入法的选词动作。

程序不会在每次语音启动或方向键之前自动发送 Escape：这可能丢弃用户尚未确认的输入，也可能关闭目标应用的菜单或对话框。不同输入法和编辑器的预编辑状态并没有在本项目中得到统一、可靠的跨应用验证；没有足够证据时不修改正在输入的内容。

## Mac 配对指引

向导可分别选择 G9N9N 和 GY3LE，并显示各自的示意图。选择型号不会跳过连接和普通按键验证。

1. 打开 Mac 的“系统设置 → 蓝牙”，将遥控器靠近电脑。
2. 同时按住返回（Back）和主页（Home）约 3 秒，直到指示灯开始闪烁。
3. 在 Mac 的蓝牙列表中选择遥控器并连接。重新配对时，可先忽略原设备。

这些步骤用于连接 Mac；不要等待 Chromecast 或电视上的配对成功提示。G9N9N 配对成功不代表普通按键映射可用；可用上文双键方法完成设置检查，再继续验证语音功能。
