import AppKit
import CoreGraphics
import Foundation

private func keyboardEventSuppressorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<KeyboardEventSuppressor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return suppressor.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

final class KeyboardEventSuppressor {
    private static let systemDefinedEventTypeRawValue: UInt32 = 14

    private struct PendingEvent {
        let event: RemoteNativeEvent
        let edge: RemoteEventEdge
        let expiresAt: TimeInterval
    }

    private let lock = NSLock()
    private var pendingEvents: [PendingEvent] = []
    private var heldEventCounts: [RemoteNativeEvent: Int] = [:]
    private var heldUntil: [RemoteNativeEvent: TimeInterval] = [:]
    private var suppressedDowns = Set<RemoteNativeEvent>()
    private let permissionsGranted: () -> Bool
    private let uptime: () -> TimeInterval

    init(
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        permissionsGranted: @escaping () -> Bool = {
            HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
        }
    ) {
        self.permissionsGranted = permissionsGranted
        self.uptime = uptime
    }

    private func expireHeldEvents(at now: TimeInterval) {
        for event in heldUntil.compactMap({ $0.value <= now ? $0.key : nil }) {
            heldEventCounts.removeValue(forKey: event)
            heldUntil.removeValue(forKey: event)
            suppressedDowns.remove(event)
            pendingEvents.removeAll { $0.event == event }
        }
    }
    private let tapRecovery = EventTapRecovery()
    private var tapRecoveryGeneration = 0
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 最近 arm 过的事件（带过期时刻），仅用于诊断日志：只有与这些事件相关的
    /// 未命中才值得记录，避免被无关键盘输入淹没。
    private var recentArmed: [(event: RemoteNativeEvent, until: TimeInterval)] = []

    private var tapReady = false
    var isRunning: Bool {
        tapReady && eventTap.map { CGEvent.tapIsEnabled(tap: $0) } == true
    }
    /// Terminal recovery failure, delivered outside the WindowServer callback.
    var onSystemDisabled: (() -> Void)?

    @discardableResult
    func start() -> Bool {
        guard permissionsGranted() else {
            stop()
            return false
        }
        // An installed tap may be temporarily disabled while recovery is queued.
        // Do not install a second port or claim filtering is available then.
        if eventTap != nil { return isRunning }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << Self.systemDefinedEventTypeRawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: keyboardEventSuppressorCallback,
            userInfo: context
        ) else {
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            // tapCreate 成功即已在 WindowServer 侧登记端口；此处失败若不释放端口，
            // 该 tap 会残留到进程退出，必须与 stop() 走同一条清理路径。
            EventTapPort.release(port: eventTap, source: nil)
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        EventTapPort.activate(port: eventTap, source: runLoopSource)
        tapReady = true
        return true
    }

    deinit { stop() }

    func stop() {
        tapRecoveryGeneration += 1
        lock.lock()
        pendingEvents.removeAll()
        heldEventCounts.removeAll()
        heldUntil.removeAll()
        suppressedDowns.removeAll()
        recentArmed.removeAll()
        lock.unlock()
        EventTapPort.release(port: eventTap, source: runLoopSource)
        runLoopSource = nil
        eventTap = nil
        tapReady = false
    }

    func arm(button: RemoteButton, edge: RemoteEventEdge) {
        arm(nativeEvents: button.nativeEvents, edge: edge)
    }

    func arm(nativeEvents: Set<RemoteNativeEvent>, edge: RemoteEventEdge) {
        guard !nativeEvents.isEmpty else { return }
        // 诊断：留证「本次预定了什么」，便于与 miss 日志里系统真实事件对照。
        AppLogger.shared.write(
            "HID FILTER arm events=\(nativeEvents.map(Self.logToken).sorted().joined(separator: "+")) "
                + "edge=\(edge == .down ? "down" : "up")"
        )
        let now = uptime()
        lock.lock()
        expireHeldEvents(at: now)
        recentArmed.removeAll { $0.until <= now }
        for nativeEvent in nativeEvents {
            recentArmed.append((event: nativeEvent, until: now + 1.0))
        }
        pendingEvents.removeAll { $0.expiresAt <= now }
        for nativeEvent in nativeEvents {
            switch edge {
            case .down:
                heldEventCounts[nativeEvent, default: 0] += 1
                heldUntil[nativeEvent] = now + 30
                pendingEvents.append(PendingEvent(
                    event: nativeEvent,
                    edge: edge,
                    expiresAt: now + 0.18
                ))
            case .up:
                // HID release may arrive before the native event tap delivers down.
                // Keep its bounded expectation until delivery/expiry so a fast click
                // cannot reach the app in addition to our injected action.
                let remaining = (heldEventCounts[nativeEvent] ?? 0) - 1
                if remaining > 0 {
                    heldEventCounts[nativeEvent] = remaining
                } else {
                    heldEventCounts.removeValue(forKey: nativeEvent)
                }
                pendingEvents.append(PendingEvent(
                    event: nativeEvent,
                    edge: edge,
                    expiresAt: now + 0.18
                ))
            }
        }
        if pendingEvents.count > 32 {
            pendingEvents.removeFirst(pendingEvents.count - 32)
        }
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Gate non-seized HID injection immediately. Leave the port and
            // monitors alive while recovery runs outside this system callback.
            tapReady = false
            tapRecoveryGeneration += 1
            let generation = tapRecoveryGeneration
            if let port = eventTap {
                tapRecovery.recover(type: type,
                    isCurrent: { [weak self] in
                        self?.tapRecoveryGeneration == generation && self?.eventTap === port
                    },
                    permissionsGranted: { [weak self] in self?.permissionsGranted() == true },
                    enable: { [weak self] in
                        CGEvent.tapEnable(tap: port, enable: true)
                        let enabled = CGEvent.tapIsEnabled(tap: port)
                        self?.tapReady = enabled
                        return enabled
                    },
                    stop: { [weak self] in
                        self?.stop()
                        self?.onSystemDisabled?()
                        AppLogger.shared.write("HID FILTER stopped reason=recovery_exhausted_or_permission_revoked")
                    })
            }
            return false
        }
        if KeyboardInjector.isSyntheticEvent(event) {
            return false
        }
        guard let descriptor = descriptor(type: type, event: event) else { return false }

