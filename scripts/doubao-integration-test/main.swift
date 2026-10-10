import Foundation

@main
enum DoubaoIntegrationTest {
    @MainActor static func main() throws {
        let soniox = "soniox"
        let aliyun = "aliyun-qwen-audio-asr"
        let doubao = "volcengine-doubao"
        let cloudIDs = [soniox, aliyun, doubao]
        try check(PrimaryTranscriptionProvider.doubao.cloudProviderID == doubao, "Doubao ID")
        try check(PrimaryTranscriptionProvider.localSenseVoice.cloudProviderID == nil, "Local is not cloud")
        let priorities: [PrimaryTranscriptionProvider: [String]] = [
            .localSenseVoice: [], .soniox: [aliyun, doubao],
            .aliyun: [soniox, doubao], .doubao: [aliyun, soniox]
        ]
        for mask in 0..<8 {
            let configured = Set(cloudIDs.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element })
            for primary in PrimaryTranscriptionProvider.allCases {
                let standby = primary.standbyProviderID(configuredCloudIDs: configured)
                try check(standby == priorities[primary]!.first { configured.contains($0) }, "Standby priority \(primary) mask=\(mask)")
                try check(standby == nil || standby != primary.cloudProviderID, "No self standby")
                for localReady in [false, true] {
                    let choice = HistoryRetranscriptionProvider.automaticChoice(primary: primary, configuredCloudIDs: configured, localModelReady: localReady)
                    let expected: String
                    if let id = primary.cloudProviderID, configured.contains(id) { expected = primary.rawValue }
                    else if primary == .localSenseVoice && localReady { expected = "localSenseVoice" }
                    else if configured.contains(soniox) { expected = "soniox" }
                    else if configured.contains(aliyun) { expected = "aliyun" }
                    else if configured.contains(doubao) { expected = "doubao" }
                    else { expected = "localSenseVoice" }
                    try check(choice.rawValue == expected, "History choice \(primary) mask=\(mask)")
                }
            }
        }
        print("PASS routes: 32 primary/key combinations, 64 automatic history choices; at most one standby")

        let tracker = ProviderOutageTracker()
        tracker.record(providerID: doubao, completed: false, failureKind: .billing, message: "fixture")
        let routed = ProviderAvailabilityPolicy.route(
            configuredPrimaryID: doubao,
            configuredStandbyID: PrimaryTranscriptionProvider.doubao.standbyProviderID(configuredCloudIDs: Set(cloudIDs)),
            outages: tracker.snapshot()
        )
        try check(routed.primaryID == aliyun && routed.standbyID == nil, "Doubao outage chooses only Aliyun")
        try check(routed.bypassedOutage?.providerID == doubao, "Outage identity")
        tracker.apply(probe: .available, providerID: doubao)
        try check(tracker.outage(for: doubao) == nil, "Probe recovery clears Doubao outage")
        print("PASS Doubao outage bypass and successful probe recovery")

        let suite = "totype-doubao-integration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.primaryProvider = .doubao
        try check(AppSettings(defaults: defaults).primaryProvider == .doubao, "Persisted selection")
        let profile = settings.makeProfile(lexicon: [])
        let portable = try PersonalProfile.decode(from: JSONEncoder().encode(profile))
        settings.primaryProvider = .localSenseVoice
        settings.apply(portable)
        try check(settings.primaryProvider == .doubao, "Profile round-trip")
        try check(HistoryRetranscriptionProvider.allCases.contains(.doubao), "History picker")
        print("PASS Doubao selection persistence, profile round-trip and history picker")

        let compiled = ProviderContextCompiler.compile(
            sessionID: UUID(), providerID: doubao,
            personalTerms: [PersonalTerm(canonical: "FixtureTerm", pinned: true)],
            builtInTerms: [], targetBundleIdentifier: nil, prompt: "FixturePrompt", hotwordWeight: 4
        )
        try check(compiled.context.terms == ["FixtureTerm"], "Supported hotwords")
        try check(compiled.receipt.includedTerms == compiled.context.terms, "Receipt equals sent terms")
        try check(compiled.receipt.includedTermIDs.count == compiled.context.terms.count, "Receipt term IDs align")
        try check(compiled.receipt.promptHash == nil, "No supported prompt claim")
        try check(compiled.receipt.capabilitiesUsed.contains("utf8_budget_not_token_count"), "Byte budget not exact token claim")
        let bounded = ProviderContextCompiler.compile(
            sessionID: UUID(), providerID: doubao,
            personalTerms: [PersonalTerm(canonical: String(repeating: "长", count: 100), pinned: true)],
            builtInTerms: ["Codex", "豆包", "OpenTypeless", "Kubernetes", "ChatGPT", "Python"],
            targetBundleIdentifier: nil, prompt: "Never sent as a rewriting prompt", hotwordWeight: 4
        )
        try check(bounded.context.terms == bounded.receipt.includedTerms, "Bounded receipt exact terms")
        try check(bounded.receipt.includedTermIDs.count == bounded.context.terms.count, "Bounded IDs align")
        try check(bounded.receipt.droppedReasons["doubao_context_utf8_budget", default: 0] > 0, "Explicit byte-budget drops")
        let wire = DoubaoHotwordContext.select(bounded.context.terms)
        try check(wire.terms == bounded.receipt.includedTerms && wire.droppedCount == 0, "Sender idempotent selection")
        try check(wire.context!.utf8.count <= DoubaoHotwordContext.maximumContextUTF8Bytes, "Serialized JSON byte budget")
        print("PASS context receipt: exact corpus hotwords/IDs, bounded UTF8 JSON, no prompt capability claim")
    }

    static func check(_ value: Bool, _ label: String) throws {
        if !value { throw NSError(domain: "DoubaoIntegrationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
    }
}
