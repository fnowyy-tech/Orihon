import XCTest
import ImageIO
@testable import MihonDomain
@testable import MihonData

/// Komga (keiyoushi `all.komga`): parsing runs on responses recorded from a Komga 1.29 server
/// (`Fixtures/komga`); the end-to-end test talks to a server named by `MIHON_KOMGA_URL` (+ `MIHON_KOMGA_USER`,
/// `MIHON_KOMGA_PASSWORD`) and skips itself without one.
final class MihonKomgaTests: XCTestCase {
    static let base = "http://komga.local:25600"

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/komga"))
        return try Data(contentsOf: url)
    }

    func testSeriesListMapsLikeUpstream() throws {
        let page = try JSONDecoder().decode(KomgaPage<KomgaSeries>.self, from: fixture("series"))
        XCTAssertTrue(page.last)
        let mangas = page.content.map { $0.toSManga(baseUrl: Self.base) }
        XCTAssertEqual(mangas.map(\.title), ["Second Series", "测试系列"])
        let first = try XCTUnwrap(mangas.first)
        XCTAssertTrue(first.url.hasPrefix("\(Self.base)/api/v1/series/"), "absolute, as upstream (backups match)")
        XCTAssertEqual(first.thumbnailUrl, first.url + "/thumbnail")
        XCTAssertEqual(first.status, .ongoing)
    }

    func testStatusAndCredits() throws {
        func series(status: String, books: Int, total: Int?, authors: String) throws -> SManga {
            let json = """
            {"id":"S1","booksCount":\(books),"metadata":{"status":"\(status)","title":"T","summary":"","genres":["b","a"],
            "tags":["a","c"],"totalBookCount":\(total.map(String.init) ?? "null")},
            "booksMetadata":{"authors":\(authors),"tags":["d"],"summary":"书的简介"}}
            """
            return try JSONDecoder().decode(KomgaSeries.self, from: Data(json.utf8)).toSManga(baseUrl: Self.base)
        }
        XCTAssertEqual(try series(status: "ENDED", books: 3, total: 10, authors: "[]").status, .publishingFinished)
        XCTAssertEqual(try series(status: "ENDED", books: 10, total: 10, authors: "[]").status, .completed)
        XCTAssertEqual(try series(status: "HIATUS", books: 1, total: nil, authors: "[]").status, .onHiatus)
        XCTAssertEqual(try series(status: "ABANDONED", books: 1, total: nil, authors: "[]").status, .cancelled)
        let credited = try series(status: "ONGOING", books: 1, total: nil, authors: """
        [{"name":"作者","role":"writer"},{"name":"画师","role":"penciller"},{"name":"作者","role":"writer"}]
        """)
        XCTAssertEqual(credited.author, "作者")
        XCTAssertEqual(credited.artist, "画师")
        XCTAssertEqual(credited.genre, ["a", "b", "c", "d"], "genres, tags and the books' tags")
        XCTAssertEqual(credited.description, "书的简介", "the series has no summary: the books'")
    }

    func testBooksBecomeChapters() throws {
        let page = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: fixture("books"))
        let chapters = page.content.map { $0.toSChapter(baseUrl: Self.base, mangaTitle: "测试系列") }
        XCTAssertEqual(chapters.map(\.name), ["1 - 测试系列 v01 (5.3 MiB)", "2 - 测试系列 v02 (5 MiB)"], "upstream's default title template")
        XCTAssertEqual(chapters.map(\.chapterNumber), [1, 2])
        XCTAssertTrue(chapters[0].url.hasPrefix("\(Self.base)/api/v1/books/"))
        XCTAssertEqual(chapters[0].dateUpload, ISO8601DateFormatter().date(from: "2026-10-28T05:56:06Z"), "no release date: created")
        XCTAssertEqual(KomgaBook.date("2024-05-01"), ISO8601DateFormatter().date(from: "2024-05-01T00:00:00Z"))
        XCTAssertNotNil(KomgaBook.date("2024-05-01T10:00:00.123Z"))
    }

    func testPagesAndAuth() throws {
        let pages = try JSONDecoder().decode([KomgaPageImage].self, from: fixture("pages"))
        XCTAssertEqual(pages.map(\.number), [1, 2, 3])
        XCTAssertEqual(KomgaAccount(address: " http://h:25600/ ").baseUrl, "http://h:25600")
        XCTAssertFalse(KomgaAccount().isConfigured)
        XCTAssertEqual(KomgaAccount(address: "x", username: "u", password: "p").headers["Authorization"], "Basic dTpw")
        XCTAssertEqual(KomgaAccount(address: "x", username: "u", password: "p", apiKey: "k").headers, ["X-API-Key": "k"], "an API key wins")
        XCTAssertEqual(KomgaAccount(address: "x").headers, [:])
    }

    func testUnconfiguredInstanceSaysSo() async {
        do {
            _ = try await KomgaLiveEngine(account: KomgaAccount()).popularManga(page: 1)
            XCTFail("no address")
        } catch {
            XCTAssertEqual(error as? KomgaError, .notConfigured)
        }
    }

    /// The first instance is listed and live; once it has an address its login goes with every request there —
    /// covers and pages too, which the image cache fetches without knowing their source.
    @MainActor
    func testInstanceIsListedAndCarriesItsLogin() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let id = KomgaLiveEngine.instanceIds[0]
        XCTAssertTrue(store.isLiveSource(id))
        XCTAssertTrue(store.activeCatalogueSources().contains { $0.id == id && $0.isLive }, "listed in Browse")
        defer { store.komgaAccounts = [:] }

        store.komgaAccounts[id] = KomgaAccount(address: "http://komga.test:25600/", username: "u", password: "p")
        let page = try XCTUnwrap(URL(string: "http://komga.test:25600/api/v1/books/B1/pages/1"))
        XCTAssertEqual(MihonServerAuth.headers(for: page)["Authorization"], "Basic dTpw")
        XCTAssertEqual(MihonServerAuth.headers(for: try XCTUnwrap(URL(string: "http://komga.test:2560/api"))), [:], "another port")
        XCTAssertEqual(MihonServerAuth.headers(for: try XCTUnwrap(URL(string: "https://elsewhere.test/a"))), [:])

        store.komgaAccounts[id] = KomgaAccount(address: "https://komga.test", apiKey: "K")
        XCTAssertEqual(MihonServerAuth.headers(for: try XCTUnwrap(URL(string: "https://komga.test/api/v1/books/B1"))), ["X-API-Key": "K"])
        XCTAssertEqual(MihonServerAuth.headers(for: try XCTUnwrap(URL(string: "https://komga.test.evil.com/a"))), [:], "a longer host")
        XCTAssertEqual(MihonServerAuth.headers(for: page), [:], "the old address no longer gets it")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "komga.test", .path: "/", .name: "KOMGA-SESSION", .value: "x"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        store.komgaAccounts = [:]
        XCTAssertEqual(MihonServerAuth.headers(for: page), [:], "signed out")
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: try XCTUnwrap(URL(string: "https://komga.test/")))?.isEmpty, true,
                       "Komga's session cookie goes with the login")
    }

    func testSecretsRoundTrip() {
        let key = "test.\(UUID().uuidString)"
        XCTAssertNil(MihonSecretStore.data(for: key))
        MihonSecretStore.set(Data("秘密".utf8), for: key)
        XCTAssertEqual(MihonSecretStore.data(for: key), Data("秘密".utf8))
        MihonSecretStore.set(nil, for: key)
        XCTAssertNil(MihonSecretStore.data(for: key))
    }

    /// Against a real server through the store: browse, open, read, and load a page image with no headers given.
    @MainActor
    func testLiveServerThroughTheStore() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["MIHON_KOMGA_URL"] else { throw XCTSkip("Set MIHON_KOMGA_URL to test against a Komga server") }
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let id = KomgaLiveEngine.instanceIds[0]
        store.komgaAccounts[id] = KomgaAccount(address: address, username: environment["MIHON_KOMGA_USER"] ?? "",
                                               password: environment["MIHON_KOMGA_PASSWORD"] ?? "")
        defer { store.komgaAccounts = [:] }
        let source = try XCTUnwrap(store.catalogueSource(for: id))
        let listed = try await source.getPopularManga(page: 1).mangas
        let manga = store.upsertCatalogMangaToStore(try XCTUnwrap(listed.first), sourceId: id)
        await store.refreshMangaFromSource(mangaId: manga.id)
        let chapters = try XCTUnwrap(store.chaptersByManga[manga.id])
        let refreshed = try XCTUnwrap(store.manga(id: manga.id))
        let pages = try await store.pageList(for: refreshed, chapter: try XCTUnwrap(chapters.first))
        let image = await MihonTwoTierImageCache.shared.image(url: try XCTUnwrap(pages.first?.imageUrl), target: .page(maxPixelSize: 1024))
        XCTAssertNotNil(image, "the page request carried the login by itself")
        let cover = await MihonTwoTierImageCache.shared.image(url: try XCTUnwrap(refreshed.thumbnailUrl), target: .cover)
        XCTAssertNotNil(cover)
    }

    /// "https://" alone (or any address without a host) is no server, so it never gets a login.
    func testAddressesWithoutAHostAreNoServer() throws {
        XCTAssertFalse(KomgaAccount(address: "https://").isConfigured)
        XCTAssertFalse(KomgaAccount(address: "komga.local:25600").isConfigured, "no scheme")
        XCTAssertFalse(KomgaAccount(address: "ftp://komga.local").isConfigured)
        XCTAssertTrue(KomgaAccount(address: "http://100.64.0.7:25600").isConfigured)
        MihonServerAuth.set(["https:": ["X-API-Key": "K"], "https://": ["X-API-Key": "K"]])
        defer { MihonServerAuth.set([:]) }
        XCTAssertEqual(MihonServerAuth.headers(for: try XCTUnwrap(URL(string: "https://api.mangadex.org/manga"))), [:])
    }

    func testServersMatchByOriginAndPath() throws {
        MihonServerAuth.set(["http://Komga.Test:25600/komga/": ["X-API-Key": "K"]])
        defer { MihonServerAuth.set([:]) }
        func headers(_ url: String) throws -> [String: String] { MihonServerAuth.headers(for: try XCTUnwrap(URL(string: url))) }
        XCTAssertEqual(try headers("http://komga.test:25600/komga/api/v1/series"), ["X-API-Key": "K"])
        XCTAssertEqual(try headers("http://komga.test:25600/komga"), ["X-API-Key": "K"])
        XCTAssertEqual(try headers("http://komga.test:25600/komgaX/api"), [:], "another path")
        XCTAssertEqual(try headers("https://komga.test:25600/komga/api"), [:], "another scheme")
        XCTAssertEqual(try headers("http://komga.test/komga/api"), [:], "another port")
        XCTAssertEqual(try headers("http://komga.test.evil.com:25600/komga/api"), [:], "another host")
        XCTAssertTrue(MihonServerAuth.isOnServer(try XCTUnwrap(URL(string: "https://h/api")), base: try XCTUnwrap(URL(string: "https://h:443"))))
    }

    /// A redirect drops the login, then adds the new address's own (none on a downgrade to http).
    func testRedirectsCarryOnlyTheNewAddresssLogin() throws {
        MihonServerAuth.set(["https://komga.test": ["Authorization": "Basic dTpw"]])
        defer { MihonServerAuth.set([:]) }
        func redirect(from: String, to: String) throws -> URLRequest? {
            let task = URLSession.shared.dataTask(with: try XCTUnwrap(URL(string: from)))
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(URL(string: from)), statusCode: 302, httpVersion: nil, headerFields: nil))
            var next = URLRequest(url: try XCTUnwrap(URL(string: to)))
            next.setValue("K", forHTTPHeaderField: "X-API-Key")
            next.setValue("Basic old", forHTTPHeaderField: "Authorization")
            var result: URLRequest?
            MihonRedirectGuard().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: next) { result = $0 }
            return result
        }
        let away = try XCTUnwrap(redirect(from: "https://komga.test/api", to: "https://sso.example.com/login"))
        XCTAssertNil(away.value(forHTTPHeaderField: "X-API-Key"), "never forwarded to another host")
        XCTAssertNil(away.value(forHTTPHeaderField: "Authorization"))
        let home = try XCTUnwrap(redirect(from: "https://komga.test/api", to: "https://komga.test/api/v2"))
        XCTAssertEqual(home.value(forHTTPHeaderField: "Authorization"), "Basic dTpw", "same server: its own login again")
        let downgrade = try XCTUnwrap(redirect(from: "https://komga.test/a", to: "http://komga.test/a"))
        XCTAssertNil(downgrade.value(forHTTPHeaderField: "Authorization"))
    }

    /// A title saved under another address does not get this server's login.
    func testTitlesOnAnotherServerAreRefused() async {
        let engine = KomgaLiveEngine(account: KomgaAccount(address: "http://new.lan:25600", username: "u", password: "p"))
        do {
            _ = try await engine.chapterList(manga: SManga(url: "http://old.lan:25600/api/v1/series/S1", title: "T"))
            XCTFail("another server")
        } catch {
            XCTAssertEqual(error as? KomgaError, .otherServer("old.lan"))
        }
    }

    /// Read lists and single books (upstream lists them as titles too) map like upstream's.
    func testReadListsAndBooksAsTitles() throws {
        let list = try JSONDecoder().decode(KomgaReadList.self, from: Data(#"{"id":"R1","name":"夏日精选","summary":"简介"}"#.utf8))
            .toSManga(baseUrl: Self.base)
        XCTAssertEqual(list.url, "\(Self.base)/api/v1/readlists/R1")
        XCTAssertEqual(list.thumbnailUrl, list.url + "/thumbnail")
        XCTAssertTrue(KomgaLiveEngine.isReadList(list.url))
        let books = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: fixture("books"))
        let chapter = books.content[0].toSChapter(baseUrl: Self.base, mangaTitle: "夏日精选", inReadList: true)
        XCTAssertEqual(chapter.name, "测试系列 1 - 测试系列 v01 (5.3 MiB)", "a read list's chapters name their series")
        let book = books.content[0].toSManga(baseUrl: Self.base)
        XCTAssertTrue(KomgaLiveEngine.isBook(book.url))
        XCTAssertEqual(book.title, "测试系列 v01")
    }

    /// Upstream `SyncChapterProgressWithTrack` (enhanced tracker): the server's progress marks chapters read here;
    /// what is read here without a gap is sent back when it is further along.
    func testProgressMergesBothWays() {
        func chapter(_ number: Double, read: Bool) -> Chapter {
            Chapter(id: Int64(number * 10), mangaId: 1, url: "/b/\(number)", name: "\(number)", read: read, chapterNumber: number)
        }
        let pulled = MihonRepositoryStore.mergeKomgaProgress([chapter(1, read: false), chapter(2, read: false), chapter(3, read: false)], remote: 2)
        XCTAssertEqual(pulled.chapters.map(\.read), [true, true, false])
        XCTAssertNil(pulled.push, "the server is ahead or level")

        let pushed = MihonRepositoryStore.mergeKomgaProgress([chapter(1, read: true), chapter(2, read: true), chapter(3, read: false), chapter(4, read: true)], remote: 1)
        XCTAssertEqual(pushed.push, 2, "read without a gap: up to 2, not 4")

        let unnumbered = MihonRepositoryStore.mergeKomgaProgress([chapter(-1, read: false)], remote: 5)
        XCTAssertEqual(unnumbered.chapters.map(\.read), [false], "an unrecognized number is left alone")
    }

    /// Accounts saved by builds 21–22 lack the progress switch: they keep their login and sync by default.
    func testOldSavedAccountsStillDecode() throws {
        // As JSONEncoder wrote `[Int64: KomgaAccount]` (non-string keys: key, value, key, value…).
        let saved = #"[4508733312114627536,{"address":"http://h:25600","username":"u","password":"p","apiKey":""}]"#
        let decoded = try JSONDecoder().decode([Int64: KomgaAccount].self, from: Data(saved.utf8))
        XCTAssertEqual(decoded[KomgaLiveEngine.instanceIds[0]]?.username, "u")
        XCTAssertEqual(decoded[KomgaLiveEngine.instanceIds[0]]?.syncsProgress, true)
    }

    /// Against a real server: the server's progress comes in on refresh, and a chapter marked read here goes out.
    @MainActor
    func testLiveProgressSync() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["MIHON_KOMGA_URL"] else { throw XCTSkip("Set MIHON_KOMGA_URL to test against a Komga server") }
        let account = KomgaAccount(address: address, username: environment["MIHON_KOMGA_USER"] ?? "",
                                   password: environment["MIHON_KOMGA_PASSWORD"] ?? "")
        let engine = KomgaLiveEngine(account: account)
        let listed = try await engine.popularManga(page: 1).mangas
        let series = try XCTUnwrap(listed.first { $0.title == "测试系列" } ?? listed.last)
        let books = try await engine.chapterList(manga: series)
        guard books.count >= 2 else { throw XCTSkip("needs a series with two books") }
        for book in books { _ = try? await Self.send(address: "\(book.url)/read-progress", account: account, method: "DELETE") }

        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let id = KomgaLiveEngine.instanceIds[0]
        store.komgaAccounts = [id: account]
        defer { store.komgaAccounts = [:] }
        let manga = store.upsertCatalogMangaToStore(series, sourceId: id)
        store.addToLibrary(mangaId: manga.id, categoryIds: [])
        await store.refreshMangaFromSource(mangaId: manga.id)
        XCTAssertEqual(store.chaptersByManga[manga.id]?.filter(\.read).count, 0)

        try await engine.setReadProgress(manga: series, lastNumberSort: 1)
        await store.refreshMangaFromSource(mangaId: manga.id, force: true)
        XCTAssertEqual(store.chaptersByManga[manga.id]?.filter(\.read).map(\.chapterNumber), [1], "pulled from the server")

        let second = try XCTUnwrap(store.chaptersByManga[manga.id]?.first { $0.chapterNumber == 2 })
        store.setChaptersRead(mangaId: manga.id, chapterIds: [second.id], read: true)
        var remote = 0.0
        for _ in 0..<40 where remote < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
            remote = try await engine.readProgress(manga: series)
        }
        XCTAssertEqual(remote, 2, "pushed to the server")
    }

    /// Against a real server: a title 智能更新 skips (unread chapters) still gets the server's progress.
    @MainActor
    func testLiveProgressReachesSkippedTitles() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["MIHON_KOMGA_URL"] else { throw XCTSkip("Set MIHON_KOMGA_URL to test against a Komga server") }
        let account = KomgaAccount(address: address, username: environment["MIHON_KOMGA_USER"] ?? "",
                                   password: environment["MIHON_KOMGA_PASSWORD"] ?? "")
        let engine = KomgaLiveEngine(account: account)
        let listed = try await engine.popularManga(page: 1).mangas
        let series = try XCTUnwrap(listed.first { $0.title == "测试系列" } ?? listed.last)
        let books = try await engine.chapterList(manga: series)
        guard books.count >= 2 else { throw XCTSkip("needs a series with two books") }
        for book in books { _ = try? await Self.send(address: "\(book.url)/read-progress", account: account, method: "DELETE") }

        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let id = KomgaLiveEngine.instanceIds[0]
        store.komgaAccounts = [id: account]
        defer { store.komgaAccounts = [:] }
        let manga = store.upsertCatalogMangaToStore(series, sourceId: id)
        store.addToLibrary(mangaId: manga.id, categoryIds: [])
        await store.refreshMangaFromSource(mangaId: manga.id)
        // Only this title: the seed library's would go to the network.
        for other in store.mangas where other.favorite && other.id != manga.id {
            store.removeFromLibrary(mangaId: other.id)
        }

        try await engine.setReadProgress(manga: series, lastNumberSort: 1)
        let result = await store.refreshLibraryUpdates(reportsResult: false)
        XCTAssertEqual(result.skipped, 1, "unread chapters: skipped")
        XCTAssertEqual(store.chaptersByManga[manga.id]?.filter(\.read).map(\.chapterNumber), [1], "the progress came in anyway")
    }

    /// Against a real server: series, details, chapters, pages and an authenticated page image.
    func testLiveServerEndToEnd() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["MIHON_KOMGA_URL"] else { throw XCTSkip("Set MIHON_KOMGA_URL to test against a Komga server") }
        let account = KomgaAccount(address: address, username: environment["MIHON_KOMGA_USER"] ?? "",
                                   password: environment["MIHON_KOMGA_PASSWORD"] ?? "")
        let engine = KomgaLiveEngine(account: account)
        let libraries = try await engine.libraries()
        XCTAssertFalse(libraries.isEmpty)
        let popular = try await engine.popularManga(page: 1)
        let manga = try XCTUnwrap(popular.mangas.first)
        let details = try await engine.mangaDetails(manga: manga)
        XCTAssertEqual(details.title, manga.title)
        let chapters = try await engine.chapterList(manga: manga)
        let chapter = try XCTUnwrap(chapters.first)
        let pages = try await engine.pageList(chapter: chapter)
        let image = try XCTUnwrap(pages.first?.imageUrl.flatMap(URL.init(string:)))
        let data = try await MihonNetworkClient.shared.fetchAsset(url: image, headers: account.headers)
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })

        // The good login left Komga's session cookie behind; 测试连接 with a wrong password must still fail.
        let wrongAccount = KomgaAccount(address: address, username: account.username, password: "wrong")
        do {
            _ = try await KomgaLiveEngine(account: wrongAccount).libraries()
            XCTFail("测试连接 is not fooled by the session cookie")
        } catch {
            XCTAssertEqual(error as? KomgaError, .unauthorized)
        }

        // Read lists and single books, as a Mihon backup may hold them.
        let book = try XCTUnwrap(chapters.last)
        let bookId = try XCTUnwrap(book.url.split(separator: "/").last.map(String.init))
        let created = try await Self.send(address: "\(address)/api/v1/readlists", account: account, method: "POST",
                                          body: #"{"name":"测试阅读列表 \#(UUID().uuidString.prefix(6))","summary":"","ordered":true,"bookIds":["\#(bookId)"]}"#)
        let listId = try XCTUnwrap((try JSONSerialization.jsonObject(with: created) as? [String: Any])?["id"] as? String)
        defer { Task { _ = try? await Self.send(address: "\(address)/api/v1/readlists/\(listId)", account: account, method: "DELETE") } }
        let list = SManga(url: "\(address)/api/v1/readlists/\(listId)", title: "list")
        let listDetails = try await engine.mangaDetails(manga: list)
        XCTAssertTrue(listDetails.title.hasPrefix("测试阅读列表"))
        let listChapters = try await engine.chapterList(manga: list)
        XCTAssertEqual(listChapters.map(\.chapterNumber), [1], "numbered by position")
        let single = try await engine.chapterList(manga: SManga(url: book.url, title: "book"))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.url, book.url)
    }

    static func send(address: String, account: KomgaAccount, method: String, body: String? = nil) async throws -> Data {
        var request = URLRequest(url: try XCTUnwrap(URL(string: address)))
        request.httpMethod = method
        for (field, value) in account.headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await URLSession(configuration: .ephemeral).data(for: request).0
    }
}
