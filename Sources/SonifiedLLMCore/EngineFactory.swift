import Foundation

public enum EngineFactory {
    public static func makeDefaultEngine() -> LLMEngine {
        return MockLLMEngine()
    }
}
