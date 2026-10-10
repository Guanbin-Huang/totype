import Foundation

final class StartupLabel { var text: String? }
final class StartupButton { var isEnabled = false }
final class StartupView { var isUserInteractionEnabled = false; var alpha = 1.0 }
final class StartupLauncher { let view = StartupView() }
final class StartupTyping { var hasComposition = false }
struct StartupProxy {
    let documentIdentifier = UUID()
    let documentContextBeforeInput: String? = ""
    let documentContextAfterInput: String? = ""
    let selectedText: String? = nil
}
extension MobileSharedStore {
    static func consume(_ id: UUID, fullAccess: Bool) throws -> MobilePendingTranscript? { nil }
}
@main struct StartupExpiryTest {
    @MainActor static func main() throws {
        let fixture = StartupKeyboard()
        let id = UUID(), document = UUID(), now = Date()
        let fresh = MobileVoiceRequest(id: id, documentID: document, contextFingerprint: "fixture", createdAt: now)
        try MobileVoiceBridge.saveRequest(fresh, fullAccess: true)
        try MobileVoiceBridge.saveStatus(.init(requestID: id, phase: .starting, pendingTranscriptID: nil, error: nil, updatedAt: now), fullAccess: true)
        fixture.tick()
        let starting = fixture.statusLabel.text
        guard starting == "正在激活麦克风…" else { print("FAIL fixture did not reach starting"); exit(2) }
        // Advance request age without changing production Date() calls or sleeping 181 seconds.
        let expired = MobileVoiceRequest(id: id, documentID: document, contextFingerprint: "fixture", createdAt: now.addingTimeInterval(-181))
        try MobileVoiceBridge.saveRequest(expired, fullAccess: true)
        fixture.tick()
        print("INPUT phase=starting requestAge=181s hostStatusUnchanged=true")
        print("OBSERVED label=\(fixture.statusLabel.text ?? "nil") stopEnabled=\(fixture.stopButton.isEnabled) cancelEnabled=\(fixture.cancelButton.isEnabled) launcherEnabled=\(fixture.voiceLauncher!.view.isUserInteractionEnabled)")
        if fixture.statusLabel.text == starting {
            print("FAIL expired request retains misleading starting label indefinitely")
            exit(1)
        }
        print("PASS expired request exits starting presentation")
    }
}
