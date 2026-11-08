import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    @ViewBuilder
    func remoteDeviceSelector(vertical: Bool = false) -> some View {
        let visibleProfiles = RemoteDeviceNamePolicy.sortedForCards(
            settings.remoteDeviceProfiles.filter { profile in
                model.isRemoteConnected(profile.id)
            },
            modelName: remoteModelName,
            systemName: { model.systemDeviceName(for: $0) }
        )
        if visibleProfiles.isEmpty {
            remoteDeviceEmptyState(vertical: vertical)
        } else if vertical {
            VStack(spacing: 8) {
                ForEach(visibleProfiles) { profile in
                    remoteDeviceCard(profile, fillsWidth: true)
                }
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleProfiles) { profile in
                        remoteDeviceCard(profile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func remoteDeviceEmptyState(vertical: Bool) -> some View {
        VStack(alignment: vertical ? .leading : .center, spacing: 8) {
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: vertical ? 24 : 18, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(model.connectionStatus.text(using: localization))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(vertical ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)

            if !vertical {
                Button(localization.text("connection.action.reconnect")) {
                    model.reconnect()
                }
                .compatibilityButtonStyle(.standard)
            }
        }
        .frame(maxWidth: .infinity, alignment: vertical ? .leading : .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18))
        }
    }

    func remoteDeviceCard(
        _ profile: RemoteDeviceProfile,
        fillsWidth: Bool = false
    ) -> some View {
        let selected = settings.selectedRemoteProfileID == profile.id
        let connected = model.isRemoteConnected(profile.id)
        let batteryLevel = model.batteryLevel(for: profile.id)
        let powerState = model.powerState(for: profile.id)
        let modelName = remoteModelName(profile)
        let systemName = remoteSystemName(profile)
        let showsBattery = RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: profile.model,
            level: batteryLevel,
            powerState: powerState
        )
        return HStack(alignment: .center, spacing: 10) {
            Button {
                model.selectRemoteProfile(profile.id)
            } label: {
                VStack(alignment: .center, spacing: 5) {
                    Text(modelName)
                        .help(modelName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(systemName)
                        .help(systemName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        remoteConnectionLabel(connected: connected)
                        if showsBattery {
                            remoteBatteryLabel(level: batteryLevel, powerState: powerState)
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(modelName), \(systemName)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: fillsWidth ? nil : 232, alignment: .center)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .center)
        .background {
            // The background handles padding; foreground buttons keep their own actions.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture {
                    model.selectRemoteProfile(profile.id)
                }
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18))
                .allowsHitTesting(false)
        }
    }

    private func remoteConnectionLabel(connected: Bool) -> some View {
        Label(
            localization.text(connected ? "common.status.connected" : "remote.device.disconnected"),
            systemImage: "circle.fill"
        )
        .foregroundStyle(connected ? Color.green : Color.secondary)
    }

    private func remoteBatteryLabel(
        level: Int?,
        powerState: RemotePowerState?
    ) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: batterySymbol(for: level))
                    .font(.system(size: 13, weight: .medium))
                if powerState == .charging || powerState == .externalPower {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.green)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 20)

            Text(level.map { "\($0)%" } ?? "—")
        }
        .foregroundStyle(batteryColor(for: level))
        .help(remoteBatteryHelp(level: level, powerState: powerState))
    }

    private func batterySymbol(for level: Int?) -> String {
        guard let level else { return "battery.0percent" }
        switch level {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func batteryColor(for level: Int?) -> Color {
        guard let level else { return .secondary }
        if level <= 10 { return .red }
        if level <= 25 { return .orange }
        return .secondary
    }

    private func remoteBatteryHelp(
        level: Int?,
        powerState: RemotePowerState?
    ) -> String {
        switch powerState {
        case .charging:
            return localization.text("remote.device.power.charging")
        case .externalPower:
            return localization.text("remote.device.power.external")
        case .onBattery:
            return level == nil
                ? localization.text("remote.device.battery_unavailable")
                : localization.text("remote.device.power.battery")
        case .unknown:
            return localization.text("remote.device.power.unknown")
        case nil:
            return level == nil
                ? localization.text("remote.device.battery_unavailable")
                : localization.text("remote.device.power.battery")
        }
    }

    func remoteModelName(_ profile: RemoteDeviceProfile) -> String {
        localization.text(profile.displayNameFallbackKey)
    }

    private func remoteSystemName(_ profile: RemoteDeviceProfile) -> String {
        model.systemDeviceName(for: profile)
            ?? localization.text("remote.device.system_name_unknown")
    }
}
