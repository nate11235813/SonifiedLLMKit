#include "sonified_llama.h"
#include "llama.h"
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <time.h>
#include <mach/mach.h>
#include <stdio.h>

// honor context override via env var SONIFIED_CTX
static int get_env_ctx_override(void) {
    const char *s = getenv("SONIFIED_CTX");
    if (!s || !*s) return 0;
    long v = strtol(s, NULL, 10);
    if (v < 64) v = 64;
    if (v > 32768) v = 32768;
    return (int) v;
}

// lightweight timing + RSS helpers
static inline double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static inline size_t current_rss_bytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return (size_t)info.phys_footprint; // good proxy for resident set on macOS
}

// ---- helpers (no dependency on common/) ----
static int detect_n_threads_default(void) {
    return 4;
}

// two-pass tokenize; follow model BOS policy, parse special tokens
static int tokenize_prompt(struct llama_model * model, const char * prompt, bool add_bos /*unused*/, llama_token ** out) {
    if (!out) return -1;
    if (!prompt) prompt = "";
    const struct llama_vocab * vocab = llama_model_get_vocab(model);
    const bool model_wants_bos = llama_vocab_get_add_bos(vocab);
    const int32_t text_len = (int32_t)strlen(prompt);
    int32_t need = llama_tokenize(vocab, prompt, text_len, NULL, 0, /*add_special=*/model_wants_bos, /*parse_special=*/true);
    if (need < 0) need = -need; // API returns negative of required size when buffer is NULL
    if (need <= 0) { *out = NULL; return 0; }
    llama_token * buf = (llama_token *)malloc(sizeof(llama_token) * (size_t)need);
    if (!buf) { *out = NULL; return -1; }
    int32_t n = llama_tokenize(vocab, prompt, text_len, buf, need, /*add_special=*/model_wants_bos, /*parse_special=*/true);
    if (n < 0) { free(buf); *out = NULL; return -1; }
    *out = buf;
    return (int)n;
}

// greedy: pick argmax from last logits
static llama_token sample_greedy(struct llama_context * ctx, const struct llama_model * model) {
    float * logits = llama_get_logits(ctx);
    if (!logits) return LLAMA_TOKEN_NULL;
    const struct llama_vocab * vocab = llama_model_get_vocab(model);
    const int32_t n_vocab = llama_vocab_n_tokens(vocab);
    int best = 0;
    float best_v = logits[0];
    for (int i = 1; i < n_vocab; ++i) {
        const float v = logits[i];
        if (v > best_v) { best_v = v; best = i; }
    }
    return (llama_token)best;
}

// Private opaque context for our handle. Keep the first field as the
// legacy stub flag to maintain ABI with existing stubbed eval/stats.
typedef struct LLMContext {
    int force_stats_fail; // must remain first for current stubbed eval/stats
    _Atomic bool cancelFlag;   // cooperative cancel checked inside decode loop
    struct llama_model*   model;
    struct llama_context* ctx;
    int n_ctx;
    int n_gpu_layers;
    // placeholders for future slices:
    llm_stats_t lastStats;   // persisted after each eval
} LLMContext;

// Global backend refcount so we init/free llama backends once
static _Atomic int g_backend_refs = 0;

