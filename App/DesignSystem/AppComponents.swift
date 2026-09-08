import SwiftUI

struct AppPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
        .background(AppAppearance.background)
    }
}

extension View {
    func appSurface() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func appFormStyle() -> some View {
        listSectionSpacing(24)
            .scrollContentBackground(.hidden)
            .background(AppAppearance.background)
            .scrollDismissesKeyboard(.interactively)
    }
}

enum AppAppearance {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let accent = Color(uiColor: .systemBlue)
}

struct AppSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 4).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct AppPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct AppSymbol: View {
    @ScaledMetric(relativeTo: .body) private var smallSize = 34.0
    @ScaledMetric(relativeTo: .title2) private var largeSize = 52.0
    let name: String
    var accent = false
    var large = false

    var body: some View {
        Image(systemName: name)
            .font(large ? .title2.weight(.medium) : .body.weight(.medium))
            .foregroundStyle(accent ? AppAppearance.accent : Color.secondary)
            .frame(width: large ? largeSize : smallSize, height: large ? largeSize : smallSize)
            .background(accent ? AppAppearance.accent.opacity(0.09) : Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: large ? 15 : 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct PageIntroduction: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSymbol(name: symbol, accent: true, large: true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryActionLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline)
            Image(systemName: symbol).font(.body.weight(.medium))
                .accessibilityHidden(true)
        }
        .foregroundStyle(isEnabled ? Color.white : Color.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(isEnabled ? AppAppearance.accent : Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct AppNavigationRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let symbol: String
    var value: String? = nil
    var detail: String? = nil
    var accent = false

    var body: some View {
        HStack(spacing: 12) {
            if !typeSize.isAccessibilitySize { AppSymbol(name: symbol, accent: accent) }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    if let value { Text(value).font(.subheadline).foregroundStyle(.secondary) }
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                if let value { Text(value).foregroundStyle(.secondary) }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .font(.body)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

struct AboutDetailRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.body)
                .foregroundStyle(AppAppearance.accent).frame(width: 22)
                .padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
}
