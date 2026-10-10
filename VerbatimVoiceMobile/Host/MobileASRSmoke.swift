#if DEBUG
import Foundation

struct MobileASRSmokeResult: Codable {
    var success = false
    var errorClassification = "none"
    var durationMilliseconds = 0
    var textLength = 0
    var firstPartialLatencyMilliseconds: Int?
    var finalizeLatencyMilliseconds: Int?
}

enum MobileASRSmoke {
    // Explicit DEBUG launch only. Synthetic silence exercises transport, not transcription accuracy.
    static func run(provider: DoubaoASRProvider) async throws -> MobileASRSmokeResult {
        let started = ContinuousClock.now
        var value = MobileASRSmokeResult()
        do {
            _ = try MobileCredentialStore.load()
            let context = ASRContext.personal(terms: ["ToType", "豆包"])
            try Task.checkCancellation()
            try await provider.prepare(context: context)
            try Task.checkCancellation()
            try await provider.startUtterance(id: UUID(), context: context, eventHandler: { _ in })
            // 300 ms, 16 kHz mono PCM16, exactly 4,800 zero samples. No audio session or permission.
            try await provider.send(PCM16Chunk(sequence: 0, data: Data(repeating: 0, count: 9600),
                capturedAt: Date(), sampleRate: 16000, channels: 1))
            let result = try await provider.finalize()
            value.success = true
            value.textLength = result.text.count
            value.firstPartialLatencyMilliseconds = result.firstPartialLatencyMilliseconds
            value.finalizeLatencyMilliseconds = result.finalizeLatencyMilliseconds
        } catch {
            value.errorClassification = error is CancellationError ? "cancelled" : ProviderFailureKind.of(error).rawValue
            await provider.cancel()
        }
        value.durationMilliseconds = Int(ProviderLivenessProbe.nanoseconds(started.duration(to: .now)) / 1_000_000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("totype-asr-smoke.json")
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
        return value
    }
}
#endif
