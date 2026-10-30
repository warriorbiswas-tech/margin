// Plain C doorway to llama.cpp and whisper.cpp. Each ships its own copy of the ggml headers,
// so Swift only ever sees this file; importing both frameworks into Swift fails to compile.
#ifndef Engines_h
#define Engines_h

#include <stdbool.h>
#include <stdint.h>

bool margin_llm_supported(void);
bool margin_whisper_supported(void);

typedef struct margin_llm margin_llm;

/// Return false to stop generating.
typedef bool (*margin_text_callback)(const char *bytes, int32_t length, void *user);

enum {
    margin_ok = 0,
    margin_error_prompt = -1,
    margin_error_too_long = -2,
    margin_error_decode = -3,
};

margin_llm *margin_llm_open(const char *model_path, int32_t context_tokens, int32_t threads);
void margin_llm_close(margin_llm *llm);
int32_t margin_llm_generate(margin_llm *llm,
                            const char *const *roles,
                            const char *const *contents,
                            int32_t message_count,
                            int32_t max_tokens,
                            float temperature,
                            const char *grammar,
                            margin_text_callback callback,
                            void *user);

typedef struct margin_whisper margin_whisper;

/// Times are in seconds from the start of `samples`.
typedef void (*margin_segment_callback)(double start, double end, const char *text, void *user);

margin_whisper *margin_whisper_open(const char *model_path);
void margin_whisper_close(margin_whisper *whisper);
/// `samples` is 16 kHz mono.
int32_t margin_whisper_transcribe(margin_whisper *whisper,
                                  const float *samples,
                                  int32_t sample_count,
                                  int32_t threads,
                                  margin_segment_callback callback,
                                  void *user);

#endif
