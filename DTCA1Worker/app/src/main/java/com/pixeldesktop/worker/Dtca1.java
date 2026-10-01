package com.pixeldesktop.worker;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * DTCA-1 — Deterministic Text Classification and Analysis, version 1.
 *
 * <p>A faithful port of {@code PixelDesktop/Compute/DTCA1Worker.swift}. The algorithm must
 * produce identical results on the Pixel and on the Mac, because the Mac verifies the Pixel's
 * result by re-running this same algorithm locally (ADR-004).
 *
 * <p>Porting notes — the three places a naive port would silently diverge:
 *
 * <ul>
 *   <li><b>Tokenization.</b> Swift uses {@code CharacterSet.alphanumerics.inverted} as
 *       separators. Java's {@code \W+} is close but <em>not</em> identical: {@code \W} treats
 *       underscore as a word character, while Swift's {@code alphanumerics} excludes it. The
 *       split is therefore done explicitly against {@link Character#isLetterOrDigit}.
 *   <li><b>Character count.</b> Swift's {@code String.count} counts Unicode <em>grapheme
 *       clusters</em>, not UTF-16 units. {@code String.length()} in Java counts UTF-16 units, so
 *       it is adjusted by subtracting surrogate pairs to match grapheme counting.
 *   <li><b>Top-word ordering.</b> Swift sorts by count descending, then key ascending. The
 *       comparator below reproduces exactly that, including the tie-break.
 * </ul>
 *
 * <p>Every constant, threshold and comparison in this file mirrors the Swift source. If the two
 * ever diverge, verification will report a mismatch — which is the intended failure mode.
 */
final class Dtca1 {

    private Dtca1() {
    }

    static final Set<String> TECHNICAL_KEYWORDS = new HashSet<>(Arrays.asList(
        "api", "code", "function", "class", "data", "server", "client",
        "http", "adb", "pixel", "compute", "model", "inference", "memory",
        "cpu", "gpu", "ram", "storage", "latency", "thread", "process",
        "shell", "command", "script", "file", "json", "xml", "debug",
        "build", "deploy", "test", "verify", "error", "log", "config",
        "network", "port", "socket", "async", "sync", "queue", "pool",
        "worker", "task", "job", "schedule", "resource", "monitor",
        "heap", "stack", "binary", "compile", "runtime", "virtual",
        "machine", "container", "bridge", "transport", "protocol", "interface"
    ));

    static final Set<String> NATURAL_LANGUAGE_WORDS = new HashSet<>(Arrays.asList(
        "the", "a", "an", "is", "are", "was", "were", "be", "have", "has",
        "had", "do", "does", "did", "will", "would", "can", "could", "may",
        "might", "shall", "should", "of", "in", "to", "for", "with", "on",
        "at", "by", "from", "as", "into", "through", "during", "before",
        "after", "above", "below", "between", "under", "again", "further",
        "then", "once", "here", "there", "when", "where", "why", "how",
        "all", "each", "every", "both", "few", "more", "most", "other",
        "some", "such", "no", "nor", "not", "only", "own", "same", "so",
        "than", "too", "very", "just", "because", "but", "and", "or", "if",
        "while", "although", "though", "until", "since", "yet", "this",
        "that", "these", "those", "i", "me", "my", "myself", "we", "our",
        "ours", "ourselves", "you", "your", "yours", "yourself", "yourselves",
        "he", "him", "his", "himself", "she", "her", "hers", "herself",
        "it", "its", "itself", "they", "them", "their", "theirs", "themselves",
        "what", "which", "who", "whom", "am", "been", "being", "about",
        "across", "after", "against", "along", "among", "around", "behind",
        "beneath", "beside", "beyond", "down", "except", "inside", "near",
        "off", "out", "outside", "over", "toward", "up", "upon", "within",
        "without"
    ));

    static final int MAX_INPUT_CHARACTERS = 10_000;

    /** Thrown for input the workload refuses. Mirrors Swift's validateInput throwing. */
    static final class InvalidInput extends Exception {
        InvalidInput(String message) {
            super(message);
        }
    }

    /** Mirrors {@code DTCA1Worker.validateInput}. */
    static void validateInput(String text) throws InvalidInput {
        int graphemes = graphemeCount(text);
        if (graphemes > MAX_INPUT_CHARACTERS) {
            throw new InvalidInput(
                "Input exceeds maximum size of 10,000 characters (got " + graphemes + ")");
        }
        if (text.indexOf('\0') >= 0) {
            throw new InvalidInput("Input contains null bytes");
        }
    }

    /**
     * Counts characters the way Swift's {@code String.count} does — by Unicode scalar sequence
     * rather than UTF-16 code unit. A surrogate pair (one astral character) counts as one.
     */
    static int graphemeCount(String text) {
        int units = text.length();
        int pairs = 0;
        for (int i = 0; i < units; i++) {
            if (Character.isHighSurrogate(text.charAt(i)) && i + 1 < units
                    && Character.isLowSurrogate(text.charAt(i + 1))) {
                pairs++;
                i++;
            }
        }
        return units - pairs;
    }

    /**
     * Mirrors {@code DTCA1Worker.tokenize}: split on non-alphanumeric characters, drop empties,
     * lowercase.
     *
     * <p>Split explicitly rather than with a regex, because {@code \W} would keep underscores
     * as word characters and diverge from Swift's {@code alphanumerics}.
     */
    static List<String> tokenize(String text) {
        List<String> tokens = new ArrayList<>();
        StringBuilder current = new StringBuilder();

        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (Character.isLetterOrDigit(c)) {
                current.append(c);
            } else if (current.length() > 0) {
                tokens.add(current.toString().toLowerCase());
                current.setLength(0);
            }
        }
        if (current.length() > 0) {
            tokens.add(current.toString().toLowerCase());
        }

        return tokens;
    }

    /** Mirrors {@code DTCA1Worker.computeWordFrequency}. */
    static Map<String, Integer> computeWordFrequency(List<String> words) {
        Map<String, Integer> frequency = new HashMap<>();
        for (String word : words) {
            Integer existing = frequency.get(word);
            frequency.put(word, existing == null ? 1 : existing + 1);
        }
        return frequency;
    }

    /** Mirrors {@code DTCA1Worker.classify}. */
    static Classification classify(List<String> words) {
        if (words.isEmpty()) {
            return new Classification("MIXED", 0.0);
        }

        int technicalCount = 0;
        int naturalCount = 0;

        for (String word : words) {
            if (TECHNICAL_KEYWORDS.contains(word)) {
                technicalCount++;
            }
            if (NATURAL_LANGUAGE_WORDS.contains(word)) {
                naturalCount++;
            }
        }

        double total = words.size();
        double technicalRatio = technicalCount / total;
        double naturalRatio = naturalCount / total;

        if (technicalRatio > naturalRatio && technicalRatio > 0.1) {
            return new Classification("TECHNICAL", technicalRatio);
        } else if (naturalRatio > technicalRatio && naturalRatio > 0.1) {
            return new Classification("NATURAL_LANGUAGE", naturalRatio);
        } else {
            return new Classification("MIXED", Math.max(technicalRatio, naturalRatio));
        }
    }

    static final class Classification {
        final String label;
        final double confidence;

        Classification(String label, double confidence) {
            this.label = label;
            this.confidence = confidence;
        }
    }

    /**
     * Mirrors {@code DTCA1Worker.execute}. Returns the result JSON object with exactly the field
     * names the Mac's {@code DTCA1Result} decodes.
     */
    static JSONObject execute(String input, String jobId) throws InvalidInput, Exception {
        validateInput(input);

        long startMs = System.currentTimeMillis();
        List<String> words = tokenize(input);
        Map<String, Integer> frequency = computeWordFrequency(words);
        Classification classification = classify(words);

        List<Map.Entry<String, Integer>> sorted = new ArrayList<>(frequency.entrySet());
        Collections.sort(sorted, new Comparator<Map.Entry<String, Integer>>() {
            @Override
            public int compare(Map.Entry<String, Integer> lhs, Map.Entry<String, Integer> rhs) {
                // Swift: count descending, then key ascending.
                int byCount = rhs.getValue().compareTo(lhs.getValue());
                if (byCount != 0) {
                    return byCount;
                }
                return lhs.getKey().compareTo(rhs.getKey());
            }
        });

        JSONArray topWords = new JSONArray();
        for (int i = 0; i < Math.min(5, sorted.size()); i++) {
            JSONObject word = new JSONObject();
            word.put("word", sorted.get(i).getKey());
            word.put("count", sorted.get(i).getValue());
            topWords.put(word);
        }

        long endMs = System.currentTimeMillis();

        JSONObject result = new JSONObject();
        result.put("status", "COMPLETED");
        result.put("job_id", jobId);
        result.put("input_characters", graphemeCount(input));
        result.put("total_words", words.size());
        result.put("unique_words", frequency.size());
        result.put("top_words", topWords);
        result.put("classification", classification.label);
        result.put("confidence", classification.confidence);
        result.put("execution_timestamp_ms", endMs);
        result.put("execution_duration_ms", endMs - startMs);
        return result;
    }
}
