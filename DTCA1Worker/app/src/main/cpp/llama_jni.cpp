//
//  llama_jni.cpp
//  PixelDesktop DTCA-1 / Phase 6 worker
//
//  The ONLY file in this project that touches llama.cpp's C API.
//
//  ADR-012 §2: llama.cpp is a replaceable runtime adapter, not architecture-wide coupling.
//  Everything above this file sees a plain JSON contract and nothing else. Replacing
//  llama.cpp with LiteRT-LM or ExecuTorch means replacing this file and nothing else.
//
//  ADR-012 §11: CPU ONLY for the first proof. GGML_VULKAN is OFF at build time and n_gpu_layers
//  is forced to 0 here, so a GPU path cannot be enabled by accident or by configuration.
//
//  Deliberate omissions, each for a reason:
//    - no sampling beyond greedy: Phase 6 requires temperature 0
//    - no streaming: the result is one bounded file
//    - no conversation state: one-shot process, no memory, no history
//    - no network: the model and the prompt are both local files
//

#include <jni.h>
#include <android/log.h>

#include <cstring>
#include <string>
#include <vector>
#include <chrono>

#include "llama.h"

#define LOG_TAG "PD_LLAMA"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kContextSize = 2048;

struct Engine {
    llama_model   * model = nullptr;
    llama_context * ctx   = nullptr;
    const llama_vocab * vocab = nullptr;
    int64_t model_load_ms = 0;
};

