import Foundation

/// A device binding. A missing device-specific binding inherits the base value;
/// `.disabled` is an explicit value and never falls through to another action.
struct UnifiedButtonBinding: Codable, Equatable {
    var remoteProfileID: UUID?
    var button: RemoteButton
    var trigger: ButtonTrigger
    var configured: ConfiguredButtonAction
}
