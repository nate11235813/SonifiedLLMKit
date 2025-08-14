import Foundation

// MARK: - Model & Options

/// Model specification used for loading a local GGUF model.
///
/// Tokenizer is read from the GGUF model by default; only override if you know what you're doing.
///
/// Example:
/// ```swift
/// let spec = LLMModelSpec(
///   name: "gpt-oss-20b",
///   quant: .q4_K_M,
///   contextTokens: 4096
/// )
/// ```
public struct LLMModelSpec: Codable, Sendable {
    public enum Quantization: String, Codable, Sendable {
        case q4_K_M
        case q5_K_M
        case q6_K
        case q8_0
        case fp16
        case mxfp4
    }

    public let name: String          // e.g., "gpt-oss-20b"
    public let quant: Quantization   // e.g., .q4_K_M
    public let contextTokens: Int    // e.g., 4096
    /// Tokenizer identifier when overriding model-embedded tokenizer. Usually leave nil.
    public let tokenizer: String?

    public init(name: String, quant: Quantization, contextTokens: Int, tokenizer: String? = nil) {
        self.name = name
        self.quant = quant
        self.contextTokens = contextTokens
        self.tokenizer = tokenizer
    }
}

/// Options controlling text generation.
///
/// Supported knobs:
/// - `temperature`: Softens or sharpens the distribution (higher = more random).
/// - `topP`: Nucleus sampling threshold.
/// - `maxTokens`: Upper bound on number of tokens to generate.
/// - `seed`: Optional PRNG seed for reproducibility.
///
/// Note: The context window size ("contextTokens") is defined by the loaded model
/// via `LLMModelSpec.context` and not configured here.
/// Example:
/// ```swift
/// let opts = GenerateOptions(temperature: 0.7, topP: 0.9, maxTokens: 256, seed: 42)
/// ```
public struct GenerateOptions: Sendable {
    // Core knobs
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var seed: Int
    public var greedy: Bool

    // New preferred initializer (with requested defaults)
    public init(maxTokens: Int = 128,
                temperature: Double = 0.7,
                topP: Double = 0.95,
                topK: Int = 40,
                repeatPenalty: Double = 1.1,
                seed: Int = -1,
                greedy: Bool = false) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.seed = seed
        self.greedy = greedy
    }

    // Backwards-compatible initializer used in tests and older callers
    public init(temperature: Float = 0.2, topP: Float = 0.9, maxTokens: Int = 256, seed: Int32? = nil) {
        self.maxTokens = maxTokens
        self.temperature = Double(temperature)
        self.topP = Double(topP)
        self.topK = 40
        self.repeatPenalty = 1.1
        self.seed = seed.map { Int($0) } ?? -1
        self.greedy = false
    }
}

// MARK: - Metrics & Events

/// Aggregate performance and accounting metrics for a single generation run.
///
/// Example:
/// ```swift
/// if case .metrics(let m) = event {
///   print("TTFB: \(m.ttfbMs) ms, total tokens: \(m.totalTokens)")
/// }
/// ```
public struct LLMMetrics: Sendable, Equatable {
    public let chip: String
    public let ramGB: Int
    public let macOSVersion: String
    public let quant: String
    public let context: Int
    /// Time-to-first-token latency in milliseconds
    public let ttfbMs: Int
    /// Number of tokens consumed by the prompt/prefill phase
    public let promptTokens: Int
    /// Number of tokens produced in the completion/decoding phase
    public let completionTokens: Int
    /// Total tokens for the run (prompt + completion)
    public let totalTokens: Int
    /// Completion tokens per second, excluding prefill/TTFB
    public let tokPerSec: Double
    public let totalDurationMillis: Int
    public let peakRSSMB: Int
    public let success: Bool

    public init(chip: String = "unknown",
                ramGB: Int = 0,
                macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                quant: String = "Q4_K_M",
                context: Int = 4096,
                ttfbMs: Int = 0,
                promptTokens: Int = 0,
                completionTokens: Int = 0,
                totalTokens: Int = 0,
                tokPerSec: Double = 0,
                totalDurationMillis: Int = 0,
                peakRSSMB: Int = 0,
                success: Bool = true) {
        self.chip = chip
        self.ramGB = ramGB
        self.macOSVersion = macOSVersion
        self.quant = quant
        self.context = context
        self.ttfbMs = ttfbMs
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.tokPerSec = tokPerSec
        self.totalDurationMillis = totalDurationMillis
        self.peakRSSMB = peakRSSMB
        self.success = success
    }
}