llm_handle_t llm_init(const char* model_path) {
    if (!model_path || model_path[0] == '\0') {
        fprintf(stderr, "[sonified_llama] llm_init: empty model path\n");
        return NULL;
    }
    // Allow unit-tests to run without a real model by treating certain paths as stub
    if (strcmp(model_path, "stub") == 0 || strcmp(model_path, "/dev/null") == 0) {
        LLMContext* h = (LLMContext*)calloc(1, sizeof(LLMContext));
        if (!h) return NULL;
        h->force_stats_fail = 0;
        h->model = NULL;
        h->ctx = NULL;
        h->n_gpu_layers = 0;
        int n_ctx = 4096;
        int ctx_override = get_env_ctx_override();
        if (ctx_override > 0) n_ctx = ctx_override;
        h->n_ctx = n_ctx;
        memset(&h->lastStats, 0, sizeof(h->lastStats));
        return (llm_handle_t)h;
    }

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
        fprintf(stderr, "[sonified_llama] llm_init: failed to load model at '%s' (insufficient memory or missing file)\n", model_path);
        if (atomic_fetch_sub(&g_backend_refs, 1) == 1) llama_backend_free();
        return NULL;
    }

    // ----- context params (sequence length, seed, etc.) -----
    struct llama_context_params cparams = llama_context_default_params();
    int n_ctx = 4096; // default until options are added to public header
    int ctx_override = get_env_ctx_override();
    if (ctx_override > 0) {
        n_ctx = ctx_override;
    }
    cparams.n_ctx = n_ctx;
    // leave seed as default for now

    struct llama_context* ctx = llama_new_context_with_model(model, cparams);
    if (!ctx) {
        fprintf(stderr, "[sonified_llama] llm_init: failed to create context (n_ctx=%d)\n", n_ctx);
        llama_free_model(model);
        if (atomic_fetch_sub(&g_backend_refs, 1) == 1) llama_backend_free();
        return NULL;
    }

    LLMContext* h = (LLMContext*)calloc(1, sizeof(LLMContext));
    if (!h) {
        fprintf(stderr, "[sonified_llama] llm_init: out of memory allocating context\n");
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
    memset(&h->lastStats, 0, sizeof(h->lastStats));
    return (llm_handle_t)h;
}

