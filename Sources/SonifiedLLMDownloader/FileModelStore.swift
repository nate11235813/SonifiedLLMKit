import Foundation

public struct FileModelStore: ModelStore {
    public init() {}

    public func ensureAvailable(spec: LLMModelSpec) async throws -> URL {
        // Default container location in Application Support
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let modelsDir = appSupport.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let file = modelsDir.appendingPathComponent("\(spec.name)-\(spec.quant).gguf")
        // In real implementation: kick off background download + checksum verify.
        return file
    }

    public func purge(spec: LLMModelSpec) throws {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let file = appSupport.appendingPathComponent("Models/\(spec.name)-\(spec.quant).gguf")
        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }

    public func diskUsage() throws -> Int64 {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let modelsDir = appSupport.appendingPathComponent("Models")
        let enumerator = fm.enumerator(at: modelsDir, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil)
        var total: Int64 = 0
        for case let url as URL in (enumerator ?? FileManager.DirectoryEnumerator()) {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
