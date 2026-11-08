import SwiftUI

struct RemoteRebindingPicker: View {
    @ObservedObject var model: BridgeAppModel
    let profile: RemoteDeviceProfile
    @EnvironmentObject var localization: LocalizationStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var failed = false

    private var replacements: [RemoteDeviceProfile] {
        model.settings.remoteDeviceProfiles.filter {
            $0.id != profile.id && $0.model == profile.model && model.isRemoteConnected($0.id) &&
                ($0.hidFingerprint == nil || profile.hidFingerprint == nil || $0.hidFingerprint == profile.hidFingerprint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localization.text("remote.rebind.title")).font(.title2.bold())
            Text(localization.text("remote.rebind.help")).fixedSize(horizontal: false, vertical: true)
            List(replacements, selection: $selected) { replacement in
                Text(model.systemDeviceName(for: replacement) ?? localization.text(replacement.model.localizationKey))
                    .tag(replacement.id)
            }.frame(minHeight: 140)
            if replacements.isEmpty { Text(localization.text("remote.rebind.empty")) }
            if failed { Text(localization.text("remote.rebind.failed")).foregroundStyle(.red) }
            HStack {
                Button(localization.text("common.action.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localization.text("remote.rebind.confirm")) {
                    guard let selected else { return }
                    if model.rebindRemote(profileID: profile.id, to: selected) { dismiss() }
                    else { failed = true }
                }.disabled(selected == nil || model.isStreaming).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
}
