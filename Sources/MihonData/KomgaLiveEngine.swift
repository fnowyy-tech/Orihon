import Foundation
import MihonDomain

// MARK: - Komga (keiyoushi `all.komga`)

/// Komga, the user's own comics server. Upstream's factory makes three instances; their ids are kept so the Komga
/// titles of a Mihon backup match. URLs are absolute (`<address>/api/v1/series/<id>`), as upstream's.
public struct KomgaLiveEngine: LiveSourceEngine {
    /// Upstream `INSTANCE_IDS`: Komga, Komga (2), Komga (3).
    public static let instanceIds: [Int64] = [4_508_733_312_114_627_536, 8_074_481_155_021_144_106, 5_132_811_728_275_817_394]
    static let supportedImageTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/jxl", "image/heif", "image/avif",
    ]

    public static func handles(sourceId: Int64) -> Bool { instanceIds.contains(sourceId) }

    let account: KomgaAccount

    public init(account: KomgaAccount) {
        self.account = account
    }

    public func popularManga(page: Int) async throws -> MangasPage {
        try await series(page: page, query: "", sort: "metadata.titleSort,asc")
    }

    public func latestUpdates(page: Int) async throws -> MangasPage {
        try await series(page: page, query: "", sort: "lastModifiedDate,desc")
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        try await series(page: page, query: query, sort: "relevance,asc")
    }

    /// Upstream also lists read lists and single books as titles (a Mihon backup may hold them): by URL path.
    public func mangaDetails(manga: SManga) async throws -> SManga {
        let base = try baseUrl()
        if Self.isReadList(manga.url) {
            return try await get(manga.url, as: KomgaReadList.self).toSManga(baseUrl: base)
        }
        if Self.isBook(manga.url) {
            return try await get(manga.url, as: KomgaBook.self).toSManga(baseUrl: base)
        }
        return try await get(manga.url, as: KomgaSeries.self).toSManga(baseUrl: base)
    }

    public func chapterList(manga: SManga) async throws -> [SChapter] {
        let base = try baseUrl()
        if Self.isBook(manga.url) {
            // A single book is its own only chapter.
            let book = try await get("\(manga.url)?unpaged=true&media_status=READY&deleted=false", as: KomgaBook.self)
            var chapter = book.toSChapter(baseUrl: base, mangaTitle: manga.title, inReadList: true)
            chapter.chapterNumber = 1
            return [chapter]
        }
        let inReadList = Self.isReadList(manga.url)
        let page = try await get("\(manga.url)/books?unpaged=true&media_status=READY&deleted=false", as: KomgaPage<KomgaBook>.self)
        return page.content
            // EPUBs Komga cannot show as pages are not chapters here (upstream filters them too).
            .filter { $0.media.mediaProfile != "EPUB" || $0.media.epubDivinaCompatible == true }
            .enumerated()
            .map { index, book in
                var chapter = book.toSChapter(baseUrl: base, mangaTitle: manga.title, inReadList: inReadList)
                // A read list's order is its own, not the books' numbers.
                if inReadList { chapter.chapterNumber = Double(index + 1) }
                return chapter
            }
            .sorted { $0.chapterNumber > $1.chapterNumber }
    }

    static func isReadList(_ url: String) -> Bool { url.contains("/api/v1/readlists") }
    static func isBook(_ url: String) -> Bool { url.contains("/api/v1/books") }
    static func isSeries(_ url: String) -> Bool { url.contains("/api/v1/series/") }

    // MARK: Read progress (upstream's Komga tracker)

    /// Komga's "Tachiyomi" read progress of a series: the number (`numberSort`) read up to without a gap.
    public func readProgress(manga: SManga) async throws -> Double {
        try await get(Self.progressUrl(manga.url), as: KomgaReadProgress.self).lastReadContinuousNumberSort
    }

    /// Marks the series' books up to `lastNumberSort` read on the server.
    public func setReadProgress(manga: SManga, lastNumberSort: Double) async throws {
        guard let url = URL(string: Self.progressUrl(manga.url)), let base = account.baseURL,
              MihonServerAuth.isOnServer(url, base: base) else { throw KomgaError.otherServer(manga.url) }
        let body = try JSONSerialization.data(withJSONObject: ["lastBookNumberSortRead": lastNumberSort])
        _ = try await MihonNetworkClient.shared.send(url: url, method: "PUT", body: body, headers: account.headers)
    }

    static func progressUrl(_ seriesUrl: String) -> String {
        seriesUrl.replacingOccurrences(of: "/api/v1/series/", with: "/api/v2/series/") + "/read-progress/tachiyomi"
    }

    public func pageList(chapter: SChapter) async throws -> [Page] {
        let pages = try await get("\(chapter.url)/pages", as: [KomgaPageImage].self)
        return pages.map { page in
            let convert = Self.supportedImageTypes.contains(page.mediaType) ? "" : "?convert=png"
            return Page(index: page.number - 1, url: chapter.url, imageUrl: "\(chapter.url)/pages/\(page.number)\(convert)")
        }
    }

    public func mangaWebUrl(manga: SManga) -> String {
        manga.url.replacingOccurrences(of: "/api/v1", with: "")
    }

    /// The server's libraries: what 测试连接 shows (upstream's login fetches them too). On a session of its own,
    /// without cookies: Komga's session cookie would let a mistyped password through.
    public func libraries() async throws -> [String] {
        guard let url = URL(string: "\(try baseUrl())/api/v1/libraries") else { throw KomgaError.badAddress }
        var request = URLRequest(url: url)
        for (field, value) in account.headers { request.setValue(value, forHTTPHeaderField: field) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let account = account
        let (data, response) = try await session.data(for: request, delegate: MihonRedirectGuard { next in
            account.baseURL.map { MihonServerAuth.isOnServer(next, base: $0) } == true ? account.headers : [:]
        })
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return try JSONDecoder().decode([KomgaLibrary].self, from: data).map(\.name)
        case 401: throw KomgaError.unauthorized
        case let code: throw MihonNetworkError.httpStatusError(code: code)
        }
    }

    // MARK: Requests

    private func baseUrl() throws -> String {
        guard account.isConfigured else { throw KomgaError.notConfigured }
        return account.baseUrl
    }

    private func series(page: Int, query: String, sort: String) async throws -> MangasPage {
        var components = URLComponents(string: "\(try baseUrl())/api/v1/series")
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "page", value: String(page - 1)),
            URLQueryItem(name: "deleted", value: "false"),
            URLQueryItem(name: "sort", value: sort),
        ]
        guard let url = components?.string else { throw KomgaError.badAddress }
        let result = try await get(url, as: KomgaPage<KomgaSeries>.self)
        let base = try baseUrl()
        return MangasPage(mangas: result.content.map { $0.toSManga(baseUrl: base) }, hasNextPage: !result.last)
    }

    private func get<T: Decodable>(_ address: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: address), let base = account.baseURL else { throw KomgaError.badAddress }
        // A title saved under another address (an old one, or a backup's) does not get this server's login.
        guard MihonServerAuth.isOnServer(url, base: base) else { throw KomgaError.otherServer(url.host ?? address) }
        do {
            let (data, _) = try await MihonNetworkClient.shared.performGET(url: url, headers: account.headers)
            return try JSONDecoder().decode(T.self, from: data)
        } catch MihonNetworkError.httpStatusError(let code) where code == 401 {
            throw KomgaError.unauthorized
        }
    }
}

