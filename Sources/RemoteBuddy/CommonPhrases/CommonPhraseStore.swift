import Combine
import Foundation

struct CommonPhrase: Codable, Equatable, Identifiable {
    let id: String
    var text: String
    var label: String

    /// Boundary spaces and tabs are easy to enter accidentally in the editor.
    /// Keep interior whitespace and all authored line breaks unchanged.
    static func removingBoundaryPadding(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    var insertionText: String { Self.removingBoundaryPadding(text) }
    var isValid: Bool {
        !id.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        text.count <= 4_000 && label.count <= 80
    }
}

struct CommonPhraseArchive: Codable, Equatable {
    var schemaVersion = 2
    var website: String?
    var github: String?
    var entries: [CommonPhrase]
    var bindings: [String: String]
    var builtInIDs: [String]?

    init(
        schemaVersion: Int = 2,
        website: String? = nil,
        github: String? = nil,
        entries: [CommonPhrase],
        bindings: [String: String],
        builtInIDs: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.website = website
        self.github = github
        self.entries = entries
        self.bindings = bindings
        self.builtInIDs = builtInIDs
    }

    func validate() throws {
        guard schemaVersion == 2, entries.count <= 500,
              entries.allSatisfy(\.isValid), Set(entries.map(\.id)).count == entries.count,
              Set(bindings.keys).isSubset(of: Set(CommonPhraseStore.buttons.map(\.rawValue))),
              bindings.values.allSatisfy({ id in entries.contains { $0.id == id } })
        else { throw CommonPhraseStore.StoreError.invalidData }
    }
}

final class CommonPhraseStore: ObservableObject {
    enum StoreError: Error { case invalidData, unavailable }
    static let maximumImportBytes = 4_000_000
    static let buttons: [RemoteButton] = [.ok, .left, .up, .right, .down]
    static let exportWebsite = "https://github.com/zfdang/voice-input-buddy"
    static let exportGitHub = "https://github.com/zfdang/voice-input-buddy"
    private static let defaultsKey = "commonPhrases.archive.v2"
    @Published private(set) var archive = CommonPhraseArchive(entries: [], bindings: [:])
    @Published private(set) var isAvailable = false
    @Published private(set) var loadFailed = false
    private let defaults: UserDefaults
    private var builtInIDs: [String] = []
    private var builtInEntries: [CommonPhrase] = []
    private var operation: UInt64 = 0

    init(defaults: UserDefaults = .standard, builtInData: Data? = nil) {
        self.defaults = defaults
        do {
            let data: Data
            if let builtInData { data = builtInData }
            else {
                guard let url = Bundle.main.url(forResource: "CommonPhrases", withExtension: "json")
                else { throw StoreError.unavailable }
                data = try Data(contentsOf: url)
            }
            var candidate = try JSONDecoder().decode(CommonPhraseArchive.self, from: data)
            try candidate.validate()
            let builtIns = candidate.entries
            builtInEntries = builtIns
            builtInIDs = builtIns.map(\.id)
            if let saved = defaults.data(forKey: Self.defaultsKey) {
                do {
                    var savedCandidate = try JSONDecoder().decode(CommonPhraseArchive.self, from: saved)
                    try savedCandidate.validate()
                    let known = Set(savedCandidate.builtInIDs ?? savedCandidate.entries.filter { $0.id.hasPrefix("builtin-") }.map(\.id))
                    savedCandidate.entries = savedCandidate.entries.compactMap { phrase in
                        phrase.id.hasPrefix("builtin-") ? builtIns.first { $0.id == phrase.id } : phrase
                    }
                    savedCandidate.entries += builtIns.filter { !known.contains($0.id) }
                    savedCandidate.bindings = savedCandidate.bindings.filter { _, id in savedCandidate.entries.contains { $0.id == id } }
                    try savedCandidate.validate()
                    candidate = savedCandidate
                } catch {
                    defaults.set(saved, forKey: Self.defaultsKey + ".corrupt")
                    defaults.removeObject(forKey: Self.defaultsKey)
                    AppLogger.shared.write("COMMON_PHRASES LOAD phase=recovered result=built_ins reason=invalid_saved_data")
                }
            }
            candidate.builtInIDs = builtInIDs
            try candidate.validate()
            archive = candidate
            isAvailable = true
        } catch {
            loadFailed = true
            AppLogger.shared.write("COMMON_PHRASES LOAD phase=failed result=unavailable reason=invalid_or_missing_data")
        }
    }

    func phrase(for button: RemoteButton) -> CommonPhrase? {
        guard let id = archive.bindings[button.rawValue] else { return nil }
        return archive.entries.first { $0.id == id }
    }

