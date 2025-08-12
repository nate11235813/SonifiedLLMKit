#include "sonified_llama.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    int force_stats_fail;
} stub_state;

llm_handle_t llm_init(const char* model_path) {
    (void)model_path;
    return (llm_handle_t)calloc(1, sizeof(stub_state));
}

int llm_eval(llm_handle_t h,
             const char* prompt_utf8,
             const llm_gen_opts_t* opts,
             llm_token_cb cb,
             void* user_ctx) {
    (void)opts;
    stub_state* st = (stub_state*)h;
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
    free(h);
}

int llm_stats(llm_handle_t h, llm_stats_t* out_stats) {
    stub_state* st = (stub_state*)h;
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
