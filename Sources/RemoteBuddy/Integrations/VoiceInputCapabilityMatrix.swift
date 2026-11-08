import Foundation

// Public remote voice capability defaults. See docs/development.md for adapter boundaries.
// Xiaomi and G9N9N physical recording follows ATVV start/stop notifications.
// Tools requiring start/stop taps can use the existing software Fn conversion.
// Siri capabilities remain separate and do not imply current hardware support.

extension RemoteModel {
    /// **型号默认值**：是否支持「按一次收音」（按一下开始、再按一下结束）。
    ///
    /// 只在「链路还没自报能力」时回退使用：运行中的判定一律走 `RemoteVoiceCapabilities.resolve`，
    /// 它优先采用设备自报的能力位；公开适配不承诺未实现的原生点按收音。
    var supportsToggleVoiceRecording: Bool {
        false // Public G9N9N adapter follows the remote's physical voice session.
    }

    /// **型号默认值**：是否有触摸面（滑动 / 光标）。同上，仅在缺少自报能力时回退使用。
    var supportsTouchSurface: Bool {
        isAppleSiriRemote
    }
}

extension OnboardingVoiceTool {
    /// 是否支持「长按收音」（按住说话、松手结束）。
    /// 已知工具里 Typeless、网易叭哥说与 macOS 听写不支持；微信输入法和豆包输入法支持。
    var supportsHoldVoiceRecording: Bool {
        switch self {
        case .typeless, .bageshuo, .macosDictation: return false
        case .weixin, .doubao, .voicecursor, .unselected, .other: return true
        }
    }
}

/// 遥控器语音能力的**最终判定结果**：链路自报的能力优先，自报缺失时才回退到型号默认表。
struct RemoteVoiceCapabilities: Equatable {
    var supportsToggleVoiceRecording: Bool
    var supportsTouchSurface: Bool

    /// - Parameters:
    ///   - model: 当前选中的遥控器型号（未知时传 nil）。
    ///   - declared: 链路自报的能力位；未连接、型号不支持或设备未自报时为空集合。
    static func resolve(
        model: RemoteModel?,
        declared: RemoteDeclaredCapabilities = []
    ) -> RemoteVoiceCapabilities {
        guard let model else {
            // 型号都认不出来时，不得假装它支持任何能力。
            return RemoteVoiceCapabilities(
                supportsToggleVoiceRecording: false,
                supportsTouchSurface: false
            )
        }
        // 自报非空即优先（调用方按型号路由到该遥控器所在链路的那份自报，不会串用）；
        // 小米等没有自报通道的遥控器自然落到下面的型号默认表。
        if !declared.isEmpty {
            return RemoteVoiceCapabilities(
                supportsToggleVoiceRecording: declared.contains(.toggleVoiceGesture),
                supportsTouchSurface: declared.contains(.touchSurface)
            )
        }
        return RemoteVoiceCapabilities(
            supportsToggleVoiceRecording: model.supportsToggleVoiceRecording,
            supportsTouchSurface: model.supportsTouchSurface
        )
    }
}

/// 「语音键模拟 Fn 点按」的适用性：界面据此决定是否展示该开关。
///
/// 该开关存在的唯一理由是把遥控器的「按住」模拟成「点按」，去驱动只认点按的输入工具。
/// 因此只有在**不支持按一次收音**的遥控器档案页面上才适用。
enum VoiceFunctionKeyTapApplicability {
    static func isApplicable(capabilities: RemoteVoiceCapabilities) -> Bool {
        !capabilities.supportsToggleVoiceRecording
    }
}

/// 触摸面类设置（滑动箭头、光标反馈）的适用性。
enum TouchSurfaceControlApplicability {
    /// 页面请求了触摸类控件、且该遥控器确实有触摸面时才显示。
    static func isApplicable(
        capabilities: RemoteVoiceCapabilities,
        pageRequestsControl: Bool
    ) -> Bool {
        pageRequestsControl && capabilities.supportsTouchSurface
    }
}
