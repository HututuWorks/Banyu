import Foundation

/// Deliberately separate from the phone's Keychain and the user's settings.
@MainActor
final class PreviewSettingsPersistence: TranslationSettingsPersisting {
    static let shared = PreviewSettingsPersistence()
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
    func reset() { data = nil }
}
