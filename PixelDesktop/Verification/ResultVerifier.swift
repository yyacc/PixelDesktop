import Foundation

struct VerificationResult: Equatable {
    let isVerified: Bool
    let mismatches: [String]

    static let success = VerificationResult(isVerified: true, mismatches: [])
    static func failure(_ mismatches: [String]) -> VerificationResult {
        VerificationResult(isVerified: false, mismatches: mismatches)
    }
}

enum ResultVerifier {
    static func verify(pixelResult: DTCA1Result, localResult: DTCA1Result, originalInput: String) -> VerificationResult {
        var mismatches: [String] = []

        if pixelResult.status != "COMPLETED" {
            mismatches.append("Status is not COMPLETED: \(pixelResult.status)")
        }

        if pixelResult.inputCharacters != originalInput.count {
            mismatches.append("Input character count mismatch: pixel=\(pixelResult.inputCharacters), expected=\(originalInput.count)")
        }

        if pixelResult.totalWords != localResult.totalWords {
            mismatches.append("Total word count mismatch: pixel=\(pixelResult.totalWords), local=\(localResult.totalWords)")
        }

        if pixelResult.uniqueWords != localResult.uniqueWords {
            mismatches.append("Unique word count mismatch: pixel=\(pixelResult.uniqueWords), local=\(localResult.uniqueWords)")
        }

        if pixelResult.classification != localResult.classification {
            mismatches.append("Classification mismatch: pixel=\(pixelResult.classification), local=\(localResult.classification)")
        }

        let confidenceDiff = abs(pixelResult.confidence - localResult.confidence)
        if confidenceDiff > 0.01 {
            mismatches.append("Confidence mismatch: pixel=\(pixelResult.confidence), local=\(localResult.confidence), diff=\(confidenceDiff)")
        }

        let pixelTopWords = pixelResult.topWords
        let localTopWords = localResult.topWords
        if pixelTopWords.count != localTopWords.count {
            mismatches.append("Top words count mismatch: pixel=\(pixelTopWords.count), local=\(localTopWords.count)")
        } else {
            for (index, pixelWord) in pixelTopWords.enumerated() {
                let localWord = localTopWords[index]
                if pixelWord.word != localWord.word || pixelWord.count != localWord.count {
                    mismatches.append("Top word mismatch at index \(index): pixel=(\(pixelWord.word), \(pixelWord.count)), local=(\(localWord.word), \(localWord.count))")
                }
            }
        }

        if mismatches.isEmpty {
            return .success
        } else {
            return .failure(mismatches)
        }
    }
}
