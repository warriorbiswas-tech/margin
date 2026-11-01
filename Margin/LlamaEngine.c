#include "Engines.h"

#if __has_include(<llama/llama.h>)

#include <llama/llama.h>
#include <stdlib.h>
#include <string.h>

struct margin_llm {
    struct llama_model *model;
    struct llama_context *context;
    llama_token *evaluated; // what the context already holds, so a request sharing its start needn't read that again
    int32_t evaluated_count;
};

bool margin_llm_supported(void) { return true; }

margin_llm *margin_llm_open(const char *model_path, int32_t context_tokens, int32_t threads) {
    llama_backend_init();

    // On the GPU, a short answer takes seconds instead of minutes. iOS forbids GPU work in the background,
    // so LocalLLM stops generating as soon as the app leaves the screen.
    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 99;
    struct llama_model *model = llama_model_load_from_file(model_path, model_params);
    if (!model) return NULL;

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = (uint32_t)context_tokens;
    context_params.n_batch = 512;
    context_params.n_threads = threads;
    context_params.n_threads_batch = threads;
    struct llama_context *context = llama_init_from_model(model, context_params);
    if (!context) {
        llama_model_free(model);
        return NULL;
    }

    // Sized by the context llama.cpp actually made, which can be larger than the one asked for.
    llama_token *evaluated = malloc(sizeof(llama_token) * llama_n_ctx(context));
    margin_llm *llm = malloc(sizeof(margin_llm));
    if (!llm || !evaluated) {
        free(llm);
        free(evaluated);
        llama_free(context);
        llama_model_free(model);
        return NULL;
    }
    llm->model = model;
    llm->context = context;
    llm->evaluated = evaluated;
    llm->evaluated_count = 0;
    return llm;
}

void margin_llm_close(margin_llm *llm) {
    if (!llm) return;
    llama_free(llm->context);
    llama_model_free(llm->model);
    free(llm->evaluated);
    free(llm);
}

static char *apply_template(const struct llama_model *model, const char *const *roles, const char *const *contents, int32_t count) {
    struct llama_chat_message *messages = malloc(sizeof(struct llama_chat_message) * (size_t)count);
    if (!messages) return NULL;
    size_t total = 64;
    for (int32_t i = 0; i < count; i++) {
        messages[i].role = roles[i];
        messages[i].content = contents[i];
        total += strlen(contents[i]) + 32;
    }
    const char *template = llama_model_chat_template(model, NULL);
    int32_t capacity = (int32_t)total * 2;
    char *prompt = malloc((size_t)capacity);
    int32_t length = prompt ? llama_chat_apply_template(template, messages, (size_t)count, true, prompt, capacity) : -1;
    if (length > capacity) {
        capacity = length + 1;
        char *larger = realloc(prompt, (size_t)capacity);
        if (larger) {
            prompt = larger;
            length = llama_chat_apply_template(template, messages, (size_t)count, true, prompt, capacity);
        } else {
            length = -1;
        }
    }
    free(messages);
    if (length < 0) {
        free(prompt);
        return NULL;
    }
    // Opens the answer past this model's reasoning block. Left to itself it can start the block and never close
    // it, and the reasoning is slow on a tablet without making short answers any better.
    static const char skip_reasoning[] = "<think>\n\n</think>\n\n";
    char *opened = realloc(prompt, (size_t)length + sizeof(skip_reasoning));
    if (!opened) {
        free(prompt);
        return NULL;
    }
    memcpy(opened + length, skip_reasoning, sizeof(skip_reasoning));
    return opened;
}

static struct llama_sampler *make_sampler(const struct llama_vocab *vocab, float temperature, const char *grammar) {
    struct llama_sampler *chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (grammar) {
        struct llama_sampler *constraint = llama_sampler_init_grammar(vocab, grammar, "root");
        if (constraint) llama_sampler_chain_add(chain, constraint);
    }
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(40));
    // Structured answers repeat their keys by design, so a repetition penalty would fight the format.
    // It runs after top-k because scanning the whole vocabulary for every token is slow.
    if (!grammar) llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1f, 0.0f, 0.0f));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9f, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return chain;
}

