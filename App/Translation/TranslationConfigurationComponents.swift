import SwiftUI

struct ConfigurationField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            content.font(.body).frame(minHeight: 36)
        }
        .padding(.vertical, 7)
    }
}

struct ConnectionTestResult: View {
    let translation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("连接成功", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(.green)
            Text("我快到了。").font(.subheadline).foregroundStyle(.secondary)
            Text(translation).font(.body).textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