int llm_eval(llm_handle_t h,
             const char* prompt_utf8,
             const llm_gen_opts_t* opts,
             llm_token_cb cb,
             void* user_ctx) {
    if (!h || !cb) {
        fprintf(stderr, "[sonified_llama] llm_eval: invalid arguments (handle/callback)\n");
        return -1;
    }

    LLMContext* st = (LLMContext*)h;
    atomic_store(&st->cancelFlag, false);

    // Stub path: no real model loaded. Emit one token and succeed unless forced to fail.
    if (st->model == NULL) {
        st->force_stats_fail = 0;
        if (prompt_utf8 && strcmp(prompt_utf8, "CAUSE_EVAL_FAIL") == 0) {
            return -1;
        }
        if (prompt_utf8 && strcmp(prompt_utf8, "CAUSE_STATS_FAIL") == 0) {
            st->force_stats_fail = 1;
        }
        const char * piece = "ok";
        cb(piece, user_ctx);
    llm_stats_t s = {0};
        s.ttfb_ms = 1;
        s.tok_per_sec = 100.0f;
        s.total_ms = 1;
        s.peak_rss_mb = 1;
        s.success = 1;
    s.prompt_tokens = 0;
    s.completion_tokens = 1;
    s.total_tokens = 1;
        st->lastStats = s;
        return 0;
    }

    // defaults (keep minimal for now)
    const int max_tokens = (opts && opts->max_tokens > 0) ? opts->max_tokens : 128;
    const int n_threads  = detect_n_threads_default();

    // allow tests to force stats failure through special prompt string (preserve ABI behavior)
    st->force_stats_fail = 0;
    if (prompt_utf8 && strcmp(prompt_utf8, "CAUSE_EVAL_FAIL") == 0) {
        return -1; // simulate eval failure path for existing tests
    }
    if (prompt_utf8 && strcmp(prompt_utf8, "CAUSE_STATS_FAIL") == 0) {
        st->force_stats_fail = 1;
    }

    // configure threads
    llama_set_n_threads(st->ctx, n_threads, n_threads);

    // ---- metrics instrumentation ----
    double t_start = now_ms();
    double t_first = 0.0;
    size_t peak_rss = current_rss_bytes();
    int prompt_token_count = 0;
    int gen_tokens = 0;
    bool canceled = false;

    // 1) tokenize
    llama_token * prompt_tokens = NULL;
    int n_prompt = tokenize_prompt(st->model, prompt_utf8, /*add_bos=*/true, &prompt_tokens);
    if (n_prompt < 0) {
        fprintf(stderr, "[sonified_llama] llm_eval: prompt tokenization failed\n");
        return -2;
    }
    // If the prompt is empty, succeed without generating tokens
    if (n_prompt == 0) {
        double t_end = now_ms();
        size_t rss = current_rss_bytes();
        if (rss > peak_rss) peak_rss = rss;
        llm_stats_t s = (llm_stats_t){0};
        s.ttfb_ms = 0;
        s.tok_per_sec = 0.0f;
        s.total_ms = (int)(t_end - t_start);
        s.peak_rss_mb = (int)((double)peak_rss / (1024.0 * 1024.0));
        s.success = 1;
        s.prompt_tokens = 0;
        s.completion_tokens = 0;
        s.total_tokens = 0;
        st->lastStats = s;
        return 0;
    }
    // record prompt token count
    prompt_token_count = n_prompt;

    // 2) prefill (prompt)
    if (n_prompt > 0) {
        struct llama_batch batch = llama_batch_get_one(prompt_tokens, n_prompt);
        if (llama_decode(st->ctx, batch) != 0) {
            fprintf(stderr, "[sonified_llama] llm_eval: llama_decode prefill failed\n");
            free(prompt_tokens);
            return -3;
        }
    }
    {
        size_t rss = current_rss_bytes();
        if (rss > peak_rss) peak_rss = rss;
    }

    // 3) decode loop (greedy)
    const struct llama_vocab * vocab = llama_model_get_vocab(st->model);
    int produced = 0;
    char piece_buf[512];

    while (produced < max_tokens) {
        if (atomic_load(&st->cancelFlag)) { canceled = true; break; } // cooperative cancel

        // pick next token
        llama_token tok = sample_greedy(st->ctx, st->model);
        if (tok == LLAMA_TOKEN_NULL) break;
        if (llama_vocab_is_eog(vocab, tok)) break;

        // convert token -> UTF-8 piece
        int n = (int)llama_token_to_piece(vocab, tok, piece_buf, (int32_t)sizeof(piece_buf) - 1, /*lstrip=*/0, /*special=*/true);
        if (n > 0 && n < (int)sizeof(piece_buf)) {
            piece_buf[n] = '\0';
            if (t_first == 0.0) t_first = now_ms();
            cb(piece_buf, user_ctx);
        }

        // feed back the token
        struct llama_batch step = llama_batch_get_one(&tok, 1);
        if (llama_decode(st->ctx, step) != 0) {
            fprintf(stderr, "[sonified_llama] llm_eval: llama_decode step failed\n");
            free(prompt_tokens);
            return -4;
        }

        produced += 1;
        gen_tokens += 1;
        if ((gen_tokens & 7) == 0) {
            size_t r = current_rss_bytes();
            if (r > peak_rss) peak_rss = r;
        }
    }

    free(prompt_tokens);

    // ---- finalize metrics ----
    double t_end = now_ms();
    double total_ms = t_end - t_start;
    double ttfb_ms  = (gen_tokens > 0 && t_first > 0.0) ? (t_first - t_start) : 0.0;
    double decode_ms = (gen_tokens > 0 && t_end > t_first) ? (t_end - t_first) : 0.0;
    double tok_per_sec = (gen_tokens > 0 && decode_ms > 0.0) ? ((double)gen_tokens / (decode_ms / 1000.0)) : 0.0;

    llm_stats_t s = {0};
    s.ttfb_ms = (int)(ttfb_ms);
    s.tok_per_sec = (float)tok_per_sec;
    s.total_ms = (int)(total_ms);
    s.peak_rss_mb = (int)((double)peak_rss / (1024.0 * 1024.0));
    s.success = canceled ? 0 : 1;
    s.prompt_tokens = prompt_token_count;
    s.completion_tokens = gen_tokens;
    s.total_tokens = prompt_token_count + gen_tokens;

    st->lastStats = s; // persist snapshot for llm_stats
    return 0; // cancellation is not an error
}

void llm_cancel(llm_handle_t h) {
    if (!h) return;
    LLMContext * ctx = (LLMContext *)h;
    atomic_store(&ctx->cancelFlag, true);
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
    if (!h || !out_stats) return -1;
    LLMContext* ctx = (LLMContext*)h;
    if (ctx->force_stats_fail) return -1; // preserve existing test behavior
    *out_stats = ctx->lastStats; // struct copy
    return 0;
}
