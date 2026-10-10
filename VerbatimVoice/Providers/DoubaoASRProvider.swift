import Foundation
import zlib

/// ByteDance's binary streaming-ASR protocol. No formatting/LLM stage is used.
enum DoubaoRealtimeProtocol {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    static let resourceID = "volc.seedasr.sauc.duration"
    static let model = "bigmodel"
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    struct Response: Equatable, Sendable {
        let text: String?
        let isFinal: Bool
    }

    static func request(apiKey: String, resourceID: String, connectionID: UUID) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRProviderError.missingAPIKey("豆包语音") }
        guard !key.contains("\r"), !key.contains("\n") else {
            throw ProviderRejection(failureKind: .auth, message: "豆包语音 Key 含换行")
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        let resource = resourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(resource.isEmpty ? Self.resourceID : resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectionID.uuidString.lowercased(), forHTTPHeaderField: "X-Api-Connect-Id")
        if let separator = key.firstIndex(of: ":") {
            let appID = key[..<separator].trimmingCharacters(in: .whitespaces)
            let token = key[key.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !appID.isEmpty, !token.isEmpty else {
                throw ProviderRejection(failureKind: .auth, message: "豆包旧版凭据格式应为 app_id:access_token")
            }
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
        } else {
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        }
        return request
    }

    static func initialFrame(context: ASRContext) throws -> Data {
        let language: String
        switch context.languages.first ?? "zh" {
        case "zh", "zh-CN", "multi", "": language = "zh-CN"
        case "en": language = "en-US"
        case "ja": language = "ja-JP"
        case "ko": language = "ko-KR"
        case let other: language = other
        }
        var configuration: [String: Any] = [
            "model_name": model, "enable_itn": false, "enable_ddc": false,
            "enable_punc": true, "show_utterances": true
        ]
        if let hotwordContext = DoubaoHotwordContext.select(context.terms).context {
            configuration["corpus"] = ["context": hotwordContext]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "user": ["uid": "totype"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000,
                      "bits": 16, "channel": 1, "language": language],
            "request": configuration
        ])
        return try frame(type: 1, flags: 1, serialization: 1, payload: payload, sequence: 1)
    }

    static func audioFrame(_ audio: Data, sequence: Int32) throws -> Data {
        try frame(type: 2, flags: sequence < 0 ? 3 : 1, serialization: 0, payload: audio, sequence: sequence)
    }

    static func frame(type: UInt8, flags: UInt8, serialization: UInt8, payload: Data, sequence: Int32) throws -> Data {
        let compressed = try gzip(payload, decompress: false)
        var result = Data([0x11, (type << 4) | flags, (serialization << 4) | 1, 0])
        append(UInt32(bitPattern: sequence), to: &result)
        append(UInt32(compressed.count), to: &result)
        result.append(compressed)
        return result
    }

    static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func parse(_ data: Data) throws -> Response? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] >> 4 == 1 else { throw malformed("帧头") }
        let headerSize = Int(bytes[0] & 15) * 4
        guard headerSize >= 4, bytes.count >= headerSize else { throw malformed("帧头长度") }
        let type = bytes[1] >> 4
        let flags = bytes[1] & 15
        let serialization = bytes[2] >> 4
        let compression = bytes[2] & 15
        guard flags <= 7, compression <= 1, serialization <= 1 else { throw malformed("编码标记") }
        var offset = headerSize
        func readUInt32() throws -> UInt32 {
            guard bytes.count - offset >= 4 else { throw malformed("序号或载荷长度") }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let sequence = flags & 1 != 0 ? Int32(bitPattern: try readUInt32()) : nil
        if flags & 4 != 0 { _ = try readUInt32() }
        let errorCode = type == 15 ? try readUInt32() : nil
        let size = Int(try readUInt32())
        guard size <= maximumPayloadBytes, bytes.count - offset == size else { throw malformed("载荷长度") }
        let payload = Data(bytes[offset...])
        let decoded = compression == 1 && !payload.isEmpty ? try gzip(payload, decompress: true) : payload
        let object: [String: Any]
        if serialization == 1, !decoded.isEmpty {
            guard let dictionary = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
                throw malformed("JSON 对象")
            }
            object = dictionary
        } else {
            object = [:]
        }
        let code = (object["code"] as? NSNumber)?.uint32Value ?? errorCode
        if type == 15 || (code != nil && code != 0 && code != 20_000_000) {
            let message = object["message"] as? String
                ?? object["error"] as? String
                ?? (object["error"] as? [String: Any])?["message"] as? String
                ?? String(data: decoded, encoding: .utf8)
                ?? "未知错误"
            throw rejection(code: code, message: message)
        }
        guard type == 9 else { return nil }
        let isFinal = flags & 2 != 0 || (sequence ?? 0) < 0
        guard serialization == 1 || isFinal else { return nil }
        // result.text is the ENTIRE utterance. Utterance snippets are not appended.
        let text = (object["result"] as? [String: Any])?["text"] as? String
        return Response(text: text, isFinal: isFinal)
    }

    static func rejection(code: UInt32?, message: String) -> ProviderRejection {
        let lower = message.lowercased()
        let kind: ProviderFailureKind
        if ["concurrency", "concurrent", "rate limit", "overload", "并发", "限流"].contains(where: lower.contains) {
            kind = .transient
        } else if ["quota", "balance", "arrear", "out of credit", "insufficient credit", "余额", "欠费", "额度", "次数", "resource exhausted"].contains(where: lower.contains) {
            kind = .billing
        } else if code == 401 || code == 403 || ["auth", "permission", "api key", "api-key", "access key", "access token", "grant", "鉴权", "权限", "未授权"].contains(where: lower.contains) {
            kind = .auth
        } else if let code, code >= 50_000_000 {
            kind = .transient
        } else {
            kind = ProviderFailureClassifier.classify(message: message)
        }
        return ProviderRejection(failureKind: kind, message: "豆包语音 \(code.map(String.init) ?? "error"): \(message)")
    }

    private static func malformed(_ field: String) -> ASRProviderError {
        .server("豆包协议响应损坏：\(field)")
    }

    /// Native zlib with gzip wrapper (not Apple's raw Compression framework).
    static func gzip(_ input: Data, decompress: Bool) throws -> Data {
        guard input.count <= maximumPayloadBytes else { throw malformed("压缩输入过大") }
        var stream = z_stream()
        let status = decompress
            ? inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw malformed("gzip 初始化 \(status)") }
        defer {
            if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) }
        }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let (result, count) = buffer.withUnsafeMutableBytes { destination -> (Int32, Int) in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    let result = decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                    return (result, destination.count - Int(stream.avail_out))
                }
                guard output.count + count <= maximumPayloadBytes else { throw malformed("gzip 输出过大") }
                output.append(contentsOf: buffer.prefix(count))
                if result == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw malformed("gzip 尾部") }
                    return output
                }
                guard result == Z_OK else { throw malformed("gzip 数据 \(result)") }
            }
        }
    }
}

