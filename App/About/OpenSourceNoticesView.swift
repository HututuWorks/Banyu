import SwiftUI

struct OpenSourceNoticesView: View {
    var body: some View {
        List {
            Section {
                NavigationLink("AOSP PinyinIME") {
                    LicenseTextView(title: "AOSP PinyinIME", resource: "AOSP-Pinyin-NOTICE")
                }
                NavigationLink("translatekb") {
                    LicenseTextView(title: "translatekb", resource: "translatekb-LICENSE")
                }
            } footer: {
                Text("拼音解码使用 AOSP PinyinIME；键盘布局参考 translatekb。")
            }
        }
        .listStyle(.insetGrouped)
        .appFormStyle()
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LicenseTextView: View {
    let title: String
    let resource: String

    var body: some View {
        ScrollView {
            Text(license)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var license: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件暂不可用" }
        return text
    }
}
