#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
metadata="$("$root/scripts/release-metadata.sh")"
while IFS='=' read -r key value; do export "$key=$value"; done <<< "$metadata"
mkdir -p "$root/.build" "$root/dist/release"
work="$(mktemp -d "$root/.build/uninstaller.XXXXXX")"
trap 'rm -rf "$work"' EXIT
for component in system data; do
    mkdir -p "$work/$component"
    cp "$root/scripts/uninstaller/"{installer-common.sh,uninstall-user.sh} "$root/scripts/installation-common.sh" "$work/$component/"
    if [[ "$component" == system ]]; then
        cp "$root/scripts/uninstaller/"{preinstall,postinstall,uninstall-system.sh} "$work/$component/"
    else
        cp "$root/scripts/uninstaller/cleanup-postinstall" "$work/$component/postinstall"
    fi
    chmod +x "$work/$component/"*
    pkgbuild --nopayload --scripts "$work/$component" \
        --identifier "com.zfdang.remote-buddy.uninstaller.$component" \
        --version "$RELEASE_PACKAGE_VERSION" "$work/$component.pkg"
done
cat > "$work/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Uninstall Remote Buddy / 卸载遥控搭子</title>
  <options customize="always" require-scripts="true" hostArchitectures="arm64,x86_64" rootVolumeOnly="true"/>
  <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
  <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
  <welcome file="welcome.html"/>
  <readme file="confirm-uninstall.html"/>
  <conclusion file="conclusion.html"/>
  <choices-outline><line choice="system"/><line choice="data"/></choices-outline>
  <choice id="system" title="Remove app and microphone driver / 删除程序和驱动" enabled="false" selected="true"><pkg-ref id="com.zfdang.remote-buddy.uninstaller.system"/></choice>
  <choice id="data" title="Delete settings, logs and caches / 删除设置、日志和缓存" start_selected="true" description="Clear personal data for the currently logged-in desktop user. Uncheck to keep it. / 默认清除当前桌面用户的数据，取消勾选即可保留。"><pkg-ref id="com.zfdang.remote-buddy.uninstaller.data"/></choice>
  <pkg-ref id="com.zfdang.remote-buddy.uninstaller.system" version="$RELEASE_PACKAGE_VERSION" auth="Root">system.pkg</pkg-ref>
  <pkg-ref id="com.zfdang.remote-buddy.uninstaller.data" version="$RELEASE_PACKAGE_VERSION" auth="Root">data.pkg</pkg-ref>
</installer-gui-script>
XML
mkdir -p "$work/resources"
cat > "$work/resources/welcome.html" <<'HTML'
<html><meta charset="utf-8"><body style="font:14px -apple-system"><h1>卸载 Remote Buddy / Uninstall</h1><p style="color:#a32626;font-weight:bold">这是卸载包。点击系统的“安装 / Install”将删除 Remote Buddy 和旧版 Voice Input Buddy 的程序和驱动。</p><p><b>This is an UNINSTALLER.</b> The system's “Install” button removes Remote Buddy and the older Voice Input Buddy apps and drivers.</p><p>默认删除当前桌面用户的设置、日志和缓存；在下一步取消勾选该选项即可保留。登录时自动启动也会关闭。</p><p>Personal-data removal is selected by default. Uncheck it to keep settings, logs and caches. Login-at-startup is also disabled.</p><p>适用于 Apple Silicon 与 Intel · Requires macOS 14 or later.</p></body></html>
HTML
cat > "$work/resources/confirm-uninstall.html" <<'HTML'
<html><meta charset="utf-8"><body style="font:14px -apple-system"><h1>确认卸载范围 / What will be removed</h1><p>此包不安装软件。系统流程仍写“安装”，执行的是以下卸载操作：</p><p>This package installs no software. Installer's fixed labels still say “Install”, but the actions are:</p><ul><li>退出 Remote Buddy 并关闭登录时自动启动 / Quit the app and unregister its login item.</li><li>删除 App 和虚拟麦克风驱动 / Remove the app and virtual microphone driver.</li><li>默认删除当前用户设置、日志、缓存和窗口状态 / Delete personal data unless unchecked.</li></ul><p>请先关闭录音和播放软件，音频服务会短暂重启。删除后由你重新安装。</p><p>Close recording/playback apps first; Core Audio briefly restarts. Reinstall manually when needed.</p></body></html>
HTML
cat > "$work/resources/conclusion.html" <<'HTML'
<html><meta charset="utf-8"><body style="font:14px -apple-system"><h1>卸载完成 / Uninstall complete</h1><p>Remote Buddy 的 App、虚拟麦克风驱动和登录启动注册已移除。若保留默认选项，当前用户的设置、日志、缓存也已清除。</p><p>The app, microphone driver and login-startup registration have been removed. Personal data has also been cleared if that option remained selected.</p><p>系统标题中的“安装完成”表示卸载脚本执行成功。此包没有安装任何程序。</p><p>Installer's “installation successful” message means the uninstall scripts succeeded. No software was installed.</p><p>系统可能保留停用的登录项历史条目和失效的隐私授权条目，不会自动启动程序。若音频设备仍有旧名称，请重启 Mac。</p><p>macOS may retain disabled login-item history and inactive privacy entries; the app will not launch. Restart your Mac if an old audio device remains visible.</p></body></html>
HTML
productbuild --distribution "$work/Distribution.xml" --resources "$work/resources" \
    --package-path "$work" "$root/dist/release/Remote_Buddy_Uninstaller_${RELEASE_TAG}_macOS_universal.pkg"
python3 "$root/scripts/verify-uninstaller-package.py" "$root/dist/release/Remote_Buddy_Uninstaller_${RELEASE_TAG}_macOS_universal.pkg"
printf 'Built universal script-only uninstall PKG\n'
