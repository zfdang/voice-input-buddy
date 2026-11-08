import AppKit
import Combine
import CoreBluetooth
import SwiftUI

/// 进程内 Onboarding 回归使用的控件 action 注册表。
///
/// 它不参与正式用户流程，也不依赖屏幕坐标或辅助功能权限；测试可以在生产视图
/// 已经构建后直接触发同一组 Button/Toggle action。
@MainActor
final class OnboardingInteractionProbe {
    private(set) var actions: [String: () -> Void] = [:]
    private(set) var toggleValues: [String: Bool] = [:]
    private(set) var openedURLs: [URL] = []
    private(set) var launchedVoiceTools: [OnboardingVoiceTool] = []
    private(set) var invokedActions: [String] = []

    var openURL: (URL) -> Void

    init(openURL: ((URL) -> Void)? = nil) {
        self.openURL = openURL ?? { url in
            NSWorkspace.shared.open(url)
        }
    }

    func registerAction(_ id: String, action: @escaping () -> Void) {
        actions[id] = action
    }

    func registerToggle(
        _ id: String,
        value: Bool,
        set: @escaping (Bool) -> Void
    ) {
        toggleValues[id] = value
        actions[id] = { [weak self] in
            let current = self?.toggleValues[id] ?? value
            self?.toggleValues[id] = !current
            set(!current)
        }
    }

    func invoke(_ id: String) {
        invokedActions.append(id)
        actions[id]?()
    }

    func recordOpenedURL(_ url: URL) {
        openedURLs.append(url)
        openURL(url)
    }

    func recordVoiceToolLaunch(_ tool: OnboardingVoiceTool) {
        launchedVoiceTools.append(tool)
    }
}
