#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <ggml-backend.h>
#include "Engines.h"

typedef struct {
    JNIEnv *env;
    jobject callback;
    jmethodID method;
} callback_context;

static bool on_text(const char *bytes, int32_t length, void *user) {
    callback_context *context = user;
    JNIEnv *env = context->env;
    jbyteArray piece = (*env)->NewByteArray(env, length);
    if (!piece) return false;
    (*env)->SetByteArrayRegion(env, piece, 0, length, (const jbyte *)bytes);
    jboolean keep_going = (*env)->CallBooleanMethod(env, context->callback, context->method, piece);
    (*env)->DeleteLocalRef(env, piece);
    if ((*env)->ExceptionCheck(env)) return false;
    return keep_going;
}

JNIEXPORT void JNICALL
Java_com_warriorbiswas_margin_LlamaBridge_loadBackends(JNIEnv *env, jobject thiz, jstring directory) {
    const char *path = (*env)->GetStringUTFChars(env, directory, NULL);
    ggml_backend_load_all_from_path(path);
    (*env)->ReleaseStringUTFChars(env, directory, path);
}

JNIEXPORT jlong JNICALL
Java_com_warriorbiswas_margin_LlamaBridge_open(JNIEnv *env, jobject thiz, jstring model, jint context_tokens, jint threads) {
    const char *path = (*env)->GetStringUTFChars(env, model, NULL);
    margin_llm *llm = margin_llm_open(path, context_tokens, threads);
    (*env)->ReleaseStringUTFChars(env, model, path);
    return (jlong)(intptr_t)llm;
}

JNIEXPORT void JNICALL
Java_com_warriorbiswas_margin_LlamaBridge_close(JNIEnv *env, jobject thiz, jlong handle) {
    margin_llm_close((margin_llm *)(intptr_t)handle);
}

JNIEXPORT jint JNICALL
Java_com_warriorbiswas_margin_LlamaBridge_generate(JNIEnv *env, jobject thiz, jlong handle, jobjectArray roles, jobjectArray contents,
                                                   jint max_tokens, jfloat temperature, jstring grammar, jobject callback) {
    jsize count = (*env)->GetArrayLength(env, roles);
    const char **role_chars = calloc((size_t)count, sizeof(char *));
    const char **content_chars = calloc((size_t)count, sizeof(char *));
    jstring *role_strings = calloc((size_t)count, sizeof(jstring));
    jstring *content_strings = calloc((size_t)count, sizeof(jstring));
    jint result = margin_error_prompt;
    if (role_chars && content_chars && role_strings && content_strings) {
        for (jsize i = 0; i < count; i++) {
            role_strings[i] = (*env)->GetObjectArrayElement(env, roles, i);
            content_strings[i] = (*env)->GetObjectArrayElement(env, contents, i);
            role_chars[i] = (*env)->GetStringUTFChars(env, role_strings[i], NULL);
            content_chars[i] = (*env)->GetStringUTFChars(env, content_strings[i], NULL);
        }
        const char *grammar_chars = grammar ? (*env)->GetStringUTFChars(env, grammar, NULL) : NULL;
        jclass type = (*env)->GetObjectClass(env, callback);
        callback_context context = {env, callback, (*env)->GetMethodID(env, type, "onPiece", "([B)Z")};
        result = margin_llm_generate((margin_llm *)(intptr_t)handle, role_chars, content_chars, count, max_tokens, temperature, grammar_chars, on_text, &context);
        if (grammar_chars) (*env)->ReleaseStringUTFChars(env, grammar, grammar_chars);
        for (jsize i = 0; i < count; i++) {
            (*env)->ReleaseStringUTFChars(env, role_strings[i], role_chars[i]);
            (*env)->ReleaseStringUTFChars(env, content_strings[i], content_chars[i]);
        }
    }
    free(role_chars);
    free(content_chars);
    free(role_strings);
    free(content_strings);
    return result;
}
