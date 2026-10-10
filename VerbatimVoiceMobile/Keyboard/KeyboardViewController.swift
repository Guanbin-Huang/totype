import UIKit
import SwiftUI
import Security

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let insertButton = UIButton(type: .system)
    private let typingView = KeyboardTypingView()
    private var pending: MobilePendingTranscript?
    private var observation: Observation?
    private var timer: Timer?
    private var diagnosticWritten = false
    private var voiceTimer: Timer?
    private var voiceRequest: MobileVoiceRequest?
    private var voiceLauncher: UIHostingController<KeyboardVoiceLauncher>?
    private let stopButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var attemptedInsertion: UUID?
    private var cancelledRequestID: UUID?
    private var lastVoiceStatus: String?
    private var lastDiagnosticStage: String?
    private var typingDocumentID: UUID?

    private struct Observation {
        let documentID: UUID
        let original: String
        let prefix: String
        let suffix: String
        let started: Date
        var edited: String
        var lastChange: Date
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 2; statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        stack.addArrangedSubview(statusLabel)
        let launcher = UIHostingController(rootView: KeyboardVoiceLauncher(
            prepare: { [weak self] in self?.prepareVoiceRequest() },
            completion: { [weak self] accepted in
                if !accepted { self?.statusLabel.text = "系统未接受语音跳转，请在主应用查看状态。" }
            }))
        voiceLauncher = launcher
        let voiceRow = UIStackView()
        voiceRow.spacing = 6; voiceRow.distribution = .fillEqually
        addChild(launcher); voiceRow.addArrangedSubview(launcher.view); launcher.didMove(toParent: self)
        launcher.view.backgroundColor = .clear
        launcher.view.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stopButton.setTitle("停止并输入", for: .normal)
        stopButton.accessibilityIdentifier = "totype.voice.stop"
        stopButton.addTarget(self, action: #selector(stopVoice), for: .touchUpInside)
        cancelButton.setTitle("取消语音", for: .normal)
        cancelButton.accessibilityIdentifier = "totype.voice.cancel"
        cancelButton.addTarget(self, action: #selector(cancelVoice), for: .touchUpInside)
        voiceRow.addArrangedSubview(stopButton); voiceRow.addArrangedSubview(cancelButton)
        stopButton.titleLabel?.font = .systemFont(ofSize: 14)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 14)
        stack.addArrangedSubview(voiceRow)
        insertButton.setTitle("插入最近转写", for: .normal)
        insertButton.addTarget(self, action: #selector(insertLatest), for: .touchUpInside)
        stack.addArrangedSubview(insertButton)
        typingView.onInsertText = { [weak self] text in
            guard let self else { return }
            guard self.typingDocumentID == self.textDocumentProxy.documentIdentifier else {
                self.synchronizeTypingDocument(); return
            }
            self.textDocumentProxy.insertText(text); self.sampleObservation()
        }
        typingView.onDeleteBackward = { [weak self] in
            self?.textDocumentProxy.deleteBackward(); self?.sampleObservation()
        }
        typingView.onNextKeyboard = { [weak self] in self?.nextKeyboard() }
        stack.addArrangedSubview(typingView)
        typingView.heightAnchor.constraint(equalToConstant: 250).isActive = true
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 350)
        ])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        MobileHostAppResolver.prepare()
        synchronizeTypingDocument()
        refresh()
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshVoice() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        stopObservation(); voiceTimer?.invalidate(); voiceTimer = nil
        super.viewWillDisappear(animated)
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        synchronizeTypingDocument()
        if observation != nil { sampleObservation() } else { refresh() }
    }
    private func synchronizeTypingDocument() {
        let documentID = textDocumentProxy.documentIdentifier
        if let typingDocumentID, typingDocumentID != documentID { typingView.discardComposition() }
        typingDocumentID = documentID
    }
    private func refresh() {
        guard hasFullAccess else {
            pending = nil; insertButton.isEnabled = false
            statusLabel.text = "请先在系统设置为 ToType 开启完全访问。"
            voiceLauncher?.view.isUserInteractionEnabled = false; stopButton.isEnabled = false; cancelButton.isEnabled = false
            return
        }
        do {
            if !diagnosticWritten {
                var privateStatus: Int32? = nil
                #if DEBUG
                // Status-only entitlement probe. No return-data flag, no secret retrieval or logging.
                let query = MobileKeychain.query("doubaoCredential", group: MobileKeychain.privateGroup)
                privateStatus = SecItemCopyMatching(query as CFDictionary, nil)
                #endif
                let roundTrip = try MobileSharedStore.diagnosticRoundTrip(fullAccess: hasFullAccess)
                let value = MobileKeyboardDiagnostic(available: true, fullAccess: hasFullAccess,
                    sharedRoundTrip: roundTrip, privateGroupQueryStatus: privateStatus)
                try MobileSharedStore.saveKeyboardDiagnostic(value, fullAccess: hasFullAccess)
                diagnosticWritten = true
            }
            voiceLauncher?.view.isUserInteractionEnabled = true
            pending = try MobileSharedStore.pending(fullAccess: hasFullAccess)
            insertButton.isEnabled = pending != nil
            if voiceRequest == nil {
                statusLabel.text = pending == nil ? "点击说话，激活录音后返回这里；完成时点停止并输入。" : "转写已就绪；点击插入一次。"
            }
            refreshVoice()
        } catch {
            pending = nil; insertButton.isEnabled = false; statusLabel.text = error.localizedDescription
        }
    }
    private func prepareVoiceRequest() -> URL? {
        guard hasFullAccess else { refresh(); return nil }
        stopObservation()
        synchronizeTypingDocument()
        typingView.commitComposition()
        let proxy = textDocumentProxy
        let id = UUID()
        let fingerprint = MobileVoiceHandoffPolicy.fingerprint(requestID: id,
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput, selected: proxy.selectedText) ?? ""
        var request = MobileVoiceRequest(id: id, documentID: proxy.documentIdentifier,
            contextFingerprint: fingerprint, createdAt: Date())
        request.sourceBundleID = MobileHostAppResolver.sourceBundleID(controller: self)
        do {
            try MobileVoiceBridge.saveRequest(request, fullAccess: hasFullAccess)
            voiceRequest = request; attemptedInsertion = nil; cancelledRequestID = nil; lastVoiceStatus = nil
            lastDiagnosticStage = nil
            try recordHandoff(request, stage: "requested")
            statusLabel.text = "正在打开 ToType 激活麦克风…"
            return URL(string: "totype://dictate?request=\(id.uuidString)")
        } catch { statusLabel.text = error.localizedDescription; return nil }
    }
    @objc private func stopVoice() { sendVoiceCommand(.stop) }
    @objc private func cancelVoice() { sendVoiceCommand(.cancel) }
    private func sendVoiceCommand(_ action: MobileVoiceAction) {
        guard hasFullAccess, let request = voiceRequest else { return }
        guard cancelledRequestID != request.id || action == .cancel else { return }
        // Stop local insertion immediately, even before the host polls the shared cancel.
        if action == .cancel { cancelledRequestID = request.id; pending = nil; insertButton.isEnabled = false }
        do {
            try MobileVoiceBridge.saveCommand(MobileVoiceCommand(id: UUID(), requestID: request.id,
                action: action, createdAt: Date()), fullAccess: hasFullAccess)
            statusLabel.text = action == .stop ? "正在停止并识别…" : "正在取消…"
            stopButton.isEnabled = false; cancelButton.isEnabled = action == .stop
        } catch {
            statusLabel.text = "控制同步失败：\(error.localizedDescription)；请重试取消。"
            cancelButton.isEnabled = true
        }
    }
    private func refreshVoice() {
        guard hasFullAccess else { return }
        do {
            guard let request = try MobileVoiceBridge.request(fullAccess: hasFullAccess),
                  (0...180).contains(Date().timeIntervalSince(request.createdAt)),
                  let status = try MobileVoiceBridge.status(fullAccess: hasFullAccess), status.requestID == request.id else {
                stopButton.isEnabled = false; cancelButton.isEnabled = false
                voiceLauncher?.view.isUserInteractionEnabled = true
                return
            }
            voiceRequest = request
            let command = try MobileVoiceBridge.command(fullAccess: hasFullAccess)
            let persistedCancel = MobileVoiceHandoffPolicy.isCancelled(request: request, command: command)
            let cancelled = cancelledRequestID == request.id || persistedCancel
            let active = status.phase == .starting || status.phase == .recording || status.phase == .finalizing
            voiceLauncher?.view.isUserInteractionEnabled = !active
            voiceLauncher?.view.alpha = active ? 0.45 : 1
            stopButton.isEnabled = status.phase == .recording && !cancelled
            cancelButton.isEnabled = active && !cancelled
            if cancelled {
                cancelledRequestID = request.id
                pending = nil; insertButton.isEnabled = false
                cancelButton.isEnabled = !persistedCancel
                if persistedCancel, let pendingID = status.pendingTranscriptID {
                    // Discard a result that raced with cancellation, including manual insertion.
                    _ = try MobileSharedStore.consume(pendingID, fullAccess: hasFullAccess)
                }
                statusLabel.text = !persistedCancel ? "取消尚未同步，请点取消重试。" : (active ? "正在取消…" : "已取消，不插入文字。")
                try recordHandoff(request, stage: persistedCancel ? "cancelled" : "cancel_pending_sync")
                return
            }
            let key = request.id.uuidString + status.phase.rawValue
            if key != lastVoiceStatus {
                lastVoiceStatus = key
                switch status.phase {
                case .starting: statusLabel.text = "正在激活麦克风…"
                case .recording: statusLabel.text = "正在听 · 说完点停止并输入"
                case .finalizing: statusLabel.text = "正在识别…"
                case .cancelled: statusLabel.text = "已取消，不插入文字。"
                case .failed: statusLabel.text = status.error ?? "本次语音未完成，请重新开始。"
                case .completed: statusLabel.text = "识别完成。"
                }
            }
            guard status.phase == .completed, attemptedInsertion != request.id, !typingView.hasComposition else { return }
            guard let transcript = try MobileSharedStore.pending(fullAccess: hasFullAccess),
                  transcript.id == status.pendingTranscriptID else { return }
            let proxy = textDocumentProxy
            let fingerprint = MobileVoiceHandoffPolicy.fingerprint(requestID: request.id,
                before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput, selected: proxy.selectedText)
            pending = transcript; insertButton.isEnabled = true
            guard MobileVoiceHandoffPolicy.mayInsert(request: request, status: status, pendingID: transcript.id,
                documentID: proxy.documentIdentifier, currentFingerprint: fingerprint, now: Date(), command: command) else {
                try recordHandoff(request, stage: "target_not_ready",
                    documentMatches: proxy.documentIdentifier == request.documentID,
                    contextMatches: fingerprint == request.contextFingerprint)
                statusLabel.text = "文字已就绪；输入位置有变化，请确认后点插入。"; return
            }
            attemptedInsertion = request.id
            insertLatest()
        } catch { statusLabel.text = error.localizedDescription; stopButton.isEnabled = false; cancelButton.isEnabled = false }
    }
    @objc private func nextKeyboard() { stopObservation(); advanceToNextInputMode() }
    @objc private func insertLatest() {
        stopObservation()
        guard hasFullAccess, let pending else { refresh(); return }
        let proxy = textDocumentProxy
        let documentID = proxy.documentIdentifier
        let prefix = proxy.documentContextBeforeInput
        let suffix = proxy.documentContextAfterInput
        do {
            let command = try MobileVoiceBridge.command(fullAccess: hasFullAccess)
            if let request = try MobileVoiceBridge.request(fullAccess: hasFullAccess),
               let status = try MobileVoiceBridge.status(fullAccess: hasFullAccess),
               status.requestID == request.id, status.pendingTranscriptID == pending.id,
               cancelledRequestID == request.id || MobileVoiceHandoffPolicy.isCancelled(request: request,
                   command: command) {
                self.pending = nil; insertButton.isEnabled = false
                statusLabel.text = "已取消，不插入文字。"; return
            }
            guard let value = try MobileSharedStore.consume(pending.id, fullAccess: hasFullAccess) else { refresh(); return }
            proxy.insertText(value.text)
            self.pending = nil; insertButton.isEnabled = false
            if let request = voiceRequest, attemptedInsertion == request.id {
                try recordHandoff(request, stage: "inserted", documentMatches: true, contextMatches: true)
            }
            guard try MobileSharedStore.learningEnabled(fullAccess: hasFullAccess) else {
                statusLabel.text = "已插入；纠错学习已关闭。"; return
            }
            statusLabel.text = "已插入；10 秒内观察当前输入位置的稳定纠错。"
            // Nil contexts, long/truncated contexts and non-unique anchors are not observable.
            guard let prefix, let suffix, value.text.count <= 1500 else {
                statusLabel.text = "已插入；当前应用未提供可核验上下文，不记录纠错。"; return
            }
            guard proxy.documentIdentifier == documentID,
                  proxy.selectedText?.isEmpty != false,
                  let verifiedBefore = proxy.documentContextBeforeInput,
                  let verifiedAfter = proxy.documentContextAfterInput,
                  verifiedBefore + verifiedAfter == prefix + value.text + suffix else {
                statusLabel.text = "已插入；完整插入区间未核验，不记录纠错。"; return
            }
            observation = Observation(documentID: documentID, original: value.text,
                prefix: prefix, suffix: suffix, started: Date(), edited: value.text, lastChange: Date())
            sampleObservation()
            if observation != nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.sampleObservation() }
            }
        } catch { statusLabel.text = error.localizedDescription; insertButton.isEnabled = false }
    }
    private func recordHandoff(_ request: MobileVoiceRequest, stage: String,
                               documentMatches: Bool? = nil, contextMatches: Bool? = nil) throws {
        let key = stage + "|" + String(describing: documentMatches) + "|" + String(describing: contextMatches)
        guard lastDiagnosticStage != key else { return }
        try MobileVoiceBridge.saveDiagnostic(MobileVoiceDiagnostic(requestID: request.id, stage: stage,
            sourceResolved: request.sourceBundleID != nil, documentMatches: documentMatches,
            contextMatches: contextMatches, updatedAt: Date()), fullAccess: hasFullAccess)
        lastDiagnosticStage = key
    }
    private func sampleObservation() {
        guard var value = observation else { return }
        let proxy = textDocumentProxy
        guard hasFullAccess, proxy.documentIdentifier == value.documentID,
              proxy.selectedText?.isEmpty != false,
              let before = proxy.documentContextBeforeInput, let after = proxy.documentContextAfterInput else {
            stopObservation(); return
        }
        do {
            guard try MobileSharedStore.learningEnabled(fullAccess: hasFullAccess) else { stopObservation(); return }
        } catch { stopObservation(); statusLabel.text = error.localizedDescription; return }
        if Date().timeIntervalSince(value.started) >= EditLearningPolicy.observationDuration {
            stopObservation()
            guard Date().timeIntervalSince(value.lastChange) >= 0.7 else { return }
            do {
                try MobileSharedStore.observe(original: value.original, edited: value.edited, fullAccess: hasFullAccess)
                statusLabel.text = "插入完成；本次 10 秒观察已结束。候选可在主应用查看。"
            } catch { statusLabel.text = error.localizedDescription }
            return
        }
        let context = before + after
        // Require both original surrounding contexts to remain visible and unchanged.
        // Unique matching prevents attributing another span or a truncated context to our insert.
        guard context.hasPrefix(value.prefix), context.hasSuffix(value.suffix),
              context.count >= value.prefix.count + value.suffix.count else { stopObservation(); return }
        let start = context.index(context.startIndex, offsetBy: value.prefix.count)
        let end = context.index(context.endIndex, offsetBy: -value.suffix.count)
        let edited = String(context[start..<end])
        if !value.prefix.isEmpty {
            guard context.components(separatedBy: value.prefix).count == 2 else { stopObservation(); return }
        }
        if !value.suffix.isEmpty {
            guard context.components(separatedBy: value.suffix).count == 2 else { stopObservation(); return }
        }
        // A cursor outside the inserted span indicates a different editing target.
        guard before.count >= value.prefix.count, after.count >= value.suffix.count else { stopObservation(); return }
        if edited != value.edited { value.edited = edited; value.lastChange = Date() }
        observation = value
    }
    private func stopObservation() { timer?.invalidate(); timer = nil; observation = nil }
}

private struct KeyboardVoiceLauncher: View {
    @Environment(\.openURL) private var openURL
    let prepare: () -> URL?
    let completion: (Bool) -> Void
    var body: some View {
        Button {
            guard let url = prepare() else { return }
            openURL(url, completion: completion)
        } label: {
            Label("点击说话", systemImage: "mic.fill").frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent)
            .accessibilityIdentifier("totype.voice.start")
    }
}
