import SwiftUI

@MainActor
struct CustomTranslationSettingsView: View {
    private enum Field: Hashable { case baseURL, model, key }
    @State private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var savedBaseURL: String?
    @State private var savedModel: String?
    @State private var current: TranslationProvider?
    @State private var hasSavedConfiguration = false
    @State private var testedConfiguration: CustomTranslationConfiguration?
    @State private var testTranslation = ""
    @State private var isTesting = false
    @State private var testID = UUID()
    @State private var testTask: Task<Void, Never>?
    @State private var errorText = ""
    @FocusState private var focusedField: Field?

    private var mayReuseKey: Bool {
        guard let savedBaseURL else { return false }
        return TranslationEndpoint.hasSameAuthority(savedBaseURL, baseURL)
    }
    private var matchesSavedConfiguration: Bool {
        hasSavedConfiguration && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (try? TranslationEndpoint.normalizedBaseURL(baseURL).absoluteString) == savedBaseURL &&
            model.trimmingCharacters(in: .whitespacesAndNewlines) == savedModel
    }
    private var canSave: Bool {
        !isTesting && !(matchesSavedConfiguration && current == .custom) &&
            (testedConfiguration != nil || matchesSavedConfiguration)
    }
    private var canTest: Bool {
        !isTesting && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (mayReuseKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                PageIntroduction(symbol: "slider.horizontal.3", title: "连接你的服务",
                                 detail: "支持 OpenAI 兼容接口。地址、模型与密钥由你配置。")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            Section {
                ConfigurationField(title: "Base URL") {
                    TextField("Base URL", text: $baseURL,
                              prompt: Text(verbatim: "https://api.example.com/v1"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .baseURL)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .model }
                        .accessibilityLabel("接口 Base URL")
                }
                ConfigurationField(title: "模型") {
                    TextField("填入模型名称", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .model)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .key }
                        .accessibilityLabel("模型名称")
                }
                ConfigurationField(title: "API Key") {
                    SecureField(mayReuseKey ? "已保存，留空沿用" : "填入接口密钥", text: $key)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .focused($focusedField, equals: .key)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityLabel("自定义接口 API Key")
                }
            } header: {
                Text("接口配置")
            } footer: {
                Text("地址使用 HTTPS，通常以 /v1 结尾，不包含 /chat/completions。更换域名后需重新填写密钥。")
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
                .disabled(!canTest)
                if !testTranslation.isEmpty { ConnectionTestResult(translation: testTranslation) }
                if !errorText.isEmpty {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            } header: { Text("连接验证") } footer: {
                Text("测试只发送「我快到了。」。修改配置后，先测试再保存。")
            }

            Section {
                Button(action: saveConfiguration) {
                    PrimaryActionLabel(title: current == .custom && matchesSavedConfiguration ? "正在使用此接口" : "保存并使用",
                                       symbol: current == .custom && matchesSavedConfiguration ? "checkmark" : "arrow.right")
                }
                    .buttonStyle(AppPressStyle())
                    .disabled(!canSave)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text("启用后，当前短句会发送到你配置的地址，费用由接口服务商收取。网络暂时不可用时会尝试苹果翻译。")
            }

            if hasSavedConfiguration {
                Section {
                    Button("移除接口", role: .destructive, action: removeConfiguration)
                        .frame(minHeight: 44)
                } footer: {
                    Text("正在使用此接口时，移除后会恢复苹果翻译。")
                }
            }
        }
        .appFormStyle()
        .navigationTitle("自定义接口")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadConfiguration)
        .onChange(of: baseURL) { oldValue, newValue in
            if !oldValue.isEmpty, !TranslationEndpoint.hasSameAuthority(oldValue, newValue) { key = "" }
            invalidateTest()
        }
        .onChange(of: model) { _, _ in invalidateTest() }
        .onChange(of: key) { _, _ in invalidateTest() }
        .onDisappear {
            invalidateTest()
            key = ""
        }
    }

    private func loadConfiguration() {
        do {
            let snapshot = try TranslationSettingsStore.shared.load()
            current = snapshot.provider
            baseURL = snapshot.custom?.baseURL ?? ""
            model = snapshot.custom?.model ?? ""
            savedBaseURL = snapshot.custom?.baseURL
            savedModel = snapshot.custom?.model
            hasSavedConfiguration = snapshot.custom != nil
            errorText = ""
            SettingsPresentation.record(snapshot)
        } catch {
            errorText = "暂时无法读取配置，请返回后重试。"
            HintDiagnostics.record(stage: "app.settings.failure")
        }
    }

    private func invalidateTest() {
        testID = UUID()
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testedConfiguration = nil
        testTranslation = ""
    }

    private func testConnection() {
        invalidateTest()
        errorText = ""
        focusedField = nil
        let configuration: CustomTranslationConfiguration
        do {
            configuration = try TranslationSettingsStore.validatedCustom(
                .init(baseURL: baseURL, model: model, apiKey: key),
                previous: TranslationSettingsStore.shared.load().custom
            )
        } catch is TranslationEndpointError {
            errorText = "请填写有效的 HTTPS Base URL，不包含账户信息、查询参数或 /chat/completions。"
            return
        } catch TranslationSettingsError.invalidModel {
            errorText = "请填写有效的模型名称。"
            return
        } catch {
            errorText = "请填写有效的 API Key；更换域名时需要新的密钥。"
            return
        }
        let request = testID
        isTesting = true
        testTask = Task {
            do {
                let result = try await OpenAICompatibleTranslator(configuration: configuration).translate("我快到了。")
                guard !Task.isCancelled, testID == request else { return }
                guard !result.text.isEmpty else { throw TranslationSettingsError.invalidData }
                testedConfiguration = configuration
                testTranslation = result.text
                HintDiagnostics.record(stage: "app.cloudTest.success", details: ["provider": "custom"])
            } catch {
                guard !Task.isCancelled, testID == request else { return }
                errorText = "连接未通过，请检查地址、模型、密钥、账户额度或网络。"
            }
            if testID == request { isTesting = false }
        }
    }

    private func saveConfiguration() {
        guard canSave else { return }
        do {
            try TranslationSettingsStore.shared.save(provider: .custom, custom: testedConfiguration)
            focusedField = nil
            key = ""
            invalidateTest()
            loadConfiguration()
        } catch { errorText = "未能保存配置，当前翻译服务没有改变。" }
    }

    private func removeConfiguration() {
        do {
            try TranslationSettingsStore.shared.removeKey(provider: .custom)
            key = ""
            invalidateTest()
            loadConfiguration()
        } catch { errorText = "未能移除配置，请重试。" }
    }
}
