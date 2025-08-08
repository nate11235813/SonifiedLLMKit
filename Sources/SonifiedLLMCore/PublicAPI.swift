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

public enum ReasoningLevel: Sendable {
    case low, medium, high
}

public struct GenerateOptions: Sendable {
    public var temperature: Float
    public var topP: Float
    public var maxTokens: Int
    public var seed: Int32?
    public var reasoning: ReasoningLevel

    public init(temperature: Float = 0.2, topP: Float = 0.9, maxTokens: Int = 256, seed: Int32? = nil, reasoning: ReasoningLevel = .low) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seed = seed
        self.reasoning = reasoning
    }
}

// MARK: - Metrics & Events

public struct LLMMetrics: Sendable {
    public let chip: String
    public let ramGB: Int
    public let macOSVersion: String
    public let quant: String
    public let context: Int
    public let ttfbMillis: Int
    public let tokPerSec: Double
    public let totalDurationMillis: Int
    public let peakRSSMB: Int
    public let success: Bool

    public init(chip: String = "unknown",
                ramGB: Int = 0,
                macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                quant: String = "Q4_K_M",
                context: Int = 4096,
                ttfbMillis: Int = 0,
                tokPerSec: Double = 0,
                totalDurationMillis: Int = 0,
                peakRSSMB: Int = 0,
                success: Bool = true) {
        self.chip = chip
        self.ramGB = ramGB
        self.macOSVersion = macOSVersion
        self.quant = quant
        self.context = context
        self.ttfbMillis = ttfbMillis
        self.tokPerSec = tokPerSec
        self.totalDurationMillis = totalDurationMillis
        self.peakRSSMB = peakRSSMB
        self.success = success
    }
}

public enum LLMEvent: Sendable {
    case token(String)
    case metrics(LLMMetrics)
    case done
}

// MARK: - Protocols

public protocol LLMEngine: AnyObject, Sendable {
    func load(modelURL: URL, spec: LLMModelSpec) async throws
    func unload() async
    func generate(prompt: String, options: GenerateOptions) -> AsyncStream<LLMEvent>
    func cancelCurrent()
    var stats: LLMMetrics { get }
}

public protocol ModelStore: Sendable {
    func ensureAvailable(spec: LLMModelSpec) async throws -> URL
    func purge(spec: LLMModelSpec) throws
    func diskUsage() throws -> Int64
}
