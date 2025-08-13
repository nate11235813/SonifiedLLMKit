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
        // Allow special stub handle by name to route to C stub path
        let pathOrStub = (modelURL.lastPathComponent == "stub" || modelURL.path == "stub") ? "stub" : modelURL.path
        let h = pathOrStub.withCString { cstr -> UnsafeMutableRawPointer? in
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

    private func makeCOpts(from opts: GenerateOptions) -> llm_gen_opts_t {
        var c = llm_gen_opts_t()
        // Keep context_length as a simple heuristic for metrics display;
        // actual context window is determined at init time via env override.
        c.context_length = Int32(opts.maxTokens + 512)
        let t = opts.greedy ? 0.0 : opts.temperature
        c.temperature = Float(t)
        c.top_p = Float(opts.topP)
        c.max_tokens = Int32(opts.maxTokens)
        c.seed = Int32(opts.seed)
        return c
    }

    func generate(prompt: String, options: GenerateOptions) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let h = self.stateQueue.sync(execute: { self.handle }), self.isLoaded else {
                continuation.finish(throwing: LLMError.notLoaded)
                return
            }
            self.stateQueue.sync { self.isCancelledFlag = false }
            let startTimeNs = DispatchTime.now().uptimeNanoseconds
            var cOpts = self.makeCOpts(from: options)
            // Box the continuation for the C callback
            final class Box {
                let cont: AsyncThrowingStream<LLMEvent, Error>.Continuation
                var earlyMetricsSent: Bool = false
                let startTimeNs: UInt64
                var completionTokens: Int = 0
                let promptTokens: Int
                init(_ c: AsyncThrowingStream<LLMEvent, Error>.Continuation, startTimeNs: UInt64, promptTokens: Int) {
                    self.cont = c
                    self.startTimeNs = startTimeNs
                    self.promptTokens = promptTokens
                }
            }
            // Accurate prompt token count is provided by runtime stats after eval.
            // For early metrics at TTFB, report 0 and update in final metrics.
            let approxPromptTokens = 0
            let box = Unmanaged.passRetained(Box(continuation, startTimeNs: startTimeNs, promptTokens: approxPromptTokens))
            let ctx = UnsafeMutableRawPointer(box.toOpaque())
            // Non-capturing C callback
            let cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { token, ctx in
                guard let ctx = ctx else { return }
                let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                if let token = token {
                    if box.earlyMetricsSent == false {
                        box.earlyMetricsSent = true
                        let now = DispatchTime.now().uptimeNanoseconds
                        let ttfbMs = Int((now &- box.startTimeNs) / 1_000_000)
                        box.cont.yield(.metrics(LLMMetrics(ttfbMs: ttfbMs, promptTokens: box.promptTokens, completionTokens: 0, totalTokens: box.promptTokens)))
                    }
                    box.completionTokens += 1
                    box.cont.yield(.token(String(cString: token)))
                }
            }
            self.currentTask = Task.detached { [weak self] in
                guard let self else { return }
                #if DEBUG
                if prompt == "CAUSE_EVAL_FAIL" {
                    continuation.finish(throwing: LLMError.runtimeFailure(code: -1))
                    box.release()
                    return
                }
                #endif
                let evalRc: Int32 = prompt.withCString { cstr in
                    llm_eval(h, cstr, &cOpts, cb, ctx)
                }
                var s = llm_stats_t()
                var statsRc = llm_stats(h, &s)
                #if DEBUG
                if prompt == "CAUSE_STATS_FAIL" { statsRc = -1 }
                #endif
                let wasCancelled = self.stateQueue.sync { self.isCancelledFlag }
                if wasCancelled {
                    let b = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                    let m = LLMMetrics(
                        chip: "unknown",
                        ramGB: 0,
                        quant: "Q4_K_M",
                        context: Int(cOpts.context_length),
                        ttfbMs: Int(s.ttfb_ms),
                        promptTokens: Int(s.prompt_tokens),
                        completionTokens: Int(s.completion_tokens),
                        totalTokens: Int(s.total_tokens),
                        tokPerSec: Double(s.tok_per_sec),
                        totalDurationMillis: Int(s.total_ms),
                        peakRSSMB: Int(s.peak_rss_mb),
                        success: false
                    )
                    self.stateQueue.sync { self._stats = m }
                    continuation.yield(.metrics(m))
                    continuation.yield(.done)
                    continuation.finish()
                    box.release()
                    return
                }

                if evalRc != 0 || statsRc != 0 {
                    let code = evalRc != 0 ? Int(evalRc) : Int(statsRc)
                    continuation.finish(throwing: LLMError.runtimeFailure(code: code))
                } else {
                    let b = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                    let m = LLMMetrics(
                        chip: "unknown",
                        ramGB: 0,
                        quant: "Q4_K_M",
                        context: Int(cOpts.context_length),
                        ttfbMs: Int(s.ttfb_ms),
                        promptTokens: Int(s.prompt_tokens),
                        completionTokens: Int(s.completion_tokens),
                        totalTokens: Int(s.total_tokens),
                        tokPerSec: Double(s.tok_per_sec),
                        totalDurationMillis: Int(s.total_ms),
                        peakRSSMB: Int(s.peak_rss_mb),
                        success: s.success != 0
                    )
                    self.stateQueue.sync { self._stats = m }
                    continuation.yield(.metrics(m))
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


