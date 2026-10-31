#include "Engines.h"

#if __has_include(<whisper/whisper.h>)

#include <stdlib.h>
#include <whisper/whisper.h>

struct margin_whisper {
    struct whisper_context *context;
};

bool margin_whisper_supported(void) { return true; }

margin_whisper *margin_whisper_open(const char *model_path) {
    // CPU only, so transcription keeps running while the iPad is locked during a lecture.
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    struct whisper_context *context = whisper_init_from_file_with_params(model_path, params);
    if (!context) return NULL;
    margin_whisper *whisper = malloc(sizeof(margin_whisper));
    whisper->context = context;
    return whisper;
}

void margin_whisper_close(margin_whisper *whisper) {
    if (!whisper) return;
    whisper_free(whisper->context);
    free(whisper);
}

int32_t margin_whisper_transcribe(margin_whisper *whisper,
                                  const float *samples,
                                  int32_t sample_count,
                                  int32_t threads,
                                  const char *language,
                                  margin_segment_callback callback,
                                  void *user) {
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.language = language;
    params.n_threads = threads;

    int32_t status = whisper_full(whisper->context, params, samples, sample_count);
    if (status != 0) return status;

    int segments = whisper_full_n_segments(whisper->context);
    for (int i = 0; i < segments; i++) {
        double start = (double)whisper_full_get_segment_t0(whisper->context, i) / 100.0;
        double end = (double)whisper_full_get_segment_t1(whisper->context, i) / 100.0;
        callback(start, end, whisper_full_get_segment_text(whisper->context, i), user);
    }
    return margin_ok;
}

#else

bool margin_whisper_supported(void) { return false; }
margin_whisper *margin_whisper_open(const char *model_path) { return 0; }
void margin_whisper_close(margin_whisper *whisper) {}
int32_t margin_whisper_transcribe(margin_whisper *whisper, const float *samples, int32_t sample_count, int32_t threads,
                                  const char *language, margin_segment_callback callback, void *user) {
    return margin_error_prompt;
}

#endif
