import Foundation

public enum EngineFactory {
    public static func makeDefaultEngine() -> LLMEngine {
        #if canImport(SonifiedLLMRuntime)
        return LLMEngineImpl()
        #else
        return MockLLMEngine()
        #endif
    }
}
