import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SonifiedLLMDownloader

final class DownloaderTests: XCTestCase {
    typealias StubURLProtocol = DeterministicURLProtocol

    final class ProgressRecorder: ModelDownloadDelegate, @unchecked Sendable {
        private(set) var updates: [(Int64, Int64?)] = []
        var onFirstUpdate: (() -> Void)?
        func modelDownloadDidUpdateProgress(bytesReceived: Int64, totalBytes: Int64?) {
            updates.append((bytesReceived, totalBytes))
            if updates.count == 1 { onFirstUpdate?() }
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

    private func configuredDownloader(spy: (any ModelDownloadDelegate)? = nil) -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.protocolClasses = [StubURLProtocol.self]
        return ModelDownloader(delegate: spy as? ModelDownloadDelegate, session: URLSession(configuration: config))
    }

    func testSmallFileDownloadAndChecksum() async throws {
        StubURLProtocol.reset(config: .init(version: .v1, chunked: true))
        let expectedHex = StubURLProtocol.sha256V1
        let expectedSize = Int64(StubURLProtocol.bodyV1.count)

        let recorder = ProgressRecorder()
        let downloader = configuredDownloader(spy: recorder)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("model.gguf")

        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: expectedSize, sha256: expectedHex, uri: URL(string: "https://example.com/m.gguf")!)
        try await downloader.download(manifest: manifest, destination: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThanOrEqual(recorder.updates.count, 3)
    }

    func testResumeViaRange() async throws {
        StubURLProtocol.reset(config: .init(version: .v1, chunked: true))
        let expectedHex = StubURLProtocol.sha256V1
        let expectedSize = Int64(StubURLProtocol.bodyV1.count)
        let recorder = ProgressRecorder()
        let progressHappened = expectation(description: "progress")
        recorder.onFirstUpdate = { progressHappened.fulfill() }
        let downloader = configuredDownloader(spy: recorder)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("resume.gguf")

        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: expectedSize, sha256: expectedHex, uri: URL(string: "https://example.com/r.gguf")!)

        let task = Task { try await downloader.download(manifest: manifest, destination: dest) }
        await fulfillment(of: [progressHappened], timeout: 2.0)
        task.cancel(); _ = try? await task.value
        try await downloader.download(manifest: manifest, destination: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThanOrEqual(recorder.updates.count, 3)
    }

    func testResumeWithChangedETagRestartsFromZero() async throws {
        StubURLProtocol.reset(config: .init(version: .v1, chunked: true))
        let hexV2 = StubURLProtocol.sha256V2
        var servedFirst = false

        let recorder = ProgressRecorder()
        let progressHappened = expectation(description: "progress")
        recorder.onFirstUpdate = { servedFirst = true; progressHappened.fulfill() }
        let downloader = configuredDownloader(spy: recorder)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("etag.gguf")
        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(StubURLProtocol.bodyV2.count), sha256: hexV2, uri: URL(string: "https://example.com/e.gguf")!)

        let task = Task { try await downloader.download(manifest: manifest, destination: dest) }
        await fulfillment(of: [progressHappened], timeout: 2.0)
        task.cancel(); _ = try? await task.value
        XCTAssertTrue(servedFirst)
        // Switch to v2 version to cause If-Range mismatch
        StubURLProtocol.reset(config: .init(version: .v2, chunked: true))
        try await downloader.download(manifest: manifest, destination: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertGreaterThanOrEqual(recorder.updates.count, 3)
    }

    func testCancellationLeavesTmpAndCanResume() async throws {
        StubURLProtocol.reset(config: .init(version: .v1, chunked: true))
        let expectedHex = StubURLProtocol.sha256V1
        let expectedSize = Int64(StubURLProtocol.bodyV1.count)
        let recorder = ProgressRecorder()
        let progressHappened = expectation(description: "progress")
        recorder.onFirstUpdate = { progressHappened.fulfill() }
        let downloader = configuredDownloader(spy: recorder)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("cancel.gguf")
        let tmp = URL(fileURLWithPath: dest.path + ".tmp")
        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: expectedSize, sha256: expectedHex, uri: URL(string: "https://example.com/c.gguf")!)

        let task = Task { try await downloader.download(manifest: manifest, destination: dest) }
        await fulfillment(of: [progressHappened], timeout: 2.0)
        task.cancel(); _ = try? await task.value
        // Ensure tmp exists for resume
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
        // Resume completes
        try await downloader.download(manifest: manifest, destination: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func testProgressDeliveredOnMainActor() async throws {
        class MainActorSpy: ModelDownloadDelegate, @unchecked Sendable {
            var isMainActorForAll = true
            func modelDownloadDidUpdateProgress(bytesReceived: Int64, totalBytes: Int64?) {
                if !Thread.isMainThread { isMainActorForAll = false }
            }
        }
        StubURLProtocol.reset(config: .init(version: .v1, chunked: true))
        let spy = MainActorSpy()
        _ = configuredDownloader(spy: nil)
        // Use a small adapter to satisfy type
        class Adapter: ModelDownloadDelegate, @unchecked Sendable {
            let inner: MainActorSpy
            init(_ inner: MainActorSpy) { self.inner = inner }
            func modelDownloadDidUpdateProgress(bytesReceived: Int64, totalBytes: Int64?) { inner.modelDownloadDidUpdateProgress(bytesReceived: bytesReceived, totalBytes: totalBytes) }
        }
        let adapter = Adapter(spy)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [StubURLProtocol.self]
        let dl = ModelDownloader(delegate: adapter, session: URLSession(configuration: cfg))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("p.gguf")
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        let m = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(StubURLProtocol.bodyV1.count), sha256: StubURLProtocol.sha256V1, uri: URL(string: "https://example.com/p.gguf")!)
        try await dl.download(manifest: m, destination: tmp)
        XCTAssertTrue(spy.isMainActorForAll)
    }

    func testRetryOn5xxAndNoRetryOn404() async throws {
        StubURLProtocol.reset(config: .init(version: .v1, chunked: false, induce5xx: 1))
        let dl = configuredDownloader()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("r.gguf")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let m = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(StubURLProtocol.bodyV1.count), sha256: StubURLProtocol.sha256V1, uri: URL(string: "https://example.com/r.gguf")!)
        try await dl.download(manifest: m, destination: dest)
        XCTAssertEqual(StubURLProtocol.requestCount, 2)

        // Now check 404 is not retried. Ensure no pre-existing files
        try? FileManager.default.removeItem(at: dest)
        let tmp = URL(fileURLWithPath: dest.path + ".tmp")
        try? FileManager.default.removeItem(at: tmp)
        StubURLProtocol.reset(config: .init(version: .v1, chunked: false, force404: true))
        do {
            try await dl.download(manifest: m, destination: dest)
            XCTFail("Expected 404 to fail without retry")
        } catch let DownloaderError.downloadFailed(status) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(StubURLProtocol.requestCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChecksumMismatch() async throws {
        StubURLProtocol.reset(config: .init(version: .v1, chunked: false))

        let downloader = configuredDownloader()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("bad.gguf")
        let manifest = ModelManifest(name: "m", quant: "q", sizeBytes: Int64(StubURLProtocol.bodyV1.count), sha256: String(repeating: "0", count: 64), uri: URL(string: "https://example.com/bad.gguf")!)
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

// sha256Hex helper is provided by DeterministicURLProtocol in DownloaderStub.swift

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure @escaping () async throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // success
    }
}


