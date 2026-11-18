import Foundation
import MihonDomain

// MARK: - 咚漫 Live Engine (native port of keiyoushi `zh.dongmanmanhua`)
//
// 咚漫 is the official Chinese edition of LINE Webtoon: licensed, free to read on the web, hosted in mainland
// China. It has no API, so this reads its pages the way the extension does with jsoup (see `HTMLDocument`):
// popular / latest → `/dailySchedule`, search → `/search`, details and chapters → the title's `list` pages,
// pages → the episode viewer's `#_imageList`.

public struct DongmanLiveEngine: LiveSourceEngine {
    public static let siteBase = "https://www.dongmanmanhua.cn"

    public init() {}

    public static func handles(baseUrl: String) -> Bool {
        baseUrl.contains("dongmanmanhua.cn")
    }

    /// Every title is a vertical webtoon cut into strips.
    public var preferredReadingMode: ReadingMode? { .webtoon }

    // MARK: Listings

    public func popularManga(page: Int) async throws -> MangasPage {
        let document = try await document("/dailySchedule")
        return MangasPage(mangas: Self.titles(in: document, "div#dailyList .daily_section li a, div.daily_lst.comp li a"), hasNextPage: false)
    }

    /// Today's (China time) column of the update-ordered schedule.
    public func latestUpdates(page: Int) async throws -> MangasPage {
        let document = try await document("/dailySchedule?sortOrder=UPDATE&webtoonCompleteType=ONGOING")
        let day = "_list_\(Self.weekday(of: Date()))"
        return MangasPage(mangas: Self.titles(in: document, "div#dailyList > div.\(day) li > a"), hasNextPage: false)
    }