/// Shared by live provider and offline tests. Final empty frames are termination
/// acknowledgements, so they preserve any last hypothesis (silence stays empty).
struct DoubaoTranscriptState {
    private(set) var text = ""
    private(set) var isFinal = false

    mutating func apply(_ response: DoubaoRealtimeProtocol.Response) {
        if let text = response.text, !text.isEmpty || !response.isFinal { self.text = text }
        isFinal = response.isFinal
    }
}

/// 100 ms PCM packets avoid one gzip/WebSocket send per tiny audio callback.
struct DoubaoAudioPacketizer {
    struct Packet {
        let data: Data
        let audioByteCount: Int
        let isFinal: Bool
    }
    private var batcher = PCMFrameBatcher(targetFrameBytes: 3_200)
    private var sequence: Int32 = 1

    mutating func append(_ audio: Data) throws -> [Packet] {
        try batcher.append(audio).map { try packet($0, final: false) }
    }

    mutating func finish() throws -> [Packet] {
        var packets: [Packet] = []
        if let tail = batcher.flush() { packets.append(try packet(tail, final: false)) }
        packets.append(try packet(Data(), final: true))
        return packets
    }

    private mutating func packet(_ audio: Data, final: Bool) throws -> Packet {
        sequence += 1
        return Packet(data: try DoubaoRealtimeProtocol.audioFrame(audio, sequence: final ? -sequence : sequence),
                      audioByteCount: audio.count, isFinal: final)
    }
}

