import Foundation
import MihonDomain
#if os(iOS)
import Security
#endif

// MARK: - The user's own servers: logins

/// What the user typed to log in to their own server (a Komga password or API key): the Keychain on iOS; on a Mac
/// (the preview app) user defaults, and memory under XCTest, so neither asks for keychain access.
public enum MihonSecretStore {
    private static let service = MihonAppIdentity.bundleId
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static let inMemory = NSClassFromString("XCTestCase") != nil

    public static func data(for key: String) -> Data? {
        if inMemory {
            lock.lock()
            defer { lock.unlock() }
            return memory[key]
        }
        #if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
        #else
        return UserDefaults.standard.data(forKey: "secret." + key)
        #endif
    }

    public static func set(_ data: Data?, for key: String) {
        if inMemory {
            lock.lock()
            memory[key] = data
            lock.unlock()
            return
        }
        #if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var item = query
        item[kSecValueData as String] = data
        // After the first unlock: an automatic update may run while the phone is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
        #else
        UserDefaults.standard.set(data, forKey: "secret." + key)
        #endif
    }
}

/// Logins by server: every request to one carries its login — cover and page images too, which the image cache
/// fetches without knowing their source (upstream's Komga client authenticates its image requests the same way).
/// A server is its scheme, host, port and path, compared as such (never as a string prefix: "https:/" would match
/// every https site); redirects drop the login and add the new address's own, if any (`MihonRedirectGuard`).
public enum MihonServerAuth {
    struct Server {
        let scheme: String
        let host: String
        let port: Int
        let path: String
        let headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [Server] = []

    /// Base URL → headers; addresses that are not http(s) URLs with a host are left out.
    public static func set(_ entries: [String: [String: String]]) {
        let parsed = entries.compactMap { address, headers -> Server? in
            guard let url = URL(string: address), let origin = origin(of: url) else { return nil }
            return Server(scheme: origin.scheme, host: origin.host, port: origin.port, path: origin.path, headers: headers)
        }
        lock.lock()
        servers = parsed
        lock.unlock()
    }

    static func headers(for url: URL) -> [String: String] {
        guard let origin = origin(of: url) else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        return servers.first { server in
            server.scheme == origin.scheme && server.host == origin.host && server.port == origin.port
                && (server.path.isEmpty || origin.path == server.path || origin.path.hasPrefix(server.path + "/"))
        }?.headers ?? [:]
    }

    /// Whether `url` is on the server at `base`: same scheme, host and port, at or under its path.
    public static func isOnServer(_ url: URL, base: URL) -> Bool {
        guard let server = origin(of: base), let origin = origin(of: url) else { return false }
        return server.scheme == origin.scheme && server.host == origin.host && server.port == origin.port
            && (server.path.isEmpty || origin.path == server.path || origin.path.hasPrefix(server.path + "/"))
    }

    /// Scheme, lowercased host, port (the scheme's default when absent) and the path without a trailing slash.
    static func origin(of url: URL) -> (scheme: String, host: String, port: Int, path: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80), path)
    }
}

/// On a redirect, drops a login the request carried and adds the new address's own (never on a downgrade from https
/// to http): URLSession would forward `X-API-Key` to any host it is sent to.
final class MihonRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let credentials: (URL) -> [String: String]

    init(credentials: @escaping (URL) -> [String: String] = MihonServerAuth.headers(for:)) {
        self.credentials = credentials
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        next.setValue(nil, forHTTPHeaderField: "X-API-Key")
        let downgrade = response.url?.scheme?.lowercased() == "https" && next.url?.scheme?.lowercased() == "http"
        if let url = next.url, !downgrade {
            for (field, value) in credentials(url) { next.setValue(value, forHTTPHeaderField: field) }
        }
        completionHandler(next)
    }
}
