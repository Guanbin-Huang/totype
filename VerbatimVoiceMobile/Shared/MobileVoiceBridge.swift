import Foundation

struct MobileVoiceRequest: Codable {
    let id: UUID
    let documentID: UUID
    let contextFingerprint: String
    var sourceBundleID: String? = nil
    let createdAt: Date
}
enum MobileVoicePhase: String, Codable {
    case starting, recording, finalizing, completed, cancelled, failed
}
struct MobileVoiceStatus: Codable {
    let requestID: UUID
    let phase: MobileVoicePhase
    let pendingTranscriptID: UUID?
    let error: String?
    let updatedAt: Date
}
enum MobileVoiceAction: String, Codable { case stop, cancel }
struct MobileVoiceCommand: Codable {
    let id: UUID
    let requestID: UUID
    let action: MobileVoiceAction
    let createdAt: Date
}

struct MobileVoiceDiagnostic: Codable {
    let requestID: UUID
    let stage: String
    let sourceResolved: Bool
    let documentMatches: Bool?
    let contextMatches: Bool?
    let updatedAt: Date
}

enum MobileVoiceBridge {
    // Three independent slots: keyboard writes request/command; host writes status.
    private static func read<T: Decodable>(_ type: T.Type, account: String, fullAccess: Bool) throws -> T? {
        guard fullAccess else { throw MobileStoreError.fullAccessRequired }
        guard let data = try MobileKeychain.read(account, group: MobileKeychain.sharedGroup) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    private static func write<T: Encodable>(_ value: T, account: String, fullAccess: Bool) throws {
        guard fullAccess else { throw MobileStoreError.fullAccessRequired }
        try MobileKeychain.write(JSONEncoder().encode(value), account: account, group: MobileKeychain.sharedGroup)
    }
    static func saveDiagnostic(_ value: MobileVoiceDiagnostic, fullAccess: Bool) throws {
        try write(value, account: "voice-diagnostic", fullAccess: fullAccess)
    }
    static func diagnostic(fullAccess: Bool) throws -> MobileVoiceDiagnostic? {
        try read(MobileVoiceDiagnostic.self, account: "voice-diagnostic", fullAccess: fullAccess)
    }
    static func saveRequest(_ value: MobileVoiceRequest, fullAccess: Bool) throws {
        guard value.contextFingerprint.utf8.count <= 128 else { throw MobileStoreError.verificationFailed }
        try write(value, account: "voice-request", fullAccess: fullAccess)
    }
    static func request(fullAccess: Bool) throws -> MobileVoiceRequest? {
        try read(MobileVoiceRequest.self, account: "voice-request", fullAccess: fullAccess)
    }
    static func saveStatus(_ value: MobileVoiceStatus, fullAccess: Bool) throws {
        try write(value, account: "voice-status", fullAccess: fullAccess)
    }
    static func status(fullAccess: Bool) throws -> MobileVoiceStatus? {
        try read(MobileVoiceStatus.self, account: "voice-status", fullAccess: fullAccess)
    }
    static func saveCommand(_ value: MobileVoiceCommand, fullAccess: Bool) throws {
        try write(value, account: "voice-command", fullAccess: fullAccess)
    }
    static func command(fullAccess: Bool) throws -> MobileVoiceCommand? {
        try read(MobileVoiceCommand.self, account: "voice-command", fullAccess: fullAccess)
    }
}
