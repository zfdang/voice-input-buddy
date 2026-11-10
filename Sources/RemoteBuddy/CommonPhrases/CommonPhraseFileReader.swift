import Foundation

/// Reads at most the limit plus one byte, including growing files and streams.
enum CommonPhraseFileReader {
    enum ReadError: Error {
        case fileTooLarge
    }

    static let maximumBytes = 4_000_000

    static func read(from url: URL, maximumBytes: Int = maximumBytes) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw ReadError.fileTooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try file.read(upToCount: min(64 * 1024, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw ReadError.fileTooLarge
    }
}