actor DoubaoASRProvider: ASRProvider, ProviderLivenessReporting {
    nonisolated let id = "volcengine-doubao"
    nonisolated let displayName = "豆包流式语音识别 2.0"

    private enum State { case idle, starting, active, finalizing }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
    private let apiKeyProvider: @Sendable () throws -> String
    private let resourceIDProvider: @Sendable () -> String
    private var state: State = .idle
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var finalContinuation: CheckedContinuation<TranscriptResult, Error>?
    private var eventHandler: (@Sendable (ASREvent) -> Void)?
    private var liveness: ProviderLivenessProbe?
    private var terminalError: Error?
    private var transcript = DoubaoTranscriptState()
    private var packetizer = DoubaoAudioPacketizer()
    private var startedAt = Date()
    private var connectStartedAt = ContinuousClock.now
    private var firstPartialAt: Date?
    private var finalizeRequestedAt: Date?
    private var connectionLatency: Int?
    private var audioBytesSent = 0
    private var audioFrameCount = 0
    private var maxSendLatency = 0
    private var backpressureCount = 0

    init(apiKeyProvider: @escaping @Sendable () throws -> String,
         resourceIDProvider: @escaping @Sendable () -> String = { "volc.seedasr.sauc.duration" }) {
        self.apiKeyProvider = apiKeyProvider
        self.resourceIDProvider = resourceIDProvider
    }

    func prepare(context: ASRContext) async throws {
        _ = context
        _ = try DoubaoRealtimeProtocol.request(apiKey: apiKeyProvider(), resourceID: resourceIDProvider(), connectionID: UUID())
    }

    func attachLiveness(_ probe: ProviderLivenessProbe) async { liveness = probe }

    func startUtterance(id utteranceID: UUID, context: ASRContext,
                        eventHandler: @escaping @Sendable (ASREvent) -> Void) async throws {
        guard state == .idle else { throw ASRProviderError.invalidState("上一段豆包口述尚未结束") }
        let request = try DoubaoRealtimeProtocol.request(apiKey: apiKeyProvider(), resourceID: resourceIDProvider(), connectionID: utteranceID)
        let initial = try DoubaoRealtimeProtocol.initialFrame(context: context)
        generation = UUID()
        let sessionID = generation
        terminalError = nil
        transcript = DoubaoTranscriptState()
        packetizer = DoubaoAudioPacketizer()
        startedAt = Date()
        connectStartedAt = .now
        firstPartialAt = nil
        finalizeRequestedAt = nil
        connectionLatency = nil
        audioBytesSent = 0
        audioFrameCount = 0
        maxSendLatency = 0
        backpressureCount = 0
        self.eventHandler = eventHandler
        state = .starting
        let socket = Self.session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                startContinuation = continuation
                deadlineTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(7)) } catch { return }
                    await self?.fail(ASRProviderError.timeout("豆包未在 7 秒内启动转写"), sessionID: sessionID)
                }
                receiveTask = Task { [weak self] in
                    await self?.receiveLoop(socket: socket, sessionID: sessionID)
                }
                Task { [weak self] in
                    do { try await socket.send(.data(initial)) }
                    catch { await self?.transportFailed(error, socket: socket, sessionID: sessionID) }
                }
            }
        } onCancel: {
            Task { await self.cancel(sessionID: sessionID) }
        }
        try Task.checkCancellation()
    }

    func send(_ chunk: PCM16Chunk) async throws {
        if let terminalError { throw terminalError }
        guard state == .active, let socket else { throw ASRProviderError.invalidState("豆包实时连接尚未就绪") }
        guard chunk.sampleRate == 16_000, chunk.channels == 1, chunk.data.count.isMultiple(of: 2) else {
            throw ASRProviderError.invalidState("豆包输入必须是 16 kHz 单声道 PCM16")
        }
        guard !chunk.data.isEmpty else { return }
        let sessionID = generation
        for packet in try packetizer.append(chunk.data) {
            try await transmit(packet, socket: socket, sessionID: sessionID)
        }
    }

    private func transmit(_ packet: DoubaoAudioPacketizer.Packet, socket: URLSessionWebSocketTask, sessionID: UUID) async throws {
        let start = ContinuousClock.now
        if packet.isFinal { liveness?.markFinalizationStage(.terminalSendStarted) }
        do {
#if DOUBAO_PROTOCOL_TEST
            if let testSend { try await testSend(packet.data) }
            else { try await socket.send(.data(packet.data)) }
#else
            try await socket.send(.data(packet.data))
#endif
        }
        catch {
            guard generation == sessionID else { throw CancellationError() }
            transportFailed(error, socket: socket, sessionID: sessionID)
            throw terminalError ?? error
        }
        guard generation == sessionID else { throw CancellationError() }
        if packet.isFinal { liveness?.markFinalizationStage(.terminalSendCompleted) }
        guard packet.audioByteCount > 0 else { return }
        liveness?.markAudioFrameSent(byteCount: packet.audioByteCount)
        let milliseconds = Int(ProviderLivenessProbe.nanoseconds(start.duration(to: .now)) / 1_000_000)
        audioBytesSent += packet.audioByteCount
        audioFrameCount += 1
        maxSendLatency = max(maxSendLatency, milliseconds)
        if milliseconds >= 240 { backpressureCount += 1 }
    }

    func finalize() async throws -> TranscriptResult {
        if let terminalError { throw terminalError }
        guard state == .active, let socket else { throw ASRProviderError.invalidState("没有活动的豆包口述") }
        let sessionID = generation
        let packets = try packetizer.finish()
        state = .finalizing
        finalizeRequestedAt = Date()
        liveness?.markFinalizationStage(.requested)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptResult, Error>) in
                finalContinuation = continuation
                deadlineTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.fail(ASRProviderError.timeout("豆包未在 10 秒内返回最终转写"), sessionID: sessionID)
                }
                Task { [weak self] in
                    do {
                        for packet in packets {
                            try await self?.transmit(packet, socket: socket, sessionID: sessionID)
                        }
                    } catch { await self?.transportFailed(error, socket: socket, sessionID: sessionID) }
                }
            }
        } onCancel: {
            Task { await self.cancel(sessionID: sessionID) }
        }
    }

    func cancel() async { cancel(sessionID: generation) }

    private func cancel(sessionID: UUID) {
        guard generation == sessionID else { return }
        startContinuation?.resume(throwing: CancellationError())
        finalContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        finalContinuation = nil
        terminalError = nil
        close()
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, sessionID: UUID) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard generation == sessionID else { return }
                switch message {
                case .data(let data): try process(data, sessionID: sessionID)
                case .string(let text): throw DoubaoRealtimeProtocol.rejection(code: nil, message: text)
                @unknown default: throw ASRProviderError.server("豆包返回未知消息类型")
                }
            }
        } catch {
            guard generation == sessionID, !Task.isCancelled else { return }
            transportFailed(error, socket: socket, sessionID: sessionID)
        }
    }

    private func process(_ data: Data, sessionID: UUID) throws {
        liveness?.markServerMessage()
        guard let response = try DoubaoRealtimeProtocol.parse(data) else { return }
        liveness?.markServerProtocolFlags(Int(data[data.startIndex + 1] & 15))
        if state == .starting {
            deadlineTask?.cancel()
            deadlineTask = nil
            connectionLatency = Int(ProviderLivenessProbe.nanoseconds(connectStartedAt.duration(to: .now)) / 1_000_000)
            state = .active
            liveness?.markConnected(reused: false)
            eventHandler?(.connected(providerID: id))
            startContinuation?.resume()
            startContinuation = nil
        }
        transcript.apply(response)
        if response.isFinal { liveness?.markFinalizationStage(.serverFinalReceived) }
        else if let text = response.text { liveness?.markPartial(characterCount: text.count) }
        if let text = response.text, !text.isEmpty {
            if firstPartialAt == nil { firstPartialAt = Date() }
            eventHandler?(response.isFinal ? .finalized(providerID: id, text: transcript.text) : .partial(providerID: id, text: transcript.text))
        }
        if response.isFinal {
            guard state == .finalizing, let continuation = finalContinuation else {
                fail(ASRProviderError.server("豆包在定稿请求前结束了转写"), sessionID: sessionID)
                return
            }
            let finishedAt = Date()
            let result = TranscriptResult(providerID: id, model: DoubaoRealtimeProtocol.model,
                text: transcript.text, tokens: [], startedAt: startedAt, finishedAt: finishedAt,
                firstPartialLatencyMilliseconds: firstPartialAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
                finalizeLatencyMilliseconds: finalizeRequestedAt.map { Int(finishedAt.timeIntervalSince($0) * 1_000) },
                transportMetrics: ProviderTransportMetrics(audioBytesSent: audioBytesSent,
                    audioFrameCount: audioFrameCount, maxSendLatencyMilliseconds: maxSendLatency,
                    backpressureEventCount: backpressureCount, connectionSetupLatencyMilliseconds: connectionLatency,
                    reusedConnection: false, connectionAttemptCount: 1))
            finalContinuation = nil
            close()
            continuation.resume(returning: result)
        }
    }

    private func transportFailed(_ error: Error, socket: URLSessionWebSocketTask, sessionID: UUID) {
        guard generation == sessionID else { return }
        if let status = (socket.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            let kind: ProviderFailureKind = status == 429 ? .transient : ProviderFailureClassifier.httpStatus(status)
            fail(ProviderRejection(failureKind: kind, message: "豆包拒绝连接（HTTP \(status)）"), sessionID: sessionID)
        } else {
            fail(error, sessionID: sessionID)
        }
    }

    private func fail(_ error: Error, sessionID: UUID) {
        guard generation == sessionID else { return }
        terminalError = error
        liveness?.markFailed()
        eventHandler?(.failed(providerID: id, message: error.localizedDescription))
        startContinuation?.resume(throwing: error)
        finalContinuation?.resume(throwing: error)
        startContinuation = nil
        finalContinuation = nil
        close()
    }

    private func close() {
        generation = UUID()
        deadlineTask?.cancel()
        receiveTask?.cancel()
        deadlineTask = nil
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        packetizer = DoubaoAudioPacketizer()
        liveness = nil
        eventHandler = nil
        state = .idle
    }
