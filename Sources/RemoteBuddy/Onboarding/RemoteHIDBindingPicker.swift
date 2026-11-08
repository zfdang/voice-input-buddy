import SwiftUI

struct RemoteHIDBindingPicker: View {
    @ObservedObject var model: BridgeAppModel
    let profile: RemoteDeviceProfile
    @EnvironmentObject var localization: LocalizationStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RemoteHIDCandidate] = []
    @State private var selected: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: localization.text("remote.hid_binding.title")).font(.title2.bold())
            Text(verbatim: localization.text("remote.hid_binding.help")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(candidates, selection: $selected) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.name)
                    Text(String(format: "%04X:%04X", candidate.binding.identity.vendorID, candidate.binding.identity.productID))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }.tag(candidate.id)
            }.frame(minHeight: 180, maxHeight: 320)
            if candidates.isEmpty { Text(verbatim: localization.text("remote.hid_binding.empty")).foregroundStyle(.secondary) }
            if failed { Text(verbatim: localization.text("remote.hid_binding.failed")).foregroundStyle(.red) }
            HStack {
                Button(localization.text("common.action.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(localization.text("remote.hid_binding.refresh")) { refresh() }
                Spacer()
                Button(localization.text("remote.hid_binding.save")) {
                    guard let candidate = candidates.first(where: { $0.id == selected }) else { return }
                    if model.bindCompatibleRemote(candidate, profileID: profile.id) { dismiss() }
                    else { failed = true }
                }.buttonStyle(.borderedProminent).disabled(selected == nil || model.isStreaming)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560).frame(minHeight: 320, maxHeight: 520)
        .onAppear { refresh() }
    }

    private func refresh() {
        candidates = RemoteHIDCandidate.available().filter { candidate in
            !model.settings.remoteDeviceProfiles.contains {
                $0.id != profile.id && $0.hidFingerprint == candidate.id
            }
        }
        if !candidates.contains(where: { $0.id == selected }) { selected = nil }
        failed = false
    }
}
