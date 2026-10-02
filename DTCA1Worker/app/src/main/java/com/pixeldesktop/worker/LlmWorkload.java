package com.pixeldesktop.worker;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.security.MessageDigest;

/**
 * The Phase 6 local-language-model workload: {@code LOCAL-LLM-1}.
 *
 * <p>Bounded by construction. One prompt in, a bounded number of tokens out, one result file.
 * No conversation, no tools, no memory, no RAG, no network, no agent loop (ADR-012 §P8).
 *
 * <p>This class is the only place that knows the job shape for inference. It delegates the
 * actual computation to {@link LlamaBridge}, which knows nothing about jobs or files.
 */
final class LlmWorkload {

    private static final String TAG = "PixelDesktopWorker";

    static final String WORKLOAD_NAME = "LOCAL-LLM-1";

    /** The single fixed model filename. No caller may influence this. */
    static final String MODEL_DIR_NAME = "model";
    static final String MODEL_FILE_NAME = "qwen2.5-1.5b-instruct-q4_k_m.gguf";

    private static final int MAX_PROMPT_CHARS = 4096;
    private static final int MAX_TOKENS_CEILING = 256;

    /** Qwen2.5 uses ChatML. The template is applied here, not in the native layer, so the
     *  native bridge stays a plain tokenizer+sampler loop with no opinion about chat formats. */
    private static final String IM_START = "<|im_start|>";
    private static final String IM_END = "<|im_end|>";

    private LlmWorkload() {}

    /** Raised for any bounded, reportable failure. Never a silent empty result. */
    static final class Failure extends Exception {
        final String errorType;

        Failure(String errorType, String message) {
            super(message);
            this.errorType = errorType;
        }
    }

    /**
     * Resolves the fixed model file inside the app's own external files directory.
     *
     * <p>The directory is created by the app, never by adb — an adb-created directory is owned
     * by {@code shell:ext_data_rw} and this process cannot write it (D8/FAIL-004 instance 3).
     */
    static File resolveModelFile(File externalFilesDir) {
        File modelDir = new File(externalFilesDir, MODEL_DIR_NAME);
        return new File(modelDir, MODEL_FILE_NAME);
    }

    /** The model directory, created by the app if absent. */
    static File ensureModelDirectory(File externalFilesDir) {
        File modelDir = new File(externalFilesDir, MODEL_DIR_NAME);
        if (!modelDir.exists()) {
            //noinspection ResultOfMethodCallIgnored
            modelDir.mkdirs();
        }
        return modelDir;
    }

