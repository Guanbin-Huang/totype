import Foundation
import Combine

struct PCM16Chunk {}
struct ASRContext { static func personal(terms: [String]) -> Self { Self() } }
enum ASREvent { case partial(UUID, String), finalized(UUID, String), warning(UUID, String), failed(UUID, String), connected }
enum ASRProviderError: Error { case unavailable(String) }
enum MobileStoreError: Error { case fullAccessRequired, verificationFailed }
struct TranscriptResult { let text: String }
struct MobileVocabulary { var terms: [String] = []; var candidates: [MobileCorrection] = [] }
struct MobileCorrection { let id: UUID; let corrected: String }
struct MobilePendingTranscript { let id = UUID(); let text: String }
enum EditLearningPolicy { static let observationDuration = 10.0 }
enum MobileCredentialStore { static func load() throws -> String { "stub" }; static func importBootstrap() throws {} }
enum AVAudioApplication { static func requestRecordPermission(_ callback: (Bool) -> Void) { callback(true) } }
struct UIBackgroundTaskIdentifier: Equatable { let raw: Int; static let invalid = Self(raw: -1) }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .init(raw: 1) }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {}
}
enum MobileKeychain {
    static let sharedGroup = "fixture"
    static var slots: [String: Data] = [:]
    static func read(_ account: String, group: String) throws -> Data? { slots[account] }
    static func write(_ data: Data, account: String, group: String) throws { slots[account] = data }
}
@MainActor enum MobileSharedStore {
    static var transcript: MobilePendingTranscript?
    static var publishCount = 0
    static func learningEnabled(fullAccess: Bool) throws -> Bool { false }
    static func setLearningEnabled(_ enabled: Bool, fullAccess: Bool) throws {}
    static func vocabulary(fullAccess: Bool) throws -> MobileVocabulary { .init() }
    static func save(_ value: MobileVocabulary, fullAccess: Bool) throws {}
    static func observe(original: String, edited: String, fullAccess: Bool) throws {}
    static func publish(_ text: String, fullAccess: Bool) throws { publishCount += 1; transcript = .init(text: text) }
    static func pending(fullAccess: Bool) throws -> MobilePendingTranscript? { transcript }
}
struct Diagnostic { let credentialPrivateReadback = true; let credentialStatus = "fixture"; let sharedRoundTrip = true; let sharedStatus = "fixture"; let keyboard: KeyboardDiagnostic? = nil }
struct KeyboardDiagnostic { let available: Bool }
enum MobileHostDiagnostics { static func writeStatus(learningEnabled: Bool) throws -> Diagnostic { .init() } }
@MainActor final class MobileAudioCapture {
    static var latest: MobileAudioCapture!
    var onInterruption: (@Sendable (String) -> Void)?
    var continuation: AsyncThrowingStream<PCM16Chunk, Error>.Continuation?
    var deactivations = 0
    init() { Self.latest = self }
    func start() throws -> AsyncThrowingStream<PCM16Chunk, Error> {
        let pair = AsyncThrowingStream<PCM16Chunk, Error>.makeStream(); continuation = pair.continuation; return pair.stream
    }
    func finish() { continuation?.finish(); continuation = nil }
    func deactivate() throws { deactivations += 1 }
    func fail() { continuation?.finish(throwing: ASRProviderError.unavailable("sender fixture")); continuation = nil }
}
@MainActor final class DoubaoASRProvider {
    static var latest: DoubaoASRProvider!
    var failPrepare = false
    var failFinalize = false
    var holdFinalize = false
    var startCount = 0
    var cancelCount = 0
    var cancelGates: [Int: CheckedContinuation<Void, Never>] = [:]
    var finalGate: CheckedContinuation<TranscriptResult, Error>?
    init(apiKeyProvider: @escaping () throws -> String) { Self.latest = self }
    func prepare(context: ASRContext) async throws { if failPrepare { failPrepare = false; throw ASRProviderError.unavailable("start fixture") } }
    func startUtterance(id: UUID, context: ASRContext, eventHandler: @escaping @Sendable (ASREvent) -> Void) async throws { startCount += 1 }
    func send(_ chunk: PCM16Chunk) async throws {}
    func finalize() async throws -> TranscriptResult {
        if failFinalize { failFinalize = false; throw ASRProviderError.unavailable("finalize fixture") }
        if holdFinalize { return try await withCheckedThrowingContinuation { finalGate = $0 } }
        return .init(text: "fixture transcript")
    }
    func cancel() async {
        cancelCount += 1
        let number = cancelCount
        await withCheckedContinuation { cancelGates[number] = $0 }
    }
    func releaseCancel(_ number: Int) { cancelGates.removeValue(forKey: number)!.resume() }
    func releaseFinal() { let gate = finalGate!; finalGate = nil; gate.resume(returning: .init(text: "fixture transcript")) }
}
