import Foundation

/// bigmodel_async documents a 100-token context limit. Without its tokenizer,
/// use a deliberately conservative 96-byte serialized-JSON budget, NOT an
/// exact token estimate. No text prompt, speaker background or rewriting pass.
public enum DoubaoHotwordContext {
    public static let maximumContextUTF8Bytes = 96
    public static let maximumTerms = 8

    public struct Selection: Equatable, Sendable {
        public let terms: [String]
        public let context: String?
        public let droppedCount: Int
    }

    public static func select(_ candidates: [String]) -> Selection {
        var terms: [String] = []
        var seen: Set<String> = []
        var dropped = 0
        for candidate in candidates {
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted,
                  terms.count < maximumTerms else { dropped += 1; continue }
            let proposal = terms + [term]
            guard json(proposal).utf8.count <= maximumContextUTF8Bytes else { dropped += 1; continue }
            terms = proposal
        }
        return Selection(terms: terms, context: terms.isEmpty ? nil : json(terms), droppedCount: dropped)
    }

    private static func json(_ terms: [String]) -> String {
        "{\"hotwords\":[" + terms.map { "{\"word\":\"" + escaped($0) + "\"}" }.joined(separator: ",") + "]}"
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0..<0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
