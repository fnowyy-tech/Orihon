import XCTest
import zlib
@testable import MihonDomain
@testable import MihonData

/// Restoring a backup made by Mihon / Tachiyomi on Android (`.tachibk`: gzip + kotlinx protobuf of `Backup`).
final class MihonTachiyomiBackupTests: XCTestCase {
    static let mangaDex = MihonSeedData.MangaDexSourceId.simplifiedChinese
    static let missingSource: Int64 = 1_234_567_890_123
    static let mangaUrl = "/manga/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// A library of three: a MangaDex title in a category with progress, one from a source this build lacks,
    /// and one browsed but not in the library.
    static func backupData() throws -> Data {
        var following = ProtoWriter()
        following.string(1, "追更")
        following.varint(2, 0)
        var finished = ProtoWriter()
        finished.string(1, "完结")
        finished.varint(2, 1)

        var read = ProtoWriter()
        read.string(1, "/chapter/read-1")
        read.string(2, "第1话")
        read.string(3, "汉化组")
        read.varint(4, 1)
        read.varint(7, 1_700_000_000_000)
        read.varint(8, 1_690_000_000_000)
        read.float(9, 1)
        read.varint(10, 1)
        var reading = ProtoWriter()
        reading.string(1, "/chapter/reading-2")
        reading.string(2, "第2话")
        reading.varint(5, 1)
        reading.varint(6, 7)
        reading.float(9, 2)
        var history = ProtoWriter()
        history.string(1, "/chapter/read-1")
        history.varint(2, 1_750_000_000_000)
        history.varint(3, 600_000)

        var dex = ProtoWriter()
        dex.varint(1, UInt64(bitPattern: Self.mangaDex))
        dex.string(2, Self.mangaUrl)
        dex.string(3, "测试作品")
        dex.string(5, "作者")
        dex.string(7, "冒险")
        dex.string(7, "奇幻")
        dex.varint(8, 1)
        dex.varint(13, 1_600_000_000_000)
        dex.message(16, read)
        dex.message(16, reading)
        dex.varint(17, 0)
        dex.varint(100, 1)
        dex.varint(101, 0x100 | 0x1 | 0x2 | 0x40)
        dex.varint(103, 2)
        dex.message(104, history)

        var missing = ProtoWriter()
        missing.varint(1, UInt64(Self.missingSource))
        missing.string(2, "/comic/123")
        missing.string(3, "没有图源的作品")
        missing.varint(17, 1)
        missing.varint(100, 1)

        var browsed = ProtoWriter()
        browsed.varint(1, UInt64(bitPattern: Self.mangaDex))
        browsed.string(2, "/manga/ffffffff-1111-4222-8333-444444444444")
        browsed.string(3, "看过但没收藏")
        browsed.varint(100, 0)

        var sourceName = ProtoWriter()
        sourceName.string(1, "拷贝漫画")
        sourceName.varint(2, UInt64(Self.missingSource))

        var backup = ProtoWriter()
        backup.message(1, dex)
        backup.message(1, missing)
        backup.message(1, browsed)
        backup.message(2, following)
        backup.message(2, finished)
        backup.message(101, sourceName)
        return try MihonRealDataAndUITests.gzip(backup.data)
    }

