import XCTest
@testable import SonifiedLLMCore

final class SonifiedLLMCoreTests: XCTestCase {
    func testPromptBuilder() throws {
        let text = PromptBuilder.conversation(system: "You are a helpful assistant.", messages: [
            ("user", "Hello"),
            ("assistant", "Hi!")
        ])
        XCTAssertTrue(text.contains("<|system|>"))
        XCTAssertTrue(text.contains("<|user|>"))
        XCTAssertTrue(text.contains("<|assistant|>"))
    }

    func testMockEngineStreams() async throws {
        let engine = EngineFactory.makeDefaultEngine()
        try await engine.load(modelURL: URL(fileURLWithPath: "/dev/null"), spec: .init(name: "gpt-oss-20b", quant: "Q4_K_M", context: 4096))
        var tokens = [String]()
        let stream = engine.generate(prompt: "Test", options: .init(maxTokens: 8))
        for try await ev in stream {
            if case .token(let t) = ev {
                tokens.append(t)
            }
        }
        await engine.unload()
        XCTAssertGreaterThan(tokens.count, 0)
    }

    func testEventOrderingAndFinalMetrics() async throws {
        let engine = MockLLMEngine()
        try await engine.load(modelURL: URL(fileURLWithPath: "/dev/null"), spec: .init(name: "gpt-oss-20b", quant: "Q4_K_M", context: 4096))
        var sequence: [LLMEvent] = []
        var finalMetrics: LLMMetrics? = nil
        let stream = engine.generate(prompt: "Hello", options: .init(maxTokens: 10))
        for try await ev in stream {
            sequence.append(ev)
            if case .metrics(let m) = ev { finalMetrics = m }
        }
        await engine.unload()

        // Validate ordering: optional early metrics, tokens*, final metrics, done
        guard let last = sequence.last else { return XCTFail("empty sequence") }
        XCTAssertEqual(last, .done)
        let metricsIndices = sequence.enumerated().compactMap { (i, ev) -> Int? in if case .metrics = ev { return i } else { return nil } }
        XCTAssertGreaterThanOrEqual(metricsIndices.count, 1)
        XCTAssertLessThan(metricsIndices.first!, sequence.count - 1) // first metrics not last
        // final metrics must be immediately before done or earlier, but present before done
        XCTAssertTrue(metricsIndices.last! < sequence.count - 1)
        if let fm = finalMetrics {
            XCTAssertGreaterThanOrEqual(fm.totalDurationMillis, fm.ttfbMs)
            XCTAssertTrue(fm.success)
        } else {
            XCTFail("No final metrics captured")
        }
    }

    func testNotLoadedThrowsNoDone() async {
        let engine = MockLLMEngine()
        var sawDone = false
        let stream = engine.generate(prompt: "hi", options: .init(maxTokens: 1))
        do {
            for try await ev in stream {
                if case .done = ev { sawDone = true }
            }
            XCTFail("Expected throw for not loaded")
        } catch {
            // expected
            XCTAssertFalse(sawDone)
        }
    }

    func testCancelMidStreamEmitsFinalMetricsThenDone() async throws {
        let engine = MockLLMEngine()
        try await engine.load(modelURL: URL(fileURLWithPath: "/dev/null"), spec: .init(name: "gpt-oss-20b", quant: "Q4_K_M", context: 4096))
        var events: [LLMEvent] = []
        let stream = engine.generate(prompt: "Hello world", options: .init(maxTokens: 128))
        do {
            var cancelled = false
            for try await ev in stream {
                events.append(ev)
                if !cancelled, case .token = ev {
                    engine.cancelCurrent()
                    cancelled = true
                }
            }
        } catch {
            XCTFail("Did not expect throw on cancel: \(error)")
        }
        await engine.unload()
        // Last two should be final metrics then done
        guard events.count >= 2 else { return XCTFail("Too few events: \(events)") }
        if case .metrics(let m) = events[events.count - 2] {
            XCTAssertFalse(m.success)
        } else {
            return XCTFail("Expected final metrics before done")
        }
        if case .done = events.last! { } else { XCTFail("Expected done last") }
    }
}

#if canImport(SonifiedLLMRuntime)
final class SonifiedLLMCoreRuntimeFailureTests: XCTestCase {
    func testRuntimeEvalFailureThrowsNoDone() async throws {
        let engine = LLMEngineImpl()
        try await engine.load(modelURL: URL(fileURLWithPath: "stub"), spec: .init(name: "stub", quant: "Q4_K_M", context: 128))
        var sawDone = false
        let stream = engine.generate(prompt: "CAUSE_EVAL_FAIL", options: .init(maxTokens: 1))
        do {
            for try await ev in stream {
                if case .done = ev { sawDone = true }
            }
            XCTFail("Expected throw for eval failure")
        } catch {
            XCTAssertFalse(sawDone)
        }
        await engine.unload()
    }

    func testRuntimeStatsFailureThrowsNoDone() async throws {
        let engine = LLMEngineImpl()
        try await engine.load(modelURL: URL(fileURLWithPath: "stub"), spec: .init(name: "stub", quant: "Q4_K_M", context: 128))
        var sawDone = false
        let stream = engine.generate(prompt: "CAUSE_STATS_FAIL", options: .init(maxTokens: 1))
        do {
            for try await ev in stream {
                if case .done = ev { sawDone = true }
            }
            XCTFail("Expected throw for stats failure")
        } catch {
            XCTAssertFalse(sawDone)
        }
        await engine.unload()
    }
}
#endif