long long now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::string json_escape(const std::string & in) {
    std::string out;
    out.reserve(in.size() + 16);
    for (unsigned char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            case '\b': out += "\\b";  break;
            case '\f': out += "\\f";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    // Bytes >= 0x80 are passed through: llama.cpp emits UTF-8, and re-encoding
                    // here would corrupt multi-byte sequences.
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

void free_engine(Engine * e) {
    if (!e) return;
    if (e->ctx)   { llama_free(e->ctx);         e->ctx = nullptr; }
    if (e->model) { llama_model_free(e->model); e->model = nullptr; }
    delete e;
}

} // namespace

extern "C" {

JNIEXPORT jstring JNICALL
Java_com_pixeldesktop_worker_LlamaBridge_nativeRuntimeInfo(JNIEnv * env, jclass) {
    std::string info = std::string("llama.cpp ") + "a868c3e" + " backend=cpu";
    return env->NewStringUTF(info.c_str());
}

/**
 * Loads a GGUF model from an absolute path.
 *
 * Returns a pointer to the Engine as a jlong, or 0 on failure. A 0 return is a real failure
 * and is surfaced as such — native errors are never swallowed (ADR-012 §13).
 */
JNIEXPORT jlong JNICALL
Java_com_pixeldesktop_worker_LlamaBridge_nativeLoadModel(JNIEnv * env, jclass, jstring jpath) {
    const char * path = env->GetStringUTFChars(jpath, nullptr);
    if (!path) return 0;

    const long long t0 = now_ms();

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    // ADR-012 §11: CPU only. Forced here so no caller can enable a GPU path.
    mparams.n_gpu_layers = 0;
    // MMAP, explicitly. The model is 1.1 GB and this is a shared phone with ~2 GB available:
    // mmap avoids a second full copy in RAM, and lets the kernel evict model pages under
    // pressure instead of the process being killed outright. MLOCK is deliberately NOT used —
    // pinning 1.1 GB would defeat exactly that reclaimability.
    mparams.load_mode    = LLAMA_LOAD_MODE_MMAP;
    mparams.vocab_only   = false;

    LOGI("loading model: %s", path);

    Engine * e = new Engine();
    e->model = llama_model_load_from_file(path, mparams);
    env->ReleaseStringUTFChars(jpath, path);

    if (!e->model) {
        LOGE("llama_model_load_from_file returned null");
        delete e;
        return 0;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx     = kContextSize;
    cparams.n_batch   = 256;
    cparams.n_threads = 4;  // Tensor G2: 4 big cores. Deliberately not 8 — the little cores
                            // would add contention without throughput, and 4 leaves headroom
                            // for the system while the screen is off.

    e->ctx = llama_init_from_model(e->model, cparams);
    if (!e->ctx) {
        LOGE("llama_init_from_model returned null");
        llama_model_free(e->model);
        delete e;
        return 0;
    }

    e->vocab = llama_model_get_vocab(e->model);
    e->model_load_ms = now_ms() - t0;

    LOGI("model loaded in %lld ms", (long long) e->model_load_ms);
    return reinterpret_cast<jlong>(e);
}

/**
 * Frees the engine. Safe to call with 0.
 */
JNIEXPORT void JNICALL
Java_com_pixeldesktop_worker_LlamaBridge_nativeFree(JNIEnv *, jclass, jlong handle) {
    free_engine(reinterpret_cast<Engine *>(handle));
}

/**
 * Reports model metadata without generating. Used to prove the model actually loaded and to
 * record what it is, independently of any generated text.
 */
JNIEXPORT jstring JNICALL
Java_com_pixeldesktop_worker_LlamaBridge_nativeModelInfo(JNIEnv * env, jclass, jlong handle) {
    Engine * e = reinterpret_cast<Engine *>(handle);
    if (!e || !e->model) return env->NewStringUTF("{\"error\":\"no model\"}");

    char desc[256] = {0};
    llama_model_desc(e->model, desc, sizeof(desc));

    char buf[1024];
    snprintf(buf, sizeof(buf),
             "{\"desc\":\"%s\",\"n_params\":%llu,\"size_bytes\":%llu,\"n_ctx_train\":%d,"
             "\"model_load_ms\":%lld,\"backend\":\"cpu\"}",
             json_escape(desc).c_str(),
             (unsigned long long) llama_model_n_params(e->model),
             (unsigned long long) llama_model_size(e->model),
             llama_model_n_ctx_train(e->model),
             (long long) e->model_load_ms);
    return env->NewStringUTF(buf);
}

/**
 * Greedy generation.
 *
 * The prompt is expected to be ALREADY formatted with the chat template by the caller, so this
 * function stays a plain tokenizer+sampler loop with no opinion about chat formats.
 *
 * Returns JSON: {"text":..., "token_ids":[...], "prompt_tokens":N, "generated_tokens":N,
 *                "prompt_eval_ms":N, "generation_ms":N}
 * or {"error":"..."} on failure.
 */
JNIEXPORT jstring JNICALL
Java_com_pixeldesktop_worker_LlamaBridge_nativeGenerate(
        JNIEnv * env, jclass, jlong handle, jstring jprompt, jint max_tokens, jint seed) {

    Engine * e = reinterpret_cast<Engine *>(handle);
    if (!e || !e->model || !e->ctx || !e->vocab) {
        return env->NewStringUTF("{\"error\":\"engine not loaded\"}");
    }

    const char * prompt = env->GetStringUTFChars(jprompt, nullptr);
    if (!prompt) return env->NewStringUTF("{\"error\":\"prompt unavailable\"}");
    const std::string prompt_str(prompt);
    env->ReleaseStringUTFChars(jprompt, prompt);

    // Fresh KV cache for every request. The process is one-shot, but a repeated invocation in
    // the same process must not inherit the previous prompt's state.
    llama_memory_clear(llama_get_memory(e->ctx), true);

    // ---- tokenize ----
    int n_prompt_max = (int) prompt_str.size() + 64;
    std::vector<llama_token> tokens(n_prompt_max);
    int n_prompt = llama_tokenize(e->vocab, prompt_str.c_str(), (int32_t) prompt_str.size(),
                                  tokens.data(), n_prompt_max,
                                  /*add_special=*/true, /*parse_special=*/true);
    if (n_prompt < 0) {
        // Negative return means "buffer too small, need -n_prompt". Grow once and retry.
        tokens.resize(-n_prompt);
        n_prompt = llama_tokenize(e->vocab, prompt_str.c_str(), (int32_t) prompt_str.size(),
                                  tokens.data(), -n_prompt, true, true);
    }
    if (n_prompt <= 0) {
        return env->NewStringUTF("{\"error\":\"tokenization failed\"}");
    }
    tokens.resize(n_prompt);

    if (n_prompt + max_tokens > kContextSize) {
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "{\"error\":\"context overflow: prompt %d + max_tokens %d > n_ctx %d\"}",
                 n_prompt, (int) max_tokens, kContextSize);
        return env->NewStringUTF(buf);
    }

    // ---- prompt eval ----
    const long long t_prompt0 = now_ms();
    llama_batch batch = llama_batch_get_one(tokens.data(), n_prompt);
    if (llama_decode(e->ctx, batch) != 0) {
        return env->NewStringUTF("{\"error\":\"llama_decode failed on prompt\"}");
    }
    const long long prompt_eval_ms = now_ms() - t_prompt0;

    // ---- greedy sampling ----
    // temperature 0 => greedy. No top_k/top_p/dist: greedy is deterministic by construction,
    // which is what makes the R4 stability measurement meaningful.
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler * smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    std::string out;
    std::vector<llama_token> generated;
    generated.reserve(max_tokens);

    const long long t_gen0 = now_ms();
    for (int i = 0; i < max_tokens; i++) {
        llama_token id = llama_sampler_sample(smpl, e->ctx, -1);
        if (llama_vocab_is_eog(e->vocab, id)) {
            break;
        }
        generated.push_back(id);

        char piece[256];
        int n = llama_token_to_piece(e->vocab, id, piece, sizeof(piece), 0, /*special=*/false);
        if (n > 0) out.append(piece, n);

        // Feed the token back to advance the sequence.
        llama_batch next = llama_batch_get_one(&id, 1);
        if (llama_decode(e->ctx, next) != 0) {
            break;  // stop cleanly; whatever was generated is still returned
        }
    }
    const long long generation_ms = now_ms() - t_gen0;

    llama_sampler_free(smpl);

    // ---- build result JSON ----
    std::string json = "{\"text\":\"" + json_escape(out) + "\",\"token_ids\":[";
    for (size_t i = 0; i < generated.size(); i++) {
        if (i) json += ",";
        json += std::to_string(generated[i]);
    }
    json += "],\"prompt_tokens\":" + std::to_string(n_prompt);
    json += ",\"generated_tokens\":" + std::to_string(generated.size());
    json += ",\"prompt_eval_ms\":" + std::to_string(prompt_eval_ms);
    json += ",\"generation_ms\":" + std::to_string(generation_ms);
    json += "}";

    LOGI("generated %zu tokens in %lld ms (prompt %d tokens in %lld ms)",
         generated.size(), (long long) generation_ms, n_prompt, (long long) prompt_eval_ms);

    return env->NewStringUTF(json.c_str());
}

} // extern "C"
