import Foundation

public struct ModelManifest: Codable, Sendable {
    public let name: String
    public let quant: String
    public let sizeBytes: Int64
    public let sha256: String
    public let uri: URL

    public init(name: String, quant: String, sizeBytes: Int64, sha256: String, uri: URL) {
        self.name = name
        self.quant = quant
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case quant
        case sizeBytes = "size_bytes"
        case sha256
        case uri
    }

    public func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.invalidName
        }
        if quant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.invalidQuant
        }
        if sizeBytes <= 0 {
            throw ValidationError.invalidSize
        }
        let hex = sha256.lowercased()
        let isHex = hex.count == 64 && hex.allSatisfy { c in
            ("0"..."9").contains(String(c)) || ("a"..."f").contains(String(c))
        }
        if !isHex {
            throw ValidationError.invalidChecksum
        }
    }

    public static func load(from url: URL) throws -> ModelManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ModelManifest.self, from: data)
    }
}

public enum ValidationError: Error, Equatable {
    case invalidName
    case invalidQuant
    case invalidSize
    case invalidChecksum
}


