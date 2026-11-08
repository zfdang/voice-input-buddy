import Combine
import Foundation

extension AppSettings {
    /// Device profile UUIDs are local to each Mac. Keep scopes known here, and
    /// map the exported selection to this Mac's selection (or global defaults
    /// before pairing). Other unknown scopes are reported rather than ignored.
    func importedUnifiedBindings(
        from configuration: PersonalizedConfiguration,
        rejected: inout Set<String>
    ) -> [UnifiedButtonBinding] {
        let bindings = configuration.unifiedBaseBindings ?? []
        let localIDs = Set(remoteDeviceProfiles.map(\.id))
        let sourceSelection = configuration.selectedMappingProfileID
        let globals = bindings.filter { $0.remoteProfileID == nil }
        let scoped = bindings.filter { $0.remoteProfileID != nil }
        var imported: [UnifiedButtonBinding] = []
        for binding in globals + scoped {
            var result = binding
            if let id = binding.remoteProfileID, !localIDs.contains(id) {
                guard id == sourceSelection else {
                    rejected.insert("unifiedBaseBindings")
                    continue
                }
                result.remoteProfileID = selectedRemoteProfileID
            }
            let configured = binding.configured.action == .repeatSingleClick && binding.trigger != .longPress
                ? nil : Self.validatedConfiguredAction(binding.configured)
            if configured == nil { rejected.insert("unifiedBaseBindings") }
            result.configured = configured ?? .disabled
            // A selected-device override beats a global default when imported
            // before pairing, where both now have the same destination scope.
            imported.removeAll {
                $0.remoteProfileID == result.remoteProfileID &&
                    $0.button == result.button && $0.trigger == result.trigger
            }
            imported.append(result)
        }
        return imported
    }

    /// `nil` when the shortcut is outside what the app can record or inject. A shortcut that
    /// passes is rebuilt through the normal initializer, which applies exactly the mask a freshly
    /// recorded shortcut gets — only bits the app never records are discarded.
    static func validatedShortcut(
        _ shortcut: CustomKeyboardShortcut
    ) -> CustomKeyboardShortcut? {
        guard shortcut.keyCode <= maximumImportedKeyCode,
              shortcut.keyLabel.count <= maximumImportedKeyLabelLength
        else { return nil }
        return CustomKeyboardShortcut(
            keyCode: shortcut.keyCode,
            modifierFlags: shortcut.modifierFlags,
            keyLabel: shortcut.keyLabel
        )
    }

    /// `nil` when the binding carries a shortcut the app cannot trust. The whole binding goes,
    /// because a `customShortcut` action without its shortcut is a button that does nothing.
    static func validatedConfiguredAction(
        _ binding: ConfiguredButtonAction
    ) -> ConfiguredButtonAction? {
        guard let shortcut = binding.shortcut else { return binding }
        guard let validated = validatedShortcut(shortcut) else { return nil }
        var result = binding
        result.shortcut = validated
        return result
    }

    /// The dangerous half of an imported payload: this is what a remote button launches.
    ///
    /// Only a structurally malformed entry is dropped. An entry whose path resolves to nothing,
    /// or to a bundle whose identifier no longer matches the declared one, is kept and reported
    /// instead: `KeyboardInjector.resolveCustomApplicationURL` re-checks that match before
    /// opening anything, so dropping it here would destroy a binding without adding safety —
    /// and refusing it outright would break the entire point of moving a configuration to a Mac
    /// that has not installed everything yet.
    static func validatedApplicationProfile(
        _ profile: CustomApplicationProfile
    ) -> ImportedApplicationProfile {
        guard profile.displayName.count <= maximumImportedIdentifierLength,
              isWellFormedBundleIdentifier(profile.bundleIdentifier),
              profile.applicationPath.isEmpty || isWellFormedApplicationBundlePath(profile.applicationPath)
        else { return .rejected }

        var sanitized = profile
        // Both focus paths are already nil-guarded at use, so clearing an untrusted detail
        // degrades focus rather than losing the application.
        sanitized.focusShortcut = profile.focusShortcut.flatMap(validatedShortcut)
        sanitized.accessibilityTarget = profile.accessibilityTarget
            .flatMap(validatedAccessibilityTarget)

        guard !sanitized.applicationPath.isEmpty else { return .notInstalledOnThisMac(sanitized) }
        let url = URL(fileURLWithPath: sanitized.applicationPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notInstalledOnThisMac(sanitized)
        }
        guard Bundle(url: url)?.bundleIdentifier == sanitized.bundleIdentifier else {
            // The launch path re-checks this match and falls back to a bundle-identifier
            // lookup, so degrading beats deleting a binding the user still wants.
            return .notInstalledOnThisMac(sanitized)
        }
        return .usable(sanitized)
    }

    private static func isWellFormedBundleIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              identifier.count <= maximumImportedIdentifierLength,
              !identifier.hasPrefix("."),
              !identifier.hasSuffix("."),
              !identifier.contains("..")
        else { return false }
        // Deliberately not ASCII-only: Script Editor derives
        // com.apple.ScriptEditor.id.<app name> from the app's name verbatim, so a CJK-named
        // app has a non-ASCII identifier that the picker already accepts. What matters here
        // is that the identifier cannot smuggle path or separator characters.
        return identifier.allSatisfy { character in
            character.isLetter || character.isNumber || ".-_".contains(character)
        }
    }

    private static func isWellFormedApplicationBundlePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= maximumImportedPathLength else { return false }
        guard !path.split(separator: "/").contains("..") else { return false }
        return URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
    }

    private static func validatedAccessibilityTarget(
        _ target: AccessibilityFocusTarget
    ) -> AccessibilityFocusTarget? {
        let fields = [
            target.role, target.identifier, target.title, target.description,
            target.help, target.placeholder, target.context, target.windowTitle,
        ]
        guard fields.allSatisfy({ $0.count <= maximumImportedIdentifierLength }) else {
            return nil
        }
        if let frame = target.normalizedFrame {
            guard [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) else {
                return nil
            }
        }
        return target
    }

    static func validatedConfiguration(from data: Data) throws -> PersonalizedConfiguration {
        guard data.count <= ConfigurationFileReader.maximumBytes else {
            throw AppConfigurationError.fileTooLarge
        }
        let configuration = try JSONDecoder().decode(PersonalizedConfiguration.self, from: data)
        guard configuration.formatVersion == PersonalizedConfiguration.currentFormatVersion else {
            throw AppConfigurationError.unsupportedVersion
        }
        guard configuration.gainDB.isFinite, (0...24).contains(configuration.gainDB) else {
            throw AppConfigurationError.invalidValues
        }
        let profiles = configuration.customApplicationProfiles ?? []
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw AppConfigurationError.invalidValues
        }
        return configuration
    }
}
