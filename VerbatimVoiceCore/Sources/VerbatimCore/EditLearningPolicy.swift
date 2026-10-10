import Foundation

public enum EditLearningDecision: Equatable, Sendable {
    case ignore
    case correction(original: String, corrected: String)
    case needsConfirmation(original: String, corrected: String)
}

/// Local attribution, not semantic understanding. A single short replacement
/// is automatic only for case/format identity or an explicitly known target.
/// Known-term changes are vocabulary evidence, not proof of semantic equivalence;
/// known-to-known changes always require review. Additions never become vocabulary.
/// Work is capped at 512 tokens.
public enum EditLearningPolicy {
    public static let observationDuration: TimeInterval = 10

    public static func classify(original: String, edited: String, knownTerms: [String] = []) -> EditLearningDecision {
        guard original != edited, !original.isEmpty else { return .ignore }
        // Linear, grapheme-safe subsequence check catches insertions anywhere,
        // including several disjoint insertions in a single AX snapshot.
        var cursor = original.startIndex
        for character in edited where cursor != original.endIndex {
            if original[cursor] == character { cursor = original.index(after: cursor) }
        }
        if cursor == original.endIndex { return .ignore }
        guard original.utf16.count <= 4_096, edited.utf16.count <= 4_096 else { return .ignore }
        let old = tokens(original), new = tokens(edited)
        guard old.count <= 512, new.count <= 512 else { return .ignore }
        let width = new.count + 1
        var lengths = [Int](repeating: 0, count: (old.count + 1) * width)
        for i in old.indices.reversed() {
            for j in new.indices.reversed() {
                lengths[i * width + j] = old[i] == new[j]
                    ? 1 + lengths[(i + 1) * width + j + 1]
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        var ambiguous = false
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                matches.append((i, j)); i += 1; j += 1
            } else {
                let down = lengths[(i + 1) * width + j], right = lengths[i * width + j + 1]
                // A zero tie is an ordinary replacement; a nonzero tie admits
                // competing anchors and must never be learned automatically.
                if down == right, down > 0 {
                    if i + 1 < old.count, j + 1 < new.count, old[i + 1] == new[j + 1] {
                        i += 1; j += 1; continue
                    }
                    ambiguous = true
                }
                if down >= right { i += 1 } else { j += 1 }
            }
        }
        matches.append((old.count, new.count))
        var oldStart = 0, newStart = 0
        var changes: [(String, String)] = []
        for (oldEnd, newEnd) in matches {
            if oldEnd > oldStart {
                changes.append((old[oldStart..<oldEnd].joined(), new[newStart..<newEnd].joined()))
            }
            oldStart = oldEnd + 1; newStart = newEnd + 1
        }
        guard !changes.isEmpty else { return .ignore }
        let before = changes.map { $0.0 }.joined(separator: " … ")
        let after = changes.map { $0.1 }.joined(separator: " … ")
        guard changes.count == 1, !ambiguous else {
            return .needsConfirmation(original: before, corrected: after)
        }
        let term = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let correction = after.trimmingCharacters(in: .whitespacesAndNewlines)
        let semanticWords: Set<String> = ["no", "not", "never", "true", "false", "yes", "can", "cannot", "can't", "don't", "enable", "disable", "enabled", "disabled", "allow", "deny", "不", "没", "无", "是", "否"]
        let risky = semanticWords.contains(term.lowercased()) || semanticWords.contains(correction.lowercased())
            || (term + correction).contains(where: { $0.isNumber })
            || ["不", "没", "无", "否"].contains(where: { (term + correction).contains($0) })
        let repeated = occursMoreThanOnce(term, in: original) || occursMoreThanOnce(correction, in: edited)
        let normalizedOriginal = normalizedTerm(term)
        let normalizedCorrection = normalizedTerm(correction)
        // Small explicit product vocabulary. Prefix resemblance alone is not
        // evidence: security -> securities, for example, changes meaning.
        let vocabulary = ["opentypeless", "kubernetes", "chatgpt", "claude", "codex", "swift", "python"] + knownTerms
        let knownTarget = vocabulary.contains { normalizedTerm($0) == normalizedCorrection }
        let knownOriginal = vocabulary.contains { normalizedTerm($0) == normalizedOriginal }
        let identity = !normalizedOriginal.isEmpty && normalizedOriginal == normalizedCorrection
        if !risky, !repeated, term.count <= 64, correction.count <= 64,
           !term.isEmpty, !correction.isEmpty,
           (identity || (knownTarget && !knownOriginal)) {
            return .correction(original: term, corrected: correction)
        }
        return .needsConfirmation(original: before, corrected: after)
    }

    private static func normalizedTerm(_ term: String) -> String {
        term.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    private static func occursMoreThanOnce(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty, let first = text.range(of: term) else { return false }
        return text.range(of: term, range: first.upperBound..<text.endIndex) != nil
    }

    private static func isLatinWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        for character in text {
            if isLatinWord(String(character)) || character.isNumber || character == "'" {
                word.append(character)
            } else {
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(character))
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }
}

/// Deterministic stability/deadline state shared by desktop observation tests.
/// `elapsed` is measured from invocation, never from the first successful read.
public struct EditLearningObservationState: Sendable {
    private var lastText: String?
    private var stableSince: TimeInterval = 0
    private var delivered: [EditLearningDecision] = []
    private let original: String
    private let duration: TimeInterval

    public init(original: String, duration: TimeInterval = EditLearningPolicy.observationDuration) {
        self.original = original
        self.duration = min(EditLearningPolicy.observationDuration, max(0, duration))
    }

    public mutating func observe(edited: String, elapsed: TimeInterval) -> EditLearningDecision {
        guard elapsed >= 0, elapsed < duration else { return .ignore }
        if edited != lastText {
            lastText = edited
            stableSince = elapsed
            return .ignore
        }
        guard elapsed - stableSince >= 1.1 else { return .ignore }
        let decision = EditLearningPolicy.classify(original: original, edited: edited)
        guard decision != .ignore, !delivered.contains(decision) else { return .ignore }
        delivered.append(decision)
        return decision
    }
}
