import Foundation
import CryptoKit

public protocol ModelDownloadDelegate: AnyObject, Sendable {
    // Progress callbacks are delivered on the main actor.
    func modelDownloadDidUpdateProgress(bytesReceived: Int64, totalBytes: Int64?)
}

public enum DownloaderError: Error {
    case downloadFailed(status: Int)
    case checksumMismatch
    case ioFailure(underlying: Error)
    case resumeInvalid
}

public final class ModelDownloader: @unchecked Sendable {
    private weak var delegate: ModelDownloadDelegate?
    private let session: URLSession

    public init(delegate: ModelDownloadDelegate? = nil, session: URLSession? = nil) {
        self.delegate = delegate
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    public func download(manifest: ModelManifest, destination: URL) async throws {
        // If destination exists and matches checksum, return immediately
        if FileManager.default.fileExists(atPath: destination.path) {
            if try verifyChecksum(of: destination, expectedHex: manifest.sha256) {
                return
            }
        }

        let tmpURL = URL(fileURLWithPath: destination.path + ".tmp")

        var attempt = 0
        var delayMs: UInt64 = 500

        while true {
            do {
                try await performDownload(manifest: manifest, tmpURL: tmpURL)

                // Verify checksum against tmp
                let ok = try verifyChecksum(of: tmpURL, expectedHex: manifest.sha256)
                if !ok {
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.removeItem(at: tmpURL)
                    try? FileManager.default.removeItem(at: etagSidecarURL(for: tmpURL))
                    throw DownloaderError.checksumMismatch
                }

                // Atomic-ish move to destination
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tmpURL, to: destination)
                return
            } catch let error as DownloaderError {
                // Retry on specific statuses or resume-invalid conditions
                switch error {
                case .resumeInvalid where attempt < 3:
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    delayMs = min(delayMs * 2, 2_000)
                    continue
                case .downloadFailed(let status) where ([408, 429].contains(status) || (500...599).contains(status)) && attempt < 3:
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    delayMs = min(delayMs * 2, 2_000)
                    continue
                default:
                    throw error
                }
            } catch is CancellationError {
                // Propagate cancellation; keep partial .tmp for resume
                throw CancellationError()
            } catch {
                // IO or networking error: retry a few times
                if attempt < 3 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    delayMs = min(delayMs * 2, 2_000)
                    continue
                }
                throw DownloaderError.ioFailure(underlying: error)
            }
        }
    }

    private func performDownload(manifest: ModelManifest, tmpURL: URL) async throws {
        var request = URLRequest(url: manifest.uri)

        let fm = FileManager.default
        var existingBytes: Int64 = 0
        var storedETag: String? = nil
        if fm.fileExists(atPath: tmpURL.path),
           let attrs = try? fm.attributesOfItem(atPath: tmpURL.path),
           let size = attrs[.size] as? NSNumber {
            existingBytes = size.int64Value
            if existingBytes > 0 {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
                storedETag = try? String(contentsOf: etagSidecarURL(for: tmpURL), encoding: .utf8)
                if let storedETag, !storedETag.isEmpty {
                    request.setValue(storedETag.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "If-Range")
                }
            }
        }

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw DownloaderError.downloadFailed(status: -1)
        }
        let status = http.statusCode
        if !(200...299).contains(status) {
            throw DownloaderError.downloadFailed(status: status)
        }

        // Determine total length if present
        var totalBytes: Int64? = nil
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
            // Format: bytes N-M/TOTAL
            if let totalPart = contentRange.split(separator: "/").last,
               let total = Int64(totalPart) {
                totalBytes = total
            }
        } else if http.expectedContentLength > 0 {
            totalBytes = existingBytes + http.expectedContentLength
        }

        // Validate resume integrity if resuming
        if existingBytes > 0 {
            let currentETag = http.value(forHTTPHeaderField: "ETag")
            let contentRange = http.value(forHTTPHeaderField: "Content-Range")
            let startsAtExpected = contentRange?.lowercased().hasPrefix("bytes \(existingBytes)-") ?? false
            let etagMatches = (storedETag == nil) || (currentETag == nil) || (storedETag?.trimmingCharacters(in: .whitespacesAndNewlines) == currentETag?.trimmingCharacters(in: .whitespacesAndNewlines))
            if !(status == 206 && startsAtExpected && etagMatches) {
                try? fm.removeItem(at: tmpURL)
                try? fm.removeItem(at: etagSidecarURL(for: tmpURL))
                throw DownloaderError.resumeInvalid
            }
        }

        // Persist latest ETag
        if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            try? etag.write(to: etagSidecarURL(for: tmpURL), atomically: true, encoding: .utf8)
        }

        // Prepare file handle
        if !fm.fileExists(atPath: tmpURL.path) {
            fm.createFile(atPath: tmpURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: tmpURL) else {
            throw DownloaderError.ioFailure(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        }
        defer { try? handle.close() }
        // Seek to end for append
        do { try handle.seekToEnd() } catch { throw DownloaderError.ioFailure(underlying: error) }

        var received: Int64 = existingBytes
        var buffer: [UInt8] = []
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                let data = Data(buffer)
                try handle.write(contentsOf: data)
                received += Int64(data.count)
                if let delegate = delegate {
                    let progressReceived = received
                    let progressTotal = totalBytes
                    await MainActor.run {
                        delegate.modelDownloadDidUpdateProgress(bytesReceived: progressReceived, totalBytes: progressTotal)
                    }
                }
                buffer.removeAll(keepingCapacity: true)
            }
            try Task.checkCancellation()
        }
        if !buffer.isEmpty {
            let data = Data(buffer)
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            if let delegate = delegate {
                let progressReceived = received
                let progressTotal = totalBytes
                await MainActor.run {
                    delegate.modelDownloadDidUpdateProgress(bytesReceived: progressReceived, totalBytes: progressTotal)
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }

        // Flush before verification/move
        try? handle.synchronize()
    }

    private func verifyChecksum(of fileURL: URL, expectedHex: String) throws -> Bool {
        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? reader.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? reader.read(upToCount: 1024 * 256)
            if let data, !data.isEmpty {
                hasher.update(data: data)
                return true
            }
            return false
        }) {}
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == expectedHex.lowercased()
    }

    private func etagSidecarURL(for tmpURL: URL) -> URL {
        tmpURL.appendingPathExtension("etag")
    }
}