    func testDecodesUpstreamBackup() throws {
        let result = try TachiyomiBackupDecoder.decode(Self.backupData())
        let payload = result.payload
        XCTAssertEqual(payload.backupManga.map(\.title), ["测试作品", "没有图源的作品", "看过但没收藏"])
        XCTAssertEqual(payload.backupManga.map(\.favorite), [true, true, false])
        XCTAssertEqual(payload.backupCategories.map(\.name), ["追更", "完结"])
        XCTAssertEqual(result.sourceNames, [Self.missingSource: "拷贝漫画"])

        let dex = payload.backupManga[0]
        XCTAssertEqual(dex.source, Self.mangaDex)
        XCTAssertEqual(dex.genre, ["冒险", "奇幻"])
        XCTAssertEqual(dex.status, .ongoing)
        XCTAssertEqual(dex.dateAdded, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(dex.readingModeOverride, .rightToLeft)
        XCTAssertEqual(dex.chapterSortMode, .chapterNumber)
        XCTAssertTrue(dex.chapterSortAscending)
        XCTAssertEqual(dex.filterUnread, .include)
        XCTAssertEqual(dex.filterBookmarked, .exclude)
        XCTAssertEqual(payload.mangaCategoriesMap[dex.id].flatMap { ids in ids.compactMap { id in payload.backupCategories.first { $0.id == id }?.name } }, ["追更"])

        let chapters = payload.backupChapters.filter { $0.mangaId == dex.id }
        XCTAssertEqual(chapters.map(\.name), ["第1话", "第2话"])
        XCTAssertEqual(chapters.map(\.read), [true, false])
        XCTAssertEqual(chapters.map(\.bookmark), [false, true])
        XCTAssertEqual(chapters.map(\.lastPageRead), [0, 7])
        XCTAssertEqual(chapters.map(\.chapterNumber), [1, 2])
        XCTAssertEqual(chapters[0].scanlator, "汉化组")
        XCTAssertEqual(chapters[0].dateUpload, Date(timeIntervalSince1970: 1_690_000_000))
        XCTAssertEqual(chapters[1].dateUpload, SChapter.undatedUpload, "no date in the backup")

        XCTAssertEqual(payload.backupHistory.count, 1)
        XCTAssertEqual(payload.backupHistory.first?.chapterId, chapters[0].id)
        XCTAssertEqual(payload.backupHistory.first?.readAt, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(payload.backupHistory.first?.readDurationSeconds, 600)
    }

    func testRejectsWhatIsNotABackup() throws {
        XCTAssertThrowsError(try TachiyomiBackupDecoder.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try TachiyomiBackupDecoder.decode(MihonRealDataAndUITests.gzip(Data([0xFF, 0xFF, 0xFF]))))
        // A length near 2⁶⁴ used to trap converting to Int; zero bytes are field 0, which does not exist.
        let hugeLength = Data([0x0A, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])
        XCTAssertThrowsError(try TachiyomiBackupDecoder.decode(MihonRealDataAndUITests.gzip(hugeLength)))
        XCTAssertThrowsError(try TachiyomiBackupDecoder.decode(MihonRealDataAndUITests.gzip(Data(count: 100_000))))
        // A damaged title inside an otherwise fine backup is the backup's error, not the extension index's.
        var backup = ProtoWriter()
        backup.bytes(1, Data([0x0A, 0x7F]))
        XCTAssertThrowsError(try TachiyomiBackupDecoder.decode(MihonRealDataAndUITests.gzip(backup.data))) { error in
            XCTAssertEqual(error.localizedDescription, TachiyomiBackupDecoder.Failure.notABackup.localizedDescription)
        }
    }

    /// Upstream `mergeManga`: a title in the library stays there, whatever the backup says or when it says it.
    @MainActor
    func testRestoreNeverTakesTitlesOutOfTheLibrary() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let kept = try XCTUnwrap(store.mangas.first { $0.favorite })
        var entry = ProtoWriter()
        entry.varint(1, UInt64(bitPattern: kept.source))
        entry.string(2, kept.url)
        entry.string(3, kept.title)
        entry.varint(100, 0)
        entry.varint(107, UInt64(Date().addingTimeInterval(86_400).timeIntervalSince1970))
        var backup = ProtoWriter()
        backup.message(1, entry)
        try store.restoreFromBackup(MihonRealDataAndUITests.gzip(backup.data))
        XCTAssertEqual(store.manga(id: kept.id)?.favorite, true, "read but not in the library on Android, newer date and all")
    }

    @MainActor
    func testRestoresIntoTheLibrary() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let data = try Self.backupData()
        XCTAssertEqual(try store.libraryTitleCount(inBackup: data), 2)
        let before = store.mangas.filter(\.favorite).count

        try store.restoreFromBackup(data)

        XCTAssertEqual(store.mangas.filter(\.favorite).count, before + 2)
        let dex = try XCTUnwrap(store.mangas.first { $0.source == Self.mangaDex && $0.url == Self.mangaUrl })
        XCTAssertTrue(dex.favorite)
        XCTAssertTrue(store.isLiveSource(dex.source), "a MangaDex title from Android reads here")
        XCTAssertEqual(dex.readingModeOverride, .rightToLeft)
        let category = try XCTUnwrap(store.categories.first { $0.name == "追更" })
        XCTAssertEqual(store.mangaCategories[dex.id], [category.id])
        let chapters = try XCTUnwrap(store.chaptersByManga[dex.id])
        XCTAssertEqual(Set(chapters.filter(\.read).map(\.url)), ["/chapter/read-1"])
        let readId = try XCTUnwrap(chapters.first { $0.url == "/chapter/read-1" }?.id)
        XCTAssertTrue(store.historyEntries.contains { $0.chapterId == readId && $0.mangaId == dex.id })

        let missing = try XCTUnwrap(store.mangas.first { $0.source == Self.missingSource })
        XCTAssertFalse(store.isLiveSource(missing.source))
        XCTAssertEqual(store.sourceName(for: missing.source), "拷贝漫画", "upstream's stub source keeps the backup's name")
        XCTAssertNil(store.mangas.first { $0.title == "看过但没收藏" && $0.favorite })

        // Restoring again adds nothing: titles match by source and URL, chapters by URL.
        let titles = store.mangas.count
        try store.restoreFromBackup(data)
        XCTAssertEqual(store.mangas.count, titles)
        XCTAssertEqual(store.chaptersByManga[dex.id]?.count, 2)
    }

