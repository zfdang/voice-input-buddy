# 项目官网

官网源文件位于 `pages/`，为无需构建的静态 HTML、CSS 和 JavaScript。默认首页 `index.html` 使用中文，英文页面位于 `index.en.html`；右上角可通过链接切换语言。仓库默认文档 `README.md` 使用中文，`README.en.md` 使用英文，并提供相互切换的链接。两份网页与 README 中英文版本应一起更新。

`.github/workflows/static.yml` 在 main 中的 `pages/**` 或该 workflow 更新时部署，也支持手动触发，以及 main 的安装包发布 workflow 成功完成后的部署。部署前通过 `scripts/prepare-pages-update-feeds.sh` 获取并校验更新源，依次从当前 `workflow_run` 产物、最新 Release 附件、最近成功的发布工作流产物、仓库 `pages/` 预提交/本地重建源或线上当前更新源回退检索并校验；全部源无效时停止部署。若线上旧源或构建产物失效，可通过 `scripts/rebuild-pages-update-feeds.py` 从已发布的安装包和签名重新生成更新源。仅上传 `pages/`，不上传 App 源码或构建目录；其中不应放入待提交以外的本地文件。

`pages/CNAME` 为 `remote.zfdang.com`，GitHub Pages 仓库设置已选择 Actions 部署与此自定义域名。域名 DNS 应正确指向 GitHub Pages；TLS 证书和域名验证由 GitHub 与域名服务配置决定。部署完成前，本地预览不等于官网已上线。

本地预览：

```bash
python3 -m http.server 8765 --directory pages
```

页面中的麦克风按钮示意仅改变本地显示，不申请麦克风权限、不录音，也不发起网络请求；页面及视频资源加载仍会产生正常 HTTP 请求。网站不使用分析或追踪脚本。下载链接指向 GitHub 最新 Release。

中英文页面的 `#interface` 区域提供程序界面的 3D 画廊（Cathedral 效果）交互式展示，分为“主程序界面”（按左侧菜单从上到下展示：遥控器连接、按键映射、常用语编辑、语音集成、系统权限、通用设置、关于搭子，共 7 张，设备连接卡片展示小米与 Google G9N9N 遥控器）与“新手设置向导”（系统权限、设备类型、连接遥控器、按键测试、驱动检查、输入工具、试说与校准，画廊展示前 7 步配置过程，程序向导共 8 步含完成页）两个分类。支持 3D 舞台层叠切换、左右拖拽/手势、键盘方向键切换及点击全屏放大查看高清细节。截图资产位于 `pages/assets/screenshots/`，包含中英文版本。可通过 `python3 scripts/generate-website-screenshots.py` 先从当前源码构建 Debug App，再用隔离设置渲染设置窗口与向导各步骤，并无损优化 PNG。截图使用示例设备、权限及驱动状态，不代表硬件验收；小米按键页保留代码中的默认映射。

中英文页面的 `#demo` 区域提供 3 分 19 秒卡通视频。MP4、封面和可选中文字幕轨道位于
`pages/assets/video/`，由 Pages 一起部署。视频为中文旁白与画内中文字幕；英文页面明确标注视频语言。
播放器使用浏览器原生控制，支持全屏、拖动和下载，不自动播放，只预加载元数据，
不依赖外部播放器或追踪服务。更新视频时同步更新封面、字幕和两种语言的介绍。

视频的动画源文件与旁白位于 `scripts/demo-video/visuals.py` 和
`scripts/demo-video/render.py`，更新时先对照当前程序界面。网页硬件区域列出五项设备，
与输入工具列表并列展示。网页说明小米与 T1 已适配、G9N9N 支持语音但不支持普通单键映射、GY3LE 与 Siri Remote 计划支持，并链接到 README 的各型号支持情况。实际连接准入与验收状态以 README 和应用向导为准。操作说明须匹配当前界面：音频固定输出 Remote Buddy Mic，用户只需在输入工具中选择同名麦克风。安装包未公证的提醒仅保留在网页文字说明中；视频不展示此提醒。

在 macOS 上重做视频（需要 `ffmpeg`、`ffprobe` 和系统中文字体）：

```bash
python3 -m venv dist/videos/venv
dist/videos/venv/bin/pip install Pillow edge-tts
dist/videos/venv/bin/python scripts/demo-video/render.py
```

旁白采用 `zh-CN-XiaoxiaoNeural`，首次生成或文字变化时通过 Edge TTS 合成，
相同文字的音频缓存在 `dist/videos/source/`。脚本同步生成 MP4、WebVTT 字幕和封面，
直接写入 `pages/assets/video/`。完成后检查画面、字幕时间和声音，再提交这些资产。
