import SwiftUI

@MainActor
enum SettingsPresentation {
    static func name(_ provider: TranslationProvider) -> String {
        switch provider {
        case .apple: "苹果"
        case .qwen: "千问"
        case .custom: "自定义"
        }
    }

    static func record(_ snapshot: TranslationSettingsSnapshot) {
        let configured = snapshot.provider == .apple ||
            (snapshot.provider == .qwen && snapshot.apiKey != nil) ||
            (snapshot.provider == .custom && snapshot.custom != nil)
        HintDiagnostics.record(stage: "app.settings.ready", details: [
            "provider": snapshot.provider.rawValue, "configured": String(configured)
        ])
    }
}
