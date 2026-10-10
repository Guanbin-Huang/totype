import Foundation
import SQLite3

struct PinyinCandidate: Equatable {
    let text: String
    /// Number of letters (not separators) consumed from the current composition.
    let consumedLetters: Int
}

/// Indexed, read-only queries keep the 65k-word resource outside the keyboard heap.
final class PinyinLexicon {
    private var database: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let database { sqlite3_close(database) }
            database = nil
            throw NSError(domain: "PinyinLexicon", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        let pragmas = sqlite3_exec(database, "PRAGMA cache_size=-512; PRAGMA mmap_size=0; PRAGMA query_only=ON;", nil, nil, nil)
        guard pragmas == SQLITE_OK else {
            let failure = error(pragmas)
            sqlite3_close(database)
            database = nil
            throw failure
        }
    }

    deinit { sqlite3_close(database) }

    func candidates(for input: String, limit: Int = 24) throws -> [PinyinCandidate] {
        let normalized = input.replacingOccurrences(of: "'", with: "").lowercased()
        guard !normalized.isEmpty else { return [] }
        // Input originates at the keyboard boundary; cap work for a long uncommitted spelling.
        guard normalized.count <= 64, normalized.utf8.allSatisfy({ (97...122).contains($0) }) else { return [] }
        let prefixes = (1...normalized.count).map { String(normalized.prefix($0)) }
        // Three bounded indexed queries: exact spelling, completed word prefixes, then abbreviations.
        let placeholders = prefixes.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT spelling,syllables,text FROM (
          SELECT spelling,syllables,text,weight,0 AS kind FROM entries WHERE spelling=?
          UNION ALL
          SELECT spelling,syllables,text,weight,1 AS kind FROM entries WHERE spelling IN (\(placeholders)) AND spelling<>?
          UNION ALL
          SELECT spelling,syllables,text,weight,2 AS kind FROM entries WHERE spelling>? AND spelling<?
        ) ORDER BY kind,CASE WHEN kind=1 THEN length(spelling) ELSE 0 END DESC,weight DESC,text LIMIT 160
        """
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK else { throw error(prepare) }
        defer { sqlite3_finalize(statement) }
        let arguments = [normalized] + prefixes + [normalized, normalized, normalized + "{"]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [PinyinCandidate] = []
        var seen: Set<String> = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let spelling = String(cString: sqlite3_column_text(statement, 0))
            let syllables = String(cString: sqlite3_column_text(statement, 1))
            let word = String(cString: sqlite3_column_text(statement, 2))
            let consumed = min(spelling.count, normalized.count)
            if matchesExplicitSeparators(input, syllables: syllables, consumed: consumed), seen.insert(word).inserted {
                result.append(PinyinCandidate(text: word, consumedLetters: consumed))
                if result.count == limit { return result }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw error(step) }
        return result
    }

    private func matchesExplicitSeparators(_ input: String, syllables: String, consumed: Int) -> Bool {
        var allowed: Set<Int> = []
        var letters = 0
        for character in syllables {
            if character == "'" { allowed.insert(letters) } else { letters += 1 }
        }
        letters = 0
        for character in input {
            if character == "'" {
                if letters < consumed && !allowed.contains(letters) { return false }
            } else { letters += 1 }
        }
        return true
    }

    private func error(_ code: Int32) -> NSError {
        NSError(domain: "PinyinLexicon", code: Int(code), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
    }
}

/// The UI and command-line tests use the same composition transitions.
struct PinyinComposition {
    private(set) var spelling = ""
    var hasComposition: Bool { !spelling.isEmpty }

    mutating func append(_ character: String) {
        guard spelling.count < 64 else { return }
        if character == "'" {
            if !spelling.isEmpty && !spelling.hasSuffix("'") { spelling += character }
        } else if character.count == 1, character.utf8.allSatisfy({ (97...122).contains($0) }) {
            spelling += character
        }
    }

    mutating func deleteBackward() { if !spelling.isEmpty { spelling.removeLast() } }

    mutating func select(_ candidate: PinyinCandidate) -> String {
        var remaining = candidate.consumedLetters
        while !spelling.isEmpty && remaining > 0 {
            let character = spelling.removeFirst()
            if character != "'" { remaining -= 1 }
        }
        while spelling.hasPrefix("'") { spelling.removeFirst() }
        return candidate.text
    }

    mutating func commit(_ candidate: PinyinCandidate?) -> String {
        guard hasComposition else { return "" }
        guard let candidate else { let raw = spelling; spelling = ""; return raw }
        return select(candidate)
    }

    mutating func takeRaw() -> String { let raw = spelling; spelling = ""; return raw }
}
