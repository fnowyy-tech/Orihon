import Foundation
import MihonDomain

// MARK: - MangaDex Live Engine (native port of keiyoushi `all.mangadex` request/parse logic)
//
// The MangaDex extension only talks to the public JSON API, so its behaviour can be reproduced exactly:
// listings → `/manga`, details → `/manga/{id}`, chapters → `/manga/{id}/feed`, pages → `/at-home/server/{id}`.

public struct MangaDexLiveEngine: LiveSourceEngine {
    public static let apiBase = "https://api.mangadex.org"
    public static let cdnBase = "https://uploads.mangadex.org"
    public static let webBase = "https://mangadex.org"

    /// Source language as published by the extension index (`zh-Hans`, `pt-BR`, `es-419`, …).
    public let sourceLang: String
    public let allowNsfw: Bool
    public let dataSaver: Bool
    private let pageSize = 20

    public init(sourceLang: String, allowNsfw: Bool = false, dataSaver: Bool = false) {
        self.sourceLang = sourceLang
        self.allowNsfw = allowNsfw
        self.dataSaver = dataSaver
    }

    public static func handles(baseUrl: String, packageName: String? = nil) -> Bool {
        baseUrl.contains("mangadex.org") || (packageName?.hasSuffix(".all.mangadex") ?? false)
    }

    /// 1:1 with the extension's `MDConstants` language mapping.
    var apiLanguages: [String] {
        switch sourceLang {
        case "zh-Hans", "zh": return ["zh"]
        case "zh-Hant": return ["zh-hk"]
        case "pt-BR": return ["pt-br"]
        case "es-419": return ["es-la"]
        case "all": return []
        default: return [sourceLang.lowercased()]
        }
    }

    private var contentRatings: [String] {
        allowNsfw ? ["safe", "suggestive", "erotica", "pornographic"] : ["safe", "suggestive"]
    }

    private var headers: [String: String] {
        ["Referer": "\(Self.webBase)/", "Accept": "application/json"]
    }

    // MARK: Listings

    public func popularManga(page: Int) async throws -> MangasPage {
        try await mangaList(page: page, extra: [URLQueryItem(name: "order[followedCount]", value: "desc")])
    }

    public func latestUpdates(page: Int) async throws -> MangasPage {
        try await mangaList(page: page, extra: [URLQueryItem(name: "order[latestUploadedChapter]", value: "desc")])
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Upstream deep-links: a pasted `https://mangadex.org/title/<uuid>` or bare uuid opens that entry.
        if let uuid = Self.extractUUID(from: trimmed) {
            let manga = try await mangaDetails(manga: SManga(url: "/manga/\(uuid)", title: ""))
            return MangasPage(mangas: [manga], hasNextPage: false)
        }
        var extra = [URLQueryItem(name: "order[relevance]", value: "desc")]
        if !trimmed.isEmpty {
            extra.append(URLQueryItem(name: "title", value: trimmed))
        }
        return try await mangaList(page: page, extra: extra)
    }

    private func mangaList(page: Int, extra: [URLQueryItem]) async throws -> MangasPage {
        var items = [
            URLQueryItem(name: "limit", value: "\(pageSize)"),
            URLQueryItem(name: "offset", value: "\(max(0, page - 1) * pageSize)"),
            URLQueryItem(name: "includes[]", value: "cover_art"),
            URLQueryItem(name: "hasAvailableChapters", value: "true")
        ]
        items += apiLanguages.map { URLQueryItem(name: "availableTranslatedLanguage[]", value: $0) }
        items += contentRatings.map { URLQueryItem(name: "contentRating[]", value: $0) }
        items += extra
        let response: MDListResponse<MDManga> = try await get("/manga", items)
        let mangas = response.data.map { toSManga($0, detailed: false) }
        let total = response.total ?? 0
        let nextOffset = (response.offset ?? 0) + response.data.count
        return MangasPage(mangas: mangas, hasNextPage: nextOffset < min(total, 10_000))
    }

    // MARK: Details

    public func mangaDetails(manga: SManga) async throws -> SManga {
        guard let id = Self.extractUUID(from: manga.url) else { return manga }
        let items = ["author", "artist", "cover_art"].map { URLQueryItem(name: "includes[]", value: $0) }
        let response: MDEntityResponse<MDManga> = try await get("/manga/\(id)", items)
        return toSManga(response.data, detailed: true)
    }

    public func mangaWebUrl(manga: SManga) -> String {
        guard let id = Self.extractUUID(from: manga.url) else { return Self.webBase }
        return "\(Self.webBase)/title/\(id)"
    }

