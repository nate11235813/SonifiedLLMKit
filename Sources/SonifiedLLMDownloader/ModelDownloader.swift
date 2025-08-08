import Foundation
import CryptoKit

public protocol ModelDownloadDelegate: AnyObject, Sendable {
    func modelDownloadDidUpdateProgress(bytesReceived: Int64, totalBytes: Int64?)
}

public enum DownloaderError: Error {
    case downloadFailed(status: Int)
    case checksumMismatch
    case ioFailure(underlying: Error)
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
                if !ok { throw DownloaderError.checksumMismatch }

                // Atomic-ish move to destination
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tmpURL, to: destination)
                return
            } catch let error as DownloaderError {
                // Retry on 5xx only; other errors rethrow
                switch error {
                case .downloadFailed(let status) where (500...599).contains(status) && attempt < 2:
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    delayMs = min(delayMs * 4, 2_000)
                    continue
                default:
                    throw error
                }
            } catch {
                // IO or networking error: wrap and maybe retry (treat as 500)
                if attempt < 2 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    delayMs = min(delayMs * 4, 2_000)
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
        if fm.fileExists(atPath: tmpURL.path),
           let attrs = try? fm.attributesOfItem(atPath: tmpURL.path),
           let size = attrs[.size] as? NSNumber {
            existingBytes = size.int64Value
            if existingBytes > 0 {
                request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
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
                delegate?.modelDownloadDidUpdateProgress(bytesReceived: received, totalBytes: totalBytes)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            let data = Data(buffer)
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            delegate?.modelDownloadDidUpdateProgress(bytesReceived: received, totalBytes: totalBytes)
            buffer.removeAll(keepingCapacity: true)
        }
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
}


