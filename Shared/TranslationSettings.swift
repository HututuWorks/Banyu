import Foundation
import Security

enum TranslationProvider: String, Codable, Equatable, Sendable {
    case apple
    case qwen
    case custom
}

struct CustomTranslationConfiguration: Codable, Equatable, Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
}

struct TranslationSettingsSnapshot: Codable, Equatable, Sendable {
    let provider: TranslationProvider
    let apiKey: String?
    let revision: String
    let custom: CustomTranslationConfiguration?

    init(provider: TranslationProvider, apiKey: String?, revision: String,
         custom: CustomTranslationConfiguration? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.revision = revision
        self.custom = custom
    }

    static let initial = Self(provider: .apple, apiKey: nil, revision: "default-apple")
}

enum TranslationSettingsError: Error {
    case unavailable
    case invalidData
    case missingKey
    case invalidKey
    case invalidModel
}

@MainActor
protocol TranslationSettingsPersisting {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

@MainActor
struct KeychainTranslationSettingsPersistence: TranslationSettingsPersisting {
    private func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TranslationKeychainAccessGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw TranslationSettingsError.unavailable }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tutuhu.EnglishHintKeyboard.translation",
            kSecAttrAccount as String: "settings-v1",
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false
        ]
    }

    func read() throws -> Data? {
        var request = try query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TranslationSettingsError.unavailable
        }
        return data
    }

    func write(_ data: Data) throws {
        let request = try query()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = request.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw TranslationSettingsError.unavailable }
    }
}

@MainActor
final class TranslationSettingsStore {
    static let shared = TranslationSettingsStore()
    private let persistence: any TranslationSettingsPersisting

    init(persistence: any TranslationSettingsPersisting = KeychainTranslationSettingsPersistence()) {
        self.persistence = persistence
    }

    func load() throws -> TranslationSettingsSnapshot {
        guard let data = try persistence.read() else { return .initial }
        guard let snapshot = try? JSONDecoder().decode(TranslationSettingsSnapshot.self, from: data),
              !snapshot.revision.isEmpty else { throw TranslationSettingsError.invalidData }
        if let key = snapshot.apiKey { try Self.validateKey(key) }
        if let custom = snapshot.custom { _ = try Self.validatedCustom(custom, previous: nil) }
        if snapshot.provider == .qwen, snapshot.apiKey == nil { throw TranslationSettingsError.missingKey }
        if snapshot.provider == .custom, snapshot.custom == nil { throw TranslationSettingsError.missingKey }
        return snapshot
    }

    @discardableResult
    func save(provider: TranslationProvider, apiKey: String? = nil,
              custom: CustomTranslationConfiguration? = nil) throws -> TranslationSettingsSnapshot {
        let previous = try load()
        var key = previous.apiKey
        if let value = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            try Self.validateKey(value)
            key = value
        }
        let customConfiguration: CustomTranslationConfiguration?
        if let custom {
            customConfiguration = try Self.validatedCustom(custom, previous: previous.custom)
        } else {
            customConfiguration = previous.custom
        }
        if provider == .qwen, key == nil { throw TranslationSettingsError.missingKey }
        if provider == .custom, customConfiguration == nil { throw TranslationSettingsError.missingKey }
        let next = TranslationSettingsSnapshot(provider: provider, apiKey: key, revision: UUID().uuidString,
                                               custom: customConfiguration)
        try persistence.write(JSONEncoder().encode(next))
        return next
    }

    @discardableResult
    func removeKey(provider: TranslationProvider = .qwen) throws -> TranslationSettingsSnapshot {
        guard provider != .apple else { throw TranslationSettingsError.invalidData }
        let previous = try load()
        let next = TranslationSettingsSnapshot(
            provider: previous.provider == provider ? .apple : previous.provider,
            apiKey: provider == .qwen ? nil : previous.apiKey,
            revision: UUID().uuidString,
            custom: provider == .custom ? nil : previous.custom
        )
        try persistence.write(JSONEncoder().encode(next))
        return next
    }

    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw TranslationSettingsError.invalidKey
        }
    }

    static func validatedCustom(_ configuration: CustomTranslationConfiguration,
                                previous: CustomTranslationConfiguration?) throws -> CustomTranslationConfiguration {
        let baseURL = try TranslationEndpoint.normalizedBaseURL(configuration.baseURL).absoluteString
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 256,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TranslationSettingsError.invalidModel
        }
        var key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty, let previous,
           TranslationEndpoint.hasSameAuthority(previous.baseURL, baseURL) {
            key = previous.apiKey
        }
        guard !key.isEmpty else { throw TranslationSettingsError.missingKey }
        try validateKey(key)
        return .init(baseURL: baseURL, model: model, apiKey: key)
    }
}