    public func searchManga(page: Int, query: String, filters: [SourceFilter]) async throws -> MangasPage {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return try await popularManga(page: page) }
        var components = URLComponents(string: Self.siteBase + "/search")!
        components.queryItems = [URLQueryItem(name: "keyword", value: keyword)] + (page > 1 ? [URLQueryItem(name: "page", value: "\(page)")] : [])
        let document = try await document(components.url!.absoluteString)
        return Self.searchPage(document)
    }

    static func searchPage(_ document: HTMLDocument) -> MangasPage {
        let query = "#content > div.card_wrap.search ul:not(#filterLayer) li a"
        let mangas = titles(in: document, query)
        // A script draws the pager (`createPagination({ recordCount: 344, currentPage: 1 })`, 18 titles a page), so
        // there is no next link to find: more pages follow while the titles so far are fewer than the count.
        if let script = document.select("script").map(\.data).first(where: { $0.contains("createPagination") }),
           let total = script.firstMatch(of: #/recordCount\s*:\s*(\d+)/#).flatMap({ Int($0.1) }),
           let current = script.firstMatch(of: #/currentPage\s*:\s*(\d+)/#).flatMap({ Int($0.1) }) {
            let listed = document.select(query).count
            let perPage = max(listed, 18)
            return MangasPage(mangas: mangas, hasNextPage: listed > 0 && (current - 1) * perPage + listed < total)
        }
        let hasNextPage = document.selectFirst("div.more_area, div.paginate a[onclick] + a") != nil
        return MangasPage(mangas: mangas, hasNextPage: hasNextPage)
    }

    static func titles(in document: HTMLDocument, _ query: String) -> [SManga] {
        var seen = Set<String>()
        return document.select(query).compactMap { link -> SManga? in
            guard let title = link.selectFirst("p.subj")?.text, !title.isEmpty else { return nil }
            let url = canonicalTitleUrl(pathAndQuery(link.absUrl("href")))
            guard !url.isEmpty, seen.insert(url).inserted else { return nil }
            let cover = link.selectFirst("img")?.absUrl("src") ?? ""
            return SManga(url: url, title: title, thumbnailUrl: cover.isEmpty ? nil : coverUrl(cover), initialized: false)
        }
    }

    /// Listings link 92–126 px thumbnails; the CDN resizes on request, so ask for one that fills a cover card.
    static func coverUrl(_ url: String) -> String {
        url.replacingOccurrences(of: #"resize,w_\d+"#, with: "resize,w_400", options: .regularExpression)
    }

    // MARK: Details

    public func mangaDetails(manga: SManga) async throws -> SManga {
        var details = Self.details(try await document(manga.url))
        details.url = manga.url
        return details
    }

    public func mangaWebUrl(manga: SManga) -> String {
        Self.siteBase + manga.url
    }

    static func details(_ document: HTMLDocument) -> SManga {
        let header = document.selectFirst(".detail_header .info")
        let aside = document.selectFirst("#_asideDetail")
        let author = header?.selectFirst(".author:nth-of-type(1)")?.ownText ?? header?.selectFirst(".author_area")?.ownText
        let artist = header?.selectFirst(".author:nth-of-type(2)")?.ownText ?? header?.selectFirst(".author_area")?.ownText ?? author
        let schedule = aside?.selectFirst("p.day_info")?.text ?? ""
        let status: MangaStatus = schedule.contains("更新") ? .ongoing : schedule.contains("完结") ? .completed : .unknown
        // The wide banner is the detail body's CSS background; titles without one show a thumbnail instead.
        let banner = document.selectFirst("#content > div.cont_box > div.detail_body")?.attr("style")
            .components(separatedBy: "url(").dropFirst().first?
            .components(separatedBy: ")").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let thumbnail = document.selectFirst("#content > div.cont_box > div.detail_header > span.thmb img:not([alt='Representative image'])")?
            .absUrl("src")
        let cover = [banner, thumbnail].compactMap { $0 }.first { !$0.isEmpty }
        return SManga(
            url: "",
            title: document.selectFirst("h1.subj, h3.subj")?.text ?? "",
            artist: artist.flatMap { $0.isEmpty ? nil : $0 },
            author: author.flatMap { $0.isEmpty ? nil : $0 },
            description: aside?.selectFirst("p.summary")?.text,
            // One `.genre` element can hold several, space-separated (`恋爱 都市`).
            genre: (header?.select(".genre") ?? []).flatMap { $0.text.split(separator: " ").map(String.init) },
            status: status,
            thumbnailUrl: cover.map { coverUrl($0.hasPrefix("//") ? "https:" + $0 : $0) },
            updateStrategy: status == .completed ? .onlyFetchOnce : .alwaysUpdate,
            initialized: true
        )
    }

    // MARK: Chapters

    /// Ten episodes per `list` page, newest first. The pager shows a block of pages — the current one, links to the
    /// rest of the block, `pg_next` to the next block — and the block's pages are fetched together: one by one,
    /// 非人哉 (1 271 episodes, 128 pages) took minutes. The mobile list (`m.dongmanmanhua.cn/episodeList?titleNo=`)
    /// has every episode in one page, but its `data-free` flag does not match what the web lets you read (title
    /// 2793: free up to 24 there, 43 episodes listed here), so it is not used until that is understood.
    public func chapterList(manga: SManga) async throws -> [SChapter] {
        var document = try await document(manga.url)
        var chapters: [SChapter] = []
        for _ in 0..<40 {
            chapters += Self.chapters(in: document)
            let pager = document.select("div.paginate a")
            guard let current = pager.firstIndex(where: { $0.hasAttr("onclick") }) else { break }
            let isArrow = { (link: HTMLElement) in link.attr("class").contains("pg_next") || link.attr("class").contains("pg_prev") }
            let block = pager[(current + 1)...].filter { !isArrow($0) }.map { $0.absUrl("href") }.filter { !$0.isEmpty }
            let pages = try await withThrowingTaskGroup(of: (Int, [SChapter]).self) { group in
                for (index, link) in block.enumerated() {
                    group.addTask { (index, Self.chapters(in: try await self.document(link))) }
                }
                var pages: [(Int, [SChapter])] = []
                for try await page in group {
                    pages.append(page)
                }
                return pages.sorted { $0.0 < $1.0 }.flatMap(\.1)
            }
            chapters += pages
            let nextBlock = pager.first { $0.attr("class").contains("pg_next") }?.absUrl("href") ?? ""
            guard !nextBlock.isEmpty else { break }
            document = try await self.document(nextBlock)
        }
        return chapters
    }

    static func chapters(in document: HTMLDocument) -> [SChapter] {
        document.select("ul#_listUl li").compactMap { item in
            guard let name = item.selectFirst("span.subj span")?.text,
                  let href = item.selectFirst("a")?.absUrl("href"), !href.isEmpty else { return nil }
            return SChapter(
                url: pathAndQuery(href),
                name: name,
                dateUpload: date(item.selectFirst("span.date")?.text) ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    // MARK: Pages

    public func pageList(chapter: SChapter) async throws -> [Page] {
        Self.pages(in: try await document(chapter.url), chapter: chapter)
    }

    /// Viewer images carry the real URL in `data-url`; `src` is a transparent placeholder.
    static func pages(in document: HTMLDocument, chapter: SChapter) -> [Page] {
        let urls = document.select("div#_imageList > img").map { $0.attr("data-url").trimmingCharacters(in: .whitespaces) }
        return urls.filter { !$0.isEmpty }.enumerated().map { index, url in
            Page(index: index, url: chapter.url, imageUrl: url, chapterTitle: chapter.name, mangaTitle: nil)
        }
    }

    // MARK: Helpers

    private func document(_ pathOrUrl: String) async throws -> HTMLDocument {
        guard let url = URL(string: pathOrUrl.hasPrefix("http") ? pathOrUrl : Self.siteBase + pathOrUrl) else {
            throw MihonNetworkError.invalidResponse
        }
        let (data, _) = try await MihonNetworkClient.shared.performGET(url: url, headers: ["Referer": Self.siteBase + "/"])
        return HTMLDocument(html: String(decoding: data, as: UTF8.self), baseURL: url)
    }

    /// The schedule links a title as `/GENRE/slug/list?title_no=N`, search as `/episodeList?titleNo=N` (which the
    /// site redirects to the former). One form per title keeps library matches and "in library" badges right.
    static func canonicalTitleUrl(_ path: String) -> String {
        guard let match = path.firstMatch(of: #/[?&]title_?[nN]o=(\d+)/#), path.contains("/list?") || path.hasPrefix("/episodeList") else {
            return path
        }
        return "/episodeList?titleNo=\(match.1)"
    }

    /// Path and query of an absolute link (jsoup `setUrlWithoutDomain`).
    static func pathAndQuery(_ absolute: String) -> String {
        guard let components = URLComponents(string: absolute) else { return absolute }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-M-d"
        return formatter
    }()

    static func date(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return dateFormatter.date(from: text)
    }

    /// `MONDAY` … `SUNDAY` in China time, as the schedule's column classes spell it.
    static func weekday(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let names = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
        return names[calendar.component(.weekday, from: date) - 1]
    }
}
