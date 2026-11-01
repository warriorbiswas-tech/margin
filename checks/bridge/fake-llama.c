// The parts of llama.cpp that LlamaEngine.c calls, faked: one token per byte, a cache that counts positions,
// and a sampler that spells out a fixed reply. Built against the real header, so every signature must match.
#include <llama/llama.h>
#include <stdlib.h>
#include <string.h>

struct llama_model { int unused; };
struct llama_vocab { int unused; };
struct llama_memory_i { int32_t used; };
struct llama_context { uint32_t n_ctx; struct llama_memory_i memory; };
struct fake_sampler { int emitted; };

static struct llama_vocab vocab;
int fake_decoded = 0;
const char *fake_reply = "Hello there";
int fake_reply_repeat = 1;
uint32_t fake_ctx_pad = 256;
enum { end_token = 256 };

void llama_backend_init(void) {}
struct llama_model_params llama_model_default_params(void) { struct llama_model_params p; memset(&p, 0, sizeof p); return p; }
struct llama_context_params llama_context_default_params(void) { struct llama_context_params p; memset(&p, 0, sizeof p); return p; }
struct llama_model *llama_model_load_from_file(const char *path_model, struct llama_model_params params) { return calloc(1, sizeof(struct llama_model)); }
void llama_model_free(struct llama_model *model) { free(model); }
struct llama_context *llama_init_from_model(struct llama_model *model, struct llama_context_params params) {
    struct llama_context *ctx = calloc(1, sizeof *ctx);
    ctx->n_ctx = params.n_ctx + fake_ctx_pad; // llama.cpp may round the context up
    return ctx;
}
void llama_free(struct llama_context *ctx) { free(ctx); }
uint32_t llama_n_ctx(const struct llama_context *ctx) { return ctx->n_ctx; }
const struct llama_vocab *llama_model_get_vocab(const struct llama_model *model) { return &vocab; }
const char *llama_model_chat_template(const struct llama_model *model, const char *name) { return "fake"; }

int32_t llama_chat_apply_template(const char *tmpl, const struct llama_chat_message *chat, size_t n_msg, bool add_ass, char *buf, int32_t length) {
    size_t need = add_ass ? strlen("assistant: ") : 0;
    for (size_t i = 0; i < n_msg; i++) need += strlen(chat[i].role) + 2 + strlen(chat[i].content) + 1;
    char *formatted = malloc(need + 1), *out = formatted;
    for (size_t i = 0; i < n_msg; i++) {
        size_t r = strlen(chat[i].role), c = strlen(chat[i].content);
        memcpy(out, chat[i].role, r); out += r;
        memcpy(out, ": ", 2); out += 2;
        memcpy(out, chat[i].content, c); out += c;
        *out++ = '\n';
    }
    if (add_ass) { memcpy(out, "assistant: ", 11); out += 11; }
    *out = 0;
    // As llama.cpp does: copies up to `length` bytes, with no terminator when it's a perfect fit.
    if (buf && length > 0) strncpy(buf, formatted, (size_t)length);
    free(formatted);
    return (int32_t)need;
}

bool llama_vocab_get_add_bos(const struct llama_vocab *v) { return false; }
int32_t llama_vocab_n_tokens(const struct llama_vocab *v) { return end_token + 1; }
bool llama_vocab_is_eog(const struct llama_vocab *v, llama_token token) { return token == end_token; }

int32_t llama_tokenize(const struct llama_vocab *v, const char *text, int32_t text_len, llama_token *tokens, int32_t n_tokens_max, bool add_special, bool parse_special) {
    if (!tokens || n_tokens_max < text_len) return -text_len;
    for (int32_t i = 0; i < text_len; i++) tokens[i] = (unsigned char)text[i];
    return text_len;
}

int32_t llama_token_to_piece(const struct llama_vocab *v, llama_token token, char *buf, int32_t length, int32_t lstrip, bool special) {
    if (length < 1) return -1;
    buf[0] = (char)token;
    return 1;
}

llama_memory_t llama_get_memory(const struct llama_context *ctx) { return (llama_memory_t)&((struct llama_context *)ctx)->memory; }
bool llama_memory_seq_rm(llama_memory_t mem, llama_seq_id seq_id, llama_pos p0, llama_pos p1) {
    if (p0 < 0) p0 = 0;
    if (p0 < mem->used) mem->used = p0;
    return true;
}
void llama_memory_clear(llama_memory_t mem, bool data) { mem->used = 0; }

struct llama_batch llama_batch_get_one(llama_token *tokens, int32_t n_tokens) {
    struct llama_batch batch;
    memset(&batch, 0, sizeof batch);
    batch.token = tokens;
    batch.n_tokens = n_tokens;
    return batch;
}
int32_t llama_decode(struct llama_context *ctx, struct llama_batch batch) {
    if (ctx->memory.used + batch.n_tokens > (int32_t)ctx->n_ctx) return 1; // no room left in the cache
    volatile llama_token touch = 0;
    for (int32_t i = 0; i < batch.n_tokens; i++) touch ^= batch.token[i]; // read every token, so a bad pointer shows
    (void)touch;
    ctx->memory.used += batch.n_tokens;
    fake_decoded += batch.n_tokens;
    return 0;
}

static struct llama_sampler *leaf(void) { return calloc(1, sizeof(struct llama_sampler)); }
struct llama_sampler_chain_params llama_sampler_chain_default_params(void) { struct llama_sampler_chain_params p; memset(&p, 0, sizeof p); return p; }
struct llama_sampler *llama_sampler_chain_init(struct llama_sampler_chain_params params) {
    struct llama_sampler *chain = leaf();
    chain->ctx = calloc(1, sizeof(struct fake_sampler));
    return chain;
}
void llama_sampler_chain_add(struct llama_sampler *chain, struct llama_sampler *smpl) { free(smpl); } // the chain owns it
struct llama_sampler *llama_sampler_init_grammar(const struct llama_vocab *v, const char *grammar_str, const char *grammar_root) { return leaf(); }
struct llama_sampler *llama_sampler_init_top_k(int32_t k) { return leaf(); }
struct llama_sampler *llama_sampler_init_penalties(int32_t n_vocab, int32_t penalty_last_n, float penalty_repeat, float penalty_freq, float penalty_present) { return leaf(); }
struct llama_sampler *llama_sampler_init_top_p(float p, size_t min_keep) { return leaf(); }
struct llama_sampler *llama_sampler_init_temp(float t) { return leaf(); }
struct llama_sampler *llama_sampler_init_dist(uint32_t seed) { return leaf(); }
llama_token llama_sampler_sample(struct llama_sampler *smpl, struct llama_context *ctx, int32_t idx) {
    struct fake_sampler *s = smpl->ctx;
    int n = (int)strlen(fake_reply);
    if (s->emitted >= n * fake_reply_repeat) return end_token;
    return (unsigned char)fake_reply[s->emitted++ % n];
}
void llama_sampler_free(struct llama_sampler *smpl) {
    if (!smpl) return;
    free(smpl->ctx);
    free(smpl);
}