public enum KomgaError: Error, LocalizedError, Equatable {
    case notConfigured
    case badAddress
    case unauthorized
    case otherServer(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在 Komga 设置里填写服务器地址"
        case .badAddress: return "Komga 服务器地址无效，例如 http://192.168.1.10:25600"
        case .unauthorized: return "Komga 登录失败：请检查用户名、密码或 API Key"
        case .otherServer(let host): return "这部作品在另一个 Komga 服务器（\(host)）上，和设置里的地址不同"
        }
    }
}

/// One instance's server and login (upstream's source preferences Address, Username, Password, API key).
public struct KomgaAccount: Codable, Equatable, Sendable {
    public var address: String
    public var username: String
    public var password: String
    public var apiKey: String
    /// Upstream's Komga tracker (an enhanced tracker): read chapters synced both ways.
    public var syncsProgress: Bool

    public init(address: String = "", username: String = "", password: String = "", apiKey: String = "", syncsProgress: Bool = true) {
        self.address = address
        self.username = username
        self.password = password
        self.apiKey = apiKey
        self.syncsProgress = syncsProgress
    }

    /// Accounts saved by builds 21–22 have no `syncsProgress`: it defaults to on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        syncsProgress = try container.decodeIfPresent(Bool.self, forKey: .syncsProgress) ?? true
    }

    /// The address without a trailing slash (upstream `removeSuffix("/")`).
    public var baseUrl: String {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    /// An http(s) URL with a host (upstream validates with `toHttpUrlOrNull`), else nil: "https://" alone is not one.
    public var baseURL: URL? {
        guard let url = URL(string: baseUrl), MihonServerAuth.origin(of: url) != nil else { return nil }
        return url
    }

    public var isConfigured: Bool { baseURL != nil }

    /// Plain http to a server that is not on this network: the password crosses the internet unencrypted.
    public var sendsLoginInTheClear: Bool {
        guard let url = baseURL, url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        let local = host == "localhost" || host.hasSuffix(".local") || !host.contains(".")
            || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("127.")
            || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
        return !local
    }

    /// An API key wins over the password, as upstream's.
    public var headers: [String: String] {
        if !apiKey.isEmpty { return ["X-API-Key": apiKey] }
        guard !username.isEmpty else { return [:] }
        return ["Authorization": "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()]
    }
}

// MARK: - Komga API (upstream `Dto.kt`)

struct KomgaPage<T: Decodable>: Decodable {
    let content: [T]
    let last: Bool
}

struct KomgaLibrary: Decodable {
    let name: String
}

struct KomgaAuthor: Decodable {
    let name: String
    let role: String
}

struct KomgaSeries: Decodable {
    struct Metadata: Decodable {
        let status: String
        let title: String
        let summary: String
        let genres: [String]
        let tags: [String]
        let totalBookCount: Int?
    }

    struct BooksMetadata: Decodable {
        let authors: [KomgaAuthor]?
        let tags: [String]?
        let summary: String
    }

    let id: String
    let booksCount: Int
    let metadata: Metadata
    let booksMetadata: BooksMetadata

    func toSManga(baseUrl: String) -> SManga {
        let url = "\(baseUrl)/api/v1/series/\(id)"
        let status: MangaStatus = switch metadata.status {
        case "ENDED" where metadata.totalBookCount.map { booksCount < $0 } ?? false: .publishingFinished
        case "ENDED": .completed
        case "ONGOING": .ongoing
        case "ABANDONED": .cancelled
        case "HIATUS": .onHiatus
        default: .unknown
        }
        let authors = Dictionary(grouping: booksMetadata.authors ?? [], by: \.role)
        func names(_ role: String) -> String? {
            guard let list = authors[role], !list.isEmpty else { return nil }
            var seen: Set<String> = []
            return list.map(\.name).filter { seen.insert($0).inserted }.joined(separator: ", ")
        }
        return SManga(
            url: url,
            title: metadata.title,
            artist: names("penciller"),
            author: names("writer"),
            description: metadata.summary.isEmpty ? booksMetadata.summary : metadata.summary,
            genre: Array(Set(metadata.genres + metadata.tags + (booksMetadata.tags ?? []))).sorted(),
            status: status,
            thumbnailUrl: "\(url)/thumbnail"
        )
    }
}

struct KomgaReadList: Decodable {
    let id: String
    let name: String
    let summary: String

    func toSManga(baseUrl: String) -> SManga {
        let url = "\(baseUrl)/api/v1/readlists/\(id)"
        return SManga(url: url, title: name, description: summary, thumbnailUrl: "\(url)/thumbnail")
    }
}

struct KomgaBook: Decodable {
    struct Media: Decodable {
        let mediaProfile: String?
        let epubDivinaCompatible: Bool?
    }

    struct Metadata: Decodable {
        let title: String
        let summary: String?
        let number: String
        let numberSort: Double
        let releaseDate: String?
        let authors: [KomgaAuthor]
        let tags: [String]?
    }

    let id: String
    let seriesTitle: String?
    let created: String?
    let fileLastModified: String
    let size: String
    let media: Media
    let metadata: Metadata

    /// A book listed as a title (upstream `BookDto.toSManga`).
    func toSManga(baseUrl: String) -> SManga {
        let url = "\(baseUrl)/api/v1/books/\(id)"
        let authors = metadata.authors.map(\.name).joined(separator: ", ")
        return SManga(
            url: url,
            title: metadata.title,
            artist: authors.isEmpty ? nil : authors,
            author: authors.isEmpty ? nil : authors,
            description: metadata.summary,
            genre: Array(Set(metadata.tags ?? [])).sorted(),
            thumbnailUrl: "\(url)/thumbnail"
        )
    }

    /// Upstream's default chapter title template, "{number} - {title} ({size})"; in a read list (or a book listed
    /// as a title) prefixed with the series' name.
    func toSChapter(baseUrl: String, mangaTitle: String, inReadList: Bool = false) -> SChapter {
        var name = "\(metadata.number) - \(metadata.title) (\(size))"
        if inReadList, let seriesTitle { name = "\(seriesTitle) \(name)" }
        // Upstream: a chapter named like its title would be trimmed to nothing by the app.
        if name == mangaTitle { name = "\u{200B}" + mangaTitle }
        let translators = metadata.authors.filter { $0.role == "translator" }.map(\.name)
        return SChapter(
            url: "\(baseUrl)/api/v1/books/\(id)",
            name: name,
            dateUpload: Self.date(metadata.releaseDate ?? created ?? fileLastModified) ?? SChapter.undatedUpload,
            chapterNumber: metadata.numberSort,
            scanlator: translators.isEmpty ? nil : translators.joined(separator: ", ")
        )
    }

    /// Upstream `parseDate`: a release date ("2024-05-01") or an instant.
    static func date(_ text: String) -> Date? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: text) { return date }
        let instant = ISO8601DateFormatter()
        instant.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = instant.date(from: text) { return date }
        instant.formatOptions = [.withInternetDateTime]
        return instant.date(from: text)
    }
}

struct KomgaReadProgress: Decodable {
    let lastReadContinuousNumberSort: Double
}

struct KomgaPageImage: Decodable {
    let number: Int
    let mediaType: String
}
