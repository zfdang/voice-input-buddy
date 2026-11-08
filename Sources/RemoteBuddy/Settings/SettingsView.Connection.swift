import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var connectionPage: some View {
        settingsPage {
            HStack(spacing: 16) {
                PageHeader(title: localization.text("connection.page.title"))
                Spacer()
                Button {
                    SettingsPageBehavior.beginDeviceSetup(settings: settings)
                } label: {
                    Label(localization.text("connection.action.add_device"), systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .compatibilityButtonStyle(.prominent)
                .controlSize(.large)
                .disabled(model.isStreaming)
            }
        } content: {
            CompatibilityGlassContainer(spacing: 14) {
                let profiles = RemoteDeviceNamePolicy.sortedForCards(settings.remoteDeviceProfiles,
                    modelName: remoteModelName, systemName: { model.systemDeviceName(for: $0) })
                VStack(spacing: 16) {
                    if profiles.isEmpty {
                        GlassPanel { remoteDeviceSelector(vertical: true) }
                    }
                    ForEach(profiles) { profile in
                        connectionDeviceGroup(profile)
                    }
                }
            }
        }
        .sheet(item: $remoteRebindingProfile) { profile in
            RemoteRebindingPicker(model: model, profile: profile).environmentObject(localization)
        }
        .confirmationDialog(localization.text("remote.remove.confirm_title"),
                            isPresented: $isRemoteRemovalPresented,
                            presenting: remoteRemovalProfile) { profile in
            Button(localization.text("remote.remove.action"), role: .destructive) {
                _ = model.removeRemoteDevice(profile.id)
                remoteRemovalProfile = nil
            }
            Button(localization.text("common.action.cancel"), role: .cancel) {
                remoteRemovalProfile = nil
            }
        } message: { profile in
            Text(LocalizedMessage("remote.remove.confirm_detail", arguments: [remoteModelName(profile)]).text(using: localization))
        }
        .onAppear {
            model.refreshVoiceKeyCompatibilityWarning()
        }
    }

    func voiceKeyCompatibilityWarningPanel(
        _ warning: VoiceKeyCompatibilityWarning
    ) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(localization.text("connection.voice_key_compatibility.title"))
                        .font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                Text(LocalizedMessage(warning.messageKey).text(using: localization))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(localization.text("connection.voice_key_compatibility.recheck")) {
                    model.recheckRemoteInput()
                }
                .compatibilityButtonStyle(.standard)
            }
        }
    }

    private func connectionDeviceGroup(_ profile: RemoteDeviceProfile) -> some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    remoteDeviceCard(profile, fillsWidth: true)
                    connectionRemotePhoto(profile)
                    if profile.bluetoothIdentifier != nil, !model.isRemoteConnected(profile.id) {
                        Button(localization.text("remote.rebind.title")) { remoteRebindingProfile = profile }
                            .compatibilityButtonStyle(.standard).disabled(model.isStreaming)
                    }
                    if profile.bluetoothIdentifier != nil {
                        Button(localization.text("connection.action.reconnect")) {
                            model.selectRemoteProfile(profile.id)
                            model.reconnect()
                        }.compatibilityButtonStyle(.standard).disabled(model.isStreaming)
                    }
                    Button(role: .destructive) {
                        remoteRemovalProfile = profile
                        isRemoteRemovalPresented = true
                    } label: {
                        Label(localization.text("remote.remove.action"), systemImage: "trash")
                    }
                    .compatibilityButtonStyle(.standard)
                    .disabled(model.isVoiceConfigurationBusy)
                }.frame(width: 230)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text(localization.text("audio.gain.title")).font(.headline)
                    HStack(spacing: 12) {
                        Slider(value: Binding(get: { settings.gainDB(for: profile.id) },
                            set: { settings.setGainDB($0, for: profile.id) }), in: 0...24, step: 1)
                            .disabled(model.isStreaming)
                        Text("\(Int(settings.gainDB(for: profile.id))) dB")
                            .font(.system(.body, design: .monospaced)).frame(width: 54, alignment: .trailing)
                    }
                    Text(localization.text("audio.gain.help")).font(.caption).foregroundStyle(.secondary)
                    Text(localization.text("audio.gain.per_device_help")).font(.caption).foregroundStyle(.secondary)
                    if settings.selectedRemoteProfileID == profile.id {
                        connectionStatusLine(symbol: "mic.fill", text: model.voiceShortcutStatus.text(using: localization), tint: .blue)
                    }
                    if let identifier = profile.bluetoothIdentifier,
                       let information = model.remoteDeviceInformation[identifier],
                       information != RemoteDeviceInformation() {
                        connectionDeviceInformation(information)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
            }
        }
    }

    private func connectionDeviceInformation(_ information: RemoteDeviceInformation) -> some View {
        let readings: [(String, String?)] = [
            ("connection.device.model", information.modelNumber),
            ("connection.device.identity", information.identityValue),
            ("connection.device.firmware", information.firmwareRevision),
            ("connection.device.protocol", information.protocolVersion),
            ("connection.device.audio", information.audioFormat),
            ("connection.device.frame", information.capabilities.map {
                LocalizedMessage("connection.device.frame_bytes", arguments: [String($0.frameSize)]).text(using: localization)
            }),
        ]
        let available = readings.compactMap { key, value -> (String, String)? in
            value.map { (key, $0) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: 12) {
                ForEach(available, id: \.0) { key, value in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(localization.text(key))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(size: 12, weight: .medium))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .help(value)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func connectionRemotePhoto(_ profile: RemoteDeviceProfile) -> some View {
        if let resource = XiaomiRemoteCatalog.photoResource(for: profile.model) {
            RemoteCatalogPhoto(resourceName: resource).frame(width: 82, height: 166)
        } else {
            UnrecognizedRemotePhoto().frame(width: 82, height: 166)
        }
    }

    private func connectionStatusLine(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
