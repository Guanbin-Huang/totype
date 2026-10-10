import Foundation

#if BASELINE
// Original immutable result predates Swift 6 concurrency annotation; test-only conformance.
extension ChatPolishResult: @unchecked Sendable {}
#endif

enum RoutingTestError: Error { case assertion(String) }

/// Intercepts every request locally; no request reaches the Ark endpoint.
final class RoutingFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        private var suspended = false
        private var stops = 0
        func reset(suspended: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            bodies = []; stops = 0; self.suspended = suspended
        }
        func record(_ data: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            bodies.append(data); return suspended
        }
        func snapshot() -> (bodies: [Data], stops: Int) {
            lock.lock(); defer { lock.unlock() }
            return (bodies, stops)
        }
        func stopped() {
            lock.lock(); defer { lock.unlock() }
            stops += 1
        }
    }
    static let store = Store()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body: Data
            if let data = request.httpBody {
                body = data
            } else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError! }
                    if count == 0 { break }
                    collected.append(buffer, count: count)
                }
                body = collected
            } else {
                throw RoutingTestError.assertion("missing request body")
            }
            if Self.store.record(body) { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            let data = Data(#"{"choices":[{"message":{"content":"fixture polished output"},"finish_reason":"stop"}]}"#.utf8)
            client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client!.urlProtocol(self, didLoad: data)
            client!.urlProtocolDidFinishLoading(self)
        } catch {
            client!.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { Self.store.stopped() }
}

@main
struct ShortModelRoutingTests {
    static let mini = "doubao-seed-2-0-mini-260428"
    static let lite = "doubao-seed-2-0-lite-260428"
    static let prompt = "原始模式提示：保留语气，只整理正文。\nPROMPT_SENTINEL"
    static let hints = "明姐 → 敏姐；明杰 → 敏姐\nToType\nRAG"
    static let background = "说话人背景原文 BACKGROUND_SENTINEL"

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw RoutingTestError.assertion(message) }
    }
    static func body(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    @MainActor static func run() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let polisher = ChatTextPolisher(session: session)
        let cases: [(String, String)] = [
            ("反正你自己想办法去解决吧。", mini),
            ("以后如何避免这种问题？", mini),
            ("f 十一和 f 十二这个乔大小熊没有 it's not working they're not working", lite),
            ("用F11调节音量", lite),
            ("这个乔大小熊识别错了", lite),
            ("they're not working", lite),
            ("音量调到11", lite),
            ("音量调到十一", lite),
            ("这个办法没有效果", lite),
            ("我不想去解决问题", lite),
            ("换成明天还是算了", lite),
            ("引用“乔大小熊”这个词", lite),
            ("分点列出解决办法", lite),
            ("这段文字应该保留语气和条件并且完整描述原始问题所涉及的背景以及用户实际表达出来的所有关键信息", lite),
            ("明姐跟我的工作。", lite),
            ("明杰跟我的工作。", lite),
            ("敏姐跟我的工作。", lite),
            ("未收到消息", lite),
            ("勿打扰", lite),
            ("明天甭来了", lite),
            ("这里有半杯水", lite),
            ("这里有壹元", lite),
            ("把前面这句话合并", lite),
            ("我想想办法", lite),
            ("解决问题解决问题", lite)
        ]
        for (text, expectedModel) in cases {
            RoutingFixtureProtocol.store.reset()
            let result = try await polisher.polish(text: text, prompt: prompt, termHints: hints, speakerBackground: background, apiKey: "fixture-not-a-key")
            let requests = RoutingFixtureProtocol.store.snapshot().bodies
            try check(requests.count == 1, "exactly one nonstreaming request per final")
            let request = try body(requests[0])
            let actual = request["model"] as? String
            try check(actual == expectedModel, "model for \(text): expected \(expectedModel), actual \(actual ?? "nil")")
            #if !BASELINE
            try check(result.model == expectedModel, "result.model matches actual request")
            #endif
            try check(result.text == "fixture polished output", "real response parsing")
            try check(request["stream"] == nil, "streaming remains disabled")
            try check(request["temperature"] as? Int == 0 && request["max_tokens"] as? Int == 2048, "inference settings preserved")
            let messages = request["messages"] as! [[String: String]]
            try check(messages.count == 2 && messages[0]["role"] == "system" && messages[1]["role"] == "user", "message roles preserved")
            let system = messages[0]["content"]!
            try check(system.hasPrefix(prompt + "\n\n"), "complete original prompt preserved")
            try check(system.contains("\n" + hints + "\n") && system.contains("\n" + background + "\n"), "hints and background unchanged")
            try check(messages[1]["content"] == "--- 原始转写开始 ---\n\(text)\n--- 原始转写结束 ---", "raw input preserved exactly")
            print("PASS model=\(actual!) input=\(text)")
        }
        #if !BASELINE
        // Short simple prompts retain the same full system body as Lite prompts.
        func capture(_ text: String) async throws -> String {
            RoutingFixtureProtocol.store.reset()
            _ = try await polisher.polish(text: text, prompt: prompt, termHints: hints, speakerBackground: background, apiKey: "fixture-not-a-key")
            let request = try body(RoutingFixtureProtocol.store.snapshot().bodies[0])
            return (request["messages"] as! [[String: String]])[0]["content"]!
        }
        let miniSystem = try await capture(cases[0].0)
        let liteSystem = try await capture(cases[2].0)
        try check(miniSystem == liteSystem, "model route never changes full system prompt")
        print("PASS Mini/Lite full system prompt byte equality")
        #endif

        RoutingFixtureProtocol.store.reset(suspended: true)
        let pending = Task {
            try await polisher.polish(text: cases[0].0, prompt: prompt, termHints: hints, speakerBackground: background, apiKey: "fixture-not-a-key")
        }
        for _ in 0..<100 {
            if !RoutingFixtureProtocol.store.snapshot().bodies.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try check(RoutingFixtureProtocol.store.snapshot().bodies.count == 1, "cancellation fixture received request")
        pending.cancel()
        do {
            _ = try await pending.value
            throw RoutingTestError.assertion("cancellation was swallowed")
        } catch is CancellationError {}
        try check(RoutingFixtureProtocol.store.snapshot().bodies.count == 1, "cancelled request never retries")
        print("PASS in-flight cancellation propagates without retry")
        print("ALL ROUTING TESTS PASSED; no paid calls")
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }
}
