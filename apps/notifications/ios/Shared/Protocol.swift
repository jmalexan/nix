import Foundation
import Security

struct EnrollmentCredential: Codable {
    let server: URL
    let id: String
    let token: String
}

struct BridgeAction: Codable {
    let id: String
    let title: String
    let kind: String
    let url: URL?
}

struct BridgeNotification: Codable {
    let id: String
    let service: String
    let title: String
    let body: String
    let url: URL
    let image: URL?
    let expires: Double
    let active: Bool
    let actions: [BridgeAction]
}

enum BridgeError: LocalizedError {
    case invalidServer, disconnected, unavailable, keychain
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server address."
        case .disconnected: return "Connect this device again."
        case .unavailable: return "Couldn’t complete this request. Open the service to check its current state."
        case .keychain: return "Couldn’t securely save this connection."
        }
    }
}

enum ConnectionStore {
    static var query: [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "notification-bridge",
            kSecAttrAccount as String: "connection"
        ]
        if let group = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String {
            result[kSecAttrAccessGroup as String] = group
        }
        return result
    }

    static func load() -> EnrollmentCredential? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(EnrollmentCredential.self, from: data)
    }

    static func save(_ credential: EnrollmentCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw BridgeError.keychain
            }
        } else if update != errSecSuccess { throw BridgeError.keychain }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum BridgeAPI {
    static func server(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw BridgeError.invalidServer }
        return url
    }

    static func request(server: URL, path: String, token: String? = nil,
                        body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.timeoutInterval = 12
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BridgeError.unavailable }
        if response.statusCode == 401 { throw BridgeError.disconnected }
        guard (200..<300).contains(response.statusCode) else { throw BridgeError.unavailable }
        return data
    }

    static func notification(_ id: String, connection: EnrollmentCredential) async throws -> BridgeNotification {
        guard id.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw BridgeError.unavailable
        }
        return try JSONDecoder().decode(BridgeNotification.self, from: await request(
            server: connection.server, path: "v1/device/notifications/\(id)", token: connection.token))
    }
}
