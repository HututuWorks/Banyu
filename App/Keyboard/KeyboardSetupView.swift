import SwiftUI

@MainActor
struct KeyboardSetupView: View {
    var body: some View {
        AppPage {
            PageIntroduction(symbol: "keyboard", title: "用你熟悉的方式输入",
                             detail: "伴语提供26键和九宫格，可分别添加，也可同时使用。")

            VStack(spacing: 20) {
                KeyboardSetupStep(number: 1, title: "添加键盘",
                                  detail: "在系统设置中，依次进入：",
                                  path: "通用 → 键盘 → 键盘 → 添加新键盘",
                                  note: "找到「伴语」，选择「伴语·26键」或「伴语·九宫格」。")
                Divider().padding(.leading, 40)
                KeyboardSetupStep(number: 2, title: "允许完全访问",
                                  detail: "点开已添加的伴语键盘，开启「允许完全访问」。两种布局需分别设置。")
                Divider().padding(.leading, 40)
                KeyboardSetupStep(number: 3, title: "回到输入框",
                                  detail: "长按键盘上的地球键，选择你想用的伴语键盘。")
            }
            .padding(20).appSurface()

            VStack(spacing: 8) {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    PrimaryActionLabel(title: "打开系统设置", symbol: "arrow.up.right")
                }
                .buttonStyle(AppPressStyle())
                NavigationLink { KeyboardTryoutView() } label: {
                    Text("已添加，去试用").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(AppPressStyle()).foregroundStyle(AppAppearance.accent)
            }
        }
        .navigationTitle("管理键盘")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyboardSetupStep: View {
    @ScaledMetric(relativeTo: .footnote) private var numberSize = 28.0
    let number: Int
    let title: String
    let detail: String
    var path: String? = nil
    var note: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(number)).font(.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(AppAppearance.accent)
                .frame(width: numberSize, height: numberSize)
                .background(AppAppearance.accent.opacity(0.09), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if let path {
                    Text(path).font(.subheadline).foregroundStyle(.primary)
                        .padding(.vertical, 3)
                }
                if let note { Text(note).font(.subheadline).foregroundStyle(.secondary) }
            }
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第\(number)步，\(title)。\(detail)\(path ?? "")\(note ?? "")")
    }
}
