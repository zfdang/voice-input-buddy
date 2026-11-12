import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Common phrase storage transactions")
@MainActor
struct CommonPhraseStorageTests {
    private func phrase(_ id: String, text: String = "测试") -> CommonPhrase {
        CommonPhrase(id: id, text: text, label: "标签")
    }
    private var bundled: CommonPhraseArchive {
        CommonPhraseArchive(entries: [phrase("builtin-one"), phrase("builtin-two", text: "第二项")],
            bindings: ["ok": "builtin-one", "left": "builtin-one", "up": "builtin-two", "home": "builtin-two"])
    }
    private func run(_ body: (CommonPhraseStore, UserDefaults, Data) throws -> Void) throws {
        let name = "phrase-unit-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = try JSONEncoder().encode(bundled)
        let store = CommonPhraseStore(defaults: defaults, builtInData: data)
        #expect(store.isAvailable)
        try body(store, defaults, data)
    }

    @Test func phraseTextRemovesOnlyBoundarySpacesAndTabs() {
        let phrase = CommonPhrase(id: "user-padding", text: " \t原始 文本\t内容\t ",
            label: "标签")
        #expect(phrase.insertionText == "原始 文本\t内容")
        #expect(CommonPhrase.removingBoundaryPadding("\n  第一行\n\t第二行\n") == "\n  第一行\n\t第二行\n")
    }

    @Test func savingRemovesInvisibleBoundaryPaddingAndPreservesBodyOnReload() throws {
        try run { store, defaults, data in
            let phrase = CommonPhrase(id: "user-padding", text: "\t 正文 空格\t正文\n下一行 \t",
                label: "标签")
            let id = try store.save(phrase, replacing: nil)
            try store.assign(.right, to: id)
            let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
            let saved = try #require(reopened.phrase(for: .right))
            #expect(saved.text == "正文 空格\t正文\n下一行")
            let builtinID = try store.save(phrase, replacing: "builtin-one")
            #expect(store.archive.entries.first { $0.id == builtinID }?.text == saved.text)
        }
    }

    @Test func languageChangesKeepMixedScriptContentAndBindings() throws {
        try run { store, defaults, data in
            let content = "请保留 API v2，继续输入 hello。"
            let phrase = CommonPhrase(id: "user-mixed", text: content, label: "混合 Mixed")
            let id = try store.save(phrase, replacing: nil)
            try store.assign(.ok, to: id)
            let settings = AppSettings(defaults: defaults)
            let localization = LocalizationStore(settings: settings)
            for language in [AppLanguage.english, .simplifiedChinese, .english] {
                localization.select(language)
                let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
                #expect(reopened.phrase(for: .ok)?.insertionText == content)
                #expect(reopened.phrase(for: .ok)?.label == "混合 Mixed")
                #expect(reopened.archive.bindings == store.archive.bindings)
            }
        }
    }

    @Test func singleContentArchiveRoundTripsEnglishOnlyAndMixedScriptPhrases() throws {
        try run { store, defaults, data in
            let id = try store.save(CommonPhrase(id: "user-english", text: "Continue with API v2", label: "Continue"), replacing: nil)
            try store.assign(.ok, to: id)
            let exported = try store.exportData()
            let decoded = try CommonPhraseStore.decodedImport(exported)
            #expect(decoded.schemaVersion == 2)
            #expect(decoded.entries.first { $0.id == id }?.text == "Continue with API v2")
            let json = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let entries = try #require(json["entries"] as? [[String: Any]])
            #expect(entries.allSatisfy { Set($0.keys) == ["id", "text", "label"] })
            #expect(json["website"] as? String == "https://remote.zfdang.com/")
            #expect(json["github"] as? String == "https://github.com/zfdang/remote-buddy")
            let imported = CommonPhraseStore(defaults: defaults, builtInData: data)
            try imported.importArchive(decoded)
            #expect(imported.phrase(for: .ok)?.insertionText == "Continue with API v2")
        }
    }

    @Test func editingBundledPhraseCreatesUserCopyAndRetargetsEveryBinding() throws {
        try run { store, defaults, data in
            let id = try store.save(phrase("builtin-one", text: "已修改"), replacing: "builtin-one")
            #expect(id.hasPrefix("user-"))
            #expect(store.phrase(for: .ok)?.id == id)
            #expect(store.phrase(for: .left)?.id == id)
            let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(reopened.phrase(for: .ok)?.text == "已修改")
            #expect(reopened.phrase(for: .left)?.id == id)
            #expect(reopened.archive.entries.allSatisfy { $0.id != "builtin-one" })
        }
    }

