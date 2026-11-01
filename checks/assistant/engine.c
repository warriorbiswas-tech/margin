// Takes the place of LlamaEngine.c for checks/assistant: the same contract, with canned answers and no model.
#include "engine.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct margin_llm { int open; };
static atomic_int mock_generate_calls = 0;
static atomic_int mock_too_long_over = 0; // prompts longer than this many bytes are refused, 0 = never
static atomic_int mock_tokens = 40;
static atomic_int mock_open_count = 0;

bool margin_llm_supported(void) { return true; }
margin_llm *margin_llm_open(const char *model_path, int32_t context_tokens, int32_t threads) {
    atomic_fetch_add(&mock_open_count, 1);
    margin_llm *llm = malloc(sizeof(margin_llm));
    llm->open = 1;
    return llm;
}
void margin_llm_close(margin_llm *llm) { free(llm); }

static int say(margin_text_callback callback, void *user, const char *text) {
    return callback(text, (int32_t)strlen(text), user);
}

int32_t margin_llm_generate(margin_llm *llm, const char *const *roles, const char *const *contents, int32_t message_count,
                            int32_t max_tokens, float temperature, const char *grammar, margin_text_callback callback, void *user) {
    atomic_fetch_add(&mock_generate_calls, 1);
    size_t total = 0;
    for (int32_t i = 0; i < message_count; i++) total += strlen(contents[i]);
    int limit = atomic_load(&mock_too_long_over);
    if (limit > 0 && total > (size_t)limit) return margin_error_too_long;
    if (grammar) {
        const char *reply = "[]";
        if (strstr(grammar, "card ::=")) reply = "[{\"front\":\"What is mitosis?\",\"back\":\"Cell division into two identical cells.\"}]";
        else if (strstr(grammar, "question ::=")) reply = "[{\"question\":\"Which stage lines chromosomes up?\",\"options\":[\"A. Prophase\",\"Metaphase\",\"Anaphase\",\"Telophase\"],\"answer\":1}]";
        else if (strstr(grammar, "branch ::=")) reply = "[{\"title\":\"Mitosis\",\"children\":[{\"title\":\"Stages\",\"children\":[{\"title\":\"Metaphase\"}]}]}]";
        else if (strstr(grammar, "unicode")) reply = "[{\"unicode\":\"x² + 1\",\"latex\":\"x^{2} + 1\"}]";
        else if (strncmp(grammar, "root ::= \"", 10) == 0) {
            static char folder[256];
            const char *start = grammar + 10, *end = strchr(start, '"');
            size_t n = end ? (size_t)(end - start) : 0;
            if (n > 250) n = 250;
            memcpy(folder, start, n);
            folder[n] = 0;
            reply = folder;
        }
        say(callback, user, reply);
        return margin_ok;
    }
    say(callback, user, "<think>\n\n</think>\n\n");
    int tokens = atomic_load(&mock_tokens);
    if (tokens > max_tokens) tokens = max_tokens;
    for (int i = 0; i < tokens; i++) {
        usleep(500);
        if (!say(callback, user, i == 0 ? "Answer" : " word")) return margin_ok;
    }
    return margin_ok;
}

bool margin_whisper_supported(void) { return false; }
margin_whisper *margin_whisper_open(const char *model_path) { return 0; }
void margin_whisper_close(margin_whisper *whisper) {}
int32_t margin_whisper_transcribe(margin_whisper *whisper, const float *samples, int32_t sample_count, int32_t threads,
                                  const char *language, margin_segment_callback callback, void *user) { return margin_error_prompt; }

int mock_calls(void) { return atomic_load(&mock_generate_calls); }
int mock_opens(void) { return atomic_load(&mock_open_count); }
void mock_set_tokens(int n) { atomic_store(&mock_tokens, n); }
void mock_set_too_long(int bytes) { atomic_store(&mock_too_long_over, bytes); }