    // MARK: Export for Android (`TachiyomiBackupEncoder`)

    /// What Mihon's restore reads back is what the store had: the library, a title outside it that was read, with
    /// chapters, categories, history, notes and the reading settings.
    @MainActor
    func testExportRoundTrips() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        try store.restoreFromBackup(Self.backupData())
        let dex = try XCTUnwrap(store.mangas.first { $0.source == Self.mangaDex && $0.url == Self.mangaUrl })
        let dexIndex = try XCTUnwrap(store.mangas.firstIndex { $0.id == dex.id })
        store.mangas[dexIndex].notes = "看到第二话"
        store.mangas[dexIndex].nextUpdate = Date(timeIntervalSince1970: 1_900_000_000)
        let readOutside = try XCTUnwrap(store.mangas.first { $0.title == "看过但没收藏" && !$0.favorite })
        store.chaptersByManga[readOutside.id] = [Chapter(id: 999_001, mangaId: readOutside.id, url: "/chapter/outside-1", name: "第1话", lastPageRead: 3)]

        let data = try await store.createTachiyomiBackupData()
        // For checking the file with upstream's own decoder (kotlinx, Mihon's `Backup` models).
        if let path = ProcessInfo.processInfo.environment["MIHON_TACHIBK_OUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        let result = try TachiyomiBackupDecoder.decode(data)
        let payload = result.payload
        let library = store.mangas.filter(\.favorite)
        XCTAssertEqual(Set(payload.backupManga.filter(\.favorite).map { "\($0.source)|\($0.url)" }), Set(library.map { "\($0.source)|\($0.url)" }))
        XCTAssertTrue(payload.backupManga.contains { $0.url == readOutside.url && !$0.favorite }, "read outside the library: upstream's readEntries")

        let exported = try XCTUnwrap(payload.backupManga.first { $0.source == Self.mangaDex && $0.url == Self.mangaUrl })
        XCTAssertEqual(exported.title, "测试作品")
        XCTAssertEqual(exported.author, "作者")
        XCTAssertEqual(exported.genre, ["冒险", "奇幻"])
        XCTAssertEqual(exported.status, .ongoing)
        XCTAssertEqual(exported.notes, "看到第二话")
        XCTAssertEqual(exported.nextUpdate, Date(timeIntervalSince1970: 1_900_000_000), "upstream's nextUpdate (113)")
        XCTAssertEqual(exported.dateAdded, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(exported.readingModeOverride, .rightToLeft)
        XCTAssertEqual(exported.chapterSortMode, .chapterNumber)
        XCTAssertTrue(exported.chapterSortAscending)
        XCTAssertEqual(exported.filterUnread, .include)
        XCTAssertEqual(exported.filterBookmarked, .exclude)
        XCTAssertEqual(payload.mangaCategoriesMap[exported.id]?.compactMap { id in payload.backupCategories.first { $0.id == id }?.name }, ["追更"])

        let chapters = payload.backupChapters.filter { $0.mangaId == exported.id }.sorted { $0.url < $1.url }
        XCTAssertEqual(chapters.map(\.url), ["/chapter/read-1", "/chapter/reading-2"])
        XCTAssertEqual(chapters.map(\.read), [true, false])
        XCTAssertEqual(chapters.map(\.bookmark), [false, true])
        XCTAssertEqual(chapters.map(\.lastPageRead), [0, 7])
        XCTAssertEqual(chapters.map(\.chapterNumber), [1, 2])
        XCTAssertEqual(chapters[0].scanlator, "汉化组")
        XCTAssertEqual(chapters[0].dateUpload, Date(timeIntervalSince1970: 1_690_000_000))
        XCTAssertEqual(chapters[1].dateUpload, SChapter.undatedUpload, "undated stays undated (0)")
        let history = try XCTUnwrap(payload.backupHistory.first { $0.mangaId == exported.id })
        XCTAssertEqual(history.chapterId, chapters[0].id)
        XCTAssertEqual(history.readAt, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(history.readDurationSeconds, 600)

        XCTAssertEqual(result.sourceNames[Self.missingSource], "拷贝漫画", "a stub source keeps the name Android gave it")
        XCTAssertEqual(result.sourceNames[Self.mangaDex], store.sourceDescriptor(for: Self.mangaDex)?.name)
    }

    /// Fields kotlinx requires are written even when zero (the local source is source 0), durations go back to
    /// milliseconds, and the gzip trailer holds the real CRC-32 and size.
    @MainActor
    func testExportWritesUpstreamWireFormat() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        try store.restoreFromBackup(Self.backupData())
        let local = Manga(id: 999_100, source: MihonLocalSource.sourceId, url: "我的漫画", title: "我的漫画", favorite: true)
        store.mangas.append(local)
        store.chaptersByManga[local.id] = [Chapter(id: 999_101, mangaId: local.id, url: "我的漫画/第1话.cbz", name: "第1话", read: true)]

        let data = try await store.createTachiyomiBackupData()
        let inflated = try MihonGzip.decompress(data, limit: 64 << 20)
        let trailer = [UInt8](data.suffix(8))
        let crc = inflated.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        XCTAssertEqual(UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24, crc)
        XCTAssertEqual(Int(UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24), inflated.count)

        let backup = try ProtobufMessage(inflated)
        let entries = try backup.messages(1)
        let localEntry = try XCTUnwrap(entries.first { $0.string(2) == "我的漫画" })
        XCTAssertEqual(localEntry.int(1), 0, "source 0 is written: kotlinx has no default for it")
        XCTAssertEqual(try localEntry.messages(16).first?.string(2), "第1话")
        XCTAssertEqual(try localEntry.messages(16).first?.int(7).map { $0 > 0 }, true, "dateFetch in milliseconds")
        let dexEntry = try XCTUnwrap(entries.first { $0.string(2) == Self.mangaUrl })
        XCTAssertEqual(try dexEntry.messages(104).first?.int(3), 600_000, "readDuration is milliseconds upstream")
        XCTAssertEqual(dexEntry.int(14), 2, "the old viewer field next to viewer_flags")
        XCTAssertEqual(dexEntry.int(103), 2)
        XCTAssertEqual(dexEntry.bool(100), true)
        XCTAssertEqual(try backup.messages(101).first { $0.int(2) == 0 }.map { _ in true }, true, "the local source is named too")
        XCTAssertTrue(try backup.messages(101).allSatisfy { $0.int(2) != nil }, "sourceId is required")
    }

    /// Titles name their categories by `order`: two categories sharing one (after a deletion here) still come back
    /// as two.
    @MainActor
    func testExportGivesEveryCategoryItsOwnOrder() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.addCategory(name: "甲")
        store.addCategory(name: "乙")
        store.deleteCategory(id: try XCTUnwrap(store.categories.first { $0.name == "甲" }?.id))
        store.addCategory(name: "丙")
        let second = try XCTUnwrap(store.categories.first { $0.name == "乙" })
        let third = try XCTUnwrap(store.categories.first { $0.name == "丙" })
        XCTAssertEqual(second.order, third.order, "the situation this test is about")
        let titles = store.mangas.filter(\.favorite).prefix(2).map(\.id)
        XCTAssertEqual(titles.count, 2)
        store.setCategoriesForManga(mangaId: titles[0], categoryIds: [second.id])
        store.setCategoriesForManga(mangaId: titles[1], categoryIds: [third.id])

        let backup = try ProtobufMessage(MihonGzip.decompress(await store.createTachiyomiBackupData(), limit: 64 << 20))
        let categories = try backup.messages(2)
        XCTAssertEqual(Set(categories.compactMap { $0.int(2) }).count, categories.count, "orders are unique")
        let nameByOrder = Dictionary(uniqueKeysWithValues: categories.compactMap { category in category.int(2).map { ($0, category.string(1) ?? "") } })
        for (mangaId, name) in [(titles[0], "乙"), (titles[1], "丙")] {
            let url = try XCTUnwrap(store.manga(id: mangaId)?.url)
            let entry = try XCTUnwrap(try backup.messages(1).first { $0.string(2) == url })
            XCTAssertEqual(entry.ints(17).map { nameByOrder[$0] }, [name])
        }
    }

