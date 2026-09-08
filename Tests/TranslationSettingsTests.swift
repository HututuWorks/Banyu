import Foundation

private struct Failure: Error { let message: String }

@MainActor
private final class MemoryPersistence: TranslationSettingsPersisting {
    var data: Data?
    var failReads = false
    var failWrites = false
    func read() throws -> Data? {
        if failReads { throw TranslationSettingsError.unavailable }
        return data
    }
    func write(_ data: Data) throws {
        if failWrites { throw TranslationSettingsError.unavailable }
        self.data = data
    }
}

@main
struct TranslationSettingsTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    @MainActor
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(message: message)
    }
    @MainActor
    static func main() throws {
        let persistence = MemoryPersistence()
        let store = TranslationSettingsStore(persistence: persistence)
        try expect(try store.load() == .initial, "Fresh install must select Apple and store no key")
        try rejects("Qwen cannot enable without a key") { _ = try store.save(provider: .qwen) }
        let qwen = try store.save(provider: .qwen, apiKey: "synthetic-test-token")
        let apple = try store.save(provider: .apple)
        try expect(apple.provider == .apple && apple.apiKey == qwen.apiKey && apple.revision != qwen.revision,
                   "Switching to Apple preserves credentials but changes the generation")
        let reused = try store.save(provider: .qwen)
        try expect(reused.apiKey == qwen.apiKey, "Saved Qwen key can be reused without re-entry")
        let config = CustomTranslationConfiguration(baseURL: " https://EXAMPLE.com/v1/ ", model: " test-model ", apiKey: "custom-test-token")
        let custom = try store.save(provider: .custom, custom: config)
        try expect(custom.custom?.baseURL == "https://example.com/v1" && custom.custom?.model == "test-model", "Normalize saved endpoint and model")
        try expect(custom.apiKey == qwen.apiKey, "Custom provider must have separate credentials")
        let same = try store.save(provider: .custom, custom: .init(baseURL: "https://example.com:443/v2", model: "new-model", apiKey: ""))
        try expect(same.custom?.apiKey == "custom-test-token", "Same authority may keep a saved key")
        for address in ["https://other.example/v1", "https://example.com:8443/v1"] {
            try rejects("Changing authority requires explicit credentials") {
                _ = try store.save(provider: .custom, custom: .init(baseURL: address, model: "new-model", apiKey: ""))
            }
        }
        let switched = try store.save(provider: .custom, custom: .init(baseURL: "https://other.example/v1", model: "new-model", apiKey: "explicit-new-token"))
        try expect(switched.custom?.apiKey == "explicit-new-token", "Explicit new authority/key can be saved")
        let removedQwen = try store.removeKey(provider: .qwen)
        try expect(removedQwen.provider == .custom && removedQwen.apiKey == nil && removedQwen.custom != nil,
                   "Deleting inactive Qwen key cannot alter current custom selection")
        let removedCustom = try store.removeKey(provider: .custom)
        try expect(removedCustom.provider == .apple && removedCustom.custom == nil,
                   "Deleting active cloud credentials returns to Apple")
        for value in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=test", "https://example.com/v1#secret", "", "https://exa mple.com"] {
            try rejects("Malformed or unsafe endpoint must be rejected") { _ = try TranslationEndpoint.normalizedBaseURL(value) }
        }
        for token in ["", "test\r\nAuthorization: other", String(repeating: "a", count: 4097)] {
            try rejects("Malformed credential must be rejected") { try TranslationSettingsStore.validateKey(token) }
        }
        let good = persistence.data
        persistence.failWrites = true
        try rejects("Failed writes must be visible") { _ = try store.save(provider: .qwen, apiKey: "another-synthetic-token") }
        try expect(persistence.data == good && (try store.load()).provider == .apple, "Failed save cannot activate cloud")
        persistence.failWrites = false
        persistence.failReads = true
        try rejects("Keychain failure cannot silently select cloud") { _ = try store.load() }
        persistence.failReads = false
        persistence.data = Data("invalid-settings".utf8)
        try rejects("Corrupt persisted settings must fail closed") { _ = try store.load() }
        persistence.data = good
        print("PASS: Apple default, provider isolation, credential deletion, origin changes, endpoint/header validation, atomic saves and storage failures")
    }
}
