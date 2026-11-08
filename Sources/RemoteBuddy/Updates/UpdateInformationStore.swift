import Combine
import Foundation

struct AvailableUpdateInformation: Equatable {
    let displayVersion: String
    let buildVersion: String
    let releaseNotes: [String]
}

enum UpdateInformationState: Equatable {
    case idle
    case checking
    case upToDate
    case unavailable
    case available(AvailableUpdateInformation)
}

enum UpdateFeedResolutionError: Error {
    case invalidResponse
}

enum UpdateFeedResolver {
    struct ResolvedFeed: Equatable {
        let url: URL
        let version: String
        let buildVersion: Int
        let isPreRelease: Bool
    }

    struct FeedResolution: Equatable {
        let stable: ResolvedFeed?
        let preview: ResolvedFeed?

        var selected: ResolvedFeed? {
            UpdateFeedResolver.preferredFeed(stable: stable, preview: preview)
        }
    }

    typealias FeedDataLoader = @Sendable (URL) async throws -> Data

    private static let maximumFeedSize = 1 * 1_024 * 1_024
    private static let feedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    #if DEBUG
    static func testInjectedFeed(
        environment: [String: String],
        assetName: String,
        includePreRelease: Bool
    ) -> ResolvedFeed? {
        guard environment["VOICE_INPUT_BUDDY_UI_TEST_MODE"] == "1",
              includePreRelease,
              let rawURL = environment["VOICE_INPUT_BUDDY_UI_TEST_FEED_URL"],
              let url = URL(string: rawURL),
              url.scheme == "http",
              url.host == "127.0.0.1",
              url.port != nil,
              ["appcast-arm64.xml", "appcast-intel.xml"].contains(url.lastPathComponent),
              url.lastPathComponent == assetName,
              let rawVersion = environment["VOICE_INPUT_BUDDY_UI_TEST_VERSION"],
              let version = UpdateVersion.normalized(rawVersion)
        else { return nil }
        return ResolvedFeed(url: url, version: version, buildVersion: 0, isPreRelease: true)
    }

    #endif

    static func preferredFeed(
        stable: ResolvedFeed?,
        preview: ResolvedFeed?
    ) -> ResolvedFeed? {
        switch (stable, preview) {
        case let (stable?, preview?):
            return preview.buildVersion > stable.buildVersion
                ? preview
                : stable
        case let (stable?, nil):
            return stable
        case let (nil, preview?):
            return preview
        case (nil, nil):
            return nil
        }
    }

    static func resolvePreviewFeed(
        stableURL: URL,
        previewURL: URL,
        loader: @escaping FeedDataLoader = { url in
            try await UpdateFeedResolver.loadFeedData(from: url)
        }
    ) async -> FeedResolution {
        async let stableData = try? loader(stableURL)
        async let previewData = try? loader(previewURL)
        let (stablePayload, previewPayload) = await (stableData, previewData)
        return FeedResolution(
            stable: stablePayload.flatMap {
                resolvedFeed(url: stableURL, data: $0, isPreRelease: false)
            },
            preview: previewPayload.flatMap {
                resolvedFeed(url: previewURL, data: $0, isPreRelease: true)
            }
        )
    }