    func testEncoderRefusesAnEmptyBackup() {
        let empty = MihonBackupPayload(backupManga: [], backupCategories: [MangaCategory(id: 0, name: "默认", order: 0)], mangaCategoriesMap: [:], backupChapters: [], backupHistory: [], backupTracks: [], backupExtensionRepos: [])
        XCTAssertThrowsError(try TachiyomiBackupEncoder.encode(empty, sourceNames: [:]))
    }

    /// The compressor and its stored-block fallback both inflate back, across DEFLATE's 64 KB block limit.
    func testGzipCompressionRoundTrips() throws {
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let text = Data(String(repeating: "第1话 测试 ", count: 20_000).utf8)
        for data in [noise, text] {
            XCTAssertEqual(try MihonGzip.decompress(MihonGzip.compress(data), limit: 1 << 24), data)
            var gzip = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
            gzip.append(MihonGzip.stored(data))
            gzip.append(Data(count: 8))
            XCTAssertEqual(try MihonGzip.decompress(gzip, limit: 1 << 24), data)
        }
        XCTAssertLessThan(MihonGzip.compress(text).count, text.count / 10)
    }

    /// Upstream `MangaRestorer`: a restored title's next update comes from its chapters; the backup's own is kept while
    /// still ahead, and only from backups of this schedule (version 3).
    @MainActor
    func testRestoreWorksOutTheNextUpdate() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let ahead = Date().addingTimeInterval(20 * 86_400)
        func backup(version: Int, url: String) -> TachiyomiBackupDecoder.Result {
            let manga = Manga(id: 1, source: Self.mangaDex, url: url, title: url, favorite: true, nextUpdate: ahead)
            // Weekly, the last one two days ago: due again in about five days.
            let chapters = (0..<6).map { week in
                Chapter(id: Int64(10 + week), mangaId: 1, url: "\(url)/\(week)", name: "第\(6 - week)话",
                        dateUpload: Date().addingTimeInterval(-Double(2 + week * 7) * 86_400))
            }
            return .init(payload: MihonBackupPayload(version: version, backupManga: [manga], backupCategories: [], mangaCategoriesMap: [:],
                                                     backupChapters: chapters, backupHistory: [], backupTracks: [], backupExtensionRepos: []),
                         sourceNames: [:])
        }
        store.restore(backup(version: 2, url: "/manga/old-backup"))
        let old = try XCTUnwrap(store.mangas.first { $0.url == "/manga/old-backup" })
        XCTAssertEqual(old.fetchInterval, 7)
        XCTAssertLessThan(try XCTUnwrap(old.nextUpdate), Date().addingTimeInterval(8 * 86_400), "an old backup's date is not trusted")

        store.restore(backup(version: 3, url: "/manga/new-backup"))
        XCTAssertEqual(store.mangas.first { $0.url == "/manga/new-backup" }?.nextUpdate, ahead, "still ahead: kept")
    }
}
