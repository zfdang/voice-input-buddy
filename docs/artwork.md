# 遥控器资源

成品：`Resources/BuddyRemoteIllustration.png`。使用内置 imagegen，根据本项目绘制的按键布局参考生成写实产品渲染，保留透明背景，不包含厂商 Logo、品牌字样或下载的产品照片。

`scripts/generate-remote-layout-reference.swift` 只生成布局参考，不应直接覆盖成品。生成新版本后核对电源、语音、方向、确认、返回、主页、菜单、音量和 TV 键与映射连线的位置，并运行 `python3 scripts/verify-onboarding-resources.py Resources`。

## 成品提示词

```text
Use case: sketch-to-render. Asset type: transparent UI product cutout for a remote button-mapping panel. The referenced image is ONLY a geometric layout guide, not the desired visual style. Turn it into a premium photorealistic studio product render of a slim silver aluminum Bluetooth voice remote, shown perfectly front-on, upright, centered, full length visible, no perspective tilt. Preserve EXACTLY the existing outer framing, remote silhouette and every button center so annotation lines still land on the buttons. Replace the crude flat diagram aesthetic with convincing fine brushed aluminum, narrow polished bevels, finely molded matte black plastic, subtle edge highlights, realistic soft product lighting and elegant restrained contrast. Top two buttons: power on left, microphone on right, embossed small dark symbols on silver circular buttons. Large black circular direction pad below with subtle small directional marks and inset center confirm button. Below it three rows: return / volume plus, home / volume minus, menu / TV. Plus and minus share one black vertical rocker. Preserve all button locations, dimensions and proportions from the reference closely. Keep legends delicate rather than oversized. The lower half is bare clean metal. Absolutely NO manufacturer logo, NO Xiaomi/Mi symbols, NO Remote Buddy text, no branding anywhere, no watermark, no labels outside the remote, no hands or background scene. True transparent alpha background. This should look like a high-end original 3D product visualization, NOT an SVG, cartoon, diagram or icon.
```
