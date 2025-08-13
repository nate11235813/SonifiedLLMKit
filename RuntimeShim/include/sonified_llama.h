// sonified_llama.h
//
// C-compatible runtime shim API for Sonified LLM runtime.
// This header is a scaffold; it is not currently wired into any build.
// Keep it self-contained, portable C, with minimal assumptions.

#ifndef SONIFIED_LLAMA_H
#define SONIFIED_LLAMA_H

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a runtime instance
typedef void* llm_handle_t;

// Token callback: receives each generated token as UTF-8 and a user context
typedef void (*llm_token_cb)(const char* token_utf8, void* user_ctx);

// Generation options (integers/floats only)
// TODO: Expand with Metal / llama.cpp-specific parameters (GPU layers, threads, batch size, etc.)
typedef struct llm_gen_opts_t {
    int   context_length; // e.g., 4096
    float temperature;    // e.g., 0.2
    float top_p;          // e.g., 0.9
    int   max_tokens;     // upper bound on tokens to generate
    int   seed;           // <= 0 means random
} llm_gen_opts_t;

// Runtime statistics snapshot (integers/floats only)
typedef struct llm_stats_t {
    int   ttfb_ms;        // time-to-first-byte in milliseconds
    float tok_per_sec;    // steady-state tokens per second
    int   total_ms;       // total generation duration in milliseconds
    int   peak_rss_mb;    // peak resident set size in MB
    int   success;        // 1 on success, 0 on failure
    // Token accounting
    int   prompt_tokens;      // tokens consumed by prompt/prefill
    int   completion_tokens;  // tokens generated in completion
    int   total_tokens;       // prompt + completion
} llm_stats_t;

// Initialize a runtime instance for the given model path.
// Returns an opaque handle, or NULL on failure.
// TODO: Add additional parameters for tokenizer overrides, quantization hints, device selection, etc.
llm_handle_t llm_init(const char* model_path /*, params TBD */);

// Evaluate/generate from a prompt using the given options.
// Returns 0 on success, non-zero on error.
// Tokens are streamed through the provided callback.
int llm_eval(llm_handle_t h,
             const char* prompt_utf8,
             const llm_gen_opts_t* opts,
             llm_token_cb cb,
             void* user_ctx);

// Request cancellation of the current generation (best-effort, async-safe intent).
void llm_cancel(llm_handle_t h);

// Free the runtime and any allocated resources. Safe to call with NULL.
void llm_free(llm_handle_t h);

// Retrieve the latest stats into out_stats. Returns 0 on success.
int llm_stats(llm_handle_t h, llm_stats_t* out_stats);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // SONIFIED_LLAMA_H


