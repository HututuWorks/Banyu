import SwiftUI
import Translation

enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case spanish = "es", french = "fr", german = "de", japanese = "ja"
    case korean = "ko", russian = "ru"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .spanish: "西班牙语"
        case .french: "法语"
        case .german: "德语"
        case .japanese: "日语"
        case .korean: "韩语"
        case .russian: "俄语"
        }
    }
}

@MainActor
struct AppleLanguagePacksView: View {
    @State private var selected = TranslationLanguage.simplifiedChinese
    @State private var configuration: TranslationSession.Configuration?
    @State private var statusText = "正在检查语言包…"
    @State private var isInstalled = false
    @State private var isPreparing = false
    @State private var requestID = UUID()

    var body: some View {
        Form {
            Section {
                PageIntroduction(symbol: "arrow.down.circle", title: "让翻译离线可用",
                                 detail: "先准备语言包，之后可在设备上完成苹果翻译。")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            Section("翻译语言") {
                Picker("输入语言", selection: $selected) {
                    ForEach(TranslationLanguage.allCases) { language in
                        Text(language.name).tag(language)
                    }
                }
                LabeledContent("翻译为", value: "英文")
            }
            Section {
                Label(statusText, systemImage: isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(isInstalled ? Color.green : Color.secondary)
                Button(action: prepare) {
                    HStack {
                        Text(isPreparing ? "正在准备…" : (isInstalled ? "重新检查" : "准备语言包"))
                        Spacer()
                        if isPreparing { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isPreparing)
            } footer: {
                Text("首次准备可能需要联网下载。语言包就绪后，苹果翻译可在设备上离线使用。")
            }
        }
        .appFormStyle()
        .navigationTitle("苹果语言包")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus(for: selected) }
        .onChange(of: selected) { _, selection in
            requestID = UUID()
            configuration = nil
            isPreparing = false
            isInstalled = false
            statusText = "正在检查语言包…"
            Task { await refreshStatus(for: selection) }
        }
        .translationTask(configuration, action: preparationAction(request: requestID, language: selected))
    }

    private func prepare() {
        requestID = UUID()
        isPreparing = true
        statusText = "正在准备语言包…"
        if configuration != nil {
            configuration?.invalidate()
        } else if #available(iOS 26.4, *) {
            configuration = .init(source: .init(identifier: selected.id),
                                  target: .init(identifier: "en"), preferredStrategy: .lowLatency)
        } else {
            configuration = .init(source: .init(identifier: selected.id), target: .init(identifier: "en"))
        }
    }

    // Keep the framework-owned, non-Sendable session on its original task executor.
    // Only Sendable request metadata and the result cross to the UI actor.
    nonisolated private func preparationAction(request: UUID, language: TranslationLanguage)
        -> (TranslationSession) async -> Void {
        // Snapshot identity while constructing the view's action, not when a queued
        // session starts: a stale session must never acquire a newer request's ID.
        { session in
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                await preparationFinished(request: request, language: language,
                                          succeeded: !Task.isCancelled)
            } catch {
                await preparationFinished(request: request, language: language, succeeded: false)
            }
        }
    }

    private func preparationFinished(request: UUID, language: TranslationLanguage, succeeded: Bool) async {
        guard requestID == request, selected == language else { return }
        if succeeded {
            await refreshStatus(for: language)
        } else {
            statusText = "准备未完成，请检查网络后重试。"
            isInstalled = false
        }
        if requestID == request { isPreparing = false }
    }

    private func refreshStatus(for language: TranslationLanguage) async {
        let statusRequest = requestID
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let status = await availability.status(from: .init(identifier: language.id), to: .init(identifier: "en"))
        guard selected == language, requestID == statusRequest else { return }
        HintDiagnostics.record(stage: "app.availability", language: language.id,
                               details: ["status": String(describing: status)])
        switch status {
        case .installed:
            isInstalled = true
            statusText = "\(language.name) → 英文已就绪"
        case .supported:
            isInstalled = false
            statusText = "首次使用需要准备语言包"
        case .unsupported:
            isInstalled = false
            statusText = "这台设备暂不支持这组语言"
        @unknown default:
            isInstalled = false
            statusText = "语言包状态暂不可用"
        }
    }
}
