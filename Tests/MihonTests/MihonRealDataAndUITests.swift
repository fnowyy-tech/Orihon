import XCTest
import SwiftUI
import AppKit
import Compression
@testable import MihonDomain
@testable import MihonAPKEngine
@testable import MihonData
@testable import MihonPresentation

/// Covers the real-data pipelines (Keiyoushi `index.pb`, MangaDex API, real APK parsing) and renders
/// offscreen UI snapshots. Network-dependent tests skip themselves when the network is unavailable.
final class MihonRealDataAndUITests: XCTestCase {

    // MARK: - index.pb (gzip + protobuf) decoding — offline

    func testKeiyoushiIndexV2ProtobufDecoding() throws {
        var source1 = ProtoWriter()
        source1.varint(1, UInt64(bitPattern: 5_148_895_169_070_562_838))
        source1.string(2, "MangaDex")
        source1.string(3, "zh-Hans")
        source1.string(4, "https://mangadex.org")
        var source2 = ProtoWriter()
        source2.varint(1, UInt64(bitPattern: -42))
        source2.string(2, "MangaDex")
        source2.string(3, "en")
        source2.string(4, "https://mangadex.org")
        var resources = ProtoWriter()
        resources.string(1, "https://github.com/keiyoushi/extensions/releases/download/x/tachiyomi-all.mangadex-v1.6.0.apk")
        resources.string(2, "https://cdn.jsdelivr.net/gh/keiyoushi/extensions-source@main/src/all/mangadex/res/mipmap-xhdpi/ic_launcher.png")
        var ext = ProtoWriter()
        ext.string(1, "MangaDex")
        ext.string(2, "eu.kanade.tachiyomi.extension.all.mangadex")
        ext.message(3, resources)
        ext.string(4, "1.6")
        ext.varint(5, 106_000)
        ext.string(6, "1.6.0")
        ext.varint(7, 3)
        ext.message(8, source1)
        ext.message(8, source2)
        var list = ProtoWriter()
        list.message(1, ext)
        var store = ProtoWriter()
        store.string(1, "Keiyoushi")
        store.string(2, "KEI")
        store.string(3, "9add655a")
        store.message(101, list)

        let gzipped = try Self.gzip(store.data)
        XCTAssertTrue(MihonGzip.isGzip(gzipped))

        let decoded = try KeiyoushiExtensionStoreDecoder.decode(gzipped)
        XCTAssertEqual(decoded.name, "Keiyoushi")
        XCTAssertEqual(decoded.extensions.count, 1)
        let first = try XCTUnwrap(decoded.extensions.first)
        XCTAssertEqual(first.versionCode, 106_000)
        XCTAssertTrue(first.isNsfw)
        XCTAssertEqual(first.sources.map(\.id), [5_148_895_169_070_562_838, -42])

        let model = first.toExtensionModel(repoUrl: "https://raw.githubusercontent.com/keiyoushi/extensions/repo", storeName: decoded.name)
        XCTAssertEqual(model.lang, "all", "multi-language extensions collapse to `all` like upstream")
        XCTAssertEqual(model.apkName, "tachiyomi-all.mangadex-v1.6.0.apk")
        XCTAssertEqual(model.libVersion, 1.6, accuracy: 0.001)
        XCTAssertTrue(model.iconUrl?.hasPrefix("https://cdn.jsdelivr.net") ?? false)
    }

    // MARK: - Memoized library snapshot invalidation — offline

    @MainActor
    func testLibraryMemoizationInvalidatesOnChapterChange() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let before = try XCTUnwrap(store.libraryItems(forCategory: -1, searchQuery: "").first { $0.id == 101 })
        let revision = store.libraryRevision
        let unreadChapter = try XCTUnwrap(store.chaptersByManga[101]?.first { !$0.read })

        store.toggleChapterRead(mangaId: 101, chapterId: unreadChapter.id)

