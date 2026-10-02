package com.pixeldesktop.worker;

/**
 * The single Java-side contact point with the native inference runtime.
 *
 * <p>ADR-012 §2: llama.cpp is a replaceable runtime adapter. This class is the whole of the
 * Android side of that boundary — nothing else in the app references the native library, and
 * the native library knows nothing about jobs, files, or JSON envelopes. It takes a path and a
 * prompt, and returns a JSON string.
 *
 * <p>The native library is loaded from the APK's own native library directory. This is the
 * only executable location available to us: the reconnaissance established that
 * /storage/emulated is mounted {@code noexec}, so a runtime could never be executed from the
 * exchange directory.
 */
final class LlamaBridge {

    private static final String LIBRARY_NAME = "pdllama";

    /** Set once at class load. If the library cannot load, every later call fails explicitly. */
    private static final boolean LOADED;
    private static final String LOAD_ERROR;

    static {
        boolean ok = false;
        String error = null;
        try {
            System.loadLibrary(LIBRARY_NAME);
            ok = true;
        } catch (UnsatisfiedLinkError e) {
            // Never swallowed: a missing native library must surface as a real failure, not as
            // an empty generation. ADR-012 §13.
            error = "UnsatisfiedLinkError loading " + LIBRARY_NAME + ": " + e.getMessage();
        }
        LOADED = ok;
        LOAD_ERROR = error;
    }

    private LlamaBridge() {}

    static boolean isAvailable() {
        return LOADED;
    }

    static String loadError() {
        return LOAD_ERROR;
    }

    /** Runtime identity, so evidence can name the runtime that produced a result. */
    static native String nativeRuntimeInfo();

    /**
     * Loads a GGUF model from an absolute path.
     *
     * @return an opaque handle, or 0 on failure. 0 is a real failure and is never treated as
     *     success.
     */
    static native long nativeLoadModel(String absolutePath);

    static native void nativeFree(long handle);

    /** Model metadata as JSON, without generating anything. */
    static native String nativeModelInfo(long handle);

    /**
     * Greedy generation.
     *
     * @param prompt the prompt, already formatted with the model's chat template by the caller
     * @return JSON with the text, token ids and timings, or {"error":...}
     */
    static native String nativeGenerate(long handle, String prompt, int maxTokens, int seed);
}
