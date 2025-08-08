#include "sonified_llama.h"
#include <stdlib.h>
#include <string.h>

typedef struct llm_handle_impl {
    volatile int cancelled;
} llm_handle_impl;

llm_handle_t llm_init(const char* model_path /*, params TBD */) {
    if (model_path == NULL) {
        return NULL;
    }
    llm_handle_impl* h = (llm_handle_impl*)malloc(sizeof(llm_handle_impl));
    if (!h) return NULL;
    h->cancelled = 0;
    return (llm_handle_t)h;
}

int llm_eval(llm_handle_t h,
             const char* prompt_utf8,
             const llm_gen_opts_t* opts,
             llm_token_cb cb,
             void* user_ctx) {
    (void)opts;
    if (h == NULL || prompt_utf8 == NULL) {
        return -1;
    }
    if (cb) {
        cb("ok", user_ctx);
    }
    return 0;
}

void llm_cancel(llm_handle_t h) {
    if (h) {
        ((llm_handle_impl*)h)->cancelled = 1;
    }
}

void llm_free(llm_handle_t h) {
    if (h) {
        llm_handle_impl* impl = (llm_handle_impl*)h;
        free(impl);
    }
}

int llm_stats(llm_handle_t h, llm_stats_t* out_stats) {
    (void)h;
    if (!out_stats) return -1;
    out_stats->ttfb_ms = 0;
    out_stats->tok_per_sec = 0.0f;
    out_stats->total_ms = 0;
    out_stats->peak_rss_mb = 0;
    out_stats->success = 1;
    return 0;
}