///
/// Event ordering contract:
/// 1) Optional early `.metrics` exactly once when first token is ready (TTFB).
/// 2) Zero or more `.token(String)` events streamed in order.
/// 3) One final `.metrics` with totals for the run.
/// 4) `.done` exactly once on successful or cancelled completion.
///
/// Errors:
/// - Fatal errors throw and MUST NOT emit `.done`.
/// - User cancellation MUST emit final `.metrics` (success=false) then `.done` (no throw).
///
/// Timing:
/// - Engines SHOULD stop producing `.token` within ≤150 ms of `cancelCurrent()`.
///
/// Example:
/// ```swift
/// let stream = engine.generate(prompt: "Hi", options: .init(maxTokens: 16))
/// for try await ev in stream {
///   switch ev {
///   case .token(let t): print(t, terminator: "")
///   case .metrics(let m): print("\\nTTFB: \(m.ttfbMs) ms, total: \(m.totalTokens)")
///   case .done: print("\\nDone")
///   }
/// }
/// ```
public enum LLMEvent: Sendable, Equatable {
    case token(String)
    case metrics(LLMMetrics)
    case done
}

// MARK: - Protocols

public protocol LLMEngine: AnyObject, Sendable {
    func load(modelURL: URL, spec: LLMModelSpec) async throws
    func unload() async
    /// Start generating tokens for the given prompt.
    ///
    /// Streams follow the `LLMEvent` ordering contract:
    /// - Optional early `.metrics` exactly once at time-to-first-token (TTFB).
    /// - Zero or more `.token(String)` events.
    /// - One final `.metrics` containing totals (tokens/sec, total duration, token counts, success flag).
    /// - `.done` exactly once on successful or cancelled completion.
    ///
    /// Errors mid-generation are delivered via `AsyncThrowingStream` throws — `.done` is never emitted when throwing.
    /// Cancellation SHOULD stop token emission within ≤150 ms and MUST still emit a final `.metrics` (success=false) then `.done`.
    ///
    /// Example:
    /// ```swift
    /// let engine = EngineFactory.makeDefaultEngine()
    /// try await engine.load(modelURL: modelURL, spec: spec)
    /// let stream = engine.generate(prompt: "hello", options: .init(maxTokens: 32))
    /// var seenToken = false
    /// for try await ev in stream {
    ///   switch ev {
    ///   case .token:
    ///     if !seenToken { engine.cancelCurrent(); seenToken = true }
    ///   case .metrics(let m): print("final tokens: \(m.totalTokens)")
    ///   case .done: break
    ///   }
    /// }
    /// ```
    func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error>
    func cancelCurrent()
    /// Snapshot of the last run's final `.metrics` (not live). Matches the payload of the final `.metrics` event.
    var stats: LLMMetrics { get }
}

/// Returns the model's embedded chat template when available for this engine instance.
/// - Note: This is a convenience shim that avoids leaking implementation types cross-module.
///         It returns nil for engines that do not support fetching a template.
public func engineChatTemplate(_ engine: LLMEngine) -> String? {
    #if canImport(SonifiedLLMRuntime)
    if let impl = engine as? LLMEngineImpl { return impl.chatTemplate() }
    #endif
    return nil
}

public protocol ModelStore: Sendable {
    /// Ensure the model described by `spec` is available locally.
    /// Returns the file URL and provenance. UI should use `location.url` and may display `location.source`.
    ///
    /// Example:
    /// ```swift
    /// let store: ModelStore = FileModelStore()
    /// let location = try await store.ensureAvailable(spec: spec)
    /// switch location.source {
    /// case .bundled: print("Using bundled model at", location.url.path)
    /// case .downloaded: print("Using downloaded model at", location.url.path)
    /// }
    /// ```
    func ensureAvailable(spec: LLMModelSpec) async throws -> ModelLocation
    func purge(spec: LLMModelSpec) throws
    /// Returns bytes; UI formats units.
    func diskUsage() async -> Int64
}

/// Location of a model on disk and how it was obtained.
public struct ModelLocation: Sendable {
    public let url: URL
    public let source: Source
    public enum Source: String, Sendable { case bundled, downloaded }

    public init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }
}

// MARK: - Bundled Catalog Types

/// Optional extended fields describing bundled entries. Backwards compatible with minimal index.json.
public struct BundledCatalogEntry: Codable, Sendable, Equatable {
    public let name: String
    public let quant: String
    public let path: String
    public let minRamGB: Int?
    public let arch: [String]?
}

public struct BundledCatalog: Codable, Sendable, Equatable {
    public let embedded: Bool
    public let models: [BundledCatalogEntry]
}

/// Device capabilities used to guide bundled selection.
public struct DeviceCaps: Sendable, Equatable {
    public let ramGB: Int
    public let arch: String
    public init(ramGB: Int, arch: String) { self.ramGB = ramGB; self.arch = arch }
}

