import Foundation

enum OnboardingAIAssistantPrompt {
    static let chinese = """
    请帮助我在这台 Mac 上配置「遥控搭子」。遥控器已通过蓝牙连接。

    本应用目前没有自动配置命令行接口。请通过应用的设置和向导，以及公开的 macOS 无障碍界面完成配置，不要调用不存在的配置命令。

    1. 运行 open -b com.zfdang.remote-buddy 打开应用，检查向导和权限状态。
    2. 选择已连接的遥控器；有多个无法区分的设备时，请让我选择。
    3. 选择已安装的语音输入工具，按照向导配置 Fn 和适合该工具的按住或点按方式。
    4. 使用遥控搭子的虚拟麦克风，保留已有增益；只有必要时再调整。
    5. 仅修改遥控搭子自己的配置。不要读取或修改第三方应用的私有文件、数据库、沙盒或未公开协议。
    6. 保留真实按键、音频和语音文字上屏验证。需要权限、用户选择或真实说话时，请明确告诉我还缺什么。
    7. 根据界面可观察的结果报告配置状态，不要将配置写入当成测试通过，不要伪造完成状态。
    """

    static let english = """
    Help me configure Remote Buddy on this Mac. My remote is connected over Bluetooth.

    The app currently has no automatic configuration CLI. Use its settings and onboarding wizard through public macOS accessibility interfaces; do not invoke nonexistent configuration commands.

    1. Run open -b com.zfdang.remote-buddy to open the app and check onboarding and permissions.
    2. Select the connected remote; ask me to choose if multiple devices cannot be distinguished.
    3. Select an installed voice typing tool and follow the wizard to configure Fn and its matching hold or tap behavior.
    4. Use the Remote Buddy virtual microphone and preserve the current gain unless adjustment is needed.
    5. Modify only this app's configuration. Do not access third-party private files, databases, sandboxes or undocumented protocols.
    6. Keep real button, audio and spoken-text verification. Explain any permission, choice or real spoken test still required.
    7. Report observable results. Written configuration is not proof that voice input works. Never fabricate completion.
    """

    static func text(for locale: Locale) -> String {
        locale.identifier.lowercased().hasPrefix("zh") ? chinese : english
    }
}

enum OnboardingVoiceGesturePrompt {
    static func text(
        for mode: VoiceGestureMode,
        fnTapModeEnabled: Bool = false,
        controlSource: OnboardingControlSource = .unselected,
        locale: Locale
    ) -> String {
        let isChinese = locale.identifier.lowercased().hasPrefix("zh")
        if controlSource == .t1Remote {
            if fnTapModeEnabled {
                return isChinese
                    ? "按一下 T1 语音键并松开开始说话，说完后再按一下结束（已自动开启点按转换）。"
                    : "Press and release the T1 voice button to start speaking, then press it once more to stop (Fn tap conversion enabled)."
            }
            return isChinese
                ? "按一下 T1 语音键并松开开始说话，说完后再按一下结束（期间遥控搭子会全程替你按住语音键）。"
                : "Press and release the T1 voice button to start speaking, then press it once more to stop (Remote Buddy holds the voice key for you while speaking)."
        }
        if fnTapModeEnabled {
            return isChinese
                ? "按住语音键说话，说完松开（已自动开启点按转换）。"
                : "Hold the voice button while speaking, then release it (Fn tap conversion enabled)."
        }
        switch (isChinese, mode) {
        case (true, .hold): return "按住语音键说话，说完松开。"
        case (true, .toggle): return "按一下语音键开始说话，再按一下结束。"
        case (false, .hold): return "Hold the voice button while speaking, then release it."
        case (false, .toggle): return "Press the voice button once to start, then once more to finish."
        }
    }
}

