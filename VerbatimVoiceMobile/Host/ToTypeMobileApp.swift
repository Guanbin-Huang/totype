import SwiftUI
import UIKit

@main
struct ToTypeMobileApp: App {
    @StateObject private var model = MobileDictationModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var credential = ""
    @State private var credentialStatus = ""
    private func returnToOrigin() {
        guard model.bridgeActive else { return }
        let requestID = model.activeVoiceRequestID
        MobileReturnNavigator.returnToOrigin(bundleID: model.originBundleID) { accepted in
            guard model.bridgeActive, model.activeVoiceRequestID == requestID else { return }
            if !accepted {
                model.status = "录音已开始。请点系统左上角的返回来源应用，或沿底部横条右滑；回到键盘后停止并输入。"
            }
            model.refreshSettingsAndDiagnostics()
        }
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("豆包实时语音") {
                        Text(model.status).font(.footnote)
                        HStack {
                            Button("开始录音") { model.start() }.disabled(model.phase != .idle)
                            Button("停止") { model.stop() }.disabled(model.phase != .recording)
                            Button("取消") { model.cancel() }.disabled(model.phase == .idle)
                        }
                        if model.phase == .starting || model.phase == .finalizing { ProgressView() }
                        if model.bridgeActive {
                            Button("返回原应用") { model.returnToOrigin?() }
                        }
                        TextEditor(text: $model.text).frame(minHeight: 180)
                            .disabled(model.phase != .idle)
                            .onChange(of: model.text) { _, _ in model.edited() }
                        if model.editingWindow { Text("本地纠错观察中（10 秒，无模型调用）").font(.caption) }
                        Button("更新键盘转写") { model.publishEditedTranscript() }
                            .disabled(model.text.isEmpty || model.phase != .idle)
                        Button("复制转写") { UIPasteboard.general.string = model.text }.disabled(model.text.isEmpty)
                        if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
                    }
                    Section("API Key（仅主应用私有 Keychain）") {
                        SecureField("豆包 API Key", text: $credential).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("保存") {
                            do { try MobileCredentialStore.save(credential); credential = ""; credentialStatus = "已保存并回读验证。"; model.refreshSettingsAndDiagnostics() }
                            catch { credentialStatus = error.localizedDescription }
                        }.disabled(credential.isEmpty || model.phase != .idle)
                        Text(credentialStatus).font(.caption)
                    }
                    Section("本地纠错学习") {
                        Toggle("启用 10 秒纠错学习（默认关闭）", isOn: Binding(
                            get: { model.learningEnabled }, set: { model.setLearningEnabled($0) }))
                            .disabled(model.phase != .idle)
                        Text(model.learningEnabled ? "已启用：只观察稳定替换；不调用模型，不增加识别链路。" : "已关闭：主应用与键盘都不记录纠错。")
                            .font(.caption)
                    }
                    Section("纠错候选（不会全局强制替换）") {
                        ForEach(model.vocabulary.candidates) { candidate in
                            VStack(alignment: .leading) {
                                Text("\(candidate.original) → \(candidate.corrected)")
                                Text("观察 \(candidate.confirmations) 次 · \(candidate.needsConfirmation ? "待确认" : "稳定候选")").font(.caption)
                                HStack {
                                    Button("确认词条") { model.confirm(candidate) }
                                    Button("忽略") { model.discard(candidate) }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                    Section("识别词表") {
                        ForEach(model.vocabulary.terms, id: \.self) { term in
                            HStack { Text(term); Spacer(); Button("撤销") { model.removeTerm(term) }.buttonStyle(.borderless) }
                        }
                    }
                    Section("设备验收状态") {
                        Text(model.diagnosticStatus).font(.caption)
                        Button("刷新诊断状态") { model.refreshSettingsAndDiagnostics() }
                            .disabled(model.phase != .idle)
                    }
                    Section("键盘设置") {
                        Text("设置 → 通用 → 键盘 → 键盘 → 添加 ToType；开启完全访问后才可读取转写与记录纠错。ToType 支持离线拼音选词、英文、数字和标点；中/EN 切换语言，空格选词。普通主应用录音离开后会取消；键盘发起的往返录音可返回目标应用继续，并在键盘停止或取消，最长 120 秒。")
                        Button("刷新词表") { model.refreshVocabulary() }
                    }.font(.footnote)
                }.navigationTitle("ToType")
            }.onAppear {
                model.onRecordingReady = returnToOrigin
                model.returnToOrigin = returnToOrigin
                model.initialize()
            }
                .onOpenURL { model.handleDictationURL($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        model.endObservation()
                        if phase == .background, model.phase != .idle, !model.bridgeActive { model.cancel() }
                    } else { model.refreshVocabulary(); model.refreshSettingsAndDiagnostics() }
                }
        }
    }
}
