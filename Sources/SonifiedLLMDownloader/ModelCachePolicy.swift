import Foundation

public struct ModelCachePolicy: Sendable {
    public let capBytes: Int64

    public init(capBytes: Int64) {
        self.capBytes = capBytes
    }

    public func enforce(at modelsDir: URL) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var entries: [(url: URL, mtime: Date, size: Int64)] = []
        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard ext == "gguf" || ext == "json" else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values.contentModificationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)
            entries.append((url, mtime, size))
        }
        // Sort by newest first
        entries.sort { $0.mtime > $1.mtime }
        var total: Int64 = entries.reduce(0) { $0 + $1.size }
        if total <= capBytes { return }
        // Remove oldest until under cap
        for entry in entries.reversed() {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= capBytes { break }
        }
    }
}