    @Test func createAssignReorderDeleteRoundTripsWithoutDanglingBindings() throws {
        try run { store, defaults, data in
            let id = try store.save(phrase("user-new"), replacing: nil)
            try store.assign(.right, to: id)
            try store.assign(.down, to: id)
            try store.move(id, by: -1)
            let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(reopened.archive.entries.map(\.id) == ["builtin-one", id, "builtin-two"])
            #expect(reopened.phrase(for: .right)?.id == id)
            try reopened.delete(id)
            let final = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(final.phrase(for: .right) == nil)
            #expect(final.phrase(for: .down) == nil)
            #expect(final.phrase(for: .ok)?.id == "builtin-one")
        }
    }

    @Test func invalidEditsNeverReplacePersistedArchive() throws {
        try run { store, defaults, data in
            try store.assign(.right, to: "builtin-two")
            let original = store.archive
            var invalid = phrase("user-invalid")
            invalid.text = "  "
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.save(invalid, replacing: nil) }
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.assign(.tv, to: "builtin-one") }
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.assign(.ok, to: "missing") }
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.save(phrase("builtin-one"), replacing: nil) }
            #expect(store.archive == original)
            #expect(CommonPhraseStore(defaults: defaults, builtInData: data).archive == original)
        }
    }

    @Test func invalidImportsAreAtomicAndValidImportPreservesEditedBundledContent() throws {
        try run { store, defaults, data in
            let original = store.archive
            var invalid = bundled
            invalid.bindings["ok"] = "missing"
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.importData(JSONEncoder().encode(invalid)) }
            invalid = bundled
            invalid.entries.append(invalid.entries[0])
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.importData(JSONEncoder().encode(invalid)) }
            #expect(store.archive == original)
            var edited = bundled
            edited.entries[0].text = "外部编辑"
            try store.importData(JSONEncoder().encode(edited))
            let id = try #require(store.phrase(for: .ok)?.id)
            #expect(id.hasPrefix("user-"))
            #expect(store.phrase(for: .left)?.id == id)
            #expect(CommonPhraseStore(defaults: defaults, builtInData: data).phrase(for: .ok)?.text == "外部编辑")
        }
    }

    @Test func importedBackupWithoutChromecastKeysLeavesThemUnassigned() throws {
        try run { store, _, _ in
            let backup = CommonPhraseArchive(entries: bundled.entries, bindings: ["ok": "builtin-one"])
            try store.importData(JSONEncoder().encode(backup))
            #expect(store.phrase(for: .ok)?.id == "builtin-one")
            #expect(store.phrase(for: .home) == nil)
        }
    }

    @Test func savedChromecastAssignmentIsNotOverwritten() throws {
        try run { store, defaults, data in
            try store.assign(.home, to: "builtin-one")
            let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(reopened.phrase(for: .home)?.id == "builtin-one")
        }
    }

    @Test func archiveValidatesChromecastKeysAndRejectsUnknownKeys() throws {
        var archive = bundled
        archive.bindings["youtube"] = "builtin-one"
        try archive.validate()
        archive.bindings["tv"] = "builtin-one"
        #expect(throws: CommonPhraseStore.StoreError.self) { try archive.validate() }
    }

    @Test func deletingBundledPhraseStaysDeletedOnReload() throws {
        try run { store, defaults, data in
            try store.delete("builtin-one")
            let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(reopened.archive.entries.map(\.id) == ["builtin-two"])
            #expect(reopened.phrase(for: .ok) == nil)
            #expect(reopened.phrase(for: .left) == nil)
        }
    }

    @Test func corruptedSavedArchiveFallsBackToBuiltInsAndKeepsBackup() throws {
        try run { _, defaults, data in
            defaults.set(Data("invalid-json".utf8), forKey: "commonPhrases.archive.v2")
            let broken = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(broken.isAvailable && !broken.loadFailed)
            #expect(broken.phrase(for: .ok)?.id == "builtin-one")
            #expect(defaults.data(forKey: "commonPhrases.archive.v2") == nil)
            #expect(defaults.data(forKey: "commonPhrases.archive.v2.corrupt") == Data("invalid-json".utf8))
            let reopened = CommonPhraseStore(defaults: defaults, builtInData: data)
            #expect(reopened.isAvailable && !reopened.loadFailed)
            try broken.importData(data)
            #expect(broken.isAvailable && !broken.loadFailed)
            #expect(CommonPhraseStore(defaults: defaults, builtInData: data).phrase(for: .ok)?.id == "builtin-one")
        }
    }

    @Test func entryLimitRejectsAnAdditionalPhraseWithoutLosingExistingEntries() throws {
        try run { store, _, _ in
            let full = CommonPhraseArchive(entries: (0..<500).map { phrase("user-\($0)") }, bindings: [:])
            try store.importData(JSONEncoder().encode(full))
            let original = store.archive
            #expect(throws: CommonPhraseStore.StoreError.self) { try store.save(phrase("user-extra"), replacing: nil) }
            #expect(store.archive == original)
        }
    }
}

