# Upstream copyright notice (historical)

The notice below is preserved from remote-mic-app. Its SayAll branding, asset paths and distribution descriptions refer to that upstream project, not Remote Buddy. Note that although this repository uses filenames such as `Resources/AppIcon.png` and `Resources/AppIcon.icns`, the current files in this repository are freshly created original assets under `GPL-3.0-only` (via `scripts/generate-icons.py`), not the upstream proprietary assets listed below. Current component and artwork notices are in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

---

# Copyright

[Upstream project](https://github.com/HD838A/remote-mic-app)

**SayAll**

Copyright (C) 2026 SayAll contributors

本程序是一个 macOS 适配版本，其实现参考了 GPL-3.0-only 项目 [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub)，参考提交为 `8a93f321ac71a602300c6cd77f7256fa4b63068e`。

本项目的改动包括：

- 带 Dock 与菜单栏入口的原生 SwiftUI/AppKit macOS 应用；
- CoreBluetooth 连接与状态管理；
- CoreAudio 输出设备选择；
- IOHID 权限、按键读取与 macOS 动作注入；
- macOS 构建、测试、安装和发布流程；
- 从固定 BlackHole 源码构建的 `MiRemoteV2ch.driver` 豆包兼容方案。

本适配作品的软件代码按 `GPL-3.0-only` 发布。完整许可见 [GPL license](../LICENSE)，第三方来源和归属见 [Current third-party notices](../THIRD_PARTY_NOTICES.md)。

## App Logo

以下 App Logo 是独立的专有品牌资产，不属于 `GPL-3.0-only` 授权范围：

- `Resources/AppIcon.png`；
- `Resources/AppIcon.icns`；
- `Resources/AppIcons/faceted-duck.png`；
- 由上述文件生成或演绎的版本。
允许在未经修改的无线麦官方源码和官方发行版本中原样分发。用于其他应用、Fork、修改版本、产品或品牌标识时，必须事先取得版权所有者的书面授权。完整条款见 `LOGO-LICENSE.md` in the upstream project。

本声明不覆盖菜单栏状态图标、程序代码或未在上述列表中明确列出的其他项目资源。
