import SwiftUI

@MainActor
struct SetupView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var currentService = "正在读取"
    @State private var serviceDetail = "选择你的翻译方式"
    @State private var errorText = ""

    var body: some View {
        NavigationStack {
            AppPage {
                Text("照常输入，英文随行。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, -8)

                NavigationLink { KeyboardTryoutView() } label: {
                    TryoutEntry()
                }
                .buttonStyle(AppPressStyle())
                .accessibilityIdentifier("app.home.tryout")

                AppSection(title: "翻译") {
                    NavigationLink { TranslationServicesView() } label: {
                        AppNavigationRow(title: "翻译服务", symbol: "character.bubble",
                                         value: currentService, detail: serviceDetail, accent: true)
                    }
                    .appSurface().buttonStyle(AppPressStyle())
                }

                AppSection(title: "键盘与应用") {
                    VStack(spacing: 0) {
                        NavigationLink { KeyboardSetupView() } label: {
                            AppNavigationRow(title: "管理键盘", symbol: "keyboard",
                                             detail: "26键与九宫格")
                        }
                        Divider().padding(.leading, typeSize.isAccessibilitySize ? 18 : 64)
                        NavigationLink { AboutView() } label: {
                            AppNavigationRow(title: "关于伴语", symbol: "info.circle")
                        }
                    }.appSurface().buttonStyle(AppPressStyle())
                }
                if !errorText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorText).font(.footnote).foregroundStyle(.secondary)
                        Button("重新读取设置", action: reload)
                            .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("伴语")
            .navigationBarTitleDisplayMode(.large)
            .onAppear(perform: reload)
        }
        .tint(Color(uiColor: .systemBlue))
    }

    private func reload() {
        do {
            let snapshot = try TranslationSettingsStore.shared.load()
            currentService = SettingsPresentation.name(snapshot.provider)
            switch snapshot.provider {
            case .apple: serviceDetail = "设备端翻译 · 支持离线"
            case .qwen: serviceDetail = "云端翻译与句子学习"
            case .custom: serviceDetail = "使用你配置的云端接口"
            }
            errorText = ""
            SettingsPresentation.record(snapshot)
        } catch {
            currentService = "暂不可用"
            serviceDetail = "请重新读取翻译设置"
            errorText = "暂时无法读取翻译设置，请重试。"
            HintDiagnostics.record(stage: "app.settings.failure")
        }
    }
}

struct TryoutEntry: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if !typeSize.isAccessibilitySize { AppSymbol(name: "keyboard", accent: true, large: true) }
            VStack(alignment: .leading, spacing: 7) {
                Text("试用键盘").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text("写下此刻想说的话").font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right").font(.body.weight(.medium))
                .foregroundStyle(AppAppearance.accent).accessibilityHidden(true)
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .appSurface().contentShape(RoundedRectangle(cornerRadius: 18))
    }
}