    func save(_ phrase: CommonPhrase, replacing id: String?) throws -> String {
        var candidate = archive
        var saved = phrase
        saved.text = saved.insertionText
        if let id, let index = candidate.entries.firstIndex(where: { $0.id == id }) {
            if id.hasPrefix("builtin-") {
                saved = CommonPhrase(id: "user-" + UUID().uuidString,
                    text: saved.text, label: saved.label)
                candidate.entries[index] = saved
                for (key, value) in candidate.bindings where value == id { candidate.bindings[key] = saved.id }
            } else { candidate.entries[index] = saved }
        } else { candidate.entries.append(saved) }
        try persist(action: "save") {
            guard isAvailable, phrase.isValid else { throw StoreError.invalidData }
            return candidate
        }
        return saved.id
    }

    func assign(_ button: RemoteButton, to id: String) throws {
        var candidate = archive
        candidate.bindings[button.rawValue] = id
        try persist(action: "assign") { candidate }
    }

    func delete(_ id: String) throws {
        var candidate = archive
        candidate.entries.removeAll { $0.id == id }
        candidate.bindings = candidate.bindings.filter { $0.value != id }
        try persist(action: "delete") { candidate }
    }

    func move(_ id: String, by offset: Int) throws {
        guard let index = archive.entries.firstIndex(where: { $0.id == id }),
              archive.entries.indices.contains(index + offset) else { return }
        var candidate = archive
        let phrase = candidate.entries.remove(at: index)
        candidate.entries.insert(phrase, at: index + offset)
        try persist(action: "reorder") { candidate }
    }

    static func decodedImport(_ data: Data) throws -> CommonPhraseArchive {
        guard data.count <= maximumImportBytes else { throw StoreError.invalidData }
        let candidate = try JSONDecoder().decode(CommonPhraseArchive.self, from: data)
        try candidate.validate()
        return candidate
    }

    static func readImport(from url: URL) throws -> CommonPhraseArchive {
        try decodedImport(ConfigurationFileReader.read(from: url, maximumBytes: maximumImportBytes))
    }

    func importData(_ data: Data) throws {
        try importArchive(Self.decodedImport(data))
    }

    func importArchive(_ archive: CommonPhraseArchive) throws {
        try persist(action: "import") {
            var candidate = archive
            try candidate.validate()
            // Imported edits and retired built-ins are user content. Keep them
            // when a later launch refreshes the bundled, unmodified entries.
            for index in candidate.entries.indices {
                let phrase = candidate.entries[index]
                guard phrase.id.hasPrefix("builtin-"),
                      builtInEntries.first(where: { $0.id == phrase.id }) != phrase else { continue }
                let copy = CommonPhrase(id: "user-" + UUID().uuidString,
                    text: phrase.text, label: phrase.label)
                candidate.entries[index] = copy
                for (key, id) in candidate.bindings where id == phrase.id { candidate.bindings[key] = copy.id }
            }
            return candidate
        }
        isAvailable = true
        loadFailed = false
    }

    func exportData() throws -> Data {
        var exported = archive
        exported.website = Self.exportWebsite
        exported.github = Self.exportGitHub
        return try JSONEncoder().encode(exported)
    }

    private func persist(action: String, candidate: () throws -> CommonPhraseArchive) throws {
        operation &+= 1
        let id = operation
        let start = ProcessInfo.processInfo.systemUptime
        AppLogger.shared.write("COMMON_PHRASES EDIT operation_id=\(id) phase=requested action=\(action)")
        do {
            var candidate = try candidate()
            candidate.builtInIDs = builtInIDs
            try candidate.validate()
            let data = try JSONEncoder().encode(candidate)
            defaults.set(data, forKey: Self.defaultsKey)
            archive = candidate
            AppLogger.shared.write("COMMON_PHRASES EDIT operation_id=\(id) phase=completed result=saved action=\(action) count=\(candidate.entries.count) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
        } catch {
            AppLogger.shared.write("COMMON_PHRASES EDIT operation_id=\(id) phase=completed result=failed action=\(action) reason=invalid_data elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
            throw error
        }
    }
}

/// Claims only panel controls from its owning input source. Held releases remain
/// consumed after closing, so Back never leaks into the foreground application.
struct CommonPhraseRouting {
    struct Input: Hashable { let source: String; let button: RemoteButton }
    enum Decision: Equatable { case unhandled, consumed, insert(RemoteButton), close }
    private(set) var owner: String?
    private var held = Set<Input>()
    mutating func open(source: String) { owner = source }
    mutating func close() { owner = nil }
    mutating func reset(source: String) {
        if owner == source { owner = nil }
        held = held.filter { $0.source != source }
    }
    func claims(_ button: RemoteButton, source: String) -> Bool {
        held.contains(Input(source: source, button: button)) ||
            (owner == source && (CommonPhraseStore.buttons.contains(button) || button == .back))
    }
    mutating func handle(_ button: RemoteButton, phase: RemoteButtonPhase, source: String) -> Decision {
        let input = Input(source: source, button: button)
        if phase == .release { return held.remove(input) != nil ? .consumed : .unhandled }
        if held.contains(input) { return .consumed }
        guard owner == source, CommonPhraseStore.buttons.contains(button) || button == .back
        else { return .unhandled }
        held.insert(input)
        owner = nil
        return button == .back ? .close : .insert(button)
    }
}