/// Policy-based selector that chooses the best bundled fallback.
public enum BundledModelSelector {
    /// Choose best entry from catalog given the desired spec and device caps.
    /// - Returns: The chosen entry or nil if nothing fits.
    public static func choose(spec: LLMModelSpec, catalog: [BundledCatalogEntry], caps: DeviceCaps) -> BundledCatalogEntry? {
        // Define quant ranking (higher is better). Known names from `LLMModelSpec.Quantization` plus common lower precisions.
        let rank: [String: Int] = [
            "fp16": 100,
            "q8_0": 90,
            "q6_K_M": 80, // alias support if present in catalog
            "q6_K": 78,
            "q5_K_M": 70,
            "q5_K": 68,
            "q4_K_M": 60,
            "mxfp4": 60,
            "q4_K_S": 58,
            "q4_1": 55,
            "q4_0": 50,
            "q3_K_M": 40,
            "q3_K_S": 35,
            "q3_0": 30
        ]

        func passesCaps(_ e: BundledCatalogEntry) -> Bool {
            if let min = e.minRamGB, caps.ramGB < min { return false }
            if let allowed = e.arch, !allowed.isEmpty, !allowed.contains(caps.arch) { return false }
            return true
        }

        // Allow cross-name fallback only if the requested name exists in the catalog at all.
        let hasRequestedName = catalog.contains(where: { $0.name == spec.name })

        // 1) Exact match (must pass caps)
        if let exact = catalog.first(where: { $0.name == spec.name && $0.quant == spec.quant.rawValue && passesCaps($0) }) {
            return exact
        }

        // 2) Same-name best quant that passes caps. Prefer higher precision (higher rank).
        let sameName = catalog.filter { $0.name == spec.name && passesCaps($0) }
        let bestSameName = sameName.max { (a, b) -> Bool in
            let ra = rank[a.quant] ?? 0
            let rb = rank[b.quant] ?? 0
            return ra < rb
        }
        if let bestSameName = bestSameName { return bestSameName }

        // 3) If the requested name is known but not suitable, pick best across catalog that passes caps (e.g., 7B fallback for 20B)
        if hasRequestedName {
            let candidates = catalog.filter { passesCaps($0) }
            let bestOverall = candidates.max { (a, b) -> Bool in
                let ra = rank[a.quant] ?? 0
                let rb = rank[b.quant] ?? 0
                if a.name == spec.name && b.name != spec.name { return false }
                if b.name == spec.name && a.name != spec.name { return true }
                return ra < rb
            }
            return bestOverall
        }
        return nil
    }

    /// Ordered candidate list to try for loading, starting from the best option.
    /// Includes the requested spec (if present and passes caps), then other same-name quants by descending quality,
    /// then cross-name fallbacks by descending quality. Duplicates are removed.
    public static func orderedCandidates(spec: LLMModelSpec, catalog: [BundledCatalogEntry], caps: DeviceCaps) -> [BundledCatalogEntry] {
        let rank: [String: Int] = [
            "fp16": 100,
            "q8_0": 90,
            "q6_K_M": 80,
            "q6_K": 78,
            "q5_K_M": 70,
            "q5_K": 68,
            "q4_K_M": 60,
            "mxfp4": 60,
            "q4_K_S": 58,
            "q4_1": 55,
            "q4_0": 50,
            "q3_K_M": 40,
            "q3_K_S": 35,
            "q3_0": 30
        ]
        func passesCaps(_ e: BundledCatalogEntry) -> Bool {
            if let min = e.minRamGB, caps.ramGB < min { return false }
            if let allowed = e.arch, !allowed.isEmpty, !allowed.contains(caps.arch) { return false }
            return true
        }
        var list: [BundledCatalogEntry] = []
        // exact first
        if let exact = catalog.first(where: { $0.name == spec.name && $0.quant == spec.quant.rawValue && passesCaps($0) }) {
            list.append(exact)
        }
        // same-name others
        let sameName = catalog.filter { $0.name == spec.name && passesCaps($0) }
        let sameSorted = sameName.sorted { (a, b) -> Bool in
            (rank[a.quant] ?? 0) > (rank[b.quant] ?? 0)
        }
        for e in sameSorted { if !list.contains(e) { list.append(e) } }
        // cross-name fallbacks
        let others = catalog.filter { $0.name != spec.name && passesCaps($0) }
        let othersSorted = others.sorted { (a, b) -> Bool in
            (rank[a.quant] ?? 0) > (rank[b.quant] ?? 0)
        }
        for e in othersSorted { if !list.contains(e) { list.append(e) } }
        return list
    }
}
