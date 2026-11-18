import XCTest
import Compression
import ImageIO
@testable import MihonDomain
@testable import MihonData
@testable import MihonPresentation

/// The local source (upstream `source-local`): ZIP / CBZ reading, the folder layout, metadata, import, and a title
/// read through the store. Engine tests use their own folder; store tests use the (temporary) default one.
final class MihonLocalSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MihonLocal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: ZIP

    func testZipArchiveReadsStoredDeflatedAndChineseNames() throws {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let big = Data((0..<20_000).map { UInt8($0 % 7) })
        let file = root.appendingPathComponent("a.cbz")
        try ZipBuilder.build([
            .init(name: Data("001.png".utf8), data: Data([1, 2, 3])),
            .init(name: Data("sub/002.jpg".utf8), data: big, deflate: true),
            .init(name: try XCTUnwrap("第三页.png".data(using: gbk)), data: Data([4])),
            .init(name: Data("图片.png".utf8), data: Data([5]), utf8Flag: true),
        ]).write(to: file)

        let archive = try MihonZipArchive(url: file)
        XCTAssertEqual(archive.entries.map(\.name), ["001.png", "sub/002.jpg", "第三页.png", "图片.png"])
        XCTAssertEqual(try archive.data(for: archive.entries[0], limit: 1 << 20), Data([1, 2, 3]))
        XCTAssertEqual(try archive.data(for: archive.entries[1], limit: 1 << 20), big, "deflated")
        XCTAssertThrowsError(try archive.data(for: archive.entries[1], limit: 1_000), "past the limit")
        XCTAssertEqual(try archive.data(for: archive.entries[2], limit: 1 << 20), Data([4]))
    }

    func testZip64EndRecordAndOffsets() throws {
        let file = root.appendingPathComponent("64.zip")
        try ZipBuilder.build([
            .init(name: Data("1.png".utf8), data: Data([9, 9])),
            .init(name: Data("2.png".utf8), data: Data(repeating: 7, count: 5_000), deflate: true),
        ], zip64: true).write(to: file)
        let archive = try MihonZipArchive(url: file)
        XCTAssertEqual(archive.entries.map(\.name), ["1.png", "2.png"])
        XCTAssertEqual(try archive.data(for: archive.entries[1], limit: 1 << 20), Data(repeating: 7, count: 5_000))
    }

    func testNotAZipIsRefused() throws {
        let file = root.appendingPathComponent("fake.cbz")
        try Data("not a zip at all".utf8).write(to: file)
        XCTAssertThrowsError(try MihonZipArchive(url: file))
    }

    // MARK: Folder layout

    private func makeLibrary() throws {
        let fm = FileManager.default
        let alpha = root.appendingPathComponent("Alpha")
        try fm.createDirectory(at: alpha.appendingPathComponent("Chapter 2"), withIntermediateDirectories: true)
        for name in ["10.png", "2.png", "1.png", "notes.txt"] {
            try Data(name.utf8).write(to: alpha.appendingPathComponent("Chapter 2/\(name)"))
        }
        try Data("cover".utf8).write(to: alpha.appendingPathComponent("cover.jpg"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:ty="http://www.w3.org/2001/XMLSchema">
          <Series>Alpha Series</Series>
          <Writer>作者甲</Writer>
          <Penciller>画师乙, 画师丙</Penciller>
          <Colorist>画师丙</Colorist>
          <Genre>Action, Drama</Genre>
          <Tags>Drama, Tag1</Tags>
          <Summary>简介</Summary>
          <ty:PublishingStatusTachiyomi>Completed</ty:PublishingStatusTachiyomi>
        </ComicInfo>
        """.utf8).write(to: alpha.appendingPathComponent("ComicInfo.xml"))
        try ZipBuilder.build([
            .init(name: Data("p2.png".utf8), data: Data("p2".utf8)),
            .init(name: Data("p10.png".utf8), data: Data("p10".utf8), deflate: true),
            .init(name: Data("p1.png".utf8), data: Data("p1".utf8)),
            .init(name: Data("__MACOSX/._p1.png".utf8), data: Data([0])),
            .init(name: Data("ComicInfo.xml".utf8), data: Data("<ComicInfo/>".utf8)),
        ]).write(to: alpha.appendingPathComponent("Ch.1.cbz"))

        let beta = root.appendingPathComponent("Beta")
        try fm.createDirectory(at: beta, withIntermediateDirectories: true)
        try Data(#"{"title":"Beta 正式名","author":"作者","genre":["奇幻"],"status":"2"}"#.utf8)
            .write(to: beta.appendingPathComponent("details.json"))
        try ZipBuilder.build([.init(name: Data("a.png".utf8), data: Data("a".utf8))])
            .write(to: beta.appendingPathComponent("c1.zip"))

        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("loose.cbz"))
    }

    func testListsTitlesWithCoversAndSearches() async throws {
        try makeLibrary()
        let source = MihonLocalSource(root: root)
        let popular = try await source.popularManga(page: 1)
        XCTAssertEqual(popular.mangas.map(\.title), ["Alpha", "Beta"], "folders only, by name, no hidden ones")
        XCTAssertFalse(popular.hasNextPage)
        XCTAssertEqual(popular.mangas[0].thumbnailUrl.flatMap(MihonLocalSource.parse)?.path, "Alpha/cover.jpg")
        let betaCover = try XCTUnwrap(popular.mangas[1].thumbnailUrl.flatMap(MihonLocalSource.parse))
        XCTAssertEqual(betaCover.path, "Beta/c1.zip", "no cover file: the first page of the first chapter")
        XCTAssertEqual(betaCover.entry, "a.png")
        let search = try await source.searchManga(page: 1, query: "alp", filters: [])
        XCTAssertEqual(search.mangas.map(\.url), ["Alpha"])
        let latest = try await source.latestUpdates(page: 1)
        XCTAssertEqual(Set(latest.mangas.map(\.url)), ["Alpha", "Beta"], "both changed within the week")
    }

    func testDetailsFromComicInfoAndLegacyJson() async throws {
        try makeLibrary()
        let source = MihonLocalSource(root: root)
        let alpha = try await source.mangaDetails(manga: SManga(url: "Alpha", title: "Alpha"))
        XCTAssertEqual(alpha.title, "Alpha Series")
        XCTAssertEqual(alpha.author, "作者甲")
        XCTAssertEqual(alpha.artist, "画师乙, 画师丙")
        XCTAssertEqual(alpha.genre, ["Action", "Drama", "Tag1"])
        XCTAssertEqual(alpha.description, "简介")
        XCTAssertEqual(alpha.status, .completed)
        XCTAssertTrue(alpha.initialized)

        let beta = try await source.mangaDetails(manga: SManga(url: "Beta", title: "Beta"))
        XCTAssertEqual(beta.title, "Beta 正式名")
        XCTAssertEqual(beta.genre, ["奇幻"])
        XCTAssertEqual(beta.status, .completed, "status given as text")

        do {
            _ = try await source.mangaDetails(manga: SManga(url: "Gone", title: "Gone"))
            XCTFail("a missing folder is an error")
        } catch {}
    }

    func testChaptersAndPagesInUpstreamOrder() async throws {
        try makeLibrary()
        let source = MihonLocalSource(root: root)
        let chapters = try await source.chapterList(manga: SManga(url: "Alpha", title: "Alpha"))
        XCTAssertEqual(chapters.map(\.name), ["Chapter 2", "Ch.1"], "newest first; files lose their extension")
        XCTAssertEqual(chapters.map(\.chapterNumber), [2, 1])
        XCTAssertEqual(chapters.map(\.url), ["Alpha/Chapter 2", "Alpha/Ch.1.cbz"])

        let folderPages = try await source.pageList(chapter: chapters[0])
        XCTAssertEqual(folderPages.compactMap(\.imageUrl).map { MihonLocalSource.parse($0)?.path ?? "" },
                       ["Alpha/Chapter 2/1.png", "Alpha/Chapter 2/2.png", "Alpha/Chapter 2/10.png"], "natural order, images only")
        let archivePages = try await source.pageList(chapter: chapters[1])
        XCTAssertEqual(archivePages.compactMap(\.imageUrl).compactMap { MihonLocalSource.parse($0)?.entry },
                       ["p1.png", "p2.png", "p10.png"], "no resource forks or ComicInfo")
        XCTAssertTrue(archivePages.allSatisfy(\.hasRealImage))

        XCTAssertEqual(MihonLocalSource.data(forUrl: try XCTUnwrap(archivePages[2].imageUrl), root: root), Data("p10".utf8))
        XCTAssertEqual(MihonLocalSource.data(forUrl: try XCTUnwrap(folderPages[0].imageUrl), root: root), Data("1.png".utf8))
        XCTAssertNil(MihonLocalSource.data(forUrl: "mihon-local:/../outside.png", root: root), "never outside the folder")
        XCTAssertNil(MihonLocalSource.data(forUrl: MihonLocalSource.pageUrl(path: "Alpha/Ch.1.cbz", entry: "missing.png"), root: root))
    }

    /// Upstream sorts chapters by name: numbering restarts each season.
    func testChaptersInNameOrderAndMacArchiveLeftoversIgnored() async throws {
        let title = root.appendingPathComponent("Seasons")
        for chapter in ["Season 1 Episode 10", "Season 2 Episode 1", "__MACOSX"] {
            try FileManager.default.createDirectory(at: title.appendingPathComponent(chapter), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: title.appendingPathComponent("Season 1 Episode 10/01.jfif"))
        let source = MihonLocalSource(root: root)
        let chapters = try await source.chapterList(manga: SManga(url: "Seasons", title: "Seasons"))
        XCTAssertEqual(chapters.map(\.name), ["Season 2 Episode 1", "Season 1 Episode 10"], "no __MACOSX chapter")
        let pages = try await source.pageList(chapter: chapters[1])
        XCTAssertEqual(pages.count, 1, ".jfif is a JPEG")
        let titles = try await source.popularManga(page: 1).mangas.map(\.url)
        XCTAssertFalse(titles.contains("__MACOSX"))
    }

    func testSymlinkedTitleIsListed() async throws {
        let elsewhere = root.appendingPathComponent("elsewhere/Linked")
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("c1"), withIntermediateDirectories: true)
        try Data([1]).write(to: elsewhere.appendingPathComponent("c1/1.png"))
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
        let source = MihonLocalSource(root: library)
        let titles = try await source.popularManga(page: 1).mangas.map(\.url)
        XCTAssertEqual(titles, ["Linked"])
        let chapters = try await source.chapterList(manga: SManga(url: "Linked", title: "Linked")).map(\.name)
        XCTAssertEqual(chapters, ["c1"])
    }

    /// A file replaced under the same name gets new page URLs (the memory cache is keyed by URL).
    func testPageUrlsChangeWhenTheFileChanges() async throws {
        let chapter = root.appendingPathComponent("Versioned/c1")
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        let page = chapter.appendingPathComponent("1.png")
        try Data([1]).write(to: page)
        let source = MihonLocalSource(root: root)
        let before = try await source.pageList(chapter: SChapter(url: "Versioned/c1", name: "c1")).first?.imageUrl
        try Data([1, 2, 3]).write(to: page)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: page.path)
        let after = try await source.pageList(chapter: SChapter(url: "Versioned/c1", name: "c1")).first?.imageUrl
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.flatMap(MihonLocalSource.parse)?.path, "Versioned/c1/1.png", "the version is not part of the path")
        XCTAssertEqual(MihonLocalSource.data(forUrl: try XCTUnwrap(after), root: root), Data([1, 2, 3]))
    }

    /// Upstream `EpubReader`: the spine's pages in order, each page's `img` / SVG `image`; the package's metadata
    /// names the chapter (`fillMetadata`).
    func testEpubChapters() async throws {
        let title = root.appendingPathComponent("电子书")
        try FileManager.default.createDirectory(at: title, withIntermediateDirectories: true)
        let container = #"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata><dc:title>第3卷</dc:title><dc:creator>作者</dc:creator><dc:publisher>出版社</dc:publisher><dc:date>2020-05-01T00:00:00Z</dc:date></metadata>
          <manifest>
            <item id="p2" href="xhtml/p2.xhtml" media-type="application/xhtml+xml"/>
            <item id="p1" href="xhtml/p1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="p1"/><itemref idref="p2"/></spine>
        </package>
        """
        let page1 = #"<html xmlns="http://www.w3.org/1999/xhtml"><body><div><img src="../images/001.png" alt=""/></div></body></html>"#
        let page2 = #"<html><body><svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../images/002%20b.png"/></svg></body></html>"#
        try ZipBuilder.build([
            .init(name: Data("mimetype".utf8), data: Data("application/epub+zip".utf8)),
            .init(name: Data("META-INF/container.xml".utf8), data: Data(container.utf8), deflate: true),
            .init(name: Data("OEBPS/content.opf".utf8), data: Data(opf.utf8), deflate: true),
            .init(name: Data("OEBPS/xhtml/p1.xhtml".utf8), data: Data(page1.utf8)),
            .init(name: Data("OEBPS/xhtml/p2.xhtml".utf8), data: Data(page2.utf8)),
            .init(name: Data("OEBPS/images/001.png".utf8), data: Data("one".utf8)),
            .init(name: Data("OEBPS/images/002 b.png".utf8), data: Data("two".utf8)),
        ]).write(to: title.appendingPathComponent("vol3.epub"))

        let source = MihonLocalSource(root: root)
        let chapters = try await source.chapterList(manga: SManga(url: "电子书", title: "电子书"))
        let chapter = try XCTUnwrap(chapters.first)
        XCTAssertEqual(chapter.name, "第3卷", "dc:title")
        XCTAssertEqual(chapter.scanlator, "出版社", "the publisher, else the creator")
        XCTAssertEqual(chapter.dateUpload, ISO8601DateFormatter().date(from: "2020-05-01T00:00:00Z"))
        let pages = try await source.pageList(chapter: chapter)
        XCTAssertEqual(pages.compactMap(\.imageUrl).compactMap { MihonLocalSource.parse($0)?.entry },
                       ["OEBPS/images/001.png", "OEBPS/images/002 b.png"], "spine order, hrefs resolved")
        XCTAssertEqual(MihonLocalSource.data(forUrl: try XCTUnwrap(pages.last?.imageUrl), root: root), Data("two".utf8))
        XCTAssertEqual(MihonLocalSource.resolve("../a/./b.png#x", from: "OEBPS/text"), "OEBPS/a/b.png")
    }

    /// Upstream reads each chapter's own ComicInfo.xml: title, number, translator, date.
    func testChapterComicInfo() async throws {
        let title = root.appendingPathComponent("Info")
        try FileManager.default.createDirectory(at: title.appendingPathComponent("folder chapter"), withIntermediateDirectories: true)
        try Data("<ComicInfo><Title>番外篇</Title><Number>12.5</Number><Translator>汉化组</Translator><Year>2021</Year><Month>3</Month></ComicInfo>".utf8)
            .write(to: title.appendingPathComponent("folder chapter/ComicInfo.xml"))
        try ZipBuilder.build([
            .init(name: Data("1.png".utf8), data: Data([1])),
            .init(name: Data("comicinfo.xml".utf8), data: Data("<ComicInfo><Title>正篇</Title><Number>13</Number></ComicInfo>".utf8)),
        ]).write(to: title.appendingPathComponent("c13.cbz"))
        let chapters = try await MihonLocalSource(root: root).chapterList(manga: SManga(url: "Info", title: "Info"))
        XCTAssertEqual(chapters.map(\.name), ["番外篇", "正篇"], "renamed, then sorted by name")
        let extra = try XCTUnwrap(chapters.first { $0.name == "番外篇" })
        XCTAssertEqual(extra.chapterNumber, 12.5)
        XCTAssertEqual(extra.scanlator, "汉化组")
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: extra.dateUpload),
                       DateComponents(year: 2021, month: 3, day: 1))
        XCTAssertEqual(chapters.first { $0.name == "正篇" }?.chapterNumber, 13)
    }

    func testPageUrlsKeepAnyFileName() throws {
        let url = MihonLocalSource.pageUrl(path: "海贼王 #1/第 1 话?.cbz", entry: "a&b/c#d 1.png")
        XCTAssertNotNil(URL(string: url))
        let parsed = try XCTUnwrap(MihonLocalSource.parse(url))
        XCTAssertEqual(parsed.path, "海贼王 #1/第 1 话?.cbz")
        XCTAssertEqual(parsed.entry, "a&b/c#d 1.png")
    }

    // MARK: Import

    func testImportCopiesFoldersAndArchivesWithoutOverwriting() throws {
        let fm = FileManager.default
        let picked = root.appendingPathComponent("picked")
        let target = root.appendingPathComponent("local")
        try fm.createDirectory(at: picked.appendingPathComponent("Gamma"), withIntermediateDirectories: true)
        try ZipBuilder.build([.init(name: Data("1.png".utf8), data: Data([1]))]).write(to: picked.appendingPathComponent("Gamma/01.cbz"))
        try Data([1]).write(to: picked.appendingPathComponent("Gamma/cover.png"))
        try fm.createDirectory(at: picked.appendingPathComponent("Delta"), withIntermediateDirectories: true)
        try Data([2]).write(to: picked.appendingPathComponent("Delta/1.jpg"))
        let archive = picked.appendingPathComponent("Epsilon v02 (2020) [Digital].cbz")
        try ZipBuilder.build([.init(name: Data("1.png".utf8), data: Data([3]))]).write(to: archive)
        try Data("text".utf8).write(to: picked.appendingPathComponent("readme.txt"))
        let urls = ["Gamma", "Delta", "Epsilon v02 (2020) [Digital].cbz", "readme.txt"].map { picked.appendingPathComponent($0) }

        let result = MihonLocalStorage.importItems(urls, intoTitle: nil, root: target)
        XCTAssertEqual(result.titles, ["Gamma", "Delta", "Epsilon"])
        XCTAssertEqual(result.chapters, 3)
        XCTAssertEqual(result.failed, 1, "a text file is not a chapter")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Gamma/01.cbz").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Gamma/cover.png").path), "the title's cover comes along")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Delta/Delta/1.jpg").path), "a folder of images is one chapter")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Epsilon/Epsilon v02 (2020) [Digital].cbz").path))

        // The local folder itself, a title in it, or a folder around it would be copied into itself.
        let refused = MihonLocalStorage.importItems([target, target.appendingPathComponent("Gamma"), root], intoTitle: nil, root: target)
        XCTAssertEqual(refused.failed, 3)
        XCTAssertEqual(refused.chapters, 0)
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("local").path))

        // A chapter folder made on a Mac: its pages, not its __MACOSX leftovers, decide what it is.
        let macChapter = picked.appendingPathComponent("Zeta 01")
        try fm.createDirectory(at: macChapter.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try Data([4]).write(to: macChapter.appendingPathComponent("001.jpg"))
        let mac = MihonLocalStorage.importItems([macChapter], intoTitle: nil, root: target)
        XCTAssertEqual(mac.chapters, 1)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Zeta 01/Zeta 01/001.jpg").path))

        let again = MihonLocalStorage.importItems(urls, intoTitle: "Named", root: target)
        XCTAssertEqual(again.chapters, 1, "only the archive, into the title given")
        XCTAssertEqual(again.skipped, 2)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Named/Epsilon v02 (2020) [Digital].cbz").path))
    }

    func testSuggestedTitles() throws {
        func suggest(_ name: String, comicInfo: String? = nil) throws -> String {
            let file = root.appendingPathComponent(name)
            var items: [ZipBuilder.Item] = [.init(name: Data("1.png".utf8), data: Data([1]))]
            if let comicInfo { items.append(.init(name: Data("ComicInfo.xml".utf8), data: Data(comicInfo.utf8))) }
            try ZipBuilder.build(items).write(to: file)
            return MihonLocalStorage.suggestedTitle(for: [file])
        }
        XCTAssertEqual(try suggest("海贼王 第01卷.cbz"), "海贼王")
        XCTAssertEqual(try suggest("[Group] Blame! v01 (2016) [Digital].cbz"), "Blame!")
        XCTAssertEqual(try suggest("Gantz 2 v03.cbz"), "Gantz 2")
        XCTAssertEqual(try suggest("001.zip"), "001", "nothing left: the name as it is")
        XCTAssertEqual(try suggest("x.cbz", comicInfo: "<ComicInfo><Series>进击的巨人</Series></ComicInfo>"), "进击的巨人")
        XCTAssertEqual(MihonLocalStorage.sanitizedTitle(" ../a/b:c "), "／a／b：c")
    }

    // MARK: Through the store

    @MainActor
    func testLocalTitleReadsThroughTheStore() async throws {
        let name = "本地测试-\(UUID().uuidString.prefix(8))"
        let title = MihonLocalStorage.defaultRootDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: title.appendingPathComponent("第1话"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: title) }
        let png = Self.pngData()
        try png.write(to: title.appendingPathComponent("第1话/01.png"))
        try png.write(to: title.appendingPathComponent("第1话/02.png"))
        try ZipBuilder.build([.init(name: Data("1.png".utf8), data: png)]).write(to: title.appendingPathComponent("第2话.cbz"))

        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        XCTAssertTrue(store.isLiveSource(MihonLocalSource.sourceId))
        XCTAssertEqual(store.sourceName(for: MihonLocalSource.sourceId), "本地图源")
        let source = try XCTUnwrap(store.catalogueSource(for: MihonLocalSource.sourceId))
        XCTAssertTrue(source.isLive)
        XCTAssertEqual(source.getFilterList(), [], "no demo filters on a real source")
        let listed = try await source.getPopularManga(page: 1).mangas
        let smanga = try XCTUnwrap(listed.first { $0.url == name })
        let manga = store.upsertCatalogMangaToStore(smanga, sourceId: MihonLocalSource.sourceId)
        await store.refreshMangaFromSource(mangaId: manga.id)

        let chapters = try XCTUnwrap(store.chaptersByManga[manga.id])
        XCTAssertEqual(Set(chapters.map(\.name)), ["第1话", "第2话"])
        let first = try XCTUnwrap(chapters.first { $0.name == "第1话" })
        let refreshed = try XCTUnwrap(store.manga(id: manga.id))
        XCTAssertNotNil(refreshed.thumbnailUrl, "the first page is the cover")
        let pages = try await store.pageList(for: refreshed, chapter: first)
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(pages.allSatisfy(\.hasRealImage))
        let image = await MihonTwoTierImageCache.shared.image(url: try XCTUnwrap(pages[0].imageUrl), target: .page(maxPixelSize: 2560))
        XCTAssertEqual(image?.width, 4, "decoded from the file")
        XCTAssertEqual(store.downloadState(for: first, in: refreshed), .downloaded, "local chapters need no download")

        // A chapter imported into the title shows up right away.
        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("MihonPicked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: picked) }
        let extra = picked.appendingPathComponent("第3话.cbz")
        try ZipBuilder.build([.init(name: Data("1.png".utf8), data: png)]).write(to: extra)
        let result = await store.importLocalFiles([extra], intoTitle: name)
        XCTAssertEqual(result.chapters, 1)
        XCTAssertEqual(store.chaptersByManga[manga.id]?.count, 3)
    }

    /// Page actions (share / save / copy) use the page's own bytes, as JPEG.
    func testPageActionsUseTheOriginalAsJPEG() async throws {
        let name = "导出测试-\(UUID().uuidString.prefix(8))"
        let title = MihonLocalStorage.defaultRootDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: title, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: title) }
        let png = Self.pngData(width: 8, height: 12)
        try ZipBuilder.build([.init(name: Data("1.png".utf8), data: png)]).write(to: title.appendingPathComponent("c1.cbz"))
        let url = MihonLocalSource.pageUrl(path: "\(name)/c1.cbz", entry: "1.png")

        let original = await MihonTwoTierImageCache.shared.originalData(url: url)
        XCTAssertEqual(original, png, "the file's bytes, not the displayed bitmap")
        let exported = await MihonPageImageFile.jpegData(url: url)
        let jpeg = try XCTUnwrap(exported)
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8, 0xFF]), "converted to JPEG")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 8)
        let missing = await MihonPageImageFile.jpegData(url: MihonLocalSource.pageUrl(path: "\(name)/gone.cbz", entry: "1.png"))
        XCTAssertNil(missing)
    }

    /// Upstream's 设为封面: a page becomes the title's cover everywhere, until it is dropped again.
    @MainActor
    func testCustomCoverReplacesTheSourcesUntilRemoved() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first { $0.favorite })
        defer { store.removeCustomCover(mangaId: manga.id) }
        XCTAssertEqual(store.coverUrl(for: manga), manga.thumbnailUrl)

        try store.setCustomCover(mangaId: manga.id, data: Self.pngData(width: 6, height: 9))
        let custom = try XCTUnwrap(store.coverUrl(for: manga))
        XCTAssertTrue(MihonCustomCovers.isCustomCoverUrl(custom))
        let image = await MihonTwoTierImageCache.shared.image(url: custom, target: .cover)
        XCTAssertEqual(image?.width, 6, "read from the covers folder")
        XCTAssertNotNil(MangaCoverView.resolveCoverUrl(custom))
        XCTAssertEqual(MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false).coverUrl(for: manga), custom,
                       "found again at the next launch")

        // Refreshing the title from its source does not undo it.
        store.mangas[try XCTUnwrap(store.mangas.firstIndex { $0.id == manga.id })].thumbnailUrl = "https://example.com/new.jpg"
        XCTAssertEqual(store.coverUrl(for: try XCTUnwrap(store.manga(id: manga.id))), custom)

        let escape = MihonCustomCovers.directory.absoluteString + "../Covers-elsewhere/1.jpg"
        XCTAssertNil(MihonCustomCovers.data(forUrl: escape), "nothing outside the covers folder")

        store.removeCustomCover(mangaId: manga.id)
        XCTAssertEqual(store.coverUrl(for: try XCTUnwrap(store.manga(id: manga.id))), "https://example.com/new.jpg")

        // Upstream drops a custom cover with the title's place in the library.
        try store.setCustomCover(mangaId: manga.id, data: Self.pngData())
        store.removeFromLibrary(mangaId: manga.id)
        XCTAssertNil(store.customCoverVersions[manga.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: MihonCustomCovers.file(manga.id).path))
    }

    @MainActor
    func testTesterSeedHasNoLocalTitles() {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        XCTAssertFalse(store.mangas.contains { $0.source == MihonLocalSource.sourceId }, "the local source starts empty")
    }

    // MARK: Helpers

    static func pngData(width: Int = 4, height: Int = 6) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

