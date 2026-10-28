# 首次设置

从本项目 GitHub Releases 下载适合 Mac 架构的 PKG，一次安装 App 与虚拟麦克风驱动；打开 `/Applications/Voice Input Buddy.app`。

首次向导依次检查系统权限、准备设备、连接遥控器、按键测试、驱动检查、输入工具、语音测试和完成。按需授予蓝牙、输入监控和辅助功能权限。小米 RC001／RC003 与 G9N9N 有连接适配；GY3LE 和 Siri Remote 尚未完成适配。

**关于 G9N9N 遥控器：** 因其按键报文不符合 macOS 规范，**不支持普通单键映射**（语音输入正常）。在首次向导中，按键检测请使用双键完成：初始验证同时按 OK＋上，后续测试依次按 OK＋上和返回＋上。设置完成后，开启按键映射并由应用独占时，短按 OK＋任意方向键可发送 Enter。详情见 [独立测试报告](https://github.com/zfdang/voice-input-buddy/blob/main/docs/g9n9n-compatibility.md)。

App 自动输出到 **Voice Input Buddy Mic**，无需选择回环设备。在目标输入工具中选择同名麦克风，配置并测试语音快捷键。App 负责音频路由及按键动作；识别由输入工具完成，不采集使用统计、不保存录音或文本历史、不上传日志。

安装驱动需要管理员授权，会短暂重启音频。当前 PKG 未签名、未公证；App 与驱动使用固定自签名身份。Windows 尚未实现。更多说明：https://github.com/zfdang/voice-input-buddy/blob/main/docs/interface.md
