import Foundation

#if canImport(Metal)
import Metal
#endif

public struct SystemPreflightResult: Sendable {
    public let metalAvailable: Bool
    public let ramGB: Int
    public let freeDiskGB: Int
    public let recommendedSpec: LLMModelSpec?
    public let notes: [String]
}

public enum Preflight {
    public static func detectMetal() -> Bool {
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    public static func ramInGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int(bytes / (1024 * 1024 * 1024))
    }

    public static func freeDiskInGB(at url: URL) -> Int {
        do {
            let rv = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let cap = rv.volumeAvailableCapacity {
                return Int(cap / (1024 * 1024 * 1024))
            }
        } catch { }
        return 0
    }

    public static func recommendSpec(ramGB: Int, metal: Bool) -> LLMModelSpec? {
        guard metal, ramGB >= 16 else { return nil }
        // Simple defaults for now
        if ramGB >= 16 {
            return LLMModelSpec(name: "gpt-oss-20b", quant: "Q4_K_M", context: 4096)
        }
        return nil
    }

    public static func runSmoke(engine: LLMEngine, store: ModelStore, spec: LLMModelSpec) async -> LLMMetrics? {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            _ = appSupport // just to ensure directory exists
            let url = try await store.ensureAvailable(spec: spec)
            try await engine.load(modelURL: url, spec: spec)
            defer { Task { await engine.unload() } }
            let opts = GenerateOptions(maxTokens: 24)
            var lastMetrics: LLMMetrics? = nil
            let stream = engine.generate(prompt: "Hello from preflight.", options: opts)
            for await ev in stream {
                if case .metrics(let m) = ev { lastMetrics = m }
            }
            if lastMetrics == nil {
                lastMetrics = engine.stats
            }
            return lastMetrics
        } catch {
            return nil
        }
    }

    public static func runAll() async -> SystemPreflightResult {
        let metal = detectMetal()
        let ram = ramInGB()
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? URL(fileURLWithPath: "/")
        let freeGB = freeDiskInGB(at: appSupport)

        var notes: [String] = []
        if !metal { notes.append("Metal not available.") }
        if ram < 16 { notes.append("At least 16 GB RAM recommended.") }
        if freeGB < 12 { notes.append("Only \(freeGB) GB free; models need ~9–10 GB.") }
        notes.append("Tip: Use Q4 on 16GB machines; free ≥12GB disk before download.")

        let spec = recommendSpec(ramGB: ram, metal: metal)
        if spec == nil { notes.append("No suitable recommendation; consider smaller models.") }

        return SystemPreflightResult(metalAvailable: metal, ramGB: ram, freeDiskGB: freeGB, recommendedSpec: spec, notes: notes)
    }
}


