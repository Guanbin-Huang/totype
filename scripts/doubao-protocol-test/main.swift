import Foundation

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ASREvent] = []
    func append(_ event: ASREvent) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    func snapshot() -> [ASREvent] { lock.lock(); defer { lock.unlock() }; return events }
}

@main
@MainActor
struct DoubaoProtocolTests {
    static var checks = 0

    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        checks += 1
    }

    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("FAIL: \(name) accepted") }
        catch { checks += 1 }
    }

    static func response(text: String?, final: Bool = false, compressed: Bool = true,
                         withSequence: Bool = true, code: UInt32 = 20_000_000) throws -> Data {
        var object: [String: Any] = ["code": code]
        if let text { object["result"] = ["text": text] }
        let json = try JSONSerialization.data(withJSONObject: object)
        let payload = compressed ? try DoubaoRealtimeProtocol.gzip(json, decompress: false) : json
        let flags: UInt8 = final ? (withSequence ? 3 : 2) : (withSequence ? 1 : 0)
        var data = Data([0x11, 0x90 | flags, compressed ? 0x11 : 0x10, 0])
        if withSequence { DoubaoRealtimeProtocol.append(final ? UInt32(bitPattern: -2) : 2, to: &data) }
        DoubaoRealtimeProtocol.append(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    static func main() async throws {
        let context = ASRContext.personal(terms: ["Codex"])
        let request = try DoubaoRealtimeProtocol.request(apiKey: " fixture-key ", resourceID: "", connectionID: UUID())
        check(request.url?.absoluteString == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async", "endpoint")
        check(request.value(forHTTPHeaderField: "X-Api-Key") == "fixture-key", "single-key header")
        check(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration", "default resource")
        check(request.value(forHTTPHeaderField: "X-Api-App-Key") == nil, "single key not legacy")
        let legacy = try DoubaoRealtimeProtocol.request(apiKey: " app : token ", resourceID: "volc.bigasr.sauc.duration", connectionID: UUID())
        check(legacy.value(forHTTPHeaderField: "X-Api-App-Key") == "app", "legacy app")
        check(legacy.value(forHTTPHeaderField: "X-Api-Access-Key") == "token", "legacy token")
        check(legacy.value(forHTTPHeaderField: "X-Api-Key") == nil, "legacy no new key")
        check(legacy.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.bigasr.sauc.duration", "custom resource")
        rejects("empty key") { _ = try DoubaoRealtimeProtocol.request(apiKey: " ", resourceID: "", connectionID: UUID()) }
        rejects("empty legacy token") { _ = try DoubaoRealtimeProtocol.request(apiKey: "app:", resourceID: "", connectionID: UUID()) }
        rejects("header newline") { _ = try DoubaoRealtimeProtocol.request(apiKey: "key\nother", resourceID: "", connectionID: UUID()) }

        let initial = try DoubaoRealtimeProtocol.initialFrame(context: context)
        check(Array(initial.prefix(8)) == [0x11, 0x11, 0x11, 0, 0, 0, 0, 1], "initial header and sequence")
        let initialJSON = try DoubaoRealtimeProtocol.gzip(initial.dropFirst(12), decompress: true)
        let object = try JSONSerialization.jsonObject(with: initialJSON) as! [String: Any]
        let settings = object["request"] as! [String: Any]
        check(settings["enable_ddc"] as? Bool == false, "literal no disfluency removal")
        check(settings["enable_itn"] as? Bool == false, "literal no ITN")
        check(settings["enable_punc"] as? Bool == true, "natural punctuation")
        check(settings["show_utterances"] as? Bool == true, "utterances enabled")
        check(settings["model_name"] as? String == "bigmodel", "ASR-only model")
        let audioConfig = object["audio"] as! [String: Any]
        check(audioConfig["rate"] as? Int == 16_000 && audioConfig["bits"] as? Int == 16 && audioConfig["channel"] as? Int == 1, "PCM format")
        check(settings["context"] == nil, "no LLM instruction injection")
        let corpus = settings["corpus"] as! [String: Any]
        let corpusString = corpus["context"] as! String
        let corpusObject = try JSONSerialization.jsonObject(with: Data(corpusString.utf8)) as! [String: [[String: String]]]
        check(corpusObject["hotwords"]?.compactMap { $0["word"] } == ["Codex"], "official corpus JSON string contains actual hotword")
        check(corpusString.utf8.count <= DoubaoHotwordContext.maximumContextUTF8Bytes, "context conservative UTF8 budget, not exact token estimate")
        let emptyInitial = try DoubaoRealtimeProtocol.initialFrame(context: .personal(terms: []))
        let emptyPayload = try DoubaoRealtimeProtocol.gzip(emptyInitial.dropFirst(12), decompress: true)
        let emptyObject = try JSONSerialization.jsonObject(with: emptyPayload) as! [String: Any]
        check((emptyObject["request"] as! [String: Any])["corpus"] == nil, "empty corpus omitted")
        print("PASS wire corpus.context: JSON string hotwords, exact sender selection, empty omission")
        let pcm = Data([0, 1, 2, 3])
        let audio = try DoubaoRealtimeProtocol.audioFrame(pcm, sequence: 2)
        check(Array(audio.prefix(8)) == [0x11, 0x21, 0x01, 0, 0, 0, 0, 2], "audio frame")
        check(try DoubaoRealtimeProtocol.gzip(audio.dropFirst(12), decompress: true) == pcm, "audio round trip")
        let end = try DoubaoRealtimeProtocol.audioFrame(Data(), sequence: -3)
        check(Array(end.prefix(8)) == [0x11, 0x23, 0x01, 0, 255, 255, 255, 253], "negative final audio sequence")
        check(try DoubaoRealtimeProtocol.gzip(end.dropFirst(12), decompress: true).isEmpty, "empty terminal audio")
        var packetizer = DoubaoAudioPacketizer()
        let tiny = Data((0..<342).map { UInt8(truncatingIfNeeded: $0) })
        var input = Data()
        var packets: [DoubaoAudioPacketizer.Packet] = []
        for _ in 0..<94 {
            input.append(tiny)
            packets.append(contentsOf: try packetizer.append(tiny))
        }
        check(packets.count == 10 && packets.allSatisfy { $0.audioByteCount == 3_200 }, "94 tiny callbacks become 10 audio packets")
        packets.append(contentsOf: try packetizer.finish())
        check(packets[10].audioByteCount == 148 && packets[11].audioByteCount == 0, "finish flushes residual before final")
        var reconstructed = Data()
        for packet in packets {
            reconstructed.append(try DoubaoRealtimeProtocol.gzip(packet.data.dropFirst(12), decompress: true))
        }
        check(reconstructed == input, "batch and flush preserve exact PCM bytes and order")
        check(packets.last?.data[1] == 0x23, "batched finish uses negative final sequence")
        var emptyPacketizer = DoubaoAudioPacketizer()
        let silentPackets = try emptyPacketizer.finish()
        check(silentPackets.count == 1 && silentPackets[0].audioByteCount == 0, "no-audio final still sends termination frame")
        let partial = try response(text: "你好，嗯，Codex")
        check(try DoubaoRealtimeProtocol.parse(partial) == .init(text: "你好，嗯，Codex", isFinal: false), "gzip partial parse")
        check(try DoubaoRealtimeProtocol.parse(response(text: "文本", compressed: false)) == .init(text: "文本", isFinal: false), "uncompressed response")
        check(try DoubaoRealtimeProtocol.parse(response(text: "", final: true)) == .init(text: "", isFinal: true), "final empty text")
        check(try DoubaoRealtimeProtocol.parse(response(text: nil, final: true, withSequence: false)) == .init(text: nil, isFinal: true), "final flag without sequence/result")
        for count in 0..<partial.count {
            rejects("truncated frame \(count)") { _ = try DoubaoRealtimeProtocol.parse(partial.prefix(count)) }
        }
        var trailing = partial; trailing.append(0)
        rejects("unexpected frame tail") { _ = try DoubaoRealtimeProtocol.parse(trailing) }
        var version = partial; version[0] = 0x21
        rejects("unsupported version") { _ = try DoubaoRealtimeProtocol.parse(version) }
        var corrupt = partial; corrupt[12] = 0
        rejects("bad gzip") { _ = try DoubaoRealtimeProtocol.parse(corrupt) }
        var compression = partial; compression[2] = 0x12
        rejects("unsupported compression") { _ = try DoubaoRealtimeProtocol.parse(compression) }
        var oversized = Data([0x11, 0x90, 0x10, 0]); DoubaoRealtimeProtocol.append(UInt32.max, to: &oversized)
        rejects("oversized payload") { _ = try DoubaoRealtimeProtocol.parse(oversized) }

        let errorJSON = try JSONSerialization.data(withJSONObject: ["message": "quota exceeded"])
        var error = Data([0x11, 0xf0, 0x10, 0])
        DoubaoRealtimeProtocol.append(45_000_081, to: &error)
        DoubaoRealtimeProtocol.append(UInt32(errorJSON.count), to: &error)
        error.append(errorJSON)
        do { _ = try DoubaoRealtimeProtocol.parse(error); fatalError("FAIL: error frame accepted") }
        catch let rejection as ProviderRejection { check(rejection.failureKind == .billing, "quota frame billing") }
        var emptyError = Data([0x11, 0xf0, 0, 0]); DoubaoRealtimeProtocol.append(401, to: &emptyError); DoubaoRealtimeProtocol.append(0, to: &emptyError)
        do { _ = try DoubaoRealtimeProtocol.parse(emptyError); fatalError("FAIL: empty error accepted") }
        catch let rejection as ProviderRejection { check(rejection.failureKind == .auth, "empty error code auth") }
        check(DoubaoRealtimeProtocol.rejection(code: nil, message: "permission denied").failureKind == .auth, "auth classification")
        check(DoubaoRealtimeProtocol.rejection(code: nil, message: "concurrency quota exceeded").failureKind == .transient, "concurrency not billing")
        check(DoubaoRealtimeProtocol.rejection(code: 55_000_031, message: "service unavailable").failureKind == .transient, "server overload transient")
        rejects("JSON non-success code") { _ = try DoubaoRealtimeProtocol.parse(response(text: nil, code: 45_000_001)) }

        var accumulated = DoubaoTranscriptState()
        accumulated.apply(try DoubaoRealtimeProtocol.parse(response(text: "我要，我要，嗯"))!)
        accumulated.apply(try DoubaoRealtimeProtocol.parse(response(text: "我要，我要，嗯，运行 Codex。"))!)
        check(accumulated.text == "我要，我要，嗯，运行 Codex。", "cumulative replaces not appends; filler preserved")
        accumulated.apply(try DoubaoRealtimeProtocol.parse(response(text: "", final: true))!)
        check(accumulated.isFinal && accumulated.text == "我要，我要，嗯，运行 Codex。", "empty final completes preserving last hypothesis")
        var silence = DoubaoTranscriptState()
        silence.apply(try DoubaoRealtimeProtocol.parse(response(text: "", final: true))!)
        check(silence.isFinal && silence.text.isEmpty, "silence final completes")
        var revised = DoubaoTranscriptState()
        revised.apply(.init(text: "错误", isFinal: false))
        revised.apply(.init(text: "修正", isFinal: true))
        check(revised.text == "修正", "final full text replaces partial")
        revised.apply(.init(text: "", isFinal: false))
        check(revised.text.isEmpty, "empty nonfinal hypothesis replaces")

        // Actor's no-network entry points and reset behavior.
        let provider = DoubaoASRProvider(apiKeyProvider: { "fixture-key" })
        try await provider.prepare(context: context)
        await provider.cancel()
        await provider.cancel()
        do { _ = try await provider.finalize(); fatalError("FAIL: finalize without active utterance") }
        catch { checks += 1 }
        do { try await provider.send(PCM16Chunk(sequence: 0, data: pcm, capturedAt: Date(), sampleRate: 16_000, channels: 1)); fatalError("FAIL: send without active utterance") }
        catch { checks += 1 }
        let invalidProvider = DoubaoASRProvider(apiKeyProvider: { "" })
        do { try await invalidProvider.prepare(context: context); fatalError("FAIL: missing credential accepted") }
        catch { checks += 1 }
        let events = EventLog()
        let oldSession = await provider.testBegin { events.append($0) }
        try await provider.testReceive(response(text: "旧会话"), sessionID: oldSession)
        await provider.cancel()
        let newSession = await provider.testBegin { events.append($0) }
        try await provider.testReceive(response(text: "过期回调"), sessionID: oldSession)
        check(events.snapshot().count == 1, "old frame ignored after cancel/new session")
        try await provider.testReceive(response(text: "新"), sessionID: newSession)
        try await provider.testReceive(response(text: "新会话"), sessionID: newSession)
        let finalResult = try await provider.testFinalize(response: response(text: "", final: true))
        check(finalResult.text == "新会话", "actor empty final completes latest cumulative result")
        check(finalResult.providerID == "volcengine-doubao" && finalResult.model == "bigmodel", "actor transcript metadata")
        check(finalResult.transportMetrics?.audioBytesSent == 0, "actor transport metadata")
        try await provider.testReceive(response(text: "定稿后过期"), sessionID: newSession)
        check(events.snapshot().count == 3, "no callback after completed generation")
        let silenceSession = await provider.testBegin { events.append($0) }
        let silentResult = try await provider.testFinalize(response: response(text: nil, final: true, withSequence: false))
        check(silentResult.text.isEmpty, "actor final without result completes silence")
        try await provider.testReceive(response(text: "静音后过期"), sessionID: silenceSession)
        check(events.snapshot().count == 3, "silent completion invalidates old callbacks")
        _ = await provider.testBegin { events.append($0) }
        do {
            _ = try await provider.testFinalize(response: error)
            fatalError("FAIL: quota actor final accepted")
        } catch let rejection as ProviderRejection {
            check(rejection.failureKind == .billing, "actor final rethrows quota rejection")
        }
        do {
            try await provider.send(PCM16Chunk(sequence: 1, data: pcm, capturedAt: Date(), sampleRate: 16_000, channels: 1))
            fatalError("FAIL: terminal quota lost")
        } catch let rejection as ProviderRejection {
            check(rejection.failureKind == .billing, "subsequent send retains quota reason")
        }
        await provider.cancel()
        do { _ = try await provider.finalize(); fatalError("FAIL: canceled actor finalize") }
        catch is ASRProviderError { checks += 1 }
        print("DOUBAO_PROTOCOL_OK checks=\(checks) network_calls=0")
    }
}
