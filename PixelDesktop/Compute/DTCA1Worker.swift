import Foundation

struct DTCA1Result: Codable, Equatable {
    let status: String
    let inputCharacters: Int
    let totalWords: Int
    let uniqueWords: Int
    let topWords: [WordCount]
    let classification: String
    let confidence: Double
    let executionTimestampMs: Int64
    let executionDurationMs: Int64

    enum CodingKeys: String, CodingKey {
        case status
        case inputCharacters = "input_characters"
        case totalWords = "total_words"
        case uniqueWords = "unique_words"
        case topWords = "top_words"
        case classification
        case confidence
        case executionTimestampMs = "execution_timestamp_ms"
        case executionDurationMs = "execution_duration_ms"
    }
}

struct WordCount: Codable, Equatable {
    let word: String
    let count: Int
}

enum DTCA1Classification: String {
    case technical = "TECHNICAL"
    case naturalLanguage = "NATURAL_LANGUAGE"
    case mixed = "MIXED"
}

enum DTCA1Worker {
    static let technicalKeywords: Set<String> = [
        "api", "code", "function", "class", "data", "server", "client",
        "http", "adb", "pixel", "compute", "model", "inference", "memory",
        "cpu", "gpu", "ram", "storage", "latency", "thread", "process",
        "shell", "command", "script", "file", "json", "xml", "debug",
        "build", "deploy", "test", "verify", "error", "log", "config",
        "network", "port", "socket", "async", "sync", "queue", "pool",
        "worker", "task", "job", "schedule", "resource", "monitor",
        "heap", "stack", "binary", "compile", "runtime", "virtual",
        "machine", "container", "bridge", "transport", "protocol", "interface"
    ]

    static let naturalLanguageWords: Set<String> = [
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
    ]

    static func validateInput(_ text: String) throws {
        if text.isEmpty {
            throw PixelDesktopError.invalidInput("Input text is empty")
        }
        if text.count > 10_000 {
            throw PixelDesktopError.invalidInput("Input exceeds maximum size of 10,000 characters (got \(text.count))")
        }
        if text.contains("\0") {
            throw PixelDesktopError.invalidInput("Input contains null bytes")
        }
    }

    static func tokenize(_ text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return text
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    static func computeWordFrequency(_ words: [String]) -> [String: Int] {
        var frequency: [String: Int] = [:]
        for word in words {
            frequency[word, default: 0] += 1
        }
        return frequency
    }

    static func classify(words: [String]) -> (DTCA1Classification, Double) {
        guard !words.isEmpty else {
            return (.mixed, 0.0)
        }

        var technicalCount = 0
        var naturalCount = 0

        for word in words {
            if technicalKeywords.contains(word) {
                technicalCount += 1
            }
            if naturalLanguageWords.contains(word) {
                naturalCount += 1
            }
        }

        let total = words.count
        let technicalRatio = Double(technicalCount) / Double(total)
        let naturalRatio = Double(naturalCount) / Double(total)

        if technicalRatio > naturalRatio && technicalRatio > 0.1 {
            return (.technical, technicalRatio)
        } else if naturalRatio > technicalRatio && naturalRatio > 0.1 {
            return (.naturalLanguage, naturalRatio)
        } else {
            return (.mixed, max(technicalRatio, naturalRatio))
        }
    }

    static func execute(_ input: String) throws -> DTCA1Result {
        try validateInput(input)

        let startTime = Date()
        let words = tokenize(input)
        let frequency = computeWordFrequency(words)
        let (classification, confidence) = classify(words: words)

        let sortedWords = frequency.sorted { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value > rhs.value
            }
            return lhs.key < rhs.key
        }

        let topWords = sortedWords.prefix(5).map { WordCount(word: $0.key, count: $0.value) }

        let endTime = Date()
        let durationMs = Int64(endTime.timeIntervalSince(startTime) * 1000)
        let timestampMs = Int64(endTime.timeIntervalSince1970 * 1000)

        return DTCA1Result(
            status: "COMPLETED",
            inputCharacters: input.count,
            totalWords: words.count,
            uniqueWords: frequency.count,
            topWords: topWords,
            classification: classification.rawValue,
            confidence: confidence,
            executionTimestampMs: timestampMs,
            executionDurationMs: durationMs
        )
    }
}
