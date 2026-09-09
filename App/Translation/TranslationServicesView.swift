import SwiftUI

struct ProviderRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let subtitle: String
    let isCurrent: Bool
    var isConfigured = false
    var symbol = "network"
    var navigates = true

    var body: some View {
        HStack(spacing: 12) {
            if !typeSize.isAccessibilitySize { AppSymbol(name: symbol, accent: isCurrent) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if typeSize.isAccessibilitySize {
                    if isCurrent {
                        Label("当前选择", systemImage: "checkmark")
                            .font(.footnote).foregroundStyle(AppAppearance.accent)
                    } else if isConfigured {
                        Text("已配置").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            if isCurrent && !typeSize.isAccessibilitySize {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .systemBlue))
                    .accessibilityLabel("当前选择")
            } else if isConfigured && !typeSize.isAccessibilitySize {
                Text("已配置").font(.footnote).foregroundStyle(.secondary)
            }
            if navigates {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 18)
        .frame(minHeight: 76)
        .contentShape(Rectangle())
    }
}

@MainActor
struct TranslationServicesView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var current: TranslationProvider?
    @State private var hasQwenKey = false
    @State private var hasCustom = false
    @State private var errorText = ""

    var body: some View {
        AppPage {
            Text("选择翻译方式，随时可以更换。")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Button(action: useApple) {
                    ProviderRow(title: "苹果", subtitle: "设备端翻译 · 支持离线",
                                isCurrent: current == .apple, symbol: "iphone", navigates: false)
                }
                Divider().padding(.leading, typeSize.isAccessibilitySize ? 18 : 64)
                NavigationLink {
                    QwenTranslationSettingsView()
                } label: {
                    ProviderRow(title: "千问", subtitle: "Qwen-MT-Flash",
                                isCurrent: current == .qwen, isConfigured: hasQwenKey, symbol: "cloud")
                }
                Divider().padding(.leading, typeSize.isAccessibilitySize ? 18 : 64)
                NavigationLink {
                    CustomTranslationSettingsView()
                } label: {
                    ProviderRow(title: "自定义", subtitle: "OpenAI 兼容接口",
                                isCurrent: current == .custom, isConfigured: hasCustom, symbol: "slider.horizontal.3")
                }
            }.appSurface().buttonStyle(AppPressStyle())

            AppSection(title: "离线使用") {
                NavigationLink { AppleLanguagePacksView() } label: {
                    AppNavigationRow(title: "苹果语言包", symbol: "arrow.down.circle", detail: "下载后可离线翻译")
                }.appSurface().buttonStyle(AppPressStyle())
                Text("勾选表示当前选择。云端服务需先配置，启用后会接收当前草稿或选中文字，以及对应英文的学习分析请求。")
                    .font(.footnote).foregroundStyle(.secondary).lineSpacing(3)
                    .padding(.horizontal, 4)
            }

            if !errorText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                    Button("重新读取设置", action: reload)
                }
            }
        }
        .navigationTitle("翻译服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func apply(_ snapshot: TranslationSettingsSnapshot) {
        current = snapshot.provider
        hasQwenKey = snapshot.apiKey != nil
        hasCustom = snapshot.custom != nil
        errorText = ""
        SettingsPresentation.record(snapshot)
    }

    private func reload() {
        do { apply(try TranslationSettingsStore.shared.load()) }
        catch {
            current = nil
            errorText = "暂时无法读取设置，请重试。"
            HintDiagnostics.record(stage: "app.settings.failure")
        }
    }

    private func useApple() {
        guard current != .apple else { return }
        do { apply(try TranslationSettingsStore.shared.save(provider: .apple)) }
        catch { errorText = "未能保存选择，当前翻译服务没有改变。" }
    }
}
