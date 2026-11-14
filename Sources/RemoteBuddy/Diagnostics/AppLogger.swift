import Darwin
import Foundation
import OSLog

final class AppLogger: PublicDiagnosticEventSink {
    struct Metadata: Equatable {
        let processID: Int32
        let version: String
        let build: String

        static func current(
            bundle: Bundle = .main,
            processInfo: ProcessInfo = .processInfo
        ) -> Metadata {
            Metadata(
                processID: processInfo.processIdentifier,
                version: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                build: bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown"
            )
        }
    }

    typealias RetirementHandler = (URL) throws -> Void

    static let shared = AppLogger()

    let logURL: URL
    let isEnabled: Bool

    var logDirectoryURL: URL {
        logURL.deletingLastPathComponent()
    }

    private static let systemLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RemoteBuddy",
        category: "AppLogger"
    )
    private static let defaultMaximumFileSize: UInt64 = 10 * 1_024 * 1_024
    private static let fileHeader = Data("Remote Buddy runtime log (UTF-8)\n".utf8)

    private let queue = DispatchQueue(label: "RemoteBuddy.logger")
    private let formatter: ISO8601DateFormatter
    private let metadata: Metadata
    private let maximumFileSize: UInt64
    private let archiveCount: Int
    private let fileManager: FileManager
    private let now: () -> Date
    private let reportFailure: (String) -> Void
    private var sessionDescriptor: Int32 = -1
    private var sessionSize: UInt64 = 0
    private var oversizedRecordWasReported = false
    private var fileLoggingStopped = false
    private var nextSequence: UInt64 = 0

    static func defaultLogDirectory(libraries: [URL], home: URL) -> URL {
        let library = libraries.first ?? home.appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RemoteBuddy", isDirectory: true)
    }

    private convenience init() {
        let fileManager = FileManager.default
        let base = Self.defaultLogDirectory(
            libraries: fileManager.urls(for: .libraryDirectory, in: .userDomainMask),
            home: fileManager.homeDirectoryForCurrentUser
        )
        let sessionName = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8)
        let day = Self.dayIdentifier(Date())
        let loggingEnabled = Self.shouldEnableSharedLogging()
        self.init(
            logURL: base.appendingPathComponent(
                "remotebuddy.app-\(day)-session-\(sessionName).log"
            ),
            metadata: .current(),
            fileManager: fileManager,
            isEnabled: loggingEnabled
        )
    }

    init(
        logURL: URL,
        metadata: Metadata = .current(),
        maximumFileSize: UInt64 = AppLogger.defaultMaximumFileSize,
        archiveCount: Int = 5,
        fileManager: FileManager = .default,
        retirementHandler: RetirementHandler? = nil,
        now: @escaping () -> Date = Date.init,
        reportFailure: ((String) -> Void)? = nil,
        isEnabled: Bool = true
    ) {
        self.logURL = logURL
        self.isEnabled = isEnabled
        self.metadata = Metadata(
            processID: metadata.processID,
            version: Self.stableToken(metadata.version),
            build: Self.stableToken(metadata.build)
        )
        self.archiveCount = max(0, archiveCount)
        self.maximumFileSize = max(UInt64(Self.fileHeader.count), maximumFileSize)
        self.fileManager = fileManager
        self.now = now
        self.reportFailure = reportFailure ?? { message in
            Self.systemLogger.error("\(message, privacy: .public)")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = formatter

        guard isEnabled else { return }
        do {
            try fileManager.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logDirectoryURL.path
            )

            try withExclusiveLogLock {
                // Session names are unique. Never overwrite an existing file or follow a link.
                let descriptor = Darwin.open(logURL.path,
                    O_CREAT | O_EXCL | O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR))
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                    _ = Darwin.close(descriptor)
                    throw POSIXError(.EIO)
                }
                sessionDescriptor = descriptor
                try appendAtomically(Self.fileHeader)
                do { try retireOldSessions(archiveCount: max(0, archiveCount), handler: retirementHandler) }
                catch { diagnose("session_retirement_failed", error: error) }
            }
        } catch {
            fileLoggingStopped = true
            diagnose("session_file_create_failed", error: error)
        }
    }

    deinit {
        if sessionDescriptor >= 0 { _ = Darwin.close(sessionDescriptor) }
    }

    private func retireOldSessions(archiveCount: Int, handler: RetirementHandler?) throws {
        let candidates = try fileManager.contentsOfDirectory(
            at: logDirectoryURL, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { url in
            url.lastPathComponent != logURL.lastPathComponent && url.pathExtension == "log" &&
                url.lastPathComponent.hasPrefix("remotebuddy.app-")
        }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left == right ? $0.lastPathComponent > $1.lastPathComponent : left > right
        }
        for url in candidates.dropFirst(archiveCount) {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { _ = Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else { continue }
            var locked = false
            for _ in 0..<5 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    locked = true
                    break
                }
                usleep(2000)
            }
            guard locked else { continue }
            // Only files belonging to this logger are eligible; symlinks and active
            // sessions are skipped. A custom retirement handler can move an archive.
            if let handler { try handler(url) }
            else { try fileManager.removeItem(at: url) }
        }
    }

    func write(_ message: String) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.appendRecord(message: message, date: self.now())
        }
    }

    /// Writes a redacted diagnostic snapshot as ordered text records.
    func writeDiagnosticSummary(_ summary: String, event: String) {
        guard isEnabled else { return }
        let normalizedEvent = Self.singleLine(event)
        let lines = summary
            .split(omittingEmptySubsequences: false) { character in
                character == "\n" || character == "\r"
            }
            .map { Self.singleLine(String($0)) }
        queue.async { [weak self] in
            guard let self else { return }
            let eventDate = self.now()
            self.appendRecord(message: "\(normalizedEvent) BEGIN", date: eventDate)
            for line in lines {
                self.appendRecord(
                    message: "\(normalizedEvent) FIELD \(line)",
                    date: eventDate
                )
            }
            self.appendRecord(message: "\(normalizedEvent) END", date: eventDate)
        }
    }

    /// Structured diagnostics use the same local-only log as other runtime messages.
    func record(_ event: PublicDiagnosticEvent) {
        write(event.canonicalLine)
    }

    func write(publicEvent: PublicDiagnosticEvent) {
        record(publicEvent)
    }

    func flush() {
        guard isEnabled else { return }
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
    }

    /// Test-only style entry point that writes UTF-8 text.
    func writeSynchronously(_ message: String, at date: Date) {
        guard isEnabled else { return }
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            appendRecord(message: message, date: date)
        }
    }

    static func shouldEnableSharedLogging(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let isXCTestProcess = arguments.contains { argument in
            argument.contains(".xctest")
        }
        let hasTestEnvironment = environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil
        return !isXCTestProcess && !hasTestEnvironment
    }

    static func errorFields(_ error: Error) -> String {
        let cocoaError = error as NSError
        return errorFields(domain: cocoaError.domain, code: cocoaError.code)
    }

    static func errorFields(
        domain: String,
        code: Int,
        fieldPrefix: String = "error"
    ) -> String {
        let prefix = stableToken(fieldPrefix)
        return "\(prefix)_domain=\(stableToken(domain)) \(prefix)_code=\(code)"
    }

    static func optionalErrorFields(_ error: Error?) -> String {
        guard let error else { return "error_domain=none error_code=0" }
        return errorFields(error)
    }

    static func stableToken(_ value: String) -> String {
        let token = String(value.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        })
        return token.isEmpty ? "unknown" : token
    }

    private func appendRecord(message: String, date: Date) {
        guard !fileLoggingStopped else { return }
        do {
            let sequence = nextSequence
            let line = "\(formatter.string(from: date)) pid=\(metadata.processID) " +
                "ver=\(metadata.version) build=\(metadata.build) seq=\(sequence) " +
                "\(Self.singleLine(message))\n"
            let record = Data(line.utf8)
            guard UInt64(record.count) + UInt64(Self.fileHeader.count) <= maximumFileSize else {
                if !oversizedRecordWasReported { reportFailure("log_record_too_large") }
                oversizedRecordWasReported = true
                return
            }
            oversizedRecordWasReported = false
            if sessionSize + UInt64(record.count) > maximumFileSize {
                try withExclusiveLogLock { try rotateCurrentSession() }
            }
            try appendAtomically(record)
            nextSequence += 1
        } catch {
            diagnose("log_write_failed", error: error)
        }
    }

    private func rotateCurrentSession() throws {
        var current = stat(), owned = stat()
        guard sessionDescriptor >= 0,
              fstat(sessionDescriptor, &owned) == 0,
              lstat(logURL.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFREG,
              current.st_dev == owned.st_dev, current.st_ino == owned.st_ino else {
            throw POSIXError(.EIO)
        }
        let archive = logURL.deletingPathExtension()
            .appendingPathExtension("part-" + UUID().uuidString + ".log")
        try fileManager.moveItem(at: logURL, to: archive)
        _ = Darwin.close(sessionDescriptor)
        sessionDescriptor = -1
        let descriptor = Darwin.open(logURL.path,
            O_CREAT | O_EXCL | O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        sessionDescriptor = descriptor
        sessionSize = 0
        try appendAtomically(Self.fileHeader)
        try retireOldSessions(archiveCount: archiveCount, handler: nil)
    }

    private func appendAtomically(_ data: Data) throws {
        let descriptor = sessionDescriptor
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                    sessionSize += UInt64(written)
                    continue
                }
                let errorCode = written == 0 ? EIO : errno
                if errorCode == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
            }
        }
    }

    private func withExclusiveLogLock<T>(_ operation: () throws -> T) throws -> T {
        let lockURL = logURL.deletingLastPathComponent()
            .appendingPathComponent(".remotebuddy-diagnostic-log.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            let errorCode = errno
            if errorCode == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func diagnose(_ operation: String, error: Error? = nil) {
        if let error {
            reportFailure("\(operation) \(Self.errorFields(error))")
        } else {
            reportFailure(operation)
        }
    }

    private static func singleLine(_ message: String) -> String {
        let collapsed = String(message.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) ||
                CharacterSet.newlines.contains(scalar)
            {
                return " "
            }
            return Character(String(scalar))
        })
        return SettingsDiagnosticSnapshot.sanitizePath(collapsed)
    }

    private static func dayIdentifier(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