    // MARK: Chapters

    public func chapterList(manga: SManga) async throws -> [SChapter] {
        guard let id = Self.extractUUID(from: manga.url) else { return [] }
        var chapters: [SChapter] = []
        var offset = 0
        let limit = 500
        // Every page, up to the API's window of 10 000 entries (long series pass 4 000 chapters per language).
        while offset < 10_000 {
            var items = [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
                URLQueryItem(name: "includes[]", value: "scanlation_group"),
                URLQueryItem(name: "order[volume]", value: "desc"),
                URLQueryItem(name: "order[chapter]", value: "desc"),
                URLQueryItem(name: "includeExternalUrl", value: "0"),
                URLQueryItem(name: "includeEmptyPages", value: "0"),
                URLQueryItem(name: "includeFuturePublishAt", value: "0")
            ]
            items += apiLanguages.map { URLQueryItem(name: "translatedLanguage[]", value: $0) }
            items += ["safe", "suggestive", "erotica", "pornographic"].map { URLQueryItem(name: "contentRating[]", value: $0) }
            let response: MDListResponse<MDChapter> = try await get("/manga/\(id)/feed", items)
            chapters += response.data.compactMap(toSChapter)
            offset += response.data.count
            if response.data.isEmpty || offset >= (response.total ?? 0) { break }
        }
        return chapters
    }

    // MARK: Pages

    public func pageList(chapter: SChapter) async throws -> [Page] {
        guard let id = Self.extractUUID(from: chapter.url) else { return [] }
        let server: MDAtHome = try await get("/at-home/server/\(id)", [])
        let quality = dataSaver ? "data-saver" : "data"
        let files = dataSaver ? server.chapter.dataSaver : server.chapter.data
        return files.enumerated().map { idx, file in
            Page(
                index: idx,
                url: chapter.url,
                imageUrl: "\(server.baseUrl)/\(quality)/\(server.chapter.hash)/\(file)",
                chapterTitle: chapter.name,
                mangaTitle: nil
            )
        }
    }

    // MARK: Mapping (1:1 with `MangaDexHelper.createBasicManga / createManga / createChapter`)

    private func toSManga(_ manga: MDManga, detailed: Bool) -> SManga {
        let attrs = manga.attributes
        let preferredLangs = apiLanguages + ["en", "ja-ro", "ja"]
        let altTitle = attrs.altTitles
            .lazy
            .compactMap { dict -> String? in
                for lang in self.apiLanguages {
                    if let value = dict[lang], !value.isEmpty { return value }
                }
                return nil
            }
            .first
        let mainTitle = preferredLangs.lazy.compactMap { attrs.title[$0] }.first ?? attrs.title.values.first ?? ""
        let title = altTitle ?? mainTitle

        let coverFile = manga.relationships.first { $0.type == "cover_art" }?.attributes?.fileName
        let thumbnail = coverFile.map { "\(Self.cdnBase)/covers/\(manga.id)/\($0).512.jpg" }

        var smanga = SManga(
            url: "/manga/\(manga.id)",
            title: title,
            thumbnailUrl: thumbnail,
            initialized: detailed
        )
        let names: (String) -> String? = { type in
            var seen = Set<String>()
            let list = manga.relationships
                .filter { $0.type == type }
                .compactMap { $0.attributes?.name }
                .filter { seen.insert($0).inserted }
            return list.isEmpty ? nil : list.joined(separator: ", ")
        }
        smanga.author = names("author")
        smanga.artist = names("artist")

        let descLang = preferredLangs.first { !(attrs.description[$0] ?? "").isEmpty }
        smanga.description = descLang.flatMap { attrs.description[$0] }.map(Self.cleanDescription)

        var genres: [String] = []
        if let demographic = attrs.publicationDemographic, !demographic.isEmpty {
            genres.append(demographic.capitalized)
        }
        genres += attrs.tags
            .sorted { ($0.attributes.group, $0.attributes.name["en"] ?? "") < ($1.attributes.group, $1.attributes.name["en"] ?? "") }
            .compactMap { $0.attributes.name["en"] }
        if let rating = attrs.contentRating, rating != "safe" {
            genres.append(rating.capitalized)
        }
        smanga.genre = genres

        switch attrs.status {
        case "ongoing": smanga.status = .ongoing
        // The original is finished; its translation may still be coming (keiyoushi MangaDex, upstream status).
        case "completed": smanga.status = .publishingFinished
        case "hiatus": smanga.status = .onHiatus
        case "cancelled": smanga.status = .cancelled
        default: smanga.status = .unknown
        }
        smanga.updateStrategy = .alwaysUpdate
        return smanga
    }

