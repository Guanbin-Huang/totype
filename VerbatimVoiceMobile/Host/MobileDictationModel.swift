import SwiftUI
import AVFoundation
import UIKit

@MainActor
final class MobileDictationModel: ObservableObject {
    @Published var text = ""
    @Published var status = "在目标应用的 ToType 键盘点说话，激活录音后自动返回；说完点停止并输入。"
    @Published var errorMessage: String?
    @Published var phase = Phase.idle
    @Published var vocabulary = MobileVocabulary()
    @Published var editingWindow = false
    @Published var learningEnabled = false
    @Published var diagnosticStatus = "尚未验证"
    @Published private(set) var bridgeActive = false
    var activeVoiceRequestID: UUID? { bridgeRequest?.id }
    var originBundleID: String? { bridgeRequest?.sourceBundleID }
    var onRecordingReady: (() -> Void)?
    var returnToOrigin: (() -> Void)?
    private var bridgeRequest: MobileVoiceRequest?
    private var bridgePoll: Task<Void, Never>?
    private var bridgeCommands: Set<UUID> = []
    enum Phase { case idle, starting, recording, finalizing }
    private let provider = DoubaoASRProvider(apiKeyProvider: { try MobileCredentialStore.load() })
    private let audio = MobileAudioCapture()
    private var sender: Task<Void, Error>?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var isCancelling = false
    private var original = ""
    private var editTask: Task<Void, Never>?
    private var lastEdit = Date()
    private var observationDeadline = Date()
    private var observedText = ""
    #if DEBUG
    private var smokeStarted = false
    #endif