        let now = uptime()
        let isRepeat = descriptor.edge == .down && (type == .keyDown
            ? event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            : (NSEvent(cgEvent: event)?.data1 ?? 0) & 1 != 0)
        lock.lock()
        // A continuing native repeat is evidence that the same mapped hold is alive.
        // Keep expiry for lost releases, but do not expire an actively repeating hold.
        if isRepeat, (heldEventCounts[descriptor.event] ?? 0) > 0,
           suppressedDowns.contains(descriptor.event), (heldUntil[descriptor.event] ?? 0) > now {
            heldUntil[descriptor.event] = now + 30
        }
        expireHeldEvents(at: now)
        pendingEvents.removeAll { $0.expiresAt <= now }
        recentArmed.removeAll { $0.until <= now }
        if let matchIndex = pendingEvents.firstIndex(where: {
            $0.event == descriptor.event && $0.edge == descriptor.edge
        }) {
            pendingEvents.remove(at: matchIndex)
            let paired: Bool
            if descriptor.edge == .down {
                suppressedDowns.insert(descriptor.event)
                paired = true
            } else {
                paired = suppressedDowns.remove(descriptor.event) != nil
                heldUntil.removeValue(forKey: descriptor.event)
            }
            lock.unlock()
            guard paired else { return false }
            // 诊断：命中并吞掉——与 miss 日志对照即可判定「系统是否产生了该事件」。
            AppLogger.shared.write(
                "HID FILTER suppressed event=\(Self.logToken(descriptor.event)) "
                    + "edge=\(descriptor.edge == .down ? "down" : "up") type=\(type.rawValue)"
            )
            return true
        }
        if descriptor.edge == .down {
            if !isRepeat {
                let hadArmedState = heldEventCounts[descriptor.event] != nil ||
                    suppressedDowns.contains(descriptor.event) ||
                    pendingEvents.contains { $0.event == descriptor.event }
                heldEventCounts.removeValue(forKey: descriptor.event)
                heldUntil.removeValue(forKey: descriptor.event)
                suppressedDowns.remove(descriptor.event)
                pendingEvents.removeAll { $0.event == descriptor.event }
                lock.unlock()
                if hadArmedState {
                    AppLogger.shared.write(
                        "HID FILTER passed event=\(Self.logToken(descriptor.event)) "
                            + "edge=down type=\(type.rawValue) reason=fresh_key_down"
                    )
                }
                return false
            }
            let paired = suppressedDowns.contains(descriptor.event)
            lock.unlock()
            return paired
        }
        if descriptor.edge == .up, suppressedDowns.remove(descriptor.event) != nil {
            heldEventCounts.removeValue(forKey: descriptor.event)
            heldUntil.removeValue(forKey: descriptor.event)
            lock.unlock()
            return true
        }
        let pendingCount = pendingEvents.count
        // 诊断范围（187 的教训：条件太窄会漏掉「系统事件与预定键码不同」的情况）：
        //   1) 与预定键码一致但没被吞（窗口过期）；
        //   2) 任意 systemDefined（媒体/音量类，我们关心的正是这些）；
        //   3) 最近 1 秒内曾 arm 过（覆盖「系统产生的键码与我们预定的不同」）。
        let armedExactly = recentArmed.contains { $0.event == descriptor.event && $0.until > now }
        let isSystemDefined = type.rawValue == Self.systemDefinedEventTypeRawValue
        let withinArmedWindow = !recentArmed.isEmpty
        lock.unlock()
        if armedExactly || isSystemDefined || withinArmedWindow {
            AppLogger.shared.write(
                "HID FILTER miss type=\(type.rawValue) event=\(Self.logToken(descriptor.event)) "
                    + "edge=\(descriptor.edge == .down ? "down" : "up") "
                    + "armed=\(armedExactly) pending=\(pendingCount)"
            )
        }
        return false
    }

    private static func logToken(_ event: RemoteNativeEvent) -> String {
        switch event {
        case .keyboard(let keyCode): return "key\(keyCode)"
        case .systemKey(let type): return "sys\(type)"
        }
    }

    private func descriptor(
        type: CGEventType,
        event: CGEvent
    ) -> (event: RemoteNativeEvent, edge: RemoteEventEdge)? {
        if type.rawValue == Self.systemDefinedEventTypeRawValue {
            guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
            let systemKeyType = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
            let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
            let edge: RemoteEventEdge
            switch keyState {
            case 0xA: edge = .down
            case 0xB: edge = .up
            default: return nil
            }
            return (.systemKey(type: systemKeyType), edge)
        }

        switch type {
        case .keyDown, .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return (.keyboard(keyCode: keyCode), type == .keyDown ? .down : .up)
        default:
            return nil
        }
    }
}
