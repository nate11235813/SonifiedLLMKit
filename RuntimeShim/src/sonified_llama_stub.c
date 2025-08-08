#include "sonified_llama.h"
#include <stdlib.h>
#include <string.h>

typedef struct { int dummy; } stub_state;

llm_handle_t llm_init(const char* model_path) {
    (void)model_path;
    return (llm_handle_t)calloc(1, sizeof(stub_state));
}

int llm_eval(llm_handle_t h,
             const char* prompt_utf8,
             const llm_gen_opts_t* opts,
             llm_token_cb cb,
             void* user_ctx) {
    (void)h; (void)prompt_utf8; (void)opts;
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
    (void)h;
    if (!out_stats) return -1;
    memset(out_stats, 0, sizeof(*out_stats));
    return 0;
}