    static func loadFeedData(from url: URL, session: URLSession = feedSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("RemoteBuddy", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.expectedContentLength <= Int64(maximumFeedSize)
        else { throw UpdateFeedResolutionError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumFeedSize else {
                throw UpdateFeedResolutionError.invalidResponse
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    private static func resolvedFeed(
        url: URL,
        data: Data,
        isPreRelease: Bool
    ) -> ResolvedFeed? {
        // Compare full build counts: display suffixes wrap at every thousand commits.
        guard let document = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
              let items = try? document.nodes(forXPath: "/rss/channel/item") else { return nil }
        let versions = items.compactMap { node -> ResolvedFeed? in
            guard let item = node as? XMLElement,
                  let rawVersion = item.elements(forName: "sparkle:shortVersionString").first?.stringValue,
                  let version = UpdateVersion.normalized(rawVersion),
                  let rawBuild = item.elements(forName: "sparkle:version").first?.stringValue,
                  let build = Int(rawBuild), build > 0 else { return nil }
            return ResolvedFeed(url: url, version: version, buildVersion: build, isPreRelease: isPreRelease)
        }
        return versions.max { $0.buildVersion < $1.buildVersion }
    }

}

enum UpdateVersion {
    static func normalized(_ rawValue: String) -> String? {
        let stripped = rawValue.hasPrefix("v") ? String(rawValue.dropFirst()) : rawValue
        let value = stripped.range(of: #"^\d{2}-\d{2}-\d{2}\.\d{3}$"#, options: .regularExpression) != nil
            ? stripped.replacingOccurrences(of: "-", with: ".") : stripped
        guard value.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = normalized(candidate),
              let current = normalized(current)
        else { return false }
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }
}

enum UpdateReleaseNotes {
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isNewline).compactMap { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("- ") || value.hasPrefix("• ") {
                value.removeFirst(2)
            }
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return value
        }
    }

}

@MainActor
final class UpdateInformationStore: ObservableObject {
    @Published private(set) var state: UpdateInformationState = .idle
    @Published private(set) var hasUnseenUpdate = false

    private struct PendingUpdate: Equatable {
        let displayVersion: String
        let buildVersion: String
        let fallbackNotes: [String]

        var identifier: String {
            "\(displayVersion)|\(buildVersion)"
        }
    }

    private static let lastSeenUpdateIdentifierKey =
        "updateInformation.lastSeenUpdateIdentifier"

    private let userDefaults: UserDefaults
    private var pendingUpdate: PendingUpdate?
    private var checkingDeadline: ScheduledOperation?
    private var checkingGeneration = UUID()
    private let schedule: OperationScheduler
    private let checkingTimeout: TimeInterval

    init(userDefaults: UserDefaults = .standard, checkingTimeout: TimeInterval = 30,
         schedule: @escaping OperationScheduler = ScheduledOperation.mainQueue) {
        self.userDefaults = userDefaults
        self.checkingTimeout = checkingTimeout
        self.schedule = schedule
    }

    deinit { checkingDeadline?.cancel() }

    private func cancelCheckingDeadline() {
        checkingGeneration = UUID()
        checkingDeadline?.cancel()
        checkingDeadline = nil
    }

    func beginChecking(timeoutEnabled: Bool = true) {
        cancelCheckingDeadline()
        state = .checking
        guard timeoutEnabled else { return }
        let generation = checkingGeneration
        checkingDeadline = schedule(checkingTimeout) { [weak self] in
            guard let self, self.checkingGeneration == generation,
                  self.state == .checking else { return }
            self.setUnavailable()
        }
    }

    func reset() {
        cancelCheckingDeadline()
        pendingUpdate = nil
        state = .idle
        clearUnseenUpdate(reason: "update_state_reset")
    }

    func setUpToDate() {
        cancelCheckingDeadline()
        pendingUpdate = nil
        state = .upToDate
        clearUnseenUpdate(reason: "up_to_date")
    }

    func setUnavailable() {
        cancelCheckingDeadline()
        pendingUpdate = nil
        state = .unavailable
        clearUnseenUpdate(reason: "update_information_unavailable")
    }

    func setAvailable(
        displayVersion: String,
        buildVersion: String,
        fallbackDescription: String?
    ) {
        cancelCheckingDeadline()
        let pending = PendingUpdate(
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            fallbackNotes: fallbackDescription.map(UpdateReleaseNotes.parse) ?? []
        )
        let candidateChanged = pendingUpdate?.identifier != pending.identifier
        pendingUpdate = pending
        state = .available(information(for: pending, notes: pending.fallbackNotes))
        if candidateChanged {
            hasUnseenUpdate = userDefaults.string(
                forKey: Self.lastSeenUpdateIdentifierKey
            ) != pending.identifier
            AppLogger.shared.write(
                "UPDATE BADGE phase=completed result=\(hasUnseenUpdate ? "shown" : "suppressed") " +
                    "reason=\(hasUnseenUpdate ? "new_update_detected" : "already_seen") " +
                    "display_version=\(AppLogger.stableToken(displayVersion)) " +
                    "build_version=\(AppLogger.stableToken(buildVersion))"
            )
        }
    }

    func markAvailableUpdateSeen() {
        guard hasUnseenUpdate, let pendingUpdate else { return }
        userDefaults.set(pendingUpdate.identifier, forKey: Self.lastSeenUpdateIdentifierKey)
        hasUnseenUpdate = false
        AppLogger.shared.write(
            "UPDATE BADGE phase=completed result=cleared reason=settings_opened " +
                "display_version=\(AppLogger.stableToken(pendingUpdate.displayVersion)) " +
                "build_version=\(AppLogger.stableToken(pendingUpdate.buildVersion))"
        )
    }

    private func information(
        for pending: PendingUpdate,
        notes: [String]
    ) -> AvailableUpdateInformation {
        AvailableUpdateInformation(
            displayVersion: pending.displayVersion,
            buildVersion: pending.buildVersion,
            releaseNotes: notes
        )
    }

    private func clearUnseenUpdate(reason: String) {
        guard hasUnseenUpdate else { return }
        hasUnseenUpdate = false
        AppLogger.shared.write(
            "UPDATE BADGE phase=completed result=cleared reason=\(reason)"
        )
    }

}