/// Writes small ZIP files (no CRCs: the reader does not check them), optionally with ZIP64 end records and offsets.
enum ZipBuilder {
    struct Item {
        var name: Data
        var data: Data
        var deflate = false
        var utf8Flag = false
    }

    static func build(_ items: [Item], zip64: Bool = false) -> Data {
        var archive = Data()
        var central = Data()
        for item in items {
            let offset = UInt64(archive.count)
            let payload = item.deflate ? deflate(item.data) : item.data
            let method: UInt16 = item.deflate ? 8 : 0
            let flags: UInt16 = item.utf8Flag ? 0x0800 : 0
            archive.append(le(UInt32(0x0403_4B50)) + le(UInt16(20)) + le(flags) + le(method) + le(UInt16(0)) + le(UInt16(0)))
            archive.append(le(UInt32(0)) + le(UInt32(payload.count)) + le(UInt32(item.data.count)))
            archive.append(le(UInt16(item.name.count)) + le(UInt16(0)))
            archive.append(item.name)
            archive.append(payload)

            let extra = zip64 ? le(UInt16(0x0001)) + le(UInt16(8)) + le(offset) : Data()
            central.append(le(UInt32(0x0201_4B50)) + le(UInt16(45)) + le(UInt16(20)) + le(flags) + le(method))
            central.append(le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)))
            central.append(le(UInt32(payload.count)) + le(UInt32(item.data.count)))
            central.append(le(UInt16(item.name.count)) + le(UInt16(extra.count)) + le(UInt16(0)))
            central.append(le(UInt16(0)) + le(UInt16(0)) + le(UInt32(0)))
            central.append(le(zip64 ? UInt32(0xFFFF_FFFF) : UInt32(offset)))
            central.append(item.name)
            central.append(extra)
        }
        let directoryOffset = UInt64(archive.count)
        archive.append(central)
        if zip64 {
            let recordOffset = UInt64(archive.count)
            archive.append(le(UInt32(0x0606_4B50)) + le(UInt64(44)) + le(UInt16(45)) + le(UInt16(45)) + le(UInt32(0)) + le(UInt32(0)))
            archive.append(le(UInt64(items.count)) + le(UInt64(items.count)) + le(UInt64(central.count)) + le(directoryOffset))
            archive.append(le(UInt32(0x0706_4B50)) + le(UInt32(0)) + le(recordOffset) + le(UInt32(1)))
        }
        let count = zip64 ? UInt16(0xFFFF) : UInt16(items.count)
        archive.append(le(UInt32(0x0605_4B50)) + le(UInt16(0)) + le(UInt16(0)) + le(count) + le(count))
        archive.append(le(UInt32(central.count)) + le(zip64 ? UInt32(0xFFFF_FFFF) : UInt32(directoryOffset)) + le(UInt16(0)))
        return archive
    }

    static func deflate(_ data: Data) -> Data {
        var output = Data(count: data.count + 1024)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        output.count = written
        return output
    }

    private static func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
