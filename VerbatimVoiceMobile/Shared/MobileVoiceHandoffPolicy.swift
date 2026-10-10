import Foundation
import CryptoKit

/// Compare an unchanged target without persisting surrounding user text.
enum MobileVoiceHandoffPolicy {
    static func fingerprint(requestID: UUID, before: String?, after: String?, selected: String?) -> String? {
        guard let before, let after, selected?.isEmpty != false else { return nil }
        let input = "\(requestID.uuidString)|\(before.utf8.count):\(before)\(after.utf8.count):\(after)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func isCancelled(request: MobileVoiceRequest, command: MobileVoiceCommand?) -> Bool {
        command?.requestID == request.id && command?.action == .cancel
    }
    static func mayInsert(request: MobileVoiceRequest, status: MobileVoiceStatus,
                          pendingID: UUID, documentID: UUID, currentFingerprint: String?, now: Date, command: MobileVoiceCommand? = nil) -> Bool {
        !isCancelled(request: request, command: command)
            && request.id == status.requestID && status.phase == .completed
            && status.pendingTranscriptID == pendingID && request.documentID == documentID
            && !request.contextFingerprint.isEmpty && currentFingerprint == request.contextFingerprint
            && (0...180).contains(now.timeIntervalSince(request.createdAt))
    }
}
