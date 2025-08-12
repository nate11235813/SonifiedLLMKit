import Foundation

// MARK: - Model & Options

public struct LLMModelSpec: Codable, Sendable {
    public let name: String          // e.g., "gpt-oss-20b"
    public let quant: String         // e.g., "Q4_K_M"
    public let context: Int          // e.g., 4096
    public let tokenizer: String?    // embedded in GGUF or external id

    public init(name: String, quant: String, context: Int, tokenizer: String? = nil) {
        self.name = name
        self.quant = quant
        self.context = context
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
public struct GenerateOptions: Sendable {
    public var temperature: Float
    public var topP: Float
    public var maxTokens: Int
    public var seed: Int32?

    public init(temperature: Float = 0.2, topP: Float = 0.9, maxTokens: Int = 256, seed: Int32? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seed = seed
    }
}

// MARK: - Metrics & Events

public struct LLMMetrics: Sendable, Equatable {
    public let chip: String
    public let ramGB: Int
    public let macOSVersion: String
    public let quant: String
    public let context: Int
    /// Time-to-first-token latency in milliseconds
    public let ttfbMs: Int
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
/// - Engines MUST stop producing `.token` within ~150 ms of `cancelCurrent()`.
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
    /// Cancellation MUST stop token emission within ~150 ms and still emit a final `.metrics` (success=false) then `.done`.
    func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error>
    func cancelCurrent()
    /// A snapshot of the last run's final `.metrics`. This is not live-updating.
    var stats: LLMMetrics { get }
}

public protocol ModelStore: Sendable {
    func ensureAvailable(spec: LLMModelSpec) async throws -> URL
    func purge(spec: LLMModelSpec) throws
    func diskUsage() throws -> Int64
}