    private func toSChapter(_ chapter: MDChapter) -> SChapter? {
        let attrs = chapter.attributes
        if attrs.externalUrl != nil && attrs.pages == 0 { return nil }

        var parts: [String] = []
        if let volume = attrs.volume, !volume.isEmpty { parts.append("Vol.\(volume)") }
        if let number = attrs.chapter, !number.isEmpty { parts.append("Ch.\(number)") }
        if let title = attrs.title, !title.isEmpty {
            if !parts.isEmpty { parts.append("-") }
            parts.append(title)
        }
        if parts.isEmpty { parts.append("Oneshot") }

        let groups = chapter.relationships
            .filter { $0.type == "scanlation_group" }
            .compactMap { $0.attributes?.name }
        let date = Self.isoFormatter.date(from: attrs.publishAt) ?? Self.isoFormatterFractional.date(from: attrs.publishAt) ?? Date()

        return SChapter(
            url: "/chapter/\(chapter.id)",
            name: parts.joined(separator: " "),
            dateUpload: date,
            chapterNumber: attrs.chapter.flatMap(Double.init) ?? -1,
            scanlator: groups.isEmpty ? "No Group" : groups.joined(separator: " & ")
        )
    }

    // MARK: Networking

    private func get<T: Decodable>(_ path: String, _ queryItems: [URLQueryItem]) async throws -> T {
        var components = URLComponents(string: Self.apiBase + path)!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw MihonNetworkError.invalidResponse }
        let (data, _) = try await MihonNetworkClient.shared.performGET(url: url, headers: headers)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func extractUUID(from text: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).lowercased()
    }

    /// Strips the MarkDown link/separator noise MangaDex descriptions carry (1:1 with `cleanString`).
    static func cleanDescription(_ text: String) -> String {
        var result = text
        if let separator = result.range(of: "\n___") ?? result.range(of: "\n---") {
            result = String(result[..<separator.lowerBound])
        }
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[*_]{1,3}([^*_]+)[*_]{1,3}", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - MangaDex DTOs

private struct MDListResponse<T: Decodable>: Decodable {
    let result: String
    let data: [T]
    let limit: Int?
    let offset: Int?
    let total: Int?
}

private struct MDEntityResponse<T: Decodable>: Decodable {
    let data: T
}

private struct MDRelationship: Decodable {
    struct Attributes: Decodable {
        let fileName: String?
        let name: String?
    }
    let id: String
    let type: String
    let attributes: Attributes?
}

private struct MDManga: Decodable {
    struct Tag: Decodable {
        struct Attributes: Decodable {
            let name: [String: String]
            let group: String
        }
        let attributes: Attributes
    }

    struct Attributes: Decodable {
        let title: [String: String]
        let altTitles: [[String: String]]
        let description: [String: String]
        let status: String?
        let contentRating: String?
        let publicationDemographic: String?
        let tags: [Tag]

        enum CodingKeys: String, CodingKey {
            case title, altTitles, description, status, contentRating, publicationDemographic, tags
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode([String: String].self, forKey: .title)) ?? [:]
            altTitles = (try? c.decode([[String: String]].self, forKey: .altTitles)) ?? []
            // MangaDex serialises an empty description as `[]` instead of `{}`.
            description = (try? c.decode([String: String].self, forKey: .description)) ?? [:]
            status = try? c.decode(String.self, forKey: .status)
            contentRating = try? c.decode(String.self, forKey: .contentRating)
            publicationDemographic = try? c.decode(String.self, forKey: .publicationDemographic)
            tags = (try? c.decode([Tag].self, forKey: .tags)) ?? []
        }
    }

    let id: String
    let attributes: Attributes
    let relationships: [MDRelationship]
}

private struct MDChapter: Decodable {
    struct Attributes: Decodable {
        let volume: String?
        let chapter: String?
        let title: String?
        let translatedLanguage: String?
        let externalUrl: String?
        let publishAt: String
        let pages: Int
    }
    let id: String
    let attributes: Attributes
    let relationships: [MDRelationship]
}

private struct MDAtHome: Decodable {
    struct Chapter: Decodable {
        let hash: String
        let data: [String]
        let dataSaver: [String]
    }
    let baseUrl: String
    let chapter: Chapter
}
