import Foundation

struct MobileHostDiagnosticStatus: Codable {
    var originBundleID: String?
    var returnRequestAccepted: Bool?
    var voicePhase: String?
    var voiceHandoff: MobileVoiceDiagnostic?
    var credentialPrivateReadback = false
    var credentialStatus = "not_checked"
    var sharedRoundTrip = false
    var sharedStatus = "not_checked"
    var learningEnabled = false
    var keyboard: MobileKeyboardDiagnostic?
    var keyboardStatus = "not_checked"
}

enum MobileHostDiagnostics {
    // Diagnostics contain only booleans and fixed/numeric states: never credentials or transcript text.
    static func writeStatus(learningEnabled: Bool) throws -> MobileHostDiagnosticStatus {
        var status = MobileHostDiagnosticStatus()
        status.learningEnabled = learningEnabled
        status.originBundleID = UserDefaults.standard.string(forKey: "lastNavigationSource")
        status.returnRequestAccepted = UserDefaults.standard.object(forKey: "lastNavigationAccepted") as? Bool
        status.voicePhase = try MobileVoiceBridge.status(fullAccess: true)?.phase.rawValue
        status.voiceHandoff = try MobileVoiceBridge.diagnostic(fullAccess: true)
        do {
            status.credentialPrivateReadback = !(try MobileCredentialStore.load()).isEmpty
            status.credentialStatus = "verified"
        } catch let error as MobileStoreError {
            if case .keychain(let code) = error { status.credentialStatus = "keychain_\(code)" }
            else { status.credentialStatus = "invalid" }
        } catch { status.credentialStatus = "missing_or_invalid" }
        do {
            status.sharedRoundTrip = try MobileSharedStore.diagnosticRoundTrip(fullAccess: true)
            status.sharedStatus = status.sharedRoundTrip ? "verified" : "mismatch"
        } catch let error as MobileStoreError {
            if case .keychain(let code) = error { status.sharedStatus = "keychain_\(code)" }
            else { status.sharedStatus = "invalid" }
        } catch { status.sharedStatus = "decode_failed" }
        do {
            status.keyboard = try MobileSharedStore.keyboardDiagnostic(fullAccess: true)
            status.keyboardStatus = status.keyboard == nil ? "awaiting_extension" : "readback"
        } catch let error as MobileStoreError {
            if case .keychain(let code) = error { status.keyboardStatus = "keychain_\(code)" }
            else { status.keyboardStatus = "invalid" }
        } catch { status.keyboardStatus = "decode_failed" }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("totype-status.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(status).write(to: url, options: [.atomic, .completeFileProtection])
        return status
    }
}
