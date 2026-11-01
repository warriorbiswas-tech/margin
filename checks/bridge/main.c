// clang -fsanitize=address,undefined -F Vendor/macos Margin/LlamaEngine.c checks/bridge/fake-llama.c checks/bridge/main.c -o /tmp/bridge && /tmp/bridge
// Runs LlamaEngine.c, the app's own bridge, against a fake llama.cpp, so its buffers and prompt cache are checked without a model.
#include "../../Margin/Engines.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int fake_decoded;
extern int fake_reply_repeat;
extern uint32_t fake_ctx_pad;

struct answer { char text[200000]; int length, pieces, stop_after; };
static bool collect(const char *bytes, int32_t length, void *user) {
    struct answer *a = user;
    memcpy(a->text + a->length, bytes, (size_t)length);
    a->length += length;
    a->text[a->length] = 0;
    a->pieces++;
    return a->stop_after == 0 || a->pieces < a->stop_after;
}
#define CHECK(ok, what) do { if (!(ok)) { printf("FAIL: %s\n", what); return 1; } } while (0)

static struct answer a;

/// How many tokens the fake makes of a question, one per byte of the prompt the bridge builds.
static int prompt_tokens(const char *question) {
    return (int)(strlen("system: Be brief.\nuser: \nassistant: <think>\n\n</think>\n\n") + strlen(question));
}

static int ask(margin_llm *llm, const char *question, int32_t max_tokens, const char *grammar, int stop_after) {
    const char *roles[] = {"system", "user"};
    const char *contents[] = {"Be brief.", question};
    memset(&a, 0, sizeof a);
    a.stop_after = stop_after;
    return margin_llm_generate(llm, roles, contents, 2, max_tokens, 0.4f, grammar, collect, &a);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    margin_llm *llm = margin_llm_open("model.gguf", 512, 2);
    CHECK(llm, "opens");
    CHECK(ask(llm, "What is mitosis?", 100, NULL, 0) == margin_ok && strcmp(a.text, "Hello there") == 0, "streams the whole answer");

    int before = fake_decoded;
    CHECK(ask(llm, "What is mitosis? And meiosis?", 100, NULL, 0) == margin_ok, "answers a follow-up");
    // Exactly the part after the shared start is read: the question's new words, and the turn that follows.
    const char *first = "system: Be brief.\nuser: What is mitosis?\nassistant: <think>\n\n</think>\n\n";
    const char *second = "system: Be brief.\nuser: What is mitosis? And meiosis?\nassistant: <think>\n\n</think>\n\n";
    int shared = 0;
    while (first[shared] && first[shared] == second[shared]) shared++;
    CHECK(fake_decoded - before == (int)strlen(second) - shared + (int)strlen("Hello there"), "a follow-up reads only what's new, then its answer");

    CHECK(ask(llm, "What is mitosis?", 100, NULL, 3) == margin_ok && a.length == 3, "stops when told");
    CHECK(ask(llm, "What is mitosis?", 100, NULL, 0) == margin_ok && strcmp(a.text, "Hello there") == 0, "works after a stop");

    static char huge[5000];
    memset(huge, 'a', sizeof huge - 1);
    CHECK(ask(llm, huge, 100, NULL, 0) == margin_error_too_long, "a prompt that can't fit is refused");
    CHECK(ask(llm, "What is mitosis?", 100, NULL, 0) == margin_ok && strcmp(a.text, "Hello there") == 0, "works after a refusal");

    // Runs on until the context is full: every token it keeps must land inside its buffer.
    fake_reply_repeat = 1000000;
    CHECK(ask(llm, "What is mitosis?", 1 << 30, NULL, 0) == margin_ok, "a runaway answer ends cleanly");
    CHECK(a.length == 512 + 256 - prompt_tokens("What is mitosis?") - 1, "it ends at the edge of the context llama.cpp made");
    CHECK(ask(llm, "What is mitosis?", 100, NULL, 0) == margin_ok, "works after filling the context");
    fake_reply_repeat = 1;

    CHECK(ask(llm, "Pick one", 100, "root ::= \"a\"", 0) == margin_ok, "a structured answer runs");
    for (int i = 0; i < 200; i++) {
        char question[64];
        snprintf(question, sizeof question, "Question %d", i);
        CHECK(ask(llm, question, 20 + i % 7, i % 5 ? NULL : "root ::= \"a\"", i % 4) == margin_ok, "many requests in a row");
    }
    margin_llm_close(llm);

    // Without rounding up, a small context fills to its last slot and no further.
    fake_ctx_pad = 0;
    llm = margin_llm_open("model.gguf", 96, 2);
    CHECK(llm, "opens a small context");
    fake_reply_repeat = 1000000;
    CHECK(ask(llm, "Hi", 1 << 30, NULL, 0) == margin_ok && a.length == 96 - prompt_tokens("Hi") - 1, "fills a small context exactly");
    fake_reply_repeat = 1;
    CHECK(ask(llm, "A question too long for so little room", 100, NULL, 0) == margin_error_too_long, "and refuses what can't fit");
    margin_llm_close(llm);
    margin_llm_close(NULL);
    printf("ok\n");
    return 0;
}
