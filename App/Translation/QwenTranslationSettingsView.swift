import SwiftUI

@MainActor
struct QwenTranslationSettingsView: View {
    @State private var current: TranslationProvider?
    @State private var hasSavedKey = false
    @State private var key = ""
    @State private var testedKey: String?
    @State private var testTranslation = ""
    @State private var isTesting = false
    @State private var testID = UUID()
    @State private var testTask: Task<Void, Never>?
    @State private var errorText = ""
    @FocusState private var keyFocused: Bool

    private var reusesSavedKey: Bool {
        hasSavedKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var isCurrentUnchanged: Bool { current == .qwen && reusesSavedKey }
    private var canSave: Bool {
        !isTesting && !isCurrentUnchanged && (testedKey != nil || reusesSavedKey)
    }

    var body: some View {
        Form {
            Section {
                PageIntroduction(symbol: "cloud", title: "千问翻译",
                                 detail: "连接你的千问账户，在键盘里翻译、学习与听读。")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("模型", value: "Qwen-MT-Flash")
                ConfigurationField(title: "API Key") {
                    SecureField(hasSavedKey ? "已保存，留空沿用" : "填入千问密钥", text: $key)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .focused($keyFocused)
                        .submitLabel(.done)
                        .onSubmit { keyFocused = false }
                        .accessibilityLabel("千问 API Key")
                }
            } header: {
                Text("接口配置")
            } footer: {
                Text(hasSavedKey ? "密钥已保存在本机。填写新密钥可更新配置。" : "使用你自己的千问 API Key。")
            }

            Section {
                Button(action: testConnection) {
                    HStack {
                        Text(isTesting ? "正在测试…" : "测试连接")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isTesting || (!hasSavedKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if !testTranslation.isEmpty { ConnectionTestResult(translation: testTranslation) }
                if !errorText.isEmpty {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            } header: { Text("连接验证") } footer: {
                Text("测试只发送「我快到了。」。新密钥测试通过后，再保存启用。")
            }

            Section {
                Button(action: saveConfiguration) {
                    PrimaryActionLabel(title: isCurrentUnchanged ? "正在使用千问" : "保存并使用千问",
                                       symbol: isCurrentUnchanged ? "checkmark" : "arrow.right")
                }
                    .buttonStyle(AppPressStyle())
                    .disabled(!canSave)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text("启用后，当前短句会发送给千问，按接口用量计费。网络暂时不可用时会尝试苹果翻译。")
            }

            Section {
                Label("点小喇叭听英文，再点停止", systemImage: "speaker.wave.2")
                    .font(.subheadline)
            } header: { Text("英文听读") } footer: {
                Text("复用这枚密钥，使用千问 AI 语音，以正常语速循环朗读。点击后才生成音频并单独计费，同一句在本地重复播放。首次播放需要联网；密钥需有语音模型权限。")
            }

            if hasSavedKey {
                Section {
                    Button("移除密钥", role: .destructive, action: removeKey)
                        .frame(minHeight: 44)
                } footer: {
                    Text("正在使用千问时，移除后会恢复苹果翻译。")
                }
            }
        }
        .appFormStyle()
        .navigationTitle("千问")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: key) { _, _ in invalidateTest() }
        .onDisappear {
            invalidateTest()
            key = ""
        }
    }

    private func apply(_ snapshot: TranslationSettingsSnapshot) {
        current = snapshot.provider
        hasSavedKey = snapshot.apiKey != nil
        errorText = ""
        SettingsPresentation.record(snapshot)
    }

    private func reload() {
        do { apply(try TranslationSettingsStore.shared.load()) }
        catch {
            errorText = "暂时无法读取配置，请返回后重试。"
            HintDiagnostics.record(stage: "app.settings.failure")
        }
    }

    private func invalidateTest() {
        testID = UUID()
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testedKey = nil
        testTranslation = ""
    }

    private func testConnection() {
        invalidateTest()
        errorText = ""
        keyFocused = false
        let candidate: String
        do {
            let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate = entered.isEmpty ? (try TranslationSettingsStore.shared.load().apiKey ?? "") : entered
            try TranslationSettingsStore.validateKey(candidate)
        } catch {
            errorText = "请填入有效的千问 API Key。"
            return
        }
        let request = testID
        isTesting = true
        testTask = Task {
            do {
                let result = try await QwenTranslator(apiKey: candidate).translate("我快到了。")
                guard !Task.isCancelled, testID == request else { return }
                guard !result.text.isEmpty else { throw TranslationSettingsError.invalidData }
                testedKey = candidate
                testTranslation = result.text
                HintDiagnostics.record(stage: "app.cloudTest.success", details: ["provider": "qwen"])
            } catch {
                guard !Task.isCancelled, testID == request else { return }
                errorText = "连接未通过，请检查密钥、账户额度或网络后重试。"
            }
            if testID == request { isTesting = false }
        }
    }

    private func saveConfiguration() {
        guard canSave else { return }
        do {
            apply(try TranslationSettingsStore.shared.save(provider: .qwen, apiKey: testedKey))
            keyFocused = false
            key = ""
            invalidateTest()
        } catch { errorText = "未能保存设置，当前翻译服务没有改变。" }
    }

    private func removeKey() {
        do {
            apply(try TranslationSettingsStore.shared.removeKey(provider: .qwen))
            key = ""
            invalidateTest()
        } catch { errorText = "未能移除密钥，请重试。" }
    }
}
