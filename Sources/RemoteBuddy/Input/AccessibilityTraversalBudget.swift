import Foundation

/// Bound a changing or unresponsive application's accessibility tree by count and elapsed time.
/// A node already in progress is limited separately by each AX message's timeout.
struct AccessibilityTraversalBudget {
    private let maximumNodes: Int
    private let deadline: TimeInterval
    private let uptime: () -> TimeInterval
    private var visitedNodes = 0

    init(maximumNodes: Int, maximumDuration: TimeInterval = 1,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumNodes = maximumNodes
        self.uptime = uptime
        deadline = uptime() + maximumDuration
    }

    var hasTimeRemaining: Bool { uptime() < deadline }

    mutating func admitNode() -> Bool {
        guard visitedNodes < maximumNodes, hasTimeRemaining else { return false }
        visitedNodes += 1
        return true
    }
}
