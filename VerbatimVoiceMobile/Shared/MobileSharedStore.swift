import Foundation
import Security

struct MobilePendingTranscript: Codable {
    let id: UUID
    let text: String
    let createdAt: Date
    var consumed: Bool
}
struct MobileCorrection: Codable, Identifiable {
    let id: UUID
    let original: String
    let corrected: String
    var confirmations: Int
    var needsConfirmation: Bool
}
struct MobileVocabulary: Codable {
    var terms: [String] = []
    var candidates: [MobileCorrection] = []
}

enum MobileStoreError: LocalizedError {
    case keychain(OSStatus), fullAccessRequired, invalidCredential, verificationFailed, transcriptTooLarge
    var errorDescription: String? {
        switch self {
        case .keychain(let code): return "Keychain 错误：\(code)"
        case .fullAccessRequired: return "请为 ToType 键盘开启完全访问；录音仍可在主应用使用。"
        case .invalidCredential: return "API Key 为空或格式无效。"
        case .verificationFailed: return "Keychain 写入回读不一致。"
        case .transcriptTooLarge: return "转写超过键盘交接容量；全文仍可在主应用复制。"
        }
    }
}

enum MobileKeychain {
    static let sharedGroup = "3795RDY2Z7.com.peter.totype.shared"
    static let privateGroup = "3795RDY2Z7.com.peter.totype.ios"
    static func query(_ account: String, group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.peter.totype.mobile",
         kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group,
         kSecAttrSynchronizable as String: false]
    }
    static func read(_ account: String, group: String) throws -> Data? {
        var q = query(account, group: group)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MobileStoreError.keychain(status) }
        guard let data = result as? Data else { throw MobileStoreError.verificationFailed }
        return data
    }
    static func write(_ data: Data, account: String, group: String) throws {
        let q = query(account, group: group)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            let status = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw MobileStoreError.keychain(status) }
        } else if update != errSecSuccess { throw MobileStoreError.keychain(update) }
        guard try read(account, group: group) == data else { throw MobileStoreError.verificationFailed }
    }
}

struct MobileKeyboardDiagnostic: Codable {
    let available: Bool
    let fullAccess: Bool
    let sharedRoundTrip: Bool
    let privateGroupQueryStatus: Int32?
}

enum MobileSharedStore {
    private static func require(_ access: Bool) throws {
        guard access else { throw MobileStoreError.fullAccessRequired }
    }
    static func learningEnabled(fullAccess: Bool) throws -> Bool {
        try require(fullAccess)
        guard let data = try MobileKeychain.read("learning-enabled", group: MobileKeychain.sharedGroup) else { return false }
        return try JSONDecoder().decode(Bool.self, from: data)
    }
    static func setLearningEnabled(_ enabled: Bool, fullAccess: Bool) throws {
        try require(fullAccess)
        try MobileKeychain.write(JSONEncoder().encode(enabled), account: "learning-enabled", group: MobileKeychain.sharedGroup)
    }
    static func diagnosticRoundTrip(fullAccess: Bool) throws -> Bool {
        try require(fullAccess)
        let data = try JSONEncoder().encode(true)
        try MobileKeychain.write(data, account: "diagnostic-roundtrip", group: MobileKeychain.sharedGroup)
        return try MobileKeychain.read("diagnostic-roundtrip", group: MobileKeychain.sharedGroup) == data
    }
    static func saveKeyboardDiagnostic(_ value: MobileKeyboardDiagnostic, fullAccess: Bool) throws {
        try require(fullAccess)
        try MobileKeychain.write(JSONEncoder().encode(value), account: "keyboard-diagnostic", group: MobileKeychain.sharedGroup)
    }
    static func keyboardDiagnostic(fullAccess: Bool) throws -> MobileKeyboardDiagnostic? {
        try require(fullAccess)
        guard let data = try MobileKeychain.read("keyboard-diagnostic", group: MobileKeychain.sharedGroup) else { return nil }
        return try JSONDecoder().decode(MobileKeyboardDiagnostic.self, from: data)
    }
    static func pending(fullAccess: Bool) throws -> MobilePendingTranscript? {
        try require(fullAccess)
        guard let data = try MobileKeychain.read("pending", group: MobileKeychain.sharedGroup) else { return nil }
        let value = try JSONDecoder().decode(MobilePendingTranscript.self, from: data)
        guard !value.consumed, Date().timeIntervalSince(value.createdAt) < 300 else { return nil }
        return value
    }
    static func publish(_ text: String, fullAccess: Bool) throws {
        try require(fullAccess)
        guard text.utf8.count <= 48000 else {
            throw MobileStoreError.transcriptTooLarge
        }
        let pending = MobilePendingTranscript(id: UUID(), text: text, createdAt: Date(), consumed: false)
        try MobileKeychain.write(JSONEncoder().encode(pending), account: "pending", group: MobileKeychain.sharedGroup)
    }
    // Commit consumed state before insertion: a failed commit never inserts, a crash never duplicates.
    static func consume(_ expected: UUID, fullAccess: Bool) throws -> MobilePendingTranscript? {
        guard var pending = try pending(fullAccess: fullAccess), pending.id == expected else { return nil }
        pending.consumed = true
        try MobileKeychain.write(JSONEncoder().encode(pending), account: "pending", group: MobileKeychain.sharedGroup)
        return pending
    }
    static func vocabulary(fullAccess: Bool) throws -> MobileVocabulary {
        try require(fullAccess)
        guard let data = try MobileKeychain.read("vocabulary", group: MobileKeychain.sharedGroup) else { return MobileVocabulary() }
        return try JSONDecoder().decode(MobileVocabulary.self, from: data)
    }
    static func save(_ vocabulary: MobileVocabulary, fullAccess: Bool) throws {
        try require(fullAccess)
        try MobileKeychain.write(JSONEncoder().encode(vocabulary), account: "vocabulary", group: MobileKeychain.sharedGroup)
    }
    static func observe(original: String, edited: String, fullAccess: Bool) throws {
        guard try learningEnabled(fullAccess: fullAccess) else { return }
        var vocabulary = try vocabulary(fullAccess: fullAccess)
        let decision = EditLearningPolicy.classify(original: original, edited: edited, knownTerms: vocabulary.terms)
        let from: String, to: String, uncertain: Bool
        switch decision {
        case .ignore: return
        case .correction(let original, let corrected): from = original; to = corrected; uncertain = false
        case .needsConfirmation(let original, let corrected): from = original; to = corrected; uncertain = true
        }
        if let i = vocabulary.candidates.firstIndex(where: { $0.original == from && $0.corrected == to }) {
            vocabulary.candidates[i].confirmations += 1
            vocabulary.candidates[i].needsConfirmation = vocabulary.candidates[i].needsConfirmation || uncertain
            if vocabulary.candidates[i].confirmations >= 2 && !vocabulary.candidates[i].needsConfirmation && !vocabulary.terms.contains(to) {
                vocabulary.terms.append(to)
            }
        } else {
            vocabulary.candidates.append(MobileCorrection(id: UUID(), original: from, corrected: to, confirmations: 1, needsConfirmation: uncertain))
        }
        vocabulary.candidates = Array(vocabulary.candidates.suffix(100))
        vocabulary.terms = Array(vocabulary.terms.suffix(500))
        try save(vocabulary, fullAccess: fullAccess)
    }
}
