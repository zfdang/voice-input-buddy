import Foundation
import Testing
@testable import RemoteBuddy

/// Runs entirely through URLProtocol; none of these requests reach the network.
private final class FeedDownloadFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = request.url!.lastPathComponent
        let limit = 1_024 * 1_024
        let size = mode == "large-body" ? limit + 1 : (mode == "exact" ? limit : 4)
        let headers = mode == "large-header" ? ["Content-Length": "1048577"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "error" ? 404 : 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 65, count: 16 * 1_024)
        var remaining = size
        while remaining > 0 {
            let amount = min(chunk.count, remaining)
            client?.urlProtocol(self, didLoad: Data(chunk.prefix(amount)))
            remaining -= amount
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Bounded update feed download")
struct UpdateFeedDownloadTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedDownloadFixture.self]
        return URLSession(configuration: configuration)
    }

    @Test(arguments: ["small", "exact"])
    func acceptedPayloadMatchesResponse(mode: String) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let data = try await UpdateFeedResolver.loadFeedData(
            from: URL(string: "https://feed.example.invalid/" + mode)!, session: session)
        #expect(data == Data(repeating: 65, count: mode == "exact" ? 1_024 * 1_024 : 4))
    }

    @Test(arguments: ["large-header", "large-body", "error"])
    func refusesOversizedOrFailedResponse(mode: String) async {
        let session = session()
        defer { session.invalidateAndCancel() }
        await #expect(throws: UpdateFeedResolutionError.self) {
            try await UpdateFeedResolver.loadFeedData(
                from: URL(string: "https://feed.example.invalid/" + mode)!, session: session)
        }
    }
    @Test func feedSelectionUsesFullBuildCountAcrossDisplayRollover() async {
        let stable = URL(string: "https://feed.example.invalid/stable")!
        let preview = URL(string: "https://feed.example.invalid/preview")!
        let resolution = await UpdateFeedResolver.resolvePreviewFeed(stableURL: stable, previewURL: preview) { url in
            let builds = url == stable ? [999] : [1000, 998, 1001]
            let items = builds.map { count in
                "<item><sparkle:version>\(count)</sparkle:version>" +
                    "<sparkle:shortVersionString>v26-10-18.\(String(format: "%03d", count % 1000))</sparkle:shortVersionString></item>"
            }.joined()
            return Data("<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel>\(items)</channel></rss>".utf8)
        }
        #expect(resolution.selected?.url == preview)
        #expect(resolution.selected?.buildVersion == 1001)
        #expect(resolution.selected?.version == "26.10.18.001")
    }

}
