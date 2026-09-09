import SwiftUI

@MainActor
struct KeyboardTryoutView: View {
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var editorHeight = 176.0

    var body: some View {
        AppPage {
            VStack(alignment: .leading, spacing: 8) {
                Text("从一句话开始").font(.title2.weight(.semibold))
                Text("输入后稍停一下，看看键盘上方的英文。")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
            }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft)
                        .font(.body).focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: editorHeight)
                        .accessibilityLabel("键盘试用输入框")
                        .accessibilityIdentifier("app.tryout.editor")
                    if draft.isEmpty {
                        Text("在这里输入你想说的话…")
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }.padding(14)
                Divider().padding(.horizontal, 18)
                HStack {
                    Button("填入测试句") {
                        draft = "我想预订明天的会议室。"
                        isFocused = true
                    }
                    .frame(minHeight: 44)
                    Spacer()
                    Button("清空") { draft = "" }
                        .frame(minWidth: 44, minHeight: 44).disabled(draft.isEmpty)
                }
                .font(.subheadline).buttonStyle(.borderless)
                .padding(.horizontal, 18).padding(.vertical, 4)
            }.appSurface()

            VStack(alignment: .leading, spacing: 18) {
                AboutDetailRow(symbol: "globe", title: "切换到伴语",
                               detail: "长按地球键，选择26键或九宫格。")
                AboutDetailRow(symbol: "arrow.triangle.2.circlepath", title: "换成英文，再决定发送",
                               detail: "点「用英文」替换，点「撤销」恢复。继续编辑后，撤销会失效。")
                AboutDetailRow(symbol: "speaker.wave.2", title: "听听这句英文",
                               detail: "使用千问时，点小喇叭听一遍。展开后点单词，顶部显示本句词义并朗读；长按可选择短语。首次播放会生成 AI 语音。")
            }.padding(.horizontal, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("试用键盘")
        .navigationBarTitleDisplayMode(.inline)
    }
}
