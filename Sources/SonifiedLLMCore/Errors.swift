import Foundation

public enum LLMError: LocalizedError {
    case modelNotFound
    case checksumMismatch
    case insufficientMemory
    case metalUnavailable
    case promptTooLong
    case runtimeFailure(code: Int)
    public enum EngineInitFailureReason: String, Sendable {
        case oom
        case unsupported
        case unknown
    }
    case engineInitFailed(reason: EngineInitFailureReason, message: String)
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Model not found."
        case .checksumMismatch: return "Model failed integrity verification."
        case .insufficientMemory: return "Insufficient memory to run the model."
        case .metalUnavailable: return "Metal driver/path unavailable."
        case .promptTooLong: return "Prompt exceeds context window."
        case .runtimeFailure(let code): return "Runtime failure (\(code))."
        case .engineInitFailed(let reason, let message): return "Engine initialization failed (\(reason.rawValue)): \(message)"
        case .notLoaded: return "Engine is not loaded."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .modelNotFound:
            return "This build requires a bundled model; ensure the GGUF is added to the app bundle."
        case .checksumMismatch:
            return "Delete and re-download the model."
        case .insufficientMemory:
            return "Try a lower quant or reduce the context length."
        case .metalUnavailable:
            return "Update macOS, ensure a compatible GPU, or switch to Cloud."
        case .promptTooLong:
            return "Shorten the prompt, or use a lower context to fit memory."
        case .runtimeFailure:
            return "Retry, lower settings, or file a bug with logs."
        case .engineInitFailed(let reason, _):
            switch reason {
            case .oom: return "Out of memory. Try a smaller bundled model or lower quant/context."
            case .unsupported: return "This model is unsupported on this device. Try a smaller model or different quant."
            case .unknown: return "Initialization failed. Try a different model or lower settings."
            }
        case .notLoaded:
            return "Call load(modelURL:spec:) before generating."
        }
    }
}

public extension LLMError {
    /// Convenience to make intent explicit at call site.
    func withBundledOnlyRecovery() -> LLMError { self }
}
