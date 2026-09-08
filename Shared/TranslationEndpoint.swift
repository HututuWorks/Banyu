import Foundation

enum TranslationEndpointError: Error {
    case invalidBaseURL
}

enum TranslationEndpoint {
    static func normalizedBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw TranslationEndpointError.invalidBaseURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard !components.path.hasSuffix("/chat/completions"), let url = components.url else {
            throw TranslationEndpointError.invalidBaseURL
        }
        return url
    }

    static func hasSameAuthority(_ first: String, _ second: String) -> Bool {
        guard let lhs = try? normalizedBaseURL(first),
              let rhs = try? normalizedBaseURL(second) else { return false }
        return lhs.scheme == rhs.scheme && lhs.host == rhs.host && (lhs.port ?? 443) == (rhs.port ?? 443)
    }
}
