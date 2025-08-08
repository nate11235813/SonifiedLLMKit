import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SonifiedLLMDownloader

final class DownloaderTests: XCTestCase {
    private final class StubURLProtocol: URLProtocol {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let handler = Self.handler else { return }
            do {
                let (resp, data) = try handler(request)
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                var offset = 0
                let bytes = [UInt8](data)
                let chunk = 64 * 1024
                while offset < bytes.count {
                    let end = min(offset + chunk, bytes.count)
                    let slice = Data(bytes[offset..<end])
                    client?.urlProtocol(self, didLoad: slice)
                    offset = end
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private final class ProgressSpy: ModelDownloadDelegate {
        private(set) var updates: [(Int64, Int64?)] = []
        func modelDownloadDidUpdateProgress(bytesReceived: Int64, totalBytes: Int64?) {
            updates.append((bytesReceived, totalBytes))
        }
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    private func configuredDownloader(spy: ProgressSpy? = nil) -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return ModelDownloader(delegate: spy, session: URLSession(configuration: config))
    }

    func testSmallFileDownloadAndChecksum() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let hex = data.sha256Hex()

        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Length": String(data.count)
            ])!
            return (resp, data)
        }

        let spy = ProgressSpy()
        let downloader = configuredDownloader(spy: spy)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("model.gguf")

        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(data.count), sha256: hex, uri: URL(string: "https://example.com/m.gguf")!)
        try await downloader.download(manifest: manifest, destination: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThanOrEqual(spy.updates.count, 3)
    }

    func testResumeViaRange() async throws {
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let hex = data.sha256Hex()
        let half = data.count / 2
        var first = true

        StubURLProtocol.handler = { req in
            if let range = req.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 206, httpVersion: nil, headerFields: [
                    "Content-Range": "bytes \(half)-\(data.count-1)/\(data.count)",
                    "Content-Length": String(data.count - half)
                ])!
                return (resp, Data(data[half...]))
            } else {
                let body = data[0..<half]
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Length": String(body.count)
                ])!
                defer { first = false }
                if first {
                    return (resp, Data(body))
                } else {
                    let errResp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                    return (errResp, Data())
                }
            }
        }

        let spy = ProgressSpy()
        let downloader = configuredDownloader(spy: spy)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("resume.gguf")

        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(data.count), sha256: hex, uri: URL(string: "https://example.com/r.gguf")!)

        do { try await downloader.download(manifest: manifest, destination: dest) } catch {}
        try await downloader.download(manifest: manifest, destination: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThanOrEqual(spy.updates.count, 3)
    }

    func testChecksumMismatch() async throws {
        let data = Data((0..<50_000).map { UInt8($0 % 251) })
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Length": String(data.count)
            ])!
            return (resp, data)
        }

        let downloader = configuredDownloader()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("bad.gguf")
        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(data.count), sha256: String(repeating: "0", count: 64), uri: URL(string: "https://example.com/bad.gguf")!)
        await XCTAssertThrowsErrorAsync(try await downloader.download(manifest: manifest, destination: dest))
    }

    func testCachePolicyEviction() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let files = [
            ("a.gguf", 3 * 1024 * 1024),
            ("b.gguf", 2 * 1024 * 1024),
            ("c.gguf", 1 * 1024 * 1024),
        ]
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        for (name, size) in files {
            let url = tmpDir.appendingPathComponent(name)
            try Data(repeating: 0xAB, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            now.addTimeInterval(10)
        }
        let policy = ModelCachePolicy(capBytes: 2 * 1024 * 1024)
        try policy.enforce(at: tmpDir)
        let remaining = try fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil).map { $0.lastPathComponent }
        XCTAssertEqual(Set(remaining), Set(["c.gguf"]))
    }
}

private extension Data {
    func sha256Hex() -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(repeating: "0", count: 64)
        #endif
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure @escaping () async throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // success
    }
}