        XCTAssertGreaterThan(store.libraryRevision, revision)
        let after = try XCTUnwrap(store.libraryItems(forCategory: -1, searchQuery: "").first { $0.id == 101 })
        XCTAssertEqual(after.unreadCount, before.unreadCount - 1)
        XCTAssertEqual(store.libraryItems(forCategory: 2, searchQuery: "迷宫").map(\.id), [102])
    }

    /// `body` may call `libraryItems` many times per frame; only the first call after a mutation may do real work.
    @MainActor
    func testLibrarySnapshotScalesAndIsMemoized() {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let now = Date()
        var mangas = store.mangas
        var chapters = store.chaptersByManga
        var categories = store.mangaCategories
        var nextChapterId: Int64 = 1_000_000
        for i in 0..<500 {
            let id = Int64(10_000 + i)
            mangas.append(Manga(id: id, source: 1001, url: "/bulk/\(i)", title: "Bulk \(i)", favorite: true, dateAdded: now))
            categories[id] = [1]
            chapters[id] = (0..<200).map { n in
                nextChapterId += 1
                return Chapter(id: nextChapterId, mangaId: id, url: "/bulk/\(i)/\(n)", name: "Ch.\(n)", read: n < 100, chapterNumber: Double(n), sourceOrder: 200 - n)
            }
        }
        store.mangas = mangas
        store.chaptersByManga = chapters
        store.mangaCategories = categories

        let cold = Date()
        let items = store.libraryItems(forCategory: 1, searchQuery: "")
        let coldMs = Date().timeIntervalSince(cold) * 1000
        XCTAssertGreaterThanOrEqual(items.count, 500)

        let warm = Date()
        for _ in 0..<200 {
            _ = store.libraryItems(forCategory: 1, searchQuery: "")
            _ = store.visibleLibraryCategories()
        }
        let warmMsPerCall = Date().timeIntervalSince(warm) * 1000 / 200
        XCTAssertLessThan(coldMs, 500, "100k chapters should snapshot well under a frame budget × 30")
        XCTAssertLessThan(warmMsPerCall, 1, "memoized reads must be O(1) for 120fps redraws")
        print("library snapshot: cold \(String(format: "%.1f", coldMs)) ms, warm \(String(format: "%.4f", warmMsPerCall)) ms/call")
    }

    @MainActor
    func testLiveSourceRoutingForSeededMangaDexEntries() {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        XCTAssertTrue(store.isLiveSource(MihonSeedData.MangaDexSourceId.simplifiedChinese))
        XCTAssertFalse(store.isLiveSource(1001))
        XCTAssertEqual(store.catalogueSource(for: MihonSeedData.MangaDexSourceId.simplifiedChinese)?.isLive, true)
        XCTAssertTrue(store.sourceName(for: MihonSeedData.MangaDexSourceId.simplifiedChinese).hasPrefix("MangaDex"))
    }

    // MARK: - Live network

    func testLiveKeiyoushiIndexV2Catalogue() async throws {
        let extensions: [ExtensionModel]
        do {
            extensions = try await MihonNetworkClient.shared.fetchExtensionRepoIndex(repoBaseUrl: "https://raw.githubusercontent.com/keiyoushi/extensions/repo")
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        XCTAssertGreaterThan(extensions.count, 1000, "index.pb should expose the full catalogue, not the 2 legacy stubs")
        let mangaDex = try XCTUnwrap(extensions.first { $0.pkgName == "eu.kanade.tachiyomi.extension.all.mangadex" })
        XCTAssertTrue(mangaDex.sources.contains { $0.id == MihonSeedData.MangaDexSourceId.simplifiedChinese })
        XCTAssertTrue(mangaDex.apkUrl?.hasSuffix(".apk") ?? false)
    }

    func testLiveMangaDexDetailsChaptersAndPageImage() async throws {
        let engine = MangaDexLiveEngine(sourceLang: "zh-Hans")
        let manga = SManga(url: "/manga/34f45c13-2b78-4900-8af2-d0bb551101f4", title: "")
        let details: SManga
        do {
            details = try await engine.mangaDetails(manga: manga)
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        XCTAssertFalse(details.title.isEmpty)
        XCTAssertTrue(details.thumbnailUrl?.hasPrefix("https://uploads.mangadex.org/covers/") ?? false)
        // MangaDex "completed" is the original's status: upstream reads it as publishing finished.
        XCTAssertEqual(details.status, .publishingFinished)
        XCTAssertEqual(details.updateStrategy, .alwaysUpdate)

        let chapters = try await engine.chapterList(manga: details)
        XCTAssertFalse(chapters.isEmpty, "Dorohedoro has hosted zh chapters on MangaDex")
        let pages = try await engine.pageList(chapter: chapters[chapters.count - 1])
        XCTAssertFalse(pages.isEmpty)
        XCTAssertTrue(pages.allSatisfy(\.hasRealImage))

        let image = await MihonTwoTierImageCache.shared.image(url: pages[0].imageUrl!, target: .page(maxPixelSize: 2048))
        let decoded = try XCTUnwrap(image, "first page should download and decode off-main")
        XCTAssertGreaterThan(decoded.width, 200)
        XCTAssertNotNil(MihonTwoTierImageCache.shared.cachedImage(url: pages[0].imageUrl!, target: .page(maxPixelSize: 2048)))

        let popular = try await engine.popularManga(page: 1)
        XCTAssertFalse(popular.mangas.isEmpty)
        XCTAssertTrue(popular.hasNextPage)
    }

    func testLiveRealExtensionApkParsing() async throws {
        let apkUrl = "https://github.com/keiyoushi/extensions/releases/download/8ef06cd-0/tachiyomi-all.mangadex-v1.6.0.apk"
        let data: Data
        do {
            data = try await MihonNetworkClient.shared.fetchAsset(url: URL(string: apkUrl)!)
        } catch {
            throw XCTSkip("Network unavailable: \(error.localizedDescription)")
        }
        let inspection = try APKBinaryDexInspector().inspectAndroidPackage(apkData: data, artifactPath: apkUrl)
        XCTAssertEqual(inspection.manifest.packageName, "eu.kanade.tachiyomi.extension.all.mangadex")
        XCTAssertFalse(inspection.dexMetrics.isEmpty)
        XCTAssertNotNil(inspection.manifest.tachiyomiExtensionClass)
    }

    // MARK: - Offscreen UI snapshots (set MIHON_SNAPSHOT_DIR to enable)

    @MainActor
    func testRenderVisualSnapshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MIHON_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set MIHON_SNAPSHOT_DIR to render UI snapshots")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        await store.bootstrapInstalledAPKSources()
        await store.syncExtensionsFromKeiyoushiRepo()
        for id: Int64 in [107, 108, 109] {
            await store.refreshMangaFromSource(mangaId: id)
        }
        for manga in store.mangas {
            if let url = MangaCoverView.resolveCoverUrl(manga.thumbnailUrl) {
                _ = await MihonTwoTierImageCache.shared.image(url: url, target: .cover)
            }
        }
        for ext in store.extensions.prefix(60) {
            if let url = ext.iconUrl { _ = await MihonTwoTierImageCache.shared.image(url: url, target: .icon) }
        }

        func themed<V: View>(_ view: V, dark: Bool = true) -> some View {
            view
                .environment(store)
                .mihonTheme(store.themePalette, pureBlack: false)
                .environment(\.colorScheme, dark ? .dark : .light)
        }

        store.duoPostureMode = .foldedSingle
        try await snapshot(themed(MihonRootView(store: store)), size: CGSize(width: 393, height: 852), path: "\(dir)/01_library_folded.png")
        try await snapshot(themed(MihonRootView(store: store), dark: false), size: CGSize(width: 393, height: 852), path: "\(dir)/02_library_folded_light.png", dark: false)

        store.libraryDisplayMode = .comfortableGrid
        store.showLanguageBadge = true
        store.showMangaCountInCategory = true
        store.duoPostureMode = .unfoldedBook
        try await snapshot(themed(MihonRootView(store: store)), size: CGSize(width: 880, height: 852), path: "\(dir)/03_duo_unfolded.png")

        try await snapshot(themed(NavigationStack { MangaDetailScreen(mangaId: 107) }), size: CGSize(width: 393, height: 852), path: "\(dir)/04_detail_live.png", settle: 2.5)
        try await snapshot(themed(NavigationStack { BrowseScreen() }), size: CGSize(width: 393, height: 852), path: "\(dir)/05_browse_sources.png")
        try await snapshot(themed(NavigationStack { BrowseScreen(initialTab: 1) }), size: CGSize(width: 393, height: 852), path: "\(dir)/05b_browse_extensions.png", settle: 2.5)
        try await snapshot(themed(NavigationStack { UpdatesScreen() }), size: CGSize(width: 393, height: 852), path: "\(dir)/08_updates.png")
        try await snapshot(themed(NavigationStack { HistoryScreen() }), size: CGSize(width: 393, height: 852), path: "\(dir)/09_history.png")
        try await snapshot(themed(NavigationStack { MoreScreen() }), size: CGSize(width: 393, height: 852), path: "\(dir)/10_more.png")
        try await snapshot(themed(LibrarySettingsSheet()), size: CGSize(width: 393, height: 560), path: "\(dir)/11_library_settings_sheet.png")
        store.libraryDisplayMode = .list
        store.duoPostureMode = .foldedSingle
        try await snapshot(themed(MihonRootView(store: store)), size: CGSize(width: 393, height: 852), path: "\(dir)/12_library_list.png")

        if let manga = store.manga(id: 107), let chapter = store.readingOrderChapters(mangaId: 107).first {
            let pages = try await store.pageList(for: manga, chapter: chapter)
            for page in pages.prefix(4) {
                _ = await MihonTwoTierImageCache.shared.image(url: page.imageUrl!, target: .page(maxPixelSize: 2556))
                _ = await MihonTwoTierImageCache.shared.image(url: page.imageUrl!, target: .page(maxPixelSize: 1704))
            }
            store.duoDualPageBehavior = .singlePageOnly
            try await snapshot(themed(MangaReaderScreen(manga: manga, initialChapter: chapter, onClose: {})), size: CGSize(width: 393, height: 852), path: "\(dir)/06_reader_single.png", settle: 3)
            try await snapshot(themed(MangaReaderScreen(manga: manga, initialChapter: chapter, showMenuInitially: true, onClose: {})), size: CGSize(width: 393, height: 852), path: "\(dir)/06b_reader_menu.png", settle: 3)
            store.duoDualPageBehavior = .alwaysDualPage
            store.shiftDoublePageCover = false
            try await snapshot(themed(MangaReaderScreen(manga: manga, initialChapter: chapter, onClose: {})), size: CGSize(width: 880, height: 852), path: "\(dir)/07_reader_duo_spread.png", settle: 3)
        }
    }

    @MainActor
    private func snapshot<V: View>(_ view: V, size: CGSize, path: String, dark: Bool = true, settle: TimeInterval = 1.5) async throws {
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hostingView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // Let `.task` / `onAppear` work (page lists, image decode) settle before capturing.
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        hostingView.layoutSubtreeIfNeeded()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("bitmap rep")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Helpers

    /// gzip container around a raw DEFLATE stream (CRC is not validated by the decoder under test).
    static func gzip(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let written = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { throw NSError(domain: "gzip", code: 1) }
        var result = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        result.append(contentsOf: output.prefix(written))
        result.append(contentsOf: [0, 0, 0, 0])
        let size = UInt32(input.count)
        result.append(contentsOf: [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8(size >> 24)])
        return result
    }
}

/// Minimal protobuf writer used to build `index.pb` fixtures.
struct ProtoWriter {
    private(set) var data = Data()

    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        rawVarint(UInt64(field << 3))
        rawVarint(value)
    }

    mutating func bytes(_ field: Int, _ payload: Data) {
        rawVarint(UInt64(field << 3 | 2))
        rawVarint(UInt64(payload.count))
        data.append(payload)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ writer: ProtoWriter) {
        bytes(field, writer.data)
    }

    mutating func float(_ field: Int, _ value: Float) {
        rawVarint(UInt64(field << 3 | 5))
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
}
