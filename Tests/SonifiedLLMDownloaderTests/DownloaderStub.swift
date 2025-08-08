import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum BodyVersion { case v1, v2 }

struct StubConfig {
    var version: BodyVersion = .v1
    var chunked: Bool = true
    var induce5xx: Int = 0
    var force404: Bool = false
    var rotateToV2OnFreshGet: Bool = false
}

final class DeterministicURLProtocol: URLProtocol {
    // Precomputed bodies and hashes
    static let bodyV1: Data = Data((0..<300_000).map { UInt8($0 % 251) })
    static let bodyV2: Data = Data((0..<300_000).map { UInt8(($0 + 7) % 251) })
    static let sha256V1: String = DeterministicURLProtocol.bodyV1.sha256Hex()
    static let sha256V2: String = DeterministicURLProtocol.bodyV2.sha256Hex()

    static var config = StubConfig()
    static var requestCount: Int = 0
    private static var induce5xxRemaining: Int = 0
    private static var rotatedOnce = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let cfg = Self.config
        if cfg.force404 {
            respond(status: 404, headers: nil, body: Data())
            return
        }
        if Self.induce5xxRemaining > 0 {
            Self.induce5xxRemaining -= 1
            respond(status: 503, headers: nil, body: Data())
            return
        }

        // pick body/etag by version (with optional rotation on fresh GET)
        var version = cfg.version
        let hasRange = (request.value(forHTTPHeaderField: "Range") ?? "").hasPrefix("bytes=")
        if cfg.rotateToV2OnFreshGet && !hasRange && !Self.rotatedOnce {
            version = .v2
            Self.rotatedOnce = true
        }
        let (body, etag): (Data, String) = {
            switch version {
            case .v1: return (Self.bodyV1, "v1")
            case .v2: return (Self.bodyV2, "v2")
            }
        }()

        // If-Range handling
        if let ifRange = request.value(forHTTPHeaderField: "If-Range"), ifRange != etag {
            let headers = [
                "ETag": etag,
                "Content-Length": String(body.count)
            ]
            respond(status: 200, headers: headers, body: body)
            return
        }

        if hasRange, let rangeHeader = request.value(forHTTPHeaderField: "Range") {
            // Parse bytes=N-
            let prefix = "bytes="
            let rest = rangeHeader.dropFirst(prefix.count)
            let startStr = rest.split(separator: "-").first ?? Substring("0")
            let start = Int(startStr) ?? 0
            let n = max(0, min(start, body.count))
            let slice = body[n...]
            let headers = [
                "ETag": etag,
                "Content-Length": String(slice.count),
                "Content-Range": "bytes \(n)-\(body.count-1)/\(body.count)"
            ]
            respond(status: 206, headers: headers, body: Data(slice))
        } else {
            let headers = [
                "ETag": etag,
                "Content-Length": String(body.count)
            ]
            respond(status: 200, headers: headers, body: body)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, headers: [String: String]?, body: Data) {
        guard let url = request.url else { return }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if Self.config.chunked, status == 200 || status == 206, body.count > 0 {
            // Deliver in 3 chunks with small delays
            let len = body.count
            let c1 = body.subdata(in: 0..<(len/3))
            let c2 = body.subdata(in: (len/3)..<(2*len/3))
            let c3 = body.subdata(in: (2*len/3)..<len)
            let q = DispatchQueue.global(qos: .utility)
            q.asyncAfter(deadline: .now() + 0.01) { self.client?.urlProtocol(self, didLoad: c1) }
            q.asyncAfter(deadline: .now() + 0.03) { self.client?.urlProtocol(self, didLoad: c2) }
            q.asyncAfter(deadline: .now() + 0.05) {
                self.client?.urlProtocol(self, didLoad: c3)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    // Test helpers
    static func reset(config: StubConfig) {
        Self.config = config
        Self.induce5xxRemaining = config.induce5xx
        Self.rotatedOnce = false
        Self.requestCount = 0
    }
}

extension Data {
    func sha256Hex() -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(repeating: "0", count: 64)
        #endif
    }
}


