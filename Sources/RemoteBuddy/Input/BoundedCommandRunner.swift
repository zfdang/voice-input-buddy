import Darwin
import Foundation

/// Runs only on worker queues. The deadline covers both process exit and stdout EOF.
/// Nonblocking reads avoid waiting forever for a descendant that inherited the output pipe.
enum BoundedCommandRunner {
    static let maximumOutputBytes = 1_024 * 1_024

    static func run(executableURL: URL, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = maximumOutputBytes)
        -> KeyboardInjector.CmuxCommandResult {
        let process = Process()
        let output = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return .init(terminationStatus: -1, standardOutput: Data(), timedOut: false)
        }
        do { try process.run() }
        catch { return .init(terminationStatus: -1, standardOutput: Data(), timedOut: false) }
        // Only the child owns the writing end now; EOF must not depend on this parent.
        try? output.fileHandleForWriting.close()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        var eof = false
        var exited = false
        var failed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !eof {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= outputLimit else { failed = true; break }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    failed = true
                    break
                }
            }
            if !exited { exited = completion.wait(timeout: .now()) == .success }
            if eof && exited {
                return .init(terminationStatus: process.terminationStatus, standardOutput: data, timedOut: false)
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            let waitMilliseconds = max(1, min(20, Int(remaining * 1_000)))
            if eof && !exited {
                exited = completion.wait(timeout: .now() + .milliseconds(waitMilliseconds)) == .success
            } else {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&descriptor, 1, Int32(waitMilliseconds))
            }
        }
        if process.isRunning {
            process.terminate()
            if completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .milliseconds(100))
            }
        }
        return .init(terminationStatus: -1, standardOutput: Data(), timedOut: !failed)
    }
}
