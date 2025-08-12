// This file intentionally only compiles when the binary runtime is available.
#if canImport(SonifiedLLMRuntime)
import Foundation
@preconcurrency import SonifiedLLMRuntime

final class LLMEngineImpl: LLMEngine, @unchecked Sendable {
    private var isLoaded: Bool = false
    private var _stats: LLMMetrics = .init()
    private var handle: UnsafeMutableRawPointer?
    private let stateQueue = DispatchQueue(label: "sonified.runtime.state")
    private var currentTask: Task<Void, Never>?
    private var isCancelledFlag: Bool = false

    func load(modelURL: URL, spec: LLMModelSpec) async throws {
        if isLoaded { return }
        let h = modelURL.path.withCString { cstr -> UnsafeMutableRawPointer? in
            return llm_init(cstr)
        }
        guard let h else {
            throw LLMError.runtimeFailure(code: -1)
        }
        stateQueue.sync {
            self.handle = h
            self.isLoaded = true
        }
    }

    func unload() async {
        let h = stateQueue.sync { () -> UnsafeMutableRawPointer? in
            defer {
                self.handle = nil
                self.isLoaded = false
            }
            return self.handle
        }
        if let h { llm_free(h) }
    }

    func cancelCurrent() {
        stateQueue.sync { self.isCancelledFlag = true }
        if let h = stateQueue.sync(execute: { self.handle }) {
            llm_cancel(h)
        }
    }

    func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let h = self.stateQueue.sync(execute: { self.handle }), self.isLoaded else {
                continuation.finish(throwing: LLMError.notLoaded)
                return
            }
            self.stateQueue.sync { self.isCancelledFlag = false }
            var cOpts = llm_gen_opts_t(
                context_length:  Int32(options.maxTokens + 512), // simple default window
                temperature:     options.temperature,
                top_p:           options.topP,
                max_tokens:      Int32(options.maxTokens),
                seed:            Int32(options.seed ?? 0)
            )
            // Box the continuation for the C callback
            final class Box { let cont: AsyncThrowingStream<LLMEvent, Error>.Continuation; init(_ c: AsyncThrowingStream<LLMEvent, Error>.Continuation){ cont = c } }
            let box = Unmanaged.passRetained(Box(continuation))
            let ctx = UnsafeMutableRawPointer(box.toOpaque())
            // Non-capturing C callback
            let cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { token, ctx in
                guard let ctx = ctx else { return }
                let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                if let token = token {
                    box.cont.yield(.token(String(cString: token)))
                }
            }
            self.currentTask = Task.detached { [weak self] in
                guard let self else { return }
                let evalRc: Int32 = prompt.withCString { cstr in
                    llm_eval(h, cstr, &cOpts, cb, ctx)
                }
                var s = llm_stats_t(ttfb_ms: 0, tok_per_sec: 0, total_ms: 0, peak_rss_mb: 0, success: 0)
                let statsRc = llm_stats(h, &s)
                let m = LLMMetrics(
                    chip: "unknown",
                    ramGB: 0,
                    quant: "Q4_K_M",
                    context: Int(cOpts.context_length),
                    ttfbMillis: Int(s.ttfb_ms),
                    tokPerSec: Double(s.tok_per_sec),
                    totalDurationMillis: Int(s.total_ms),
                    peakRSSMB: Int(s.peak_rss_mb),
                    success: s.success != 0
                )
                self.stateQueue.sync { self._stats = m }
                continuation.yield(.metrics(m))
                if evalRc != 0 || statsRc != 0 {
                    let code = evalRc != 0 ? Int(evalRc) : Int(statsRc)
                    continuation.finish(throwing: LLMError.runtimeFailure(code: code))
                } else {
                    continuation.yield(.done)
                    continuation.finish()
                }
                // release the box
                box.release()
            }
        }
    }

    var stats: LLMMetrics {
        stateQueue.sync { _stats }
    }
}
#endif