@Suite("Common phrase voice key")
@MainActor
struct CommonPhraseVoiceKeyTests {
    private func profile(_ model: RemoteModel) throws -> (RemoteDeviceProfile, () -> Void) {
        let name = "phrase-voice-key-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        let id = settings.registerBluetoothRemote(identifier: UUID(), model: model)
        let profile = try #require(settings.remoteDeviceProfiles.first { $0.id == id })
        return (profile, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func chromecastVoiceKeyTargetsItsOwnPanel() throws {
        let (chromecast, cleanup) = try profile(.chromecastVoiceRemote)
        defer { cleanup() }
        #expect(BridgeAppModel.commonPhraseVoiceKeySource(profile: chromecast, longRecordingRequested: false)
            == BridgeAppModel.commonPhraseHIDSource(chromecast.id))
        #expect(BridgeAppModel.commonPhraseVoiceKeySource(profile: chromecast, longRecordingRequested: true) == nil)
    }

    @Test(arguments: [RemoteModel.rc001, .rc003])
    func otherRemotesKeepVoiceKeyBehavior(model: RemoteModel) throws {
        let (other, cleanup) = try profile(model)
        defer { cleanup() }
        #expect(BridgeAppModel.commonPhraseVoiceKeySource(profile: other, longRecordingRequested: false) == nil)
        #expect(BridgeAppModel.commonPhraseVoiceKeySource(profile: nil, longRecordingRequested: false) == nil)
    }

    @Test func hiddenPanelIgnoresVoiceKey() throws {
        let name = "phrase-voice-hidden-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let data = try JSONEncoder().encode(CommonPhraseArchive(
            entries: [CommonPhrase(id: "builtin-one", text: "好的", label: "好的")], bindings: [:]))
        let controller = CommonPhraseController(store: CommonPhraseStore(defaults: defaults, builtInData: data))
        #expect(!controller.closeForVoiceKey(source: "hid:any"))
    }
}

@Suite("Common phrase input ownership")
struct CommonPhraseOwnershipTests {
    @Test func foreignRemoteCannotChooseOrReleaseOwnersPhrase() {
        var routing = CommonPhraseRouting()
        routing.open(source: "first", buttons: CommonPhraseStore.baseButtons)
        #expect(routing.handle(.up, phase: .press, source: "second") == .unhandled)
        #expect(routing.owner == "first")
        #expect(routing.handle(.up, phase: .press, source: "first") == .insert(.up))
        #expect(routing.handle(.up, phase: .press, source: "first") == .consumed)
        routing.close()
        #expect(routing.handle(.up, phase: .release, source: "second") == .unhandled)
        #expect(routing.handle(.up, phase: .release, source: "first") == .consumed)
        #expect(routing.handle(.up, phase: .release, source: "first") == .unhandled)
    }
    @Test func reopeningDoesNotLeakHeldReleaseFromPreviousOwner() {
        var routing = CommonPhraseRouting()
        routing.open(source: "first", buttons: CommonPhraseStore.baseButtons)
        #expect(routing.handle(.back, phase: .press, source: "first") == .close)
        routing.open(source: "second", buttons: CommonPhraseStore.baseButtons)
        routing.reset(source: "unrelated")
        #expect(routing.claims(.back, source: "first"))
        #expect(routing.handle(.back, phase: .release, source: "first") == .consumed)
        #expect(routing.owner == "second")
        #expect(routing.handle(.ok, phase: .press, source: "second") == .insert(.ok))
        routing.reset(source: "second")
        #expect(!routing.claims(.ok, source: "second"))
    }
    @Test(arguments: [RemoteButton.power, .home, .tv, .volumeUp])
    func baseRemoteKeepsUnrelatedButtonsUnhandled(button: RemoteButton) {
        var routing = CommonPhraseRouting()
        routing.open(source: "first", buttons: CommonPhraseStore.baseButtons)
        #expect(!routing.claims(button, source: "first"))
        #expect(routing.handle(button, phase: .press, source: "first") == .unhandled)
        #expect(routing.owner == "first")
    }
    @Test(arguments: CommonPhraseStore.chromecastButtons)
    func chromecastKeysInsertWhenPanelIsOpen(button: RemoteButton) {
        var routing = CommonPhraseRouting()
        routing.open(source: "first", buttons: CommonPhraseStore.buttons(chromecast: true))
        #expect(routing.claims(button, source: "first"))
        #expect(routing.handle(button, phase: .press, source: "first") == .insert(button))
        #expect(routing.handle(button, phase: .release, source: "first") == .consumed)
    }
    @Test(arguments: [RemoteButton.volumeUp, .volumeDown])
    func chromecastVolumeKeysStayUnhandled(button: RemoteButton) {
        var routing = CommonPhraseRouting()
        routing.open(source: "first", buttons: CommonPhraseStore.buttons(chromecast: true))
        #expect(!routing.claims(button, source: "first"))
        #expect(routing.handle(button, phase: .press, source: "first") == .unhandled)
        #expect(routing.owner == "first")
    }
}