    func initialize() {
        do { try MobileCredentialStore.importBootstrap() }
        catch { errorMessage = error.localizedDescription }
        refreshVocabulary()
        refreshSettingsAndDiagnostics()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--totype-asr-smoke"), !smokeStarted, phase == .idle {
            smokeStarted = true
            phase = .starting
            status = "正在运行显式合成静音网络测试；不会开启麦克风。"
            let id = UUID(); generation = id
            operation = Task {
                do {
                    let result = try await MobileASRSmoke.run(provider: provider)
                    guard generation == id else { return }
                    status = result.success ? "合成静音网络测试已完成；结果已写入诊断文件。" : "合成静音网络测试结束：\(result.errorClassification)；结果已写入诊断文件。"
                } catch {
                    guard generation == id else { return }
                    errorMessage = "测试诊断文件写入失败：\(error.localizedDescription)"
                }
                guard generation == id else { return }
                phase = .idle
            }
        }
        #endif
    }
    func refreshSettingsAndDiagnostics() {
        do { learningEnabled = try MobileSharedStore.learningEnabled(fullAccess: true) }
        catch { errorMessage = error.localizedDescription; learningEnabled = false }
        if !learningEnabled { endObservation() }
        do {
            let result = try MobileHostDiagnostics.writeStatus(learningEnabled: learningEnabled)
            diagnosticStatus = "私有凭据：\(result.credentialPrivateReadback ? "已验证" : result.credentialStatus)；共享存储：\(result.sharedRoundTrip ? "已验证" : result.sharedStatus)；键盘：\(result.keyboard?.available == true ? "已回读" : "待开启")"
        } catch { errorMessage = error.localizedDescription; diagnosticStatus = "诊断文件写入失败" }
    }
    func setLearningEnabled(_ enabled: Bool) {
        do {
            try MobileSharedStore.setLearningEnabled(enabled, fullAccess: true)
            learningEnabled = enabled
            if !enabled { endObservation() }
            refreshSettingsAndDiagnostics()
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshVocabulary() {
        do { vocabulary = try MobileSharedStore.vocabulary(fullAccess: true) }
        catch { errorMessage = error.localizedDescription }
    }
    func handleDictationURL(_ url: URL) {
        guard url.scheme == "totype", url.host == "dictate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawID = components.queryItems?.first(where: { $0.name == "request" })?.value,
              let requestedID = UUID(uuidString: rawID) else { return }
        guard phase == .idle, !bridgeActive else { return }
        do {
            guard let request = try MobileVoiceBridge.request(fullAccess: true), request.id == requestedID,
                  (0...30).contains(Date().timeIntervalSince(request.createdAt)),
                  request.contextFingerprint.utf8.count <= 128 else {
                throw ASRProviderError.unavailable("键盘语音请求已失效，请重新点击语音。")
            }
            let used = UserDefaults.standard.stringArray(forKey: "acceptedVoiceRequestIDs") ?? []
            guard !used.contains(request.id.uuidString),
                  try MobileVoiceBridge.status(fullAccess: true)?.requestID != request.id else { return }
            // Persist acceptance before opening microphone: URL replay cannot restart this request.
            try MobileVoiceBridge.saveStatus(MobileVoiceStatus(requestID: request.id, phase: .starting,
                pendingTranscriptID: nil, error: nil, updatedAt: Date()), fullAccess: true)
            UserDefaults.standard.set(Array((used + [request.id.uuidString]).suffix(128)), forKey: "acceptedVoiceRequestIDs")
            bridgeRequest = request; bridgeActive = true; bridgeCommands.removeAll()
            start()
            bridgePoll = Task {
                let deadline = Date().addingTimeInterval(120)
                while bridgeActive, bridgeRequest?.id == request.id {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard bridgeActive, bridgeRequest?.id == request.id else { return }
                    if Date() >= deadline { cancel(failure: "语音会话已达到 120 秒上限。"); return }
                    do {
                        guard let command = try MobileVoiceBridge.command(fullAccess: true),
                              command.requestID == request.id, !bridgeCommands.contains(command.id),
                              command.createdAt >= request.createdAt,
                              (0...120).contains(Date().timeIntervalSince(command.createdAt)) else { continue }
                        bridgeCommands.insert(command.id)
                        switch command.action {
                        case .stop:
                            if phase == .recording { stop() }
                            else if phase == .starting { cancel(); return }
                        case .cancel: cancel(); return
                        }
                    } catch { cancel(failure: "共享语音控制读取失败。"); errorMessage = error.localizedDescription; return }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    private func publishBridge(_ phase: MobileVoicePhase, pendingID: UUID? = nil, error: String? = nil) -> Bool {
        guard let request = bridgeRequest else { return true }
        do {
            try MobileVoiceBridge.saveStatus(MobileVoiceStatus(requestID: request.id, phase: phase,
                pendingTranscriptID: pendingID, error: error, updatedAt: Date()), fullAccess: true)
            return true
        } catch { errorMessage = "共享语音状态写入失败：\(error.localizedDescription)"; return false }
    }
    private func finishBridge(_ phase: MobileVoicePhase, pendingID: UUID? = nil, error: String? = nil) {
        publishBridge(phase, pendingID: pendingID, error: error)
        bridgePoll?.cancel(); bridgePoll = nil; bridgeActive = false; bridgeRequest = nil
    }
    func start() {
        guard phase == .idle else { return }
        editTask?.cancel(); editingWindow = false
        phase = .starting; errorMessage = nil; text = ""
        guard publishBridge(.starting) else { phase = .idle; finishBridge(.failed, error: "共享语音状态写入失败。"); return }
        let id = UUID(); generation = id
        operation = Task {
            do {
                let permitted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                }
                guard permitted else { throw ASRProviderError.unavailable("请在系统设置中允许麦克风访问") }
                guard generation == id, !Task.isCancelled else { throw CancellationError() }
                var terms: [String] = []
                do { terms = Array(try MobileSharedStore.vocabulary(fullAccess: true).terms.reversed()) }
                catch { errorMessage = error.localizedDescription }
                let context = ASRContext.personal(terms: terms)
                try await provider.prepare(context: context)
                guard generation == id, !Task.isCancelled else { throw CancellationError() }
                try await provider.startUtterance(id: id, context: context) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        switch event {
                        case .partial(_, let value), .finalized(_, let value): self.text = value
                        case .warning(_, let message), .failed(_, let message): self.errorMessage = message
                        case .connected: break
                        }
                    }
                }
                guard generation == id, !Task.isCancelled else { throw CancellationError() }
                audio.onInterruption = { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.phase == .recording else { return }
                        self.cancel(failure: message)
                    }
                }
                let stream = try audio.start()
                sender = Task {
                    do {
                        for try await chunk in stream { try Task.checkCancellation(); try await provider.send(chunk) }
                    } catch {
                        if generation == id, !Task.isCancelled {
                            audio.finish()
                            await provider.cancel()
                            guard generation == id else { throw error }
                            phase = .idle
                            errorMessage = error.localizedDescription
                            finishBridge(.failed, error: "录音或语音连接已中断，请重新开始。")
                            do { try audio.deactivate() } catch { errorMessage = error.localizedDescription }
                        }
                        throw error
                    }
                }
                phase = .recording; status = "正在录音；其他音频不会被主动压低。"
                guard publishBridge(.recording) else { cancel(failure: "共享语音状态写入失败。"); return }
                if bridgeActive { onRecordingReady?() }
            } catch {
                guard generation == id else { return }
                audio.finish()
                await provider.cancel()
                guard generation == id else { return }
                phase = .idle
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                finishBridge(error is CancellationError ? .cancelled : .failed, error: "语音启动未完成，请重新开始。")
                do { try audio.deactivate() } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    func stop() {
        guard phase == .recording else { return }
        phase = .finalizing
        guard publishBridge(.finalizing) else { cancel(failure: "共享语音状态写入失败。"); return }
        let id = generation
        let backgroundID: UIBackgroundTaskIdentifier = bridgeActive
            ? UIApplication.shared.beginBackgroundTask(withName: "ToType finalize") { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == id, self.phase == .finalizing else { return }
                    self.cancel(failure: "后台定稿时间已结束，请返回主应用重试。")
                }
            } : .invalid
        audio.finish()
        operation = Task {
            defer {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
            }
            do {
                try await sender?.value
                guard generation == id, !Task.isCancelled else { return }
                let result = try await provider.finalize()
                guard generation == id, !Task.isCancelled else { return }
                if let request = bridgeRequest,
                   MobileVoiceHandoffPolicy.isCancelled(request: request,
                       command: try MobileVoiceBridge.command(fullAccess: true)) {
                    cancel(); return
                }
                text = result.text
                status = learningEnabled ? "转写完成。10 秒内的稳定替换会生成本地候选；复制或返回目标应用插入。" : "转写完成。学习已关闭；复制或返回目标应用插入。"
                do {
                    try MobileSharedStore.publish(text, fullAccess: true)
                    if bridgeActive {
                        guard let pending = try MobileSharedStore.pending(fullAccess: true) else { throw MobileStoreError.verificationFailed }
                        finishBridge(.completed, pendingID: pending.id)
                    }
                } catch {
                    errorMessage = "转写已保留；键盘交接失败：\(error.localizedDescription)"
                    finishBridge(.failed, error: "转写已完成，但键盘交接失败。")
                }
                beginObservation()
            } catch {
                guard generation == id else { return }
                await provider.cancel()
                guard generation == id else { return }
                errorMessage = error.localizedDescription
                finishBridge(.failed, error: "语音定稿失败，请重新开始。")
            }
            guard generation == id else { return }
            phase = .idle
            do { try audio.deactivate() } catch { errorMessage = error.localizedDescription }
        }
    }
    func cancel(failure: String? = nil) {
        guard phase != .idle, !isCancelling else { return }
        isCancelling = true
        generation = UUID()
        let id = generation
        operation?.cancel(); sender?.cancel()
        audio.finish()
        bridgePoll?.cancel(); bridgePoll = nil
        phase = .finalizing
        operation = Task {
            await provider.cancel()
            guard generation == id else { return }
            isCancelling = false
            phase = .idle; text = ""; status = failure ?? "录音已取消。"
            if let failure { errorMessage = failure }
            finishBridge(failure == nil ? .cancelled : .failed, error: failure)
            do { try audio.deactivate() } catch { errorMessage = error.localizedDescription }
        }
    }
    func publishEditedTranscript() {
        guard phase == .idle, !text.isEmpty else { return }
        do {
            try MobileSharedStore.publish(text, fullAccess: true)
            status = "键盘待插入转写已更新为编辑后的全文。请手动返回目标应用插入。"
        } catch { errorMessage = error.localizedDescription }
    }
    func edited() {
        guard editingWindow, Date() < observationDeadline else { return }
        lastEdit = Date(); observedText = text
    }
    func endObservation() { editTask?.cancel(); editingWindow = false }
    private func beginObservation() {
        guard learningEnabled else { return }
        original = text; observedText = text; lastEdit = Date(); editingWindow = true
        observationDeadline = Date().addingTimeInterval(EditLearningPolicy.observationDuration)
        editTask?.cancel()
        editTask = Task {
            do { try await Task.sleep(for: .seconds(EditLearningPolicy.observationDuration)) }
            catch { return }
            editingWindow = false
            guard learningEnabled, Date().timeIntervalSince(lastEdit) >= 0.7 else { return }
            do {
                try MobileSharedStore.observe(original: original, edited: observedText, fullAccess: true)
                refreshVocabulary()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func confirm(_ candidate: MobileCorrection) {
        do {
            var value = try MobileSharedStore.vocabulary(fullAccess: true)
            guard !candidate.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ASRProviderError.unavailable("纯删除不是可添加的识别词条；请选择忽略。")
            }
            if !value.terms.contains(candidate.corrected) { value.terms.append(candidate.corrected) }
            value.terms = Array(value.terms.suffix(500))
            value.candidates.removeAll { $0.id == candidate.id }
            try MobileSharedStore.save(value, fullAccess: true); vocabulary = value
        } catch { errorMessage = error.localizedDescription }
    }
    func removeTerm(_ term: String) {
        do {
            var value = try MobileSharedStore.vocabulary(fullAccess: true)
            value.terms.removeAll { $0 == term }
            value.candidates.removeAll { $0.corrected == term }
            try MobileSharedStore.save(value, fullAccess: true); vocabulary = value
        } catch { errorMessage = error.localizedDescription }
    }
    func discard(_ candidate: MobileCorrection) {
        do {
            var value = try MobileSharedStore.vocabulary(fullAccess: true)
            value.candidates.removeAll { $0.id == candidate.id }
            try MobileSharedStore.save(value, fullAccess: true); vocabulary = value
        } catch { errorMessage = error.localizedDescription }
    }
}