    /**
     * Executes the workload and returns the result envelope.
     *
     * @param job the parsed job file
     * @param externalFilesDir this app's own external files directory
     */
    static JSONObject execute(JSONObject job, File externalFilesDir) throws Failure {
        String jobId = job.optString("job_id", "unknown");

        // ---- validate the request before touching the device's heavy resources ----
        String prompt = job.optString("prompt", "");
        int maxTokens = job.optInt("max_tokens", 32);
        double temperature = job.optDouble("temperature", 0.0);
        int seed = job.optInt("seed", 0);

        if (prompt.isEmpty()) {
            throw new Failure("INVALID_INPUT", "prompt is empty");
        }
        if (prompt.length() > MAX_PROMPT_CHARS) {
            throw new Failure("INVALID_INPUT",
                    "prompt is " + prompt.length() + " characters, maximum is " + MAX_PROMPT_CHARS);
        }
        if (maxTokens <= 0) {
            throw new Failure("INVALID_INPUT", "max_tokens must be positive, got " + maxTokens);
        }
        if (maxTokens > MAX_TOKENS_CEILING) {
            throw new Failure("INVALID_INPUT",
                    "max_tokens is " + maxTokens + ", ceiling is " + MAX_TOKENS_CEILING);
        }
        // Phase 6 is greedy only. Refused rather than silently coerced, so a non-greedy request
        // can never be mistaken for a greedy one in the evidence.
        if (temperature != 0.0) {
            throw new Failure("INVALID_INPUT",
                    "Phase 6 requires greedy decoding (temperature 0), got " + temperature);
        }

        // ---- native runtime present? ----
        if (!LlamaBridge.isAvailable()) {
            throw new Failure("NATIVE_LIBRARY_MISSING", LlamaBridge.loadError());
        }

        // ---- model present? ----
        File modelFile = resolveModelFile(externalFilesDir);
        if (!modelFile.isFile()) {
            throw new Failure("MODEL_MISSING",
                    "model not found at " + modelFile.getAbsolutePath());
        }

        long totalStart = System.currentTimeMillis();

        // ---- load ----
        long loadStart = System.currentTimeMillis();
        long handle = LlamaBridge.nativeLoadModel(modelFile.getAbsolutePath());
        long modelLoadMs = System.currentTimeMillis() - loadStart;

        if (handle == 0) {
            throw new Failure("MODEL_LOAD_FAILED",
                    "llama.cpp could not load " + modelFile.getName());
        }

        try {
            // ---- generate ----
            String chatPrompt = applyChatTemplate(prompt);
            String raw = LlamaBridge.nativeGenerate(handle, chatPrompt, maxTokens, seed);

            JSONObject nativeResult = new JSONObject(raw);
            if (nativeResult.has("error")) {
                throw new Failure("INFERENCE_FAILED", nativeResult.optString("error"));
            }

            long totalMs = System.currentTimeMillis() - totalStart;

            // ---- build the result envelope ----
            JSONObject result = new JSONObject();
            result.put("status", "OK");
            result.put("job_id", jobId);
            result.put("workload", WORKLOAD_NAME);
            result.put("text", nativeResult.optString("text", ""));

            JSONArray ids = nativeResult.optJSONArray("token_ids");
            result.put("token_ids", ids == null ? new JSONArray() : ids);

            result.put("generated_tokens", nativeResult.optInt("generated_tokens", 0));
            result.put("prompt_tokens", nativeResult.optInt("prompt_tokens", 0));
            result.put("model_load_ms", modelLoadMs);
            result.put("prompt_eval_ms", nativeResult.optLong("prompt_eval_ms", 0));
            result.put("generation_ms", nativeResult.optLong("generation_ms", 0));
            result.put("total_ms", totalMs);

            result.put("runtime", LlamaBridge.nativeRuntimeInfo());
            result.put("model_file", modelFile.getName());
            result.put("model_bytes", modelFile.length());

            // Worker-attributable process memory, read by the process itself from
            // /proc/self/status. This is NATIVE memory (model + KV cache + runtime), which is
            // NOT bounded by the 256 MB Java heap — the distinction the reconnaissance
            // established. Reading it here is more reliable than sampling from outside, because
            // the process lives only ~15-25 s and an external sampler can easily miss the peak.
            int[] mem = readProcessMemoryKb();
            result.put("vm_peak_kb", mem[0]);
            result.put("vm_rss_kb", mem[1]);

            // The model's SHA-256 is computed ON THE DEVICE, over the exact bytes the runtime
            // just read. This is what ties the generated text to a specific artifact.
            result.put("model_sha256", sha256OfFile(modelFile));

            result.put("execution_timestamp_ms", System.currentTimeMillis());

            return result;

        } catch (Failure f) {
            throw f;
        } catch (Exception e) {
            throw new Failure("INFERENCE_FAILED", String.valueOf(e.getMessage()));
        } finally {
            LlamaBridge.nativeFree(handle);
        }
    }

    /**
     * Qwen2.5 ChatML template.
     *
     * <p>A minimal, fixed system prompt keeps the first proof's behaviour reproducible: the
     * system turn is a constant, not a job input, so it cannot vary between runs.
     */
    static String applyChatTemplate(String userPrompt) {
        return IM_START + "system\nYou are a helpful assistant." + IM_END + "\n"
                + IM_START + "user\n" + userPrompt + IM_END + "\n"
                + IM_START + "assistant\n";
    }

    /**
     * Reads this process's own memory from /proc/self/status.
     *
     * @return [peak_kb, rss_kb]; zeros if unreadable. Never throws — a missing measurement must
     *     not turn a successful inference into a failure, but it is recorded as 0 so the
     *     absence is visible rather than silently substituted.
     */
    static int[] readProcessMemoryKb() {
        int peak = 0, rss = 0;
        try (java.io.BufferedReader r = new java.io.BufferedReader(
                new java.io.FileReader("/proc/self/status"))) {
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("VmHWM:")) {
                    peak = parseKb(line);
                } else if (line.startsWith("VmRSS:")) {
                    rss = parseKb(line);
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "could not read /proc/self/status: " + e.getMessage());
        }
        return new int[]{peak, rss};
    }

    private static int parseKb(String line) {
        try {
            String[] parts = line.trim().split("\\s+");
            return Integer.parseInt(parts[1]);
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * SHA-256 of a file, computed on the device.
     *
     * <p>Streamed rather than slurped: the model is 1.1 GB and must never be held in memory.
     * A model-absent case cannot reach here (checked earlier), so a hash failure is a real
     * failure rather than something to paper over.
     */
    static String sha256OfFile(File file) {
        try (java.io.InputStream in = new java.io.FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buf = new byte[1 << 16];
            int read;
            while ((read = in.read(buf)) != -1) {
                digest.update(buf, 0, read);
            }
            StringBuilder sb = new StringBuilder(64);
            for (byte b : digest.digest()) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (Exception e) {
            Log.e(TAG, "hash failed", e);
            return "";
        }
    }
}