int32_t margin_llm_generate(margin_llm *llm,
                            const char *const *roles,
                            const char *const *contents,
                            int32_t message_count,
                            int32_t max_tokens,
                            float temperature,
                            const char *grammar,
                            margin_text_callback callback,
                            void *user) {
    const struct llama_vocab *vocab = llama_model_get_vocab(llm->model);

    char *prompt = apply_template(llm->model, roles, contents, message_count);
    if (!prompt) return margin_error_prompt;

    int32_t prompt_length = (int32_t)strlen(prompt);
    bool add_bos = llama_vocab_get_add_bos(vocab);
    int32_t token_count = -llama_tokenize(vocab, prompt, prompt_length, NULL, 0, add_bos, true);
    if (token_count <= 0) {
        free(prompt);
        return margin_error_prompt;
    }
    llama_token *tokens = malloc(sizeof(llama_token) * (size_t)token_count);
    if (!tokens) {
        free(prompt);
        return margin_error_prompt;
    }
    int32_t written = llama_tokenize(vocab, prompt, prompt_length, tokens, token_count, add_bos, true);
    free(prompt);
    if (written < 0) {
        free(tokens);
        return margin_error_prompt;
    }

    int32_t context_size = (int32_t)llama_n_ctx(llm->context);
    if (token_count + 16 >= context_size) {
        free(tokens);
        return margin_error_too_long;
    }

    // Keep what's shared with the last request. The final token is always read again, since sampling needs its output.
    int32_t kept = 0;
    while (kept < llm->evaluated_count && kept < token_count - 1 && llm->evaluated[kept] == tokens[kept]) kept++;
    llama_memory_t memory = llama_get_memory(llm->context);
    if (kept == 0 || !llama_memory_seq_rm(memory, 0, kept, -1)) {
        llama_memory_clear(memory, true);
        kept = 0;
    }
    llm->evaluated_count = kept;

    const int32_t batch_size = 512;
    for (int32_t start = kept; start < token_count; start += batch_size) {
        int32_t count = token_count - start < batch_size ? token_count - start : batch_size;
        if (llama_decode(llm->context, llama_batch_get_one(tokens + start, count)) != 0) {
            llm->evaluated_count = 0;
            free(tokens);
            return margin_error_decode;
        }
        memcpy(llm->evaluated + start, tokens + start, sizeof(llama_token) * (size_t)count);
        llm->evaluated_count = start + count;
    }
    free(tokens);

    struct llama_sampler *sampler = make_sampler(vocab, temperature, grammar);
    int32_t result = margin_ok;
    int32_t room = context_size - token_count - 1;
    int32_t limit = max_tokens < room ? max_tokens : room;
    for (int32_t i = 0; i < limit; i++) {
        llama_token token = llama_sampler_sample(sampler, llm->context, -1);
        if (llama_vocab_is_eog(vocab, token)) break;

        char piece[256];
        int32_t length = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (length > 0 && !callback(piece, length, user)) break;

        if (llama_decode(llm->context, llama_batch_get_one(&token, 1)) != 0) {
            llm->evaluated_count = 0;
            result = margin_error_decode;
            break;
        }
        llm->evaluated[llm->evaluated_count++] = token;
    }
    llama_sampler_free(sampler);
    return result;
}

#else

// The published llama.cpp build has no Simulator slice, so AI is simply unavailable there.
bool margin_llm_supported(void) { return false; }
margin_llm *margin_llm_open(const char *model_path, int32_t context_tokens, int32_t threads) { return 0; }
void margin_llm_close(margin_llm *llm) {}
int32_t margin_llm_generate(margin_llm *llm, const char *const *roles, const char *const *contents, int32_t message_count,
                            int32_t max_tokens, float temperature, const char *grammar, margin_text_callback callback, void *user) {
    return margin_error_prompt;
}

#endif
