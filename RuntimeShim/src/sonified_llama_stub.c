#include "sonified_llama.h"
#include "llama.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

// Private opaque context for our handle. Keep the first field as the
// legacy stub flag to maintain ABI with existing stubbed eval/stats.
typedef struct LLMContext {
    int force_stats_fail; // must remain first for current stubbed eval/stats
    struct llama_model*   model;
    struct llama_context* ctx;
    int n_ctx;
    int n_gpu_layers;
    // placeholders for future slices:
    // _Atomic bool cancelFlag;
    // struct llm_stats_t lastStats;
} LLMContext;

// Global backend refcount so we init/free llama backends once
static _Atomic int g_backend_refs = 0;

llm_handle_t llm_init(const char* model_path) {
    if (!model_path || model_path[0] == '\0') return NULL;

    if (atomic_fetch_add(&g_backend_refs, 1) == 0) {
        // Initialize ggml backends (Metal/CPU/etc.)
        llama_backend_init();
    }

    // ----- model params (GPU offload on Apple Silicon by default) -----
    struct llama_model_params mparams = llama_model_default_params();
    int n_gpu_layers = 0;
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__ARM64__))
    n_gpu_layers = 999; // try to offload as many layers as possible by default
#endif
    if (n_gpu_layers < 0) n_gpu_layers = 0;
    mparams.n_gpu_layers = n_gpu_layers;

    struct llama_model* model = llama_load_model_from_file(model_path, mparams);
    if (!model) {
        if (atomic_fetch_sub(&g_backend_refs, 1) == 1) llama_backend_free();
        return NULL;
    }

    // ----- context params (sequence length, seed, etc.) -----
    struct llama_context_params cparams = llama_context_default_params();
    int n_ctx = 4096; // default until options are added to public header
    cparams.n_ctx = n_ctx;
    // leave seed as default for now

    struct llama_context* ctx = llama_new_context_with_model(model, cparams);
    if (!ctx) {
        llama_free_model(model);
        if (atomic_fetch_sub(&g_backend_refs, 1) == 1) llama_backend_free();
        return NULL;
    }

    LLMContext* h = (LLMContext*)calloc(1, sizeof(LLMContext));
    if (!h) {
        llama_free(ctx);
        llama_free_model(model);
        if (atomic_fetch_sub(&g_backend_refs, 1) == 1) llama_backend_free();
        return NULL;
    }
    h->force_stats_fail = 0;
    h->model = model;
    h->ctx = ctx;
    h->n_ctx = n_ctx;
    h->n_gpu_layers = n_gpu_layers;
    return (llm_handle_t)h;
}

int llm_eval(llm_handle_t h,
             const char* prompt_utf8,
             const llm_gen_opts_t* opts,
             llm_token_cb cb,
             void* user_ctx) {
    (void)opts;
    // NOTE: relies on LLMContext first field layout
    LLMContext* st = (LLMContext*)h;
    st->force_stats_fail = 0;
    if (prompt_utf8 && strcmp(prompt_utf8, "CAUSE_EVAL_FAIL") == 0) {
        return -1; // simulate eval failure
    }
    if (prompt_utf8 && strcmp(prompt_utf8, "CAUSE_STATS_FAIL") == 0) {
        st->force_stats_fail = 1;
    }
    if (cb) cb("ok", user_ctx); // emit one token so streaming paths work
    return 0;
}

void llm_cancel(llm_handle_t h) {
    (void)h;
}

void llm_free(llm_handle_t h) {
    if (!h) return;
    LLMContext* ctx = (LLMContext*)h;
    if (ctx->ctx)   llama_free(ctx->ctx);
    if (ctx->model) llama_free_model(ctx->model);
    free(ctx);
    if (atomic_fetch_sub(&g_backend_refs, 1) == 1) {
        llama_backend_free();
    }
}

int llm_stats(llm_handle_t h, llm_stats_t* out_stats) {
    // NOTE: relies on LLMContext first field layout
    LLMContext* st = (LLMContext*)h;
    if (!out_stats) return -1;
    if (st && st->force_stats_fail) return -1;
    memset(out_stats, 0, sizeof(*out_stats));
    out_stats->ttfb_ms = 10;
    out_stats->tok_per_sec = 25.0;
    out_stats->total_ms = 50;
    out_stats->peak_rss_mb = 100;
    out_stats->success = 1;
    return 0;
}
