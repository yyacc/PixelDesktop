package com.pixeldesktop.worker;

import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * The second inference backend for {@code LOCAL-LLM-1}: the on-device {@code llama-server}.
 *
 * <h2>Why this exists</h2>
 *
 * <p>{@link LlmWorkload}'s original path is self-contained: this APK ships llama.cpp, loads one
 * fixed GGUF from its own files directory, and samples greedily in-process. That design has a
 * property the project now needs to change: <em>the model is a compile-time constant</em>. A job
 * cannot ask for a different model, and the only model the worker will ever accept is the one
 * whose filename is baked into {@link LlmWorkload#MODEL_FILE_NAME}.
 *
 * <p>Separately, and already verified end to end, the Pixel runs {@code llama-server} (installed
 * from Termux, serving Gemma 3n E4B from Termux's private home). That runtime loads its model at
 * startup and applies the model's <em>own</em> chat template from the GGUF metadata.
 *
 * <p>This class connects those two facts with as little new machinery as possible. The worker
 * stays the thing that owns the job, the bounds, the envelope and the result file; it delegates
 * only token generation to the already-running server. Model selection therefore stops being a
 * property of the worker build and becomes a property of what the server is serving, described by
 * the server at request time.
 *
 * <h2>What this backend deliberately does NOT do</h2>
 *
 * <ul>
 *   <li><b>It does not start or stop the server.</b> Process lifecycle belongs to the host
 *       (Termux), not to a bounded task whose process lives for a few seconds. If the server is
 *       not listening, the result is {@code BACKEND_UNAVAILABLE} — an accurate report, not a
 *       failure to retry.</li>
 *   <li><b>It does not take an endpoint from the job.</b> The URL is a private constant. Combined
 *       with the loopback literal, the {@code INTERNET} permission this backend requires can only
 *       ever reach the local server; a job document cannot redirect it.</li>
 *   <li><b>It does not pretend to know what it cannot see.</b> The model's SHA-256 lives under
 *       Termux's private data directory, which this process cannot read. {@code model_sha256} is
 *       reported as the empty string with {@code model_sha256_source = "unavailable"}, rather than
 *       hashing something else and implying a provenance link that does not exist.</li>
 * </ul>
 *
 * <p>The envelope it returns is field-for-field the one {@link LlmWorkload} returns, so the Mac
 * side decodes both without knowing which backend produced the text. Fields that only make sense
 * for in-process inference are reported as unmeasured-zero or absent, never as a plausible-looking
 * substitute.
 */
final class HttpInferenceBackend {

    private static final String TAG = "HttpInferenceBackend";

    /** Stable id for this backend, written into the result so the evidence names its producer. */
    static final String BACKEND_ID = "llama-server-http";

    /**
     * Fixed endpoint. Not job-controllable, deliberately: a literal loopback address is the whole
     * containment story for the INTERNET permission this backend needs. See AndroidManifest.xml.
     */
    private static final String ENDPOINT = "http://127.0.0.1:8080/v1/chat/completions";

    /** Connect is local; if it is not nearly instant, nothing is listening. */
    private static final int CONNECT_TIMEOUT_MS = 3000;

    /**
     * Read timeout covers generation, not the socket read alone: with {@code stream=false} the
     * server sends nothing until the answer is complete. The worker's own token ceiling is 256 and
     * measured device throughput is 4.5–6.8 tok/s, so 256 tokens is under 60 s. 180 s leaves ~3x
     * headroom without letting a wedged request hold the worker forever.
     */
    private static final int READ_TIMEOUT_MS = 180_000;

    /** Same fixed system turn as the in-process path, so the two backends stay comparable. */
    private static final String SYSTEM_PROMPT = "You are a helpful assistant.";

    private HttpInferenceBackend() {}

    /**
     * Runs one bounded completion through the server and returns a {@link LlmWorkload}-shaped
     * result envelope.
     *
     * <p>Validation of prompt length, token ceiling and greedy-only decoding has already happened
     * in {@link LlmWorkload#execute}; this method assumes a valid request and never re-decides
     * those bounds.
     */
    static JSONObject execute(String jobId, String prompt, int maxTokens, int seed)
            throws LlmWorkload.Failure {

        // WHY THIS THREAD EXISTS - discovered by real-device failure, not assumed.
        //
        // The first run that got past the cleartext policy died with:
        //
        //   WORKER_FAILED type=BACKEND_ERROR android.os.NetworkOnMainThreadException (no message)
        //
        // WorkerActivity executes the job in onCreate, i.e. on the main thread, and StrictMode
        // blocks Java sockets there. The in-process backend was never exposed to this because it
        // does its work in native code, which StrictMode does not police. So the blocking request
        // is moved to a plain thread and joined.
        //
        // The join ceiling is deliberately LONGER than the connect plus read timeouts, so those
        // fire first and keep their own honest categories (BACKEND_UNAVAILABLE / BACKEND_TIMEOUT)
        // instead of every slow request being reported as a generic wrapper timeout.
        final JSONObject[] result = new JSONObject[1];
        final LlmWorkload.Failure[] failure = new LlmWorkload.Failure[1];

        Thread request = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    result[0] = performRequest(jobId, prompt, maxTokens, seed);
                } catch (LlmWorkload.Failure f) {
                    failure[0] = f;
                } catch (Throwable t) {
                    Log.e(TAG, "backend request crashed", t);
                    failure[0] = new LlmWorkload.Failure("BACKEND_ERROR", t.toString());
                }
            }
        }, "llama-server-http");
        request.setDaemon(true);
        request.start();

        long joinCeilingMs = (long) CONNECT_TIMEOUT_MS + (long) READ_TIMEOUT_MS + 5000L;
        try {
            request.join(joinCeilingMs);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new LlmWorkload.Failure("BACKEND_ERROR",
                    "interrupted while waiting for llama-server");
        }

        if (request.isAlive()) {
            throw new LlmWorkload.Failure("BACKEND_TIMEOUT",
                    "llama-server request still running after " + joinCeilingMs + " ms");
        }
        if (failure[0] != null) {
            throw failure[0];
        }
        if (result[0] == null) {
            throw new LlmWorkload.Failure("BACKEND_ERROR", "backend produced no result");
        }
        return result[0];
    }

    /**
     * The blocking half: builds the OpenAI-shaped body, POSTs it, and maps the reply into the
     * worker's envelope. Runs on a thread that has no Looper; see {@link #execute}.
     */
    private static JSONObject performRequest(String jobId, String prompt, int maxTokens, int seed)
            throws LlmWorkload.Failure {

        long totalStart = System.currentTimeMillis();

        HttpURLConnection conn = null;
        try {
            JSONObject body = new JSONObject();
            JSONArray messages = new JSONArray();
            messages.put(new JSONObject().put("role", "system").put("content", SYSTEM_PROMPT));
            messages.put(new JSONObject().put("role", "user").put("content", prompt));
            body.put("messages", messages);
            body.put("max_tokens", maxTokens);
            // Greedy, matching LlmWorkload's contract. The server applies the model's own chat
            // template, which is the point of this backend: no template lives in this APK.
            body.put("temperature", 0.0);
            body.put("seed", seed);
            body.put("stream", false);

            byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);

            conn = (HttpURLConnection) new URL(ENDPOINT).openConnection();
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            conn.setRequestProperty("Accept", "application/json");
            conn.setRequestProperty("Connection", "close");
            conn.setConnectTimeout(CONNECT_TIMEOUT_MS);
            conn.setReadTimeout(READ_TIMEOUT_MS);
            conn.setDoOutput(true);

            try (OutputStream out = conn.getOutputStream()) {
                out.write(payload);
            }

            int status = conn.getResponseCode();
            String responseBody = readBody(
                    status >= 400 ? conn.getErrorStream() : conn.getInputStream());
            long wallMs = System.currentTimeMillis() - totalStart;

            if (status < 200 || status >= 300) {
                throw new LlmWorkload.Failure("BACKEND_ERROR",
                        "server returned HTTP " + status + ": " + truncate(responseBody));
            }

            JSONObject doc;
            try {
                doc = new JSONObject(responseBody);
            } catch (Exception parseError) {
                throw new LlmWorkload.Failure("BACKEND_BAD_RESPONSE",
                        "response was not JSON: " + truncate(responseBody));
            }

            JSONArray choices = doc.optJSONArray("choices");
            if (choices == null || choices.length() == 0) {
                throw new LlmWorkload.Failure("BACKEND_BAD_RESPONSE", "response had no choices");
            }
            JSONObject choice = choices.optJSONObject(0);
            JSONObject message = choice == null ? null : choice.optJSONObject("message");
            String content = message == null ? null : message.optString("content", null);
            if (content == null) {
                throw new LlmWorkload.Failure("BACKEND_BAD_RESPONSE",
                        "response had no choices[0].message.content");
            }

            JSONObject usage = doc.optJSONObject("usage");
            JSONObject timings = doc.optJSONObject("timings");

            int generatedTokens = usage == null ? 0 : usage.optInt("completion_tokens", 0);
            int promptTokens = usage == null ? 0 : usage.optInt("prompt_tokens", 0);

            // The server reports milliseconds directly; no conversion, no re-derivation.
            long promptEvalMs = timings == null
                    ? 0 : Math.round(timings.optDouble("prompt_ms", 0.0));
            long generationMs = timings == null
                    ? 0 : Math.round(timings.optDouble("predicted_ms", 0.0));

            // Whatever the server says it is serving. llama-server reports the full model path;
            // the filename is what the evidence compares, the same field shape as the JNI path.
            String modelFileName = basename(doc.optString("model", ""));

            JSONObject runtime = new JSONObject();
            runtime.put("name", "llama.cpp-server");
            // The server exposes no build id over HTTP (/props carries none), so this is stated as
            // unknown rather than copied from a source pin that may not match the running binary.
            runtime.put("version", "unknown");
            // Compute backend. llama-server's HTTP surface (/props, /slots, /health) carries no
            // device attribution, and this worker is a different process in a different SELinux
            // domain, so it cannot read the server's argv or its ggml init log. The previous
            // hardcoded "cpu" asserted something the request cannot observe: which device runs the
            // tokens is decided when the *server* starts (-ngl), not by which side of the socket
            // sent the request. Unknown until an observer that can see the server attests it —
            // scripts/pixel-gpu/serve.sh greps the ggml Vulkan lines out of the server log.
            runtime.put("backend", "unknown");
            runtime.put("backend_source", "not_observable_over_http");

            JSONObject result = new JSONObject();
            result.put("status", "OK");
            result.put("job_id", jobId);
            result.put("workload", LlmWorkload.WORKLOAD_NAME);
            result.put("text", content);
            // This endpoint returns text, not ids. Empty rather than fabricated: a caller that
            // compares token ids must see that this backend cannot supply them.
            result.put("token_ids", new JSONArray());
            result.put("generated_tokens", generatedTokens);
            result.put("prompt_tokens", promptTokens);
            // The server was already holding the model when it answered, so there is no load step
            // in this request. Zero is a fact here, and model_resident says why.
            result.put("model_load_ms", 0);
            result.put("prompt_eval_ms", promptEvalMs);
            result.put("generation_ms", generationMs);
            result.put("total_ms", wallMs);
            result.put("runtime", runtime);
            result.put("model_file", modelFileName);
            result.put("model_sha256", "");
            result.put("model_sha256_source", "unavailable");
            result.put("model_resident", true);
            result.put("backend", BACKEND_ID);
            result.put("inference_process", "external");

            // This process's own memory. Honest but small: inference happens in the server's
            // process, whose /proc entry this app cannot read, so those bytes are absent rather
            // than estimated.
            int[] mem = LlmWorkload.readProcessMemoryKb();
            result.put("vm_peak_kb", mem[0]);
            result.put("vm_rss_kb", mem[1]);

            result.put("execution_timestamp_ms", System.currentTimeMillis());

            return result;

        } catch (LlmWorkload.Failure f) {
            throw f;
        } catch (ConnectException e) {
            throw new LlmWorkload.Failure("BACKEND_UNAVAILABLE",
                    "no llama-server listening on " + ENDPOINT + " (" + e.getMessage() + ")");
        } catch (SocketTimeoutException e) {
            throw new LlmWorkload.Failure("BACKEND_TIMEOUT",
                    "llama-server did not answer within " + READ_TIMEOUT_MS + " ms");
        } catch (Exception e) {
            // The trace, not just the message. An exception whose message is null (a
            // RuntimeException such as NetworkOnMainThreadException, or some IOExceptions)
            // reported as String.valueOf(getMessage()) surfaces as the useless token "null",
            // which is exactly what the first real run produced.
            Log.e(TAG, "backend request to " + ENDPOINT + " failed", e);
            throw new LlmWorkload.Failure("BACKEND_ERROR",
                    e.getClass().getName()
                            + (e.getMessage() == null ? " (no message)" : (": " + e.getMessage())));
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private static String readBody(InputStream in) throws Exception {
        if (in == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(in, StandardCharsets.UTF_8))) {
            char[] buf = new char[4096];
            int read;
            while ((read = reader.read(buf)) != -1) {
                sb.append(buf, 0, read);
            }
        }
        return sb.toString();
    }

    private static String basename(String path) {
        if (path == null) {
            return "";
        }
        int slash = path.lastIndexOf('/');
        return slash >= 0 ? path.substring(slash + 1) : path;
    }

    private static String truncate(String s) {
        if (s == null) {
            return "";
        }
        return s.length() <= 300 ? s : s.substring(0, 300) + "…";
    }
}
