import Foundation

enum VoiceKeyTransition: Equatable {
    case press
    case release
}

struct VoiceKeyLatch {
    /// 语音键按下者。多个 owner 同时按住时按引用计数处理：
    /// 只有最后一个 owner 释放才会真正抬起语音键，因此各路硬件互不取消。
    enum Owner: Hashable {
        /// 蓝牙遥控器（如 Xiaomi 语音遥控器）。
        case bluetooth
        /// Chromecast 遥控器（通过 ATVV 协议触发语音输入）。
        case chromecast
    }

    private var owners: Set<Owner> = []

    var isHeld: Bool {
        !owners.isEmpty
    }

    mutating func transition(
        streaming: Bool,
        owner: Owner
    ) -> VoiceKeyTransition? {
        if streaming {
            guard owners.insert(owner).inserted else { return nil }
            return owners.count == 1 ? .press : nil
        }

        guard owners.remove(owner) != nil else { return nil }
        return owners.isEmpty ? .release : nil
    }

    mutating func rollback(
        _ transition: VoiceKeyTransition,
        owner: Owner
    ) {
        switch transition {
        case .press:
            owners.remove(owner)
        case .release:
            owners.insert(owner)
        }
    }

    mutating func reset() {
        owners.removeAll()
    }
}
