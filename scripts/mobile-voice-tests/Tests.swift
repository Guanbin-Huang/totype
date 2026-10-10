import Foundation

@main struct Tests {
    @MainActor static var passed = 0
    @MainActor static var failed = 0
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            if Date() > deadline { throw Failure(description: "await condition timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    @MainActor static func settle() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(5)) }
    @MainActor static func test(_ name: String, _ body: () async throws -> Void) async {
        MobileKeychain.slots = [:]; MobileSharedStore.transcript = nil; MobileSharedStore.publishCount = 0
        do { try await body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }
    @MainActor static func bridge(_ model: MobileDictationModel) throws -> MobileVoiceRequest {
        let id = UUID(), now = Date()
        let fp = MobileVoiceHandoffPolicy.fingerprint(requestID: id, before: "", after: "", selected: nil)!
        let request = MobileVoiceRequest(id: id, documentID: UUID(), contextFingerprint: fp, createdAt: now)
        try MobileVoiceBridge.saveRequest(request, fullAccess: true)
        model.handleDictationURL(URL(string: "totype://dictate?request=\(id)")!)
        return request
    }
    @MainActor static func cleanup(_ model: MobileDictationModel, _ provider: DoubaoASRProvider) async throws {
        model.cancel()
        try await until { !provider.cancelGates.isEmpty }
        for key in Array(provider.cancelGates.keys) { provider.releaseCancel(key) }
        try await until { model.phase == .idle }
    }
    @MainActor static func staleCleanup(_ kind: String) async throws {
        let model = MobileDictationModel(), provider = DoubaoASRProvider.latest!
        if kind == "start" { provider.failPrepare = true }
        model.start()
        if kind != "start" {
            try await until { model.phase == .recording }
            if kind == "sender" { MobileAudioCapture.latest.fail() }
            else { provider.failFinalize = true; model.stop() }
        }
        try await until { provider.cancelGates[1] != nil }
        model.cancel()
        try await until { provider.cancelGates[2] != nil }
        provider.releaseCancel(2)
        try await until { model.phase == .idle }
        let request = try bridge(model)
        try await until { model.phase == .recording }
        let deactivations = MobileAudioCapture.latest.deactivations
        provider.releaseCancel(1)
        await settle()
        try require(model.phase == .recording, "old \(kind) cleanup changed new phase")
        try require(model.activeVoiceRequestID == request.id && model.bridgeActive, "old \(kind) cleanup finished new bridge")
        try require(MobileAudioCapture.latest.deactivations == deactivations, "old \(kind) cleanup deactivated new audio")
        try await cleanup(model, provider)
    }
    @MainActor static func main() async {
        await test("repeat-cancel-idempotent-and-start-blocked-during-cleanup") {
            let model = MobileDictationModel(), provider = DoubaoASRProvider.latest!
            model.start(); try await until { model.phase == .recording }
            model.cancel(); try await until { provider.cancelGates[1] != nil }
            model.cancel(); model.start(); await settle()
            try require(provider.cancelCount == 1, "duplicate cancel reached provider")
            try require(provider.startCount == 1 && model.phase != .recording, "start entered during cancel await")
            provider.releaseCancel(1); try await until { model.phase == .idle }
            model.start(); try await until { model.phase == .recording }
            try require(provider.startCount == 2, "start did not resume after cleanup")
            try await cleanup(model, provider)
        }
        for kind in ["start", "sender", "finalize"] {
            await test("stale-\(kind)-cleanup-does-not-overwrite-new-generation") { try await staleCleanup(kind) }
        }
        await test("cancel-before-final-result-prevents-pending-publish") {
            let model = MobileDictationModel(), provider = DoubaoASRProvider.latest!
            let request = try bridge(model)
            try await until { model.phase == .recording }
            provider.holdFinalize = true; model.stop()
            try await until { provider.finalGate != nil }
            try MobileVoiceBridge.saveCommand(.init(id: UUID(), requestID: request.id, action: .cancel, createdAt: Date()), fullAccess: true)
            provider.releaseFinal()
            try await until { provider.cancelGates[1] != nil || MobileSharedStore.publishCount > 0 }
            try require(MobileSharedStore.publishCount == 0, "final result published despite persisted cancel")
            provider.releaseCancel(1); try await until { model.phase == .idle }
            try require(try MobileVoiceBridge.status(fullAccess: true)?.phase == .cancelled, "cancel terminal status missing")
        }
        await test("late-finalize-result-after-cancel-cannot-publish-or-change-new-session") {
            let model = MobileDictationModel(), provider = DoubaoASRProvider.latest!
            _ = try bridge(model)
            try await until { model.phase == .recording }
            provider.holdFinalize = true; model.stop()
            try await until { provider.finalGate != nil }
            model.cancel(); try await until { provider.cancelGates[1] != nil }
            provider.releaseCancel(1); try await until { model.phase == .idle }
            let next = try bridge(model)
            try await until { model.phase == .recording }
            provider.releaseFinal(); await settle()
            try require(MobileSharedStore.publishCount == 0, "late result published")
            try require(model.phase == .recording && model.activeVoiceRequestID == next.id, "late result changed new session")
            try await cleanup(model, provider)
        }
        await test("persisted-cancel-blocks-completed-status-and-reloaded-bridge") {
            let now = Date(), id = UUID(), document = UUID(), pending = UUID()
            let fp = MobileVoiceHandoffPolicy.fingerprint(requestID: id, before: "", after: "", selected: nil)!
            let request = MobileVoiceRequest(id: id, documentID: document, contextFingerprint: fp, createdAt: now)
            let status = MobileVoiceStatus(requestID: id, phase: .completed, pendingTranscriptID: pending, error: nil, updatedAt: now)
            try MobileVoiceBridge.saveRequest(request, fullAccess: true)
            try MobileVoiceBridge.saveStatus(status, fullAccess: true)
            try MobileVoiceBridge.saveCommand(.init(id: UUID(), requestID: id, action: .cancel, createdAt: now), fullAccess: true)
            let loaded = try MobileVoiceBridge.request(fullAccess: true)!
            let command = try MobileVoiceBridge.command(fullAccess: true)
            try require(MobileVoiceHandoffPolicy.isCancelled(request: loaded, command: command), "persisted cancellation not detected")
            try require(!MobileVoiceHandoffPolicy.mayInsert(request: loaded, status: status, pendingID: pending, documentID: document, currentFingerprint: fp, now: now, command: command), "completed overrides cancel")
            try require(MobileVoiceHandoffPolicy.mayInsert(request: loaded, status: status, pendingID: pending, documentID: document, currentFingerprint: fp, now: now), "normal completion rejected")
            let other = MobileVoiceCommand(id: UUID(), requestID: UUID(), action: .cancel, createdAt: now)
            try require(!MobileVoiceHandoffPolicy.isCancelled(request: loaded, command: other), "unrelated cancel blocked request")
            try require(!MobileVoiceHandoffPolicy.mayInsert(request: loaded, status: status, pendingID: pending, documentID: UUID(), currentFingerprint: fp, now: now), "different document allowed")
        }
        print("TESTS=\(passed + failed) PASS=\(passed) FAIL=\(failed)")
        if failed != 0 { exit(1) }
    }
}
