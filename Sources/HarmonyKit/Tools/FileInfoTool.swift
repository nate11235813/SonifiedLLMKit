import Foundation
import CryptoKit

public final class FileInfoTool: HarmonyTool {
    public let name: String = "fileInfo"
    public let description: String = "Return size, last-modified, and SHA-256 for a file under an allowed root."
    public let parametersJSONSchema: String = "{" +
    "\"type\":\"object\",\"properties\":{\"relativePath\":{\"type\":\"string\"}},\"required\":[\"relativePath\"],\"additionalProperties\":false" +
    "}"

    private let allowedRoot: URL

    public init(allowedRoot: URL) {
        self.allowedRoot = allowedRoot
    }

    public func invoke(args: [String : Any]) throws -> ToolResult {
        guard let rel = args["relativePath"] as? String else {
            return ToolResult(name: name, content: "error: missing relativePath", metadata: ["error": "missing relativePath"])
        }
        // Resolve and normalize within allowed root
        let candidate = allowedRoot.appendingPathComponent(rel)
        guard let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().absoluteURLIfPossible else {
            return ToolResult(name: name, content: "error: invalid path", metadata: ["error": "invalidPath"])
        }
        // Ensure it stays under allowedRoot
        let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path) else {
            return ToolResult(name: name, content: "error: path escapes allowed root", metadata: ["error": "escape"])
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
            return ToolResult(name: name, content: "error: file missing", metadata: ["error": "missing"])
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: resolved.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let iso = isoString(utc: mtime)
            // Hash
            let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let meta: [String: Any] = [
                "size": size,
                "lastModified": iso,
                "sha256": hex,
                "path": resolved.path
            ]
            return ToolResult(name: name, content: "ok", metadata: meta)
        } catch {
            return ToolResult(name: name, content: "error: unreadable", metadata: ["error": String(describing: error)])
        }
    }

    private func isoString(utc date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }
}

private extension URL {
    var absoluteURLIfPossible: URL? {
        if self.isFileURL { return self.absoluteURL }
        return nil
    }
}