#if DOUBAO_PROTOCOL_TEST
    private var testSend: (@Sendable (Data) async throws -> Void)?

    // The production send/finalize bodies run unchanged; only socket I/O is
    // replaced. The placeholder URLSession task is never resumed.
    func testSetTransport(_ send: @escaping @Sendable (Data) async throws -> Void) {
        testSend = send
        socket = Self.session.webSocketTask(with: DoubaoRealtimeProtocol.endpoint)
        packetizer = DoubaoAudioPacketizer()
    }

    // Offline dispatch seam: no credential lookup or network calls.
    func testBegin(eventHandler: @escaping @Sendable (ASREvent) -> Void) -> UUID {
        generation = UUID()
        terminalError = nil
        transcript = DoubaoTranscriptState()
        startedAt = Date()
        firstPartialAt = nil
        self.eventHandler = eventHandler
        state = .active
        return generation
    }

    func testReceive(_ data: Data, sessionID: UUID) throws {
        guard generation == sessionID else { return }
        try process(data, sessionID: sessionID)
    }

    func testFinalize(response: Data) async throws -> TranscriptResult {
        state = .finalizing
        finalizeRequestedAt = Date()
        let sessionID = generation
        return try await withCheckedThrowingContinuation { continuation in
            finalContinuation = continuation
            do { try process(response, sessionID: sessionID) }
            catch { fail(error, sessionID: sessionID) }
        }
    }
#endif

}
