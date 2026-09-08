import SwiftUI

struct AboutView: View {
    private var version: String {
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(number) (\(build))"
    }

    var body: some View {
        AppPage {
            VStack(spacing: 14) {
                Image("BrandLogo")
                    .resizable().scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("伴语").font(.title.weight(.semibold))
                    Text("输入时的英文伙伴").font(.subheadline).foregroundStyle(.secondary)
                    Text("版本 \(version)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 20) {
                AboutDetailRow(symbol: "character.bubble", title: "翻译，由你选择",
                               detail: "使用苹果设备端翻译，或连接自己的云端服务。")
                Divider().padding(.leading, 34)
                AboutDetailRow(symbol: "hand.tap", title: "发送，由你决定",
                               detail: "伴语只在你点「用英文」后替换当前句。确认内容后，再由你发送。")
                Divider().padding(.leading, 34)
                AboutDetailRow(symbol: "lock", title: "只处理当前内容",
                               detail: "云端服务翻译当前短句，并提前分析对应英文。API Key 保存在本机钥匙串。")
            }.padding(20).appSurface()

            NavigationLink { OpenSourceNoticesView() } label: {
                AppNavigationRow(title: "开源许可", symbol: "doc.text")
            }.appSurface().buttonStyle(AppPressStyle())
        }
        .navigationTitle("关于伴语")
        .navigationBarTitleDisplayMode(.inline)
    }
}
