import XCTest
@testable import MihonDomain
@testable import MihonData

/// Upstream `MigrateMangaUseCase`, onto local titles (they fetch offline) from demo titles (offline too).
@MainActor
final class MihonMigrationTests: XCTestCase {
    private var titles: [URL] = []

    override func tearDown() {
        for title in titles { try? FileManager.default.removeItem(at: title) }
    }

    /// A local title with chapters 1…count, one page each.
    private func localTitle(chapters count: Int) throws -> SManga {
        let name = "迁移目标-\(UUID().uuidString.prefix(8))"
        let title = MihonLocalStorage.defaultRootDirectory.appendingPathComponent(name, isDirectory: true)
        titles.append(title)
        for number in 1...count {
            let chapter = title.appendingPathComponent("第\(number)话", isDirectory: true)
            try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
            try Data([1]).write(to: chapter.appendingPathComponent("1.png"))
        }
        return SManga(url: name, title: name)
    }

    private func readTitle(_ store: MihonRepositoryStore) throws -> Manga {
        try XCTUnwrap(store.mangas.first { manga in
            manga.favorite && !store.isLiveSource(manga.source) && (store.chaptersByManga[manga.id] ?? []).contains(where: \.read)
                && (store.chaptersByManga[manga.id] ?? []).contains { !$0.read }
        })
    }

    func testMigrationCarriesProgressAndReplaces() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let current = try readTitle(store)
        let chapters = try XCTUnwrap(store.chaptersByManga[current.id])
        let maxRead = try XCTUnwrap(chapters.filter(\.read).map(\.chapterNumber).max())
        let bookmarked = try XCTUnwrap(chapters.first { $0.chapterNumber == 2 })
        store.setChaptersBookmarked(mangaId: current.id, chapterIds: [bookmarked.id], bookmarked: true)
        let index = try XCTUnwrap(store.mangas.firstIndex { $0.id == current.id })
        store.mangas[index].notes = "我的注释"
        store.mangas[index].chapterSortAscending = true
        let categories = store.mangaCategories[current.id]
        let target = try localTitle(chapters: Int(maxRead) + 2)

        let migrated = await store.migrateManga(currentId: current.id, to: target, sourceId: MihonLocalSource.sourceId, replace: true)
        XCTAssertTrue(migrated)
        let moved = try XCTUnwrap(store.mangas.first { $0.source == MihonLocalSource.sourceId && $0.url == target.url })
        XCTAssertTrue(moved.favorite)
        XCTAssertFalse(try XCTUnwrap(store.manga(id: current.id)).favorite, "replaced")
        let movedChapters = try XCTUnwrap(store.chaptersByManga[moved.id])
        XCTAssertTrue(movedChapters.filter { $0.chapterNumber <= maxRead }.allSatisfy(\.read), "read up to the furthest read number")
        XCTAssertFalse(movedChapters.filter { $0.chapterNumber > maxRead }.contains(where: \.read))
        XCTAssertEqual(movedChapters.first { $0.chapterNumber == 2 }?.bookmark, true, "bookmarks by number")
        XCTAssertEqual(store.mangaCategories[moved.id], categories)
        XCTAssertEqual(moved.notes, "我的注释")
        XCTAssertTrue(moved.chapterSortAscending, "the chapter settings come along")
    }

    func testCopyKeepsBothAndFlagsAreHonoured() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let current = try readTitle(store)
        store.migrationFlags = [.categories]
        let target = try localTitle(chapters: 3)
        let copied = await store.migrateManga(currentId: current.id, to: target, sourceId: MihonLocalSource.sourceId, replace: false)
        XCTAssertTrue(copied)
        let copy = try XCTUnwrap(store.mangas.first { $0.source == MihonLocalSource.sourceId && $0.url == target.url })
        XCTAssertTrue(copy.favorite)
        XCTAssertTrue(try XCTUnwrap(store.manga(id: current.id)).favorite, "a copy leaves the original in the library")
        XCTAssertFalse((store.chaptersByManga[copy.id] ?? []).contains(where: \.read), "chapters were not selected")
    }

    /// Chapters cached from an earlier visit do not pass for a fetch that failed now.
    func testStaleTargetChaptersDoNotCount() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let current = try readTitle(store)
        let target = try localTitle(chapters: 2)
        let cached = store.upsertCatalogMangaToStore(target, sourceId: MihonLocalSource.sourceId)
        await store.refreshMangaFromSource(mangaId: cached.id)
        XCTAssertFalse((store.chaptersByManga[cached.id] ?? []).isEmpty, "opened before")
        try FileManager.default.removeItem(at: MihonLocalStorage.defaultRootDirectory.appendingPathComponent(target.url))
        let migrated = await store.migrateManga(currentId: current.id, to: target, sourceId: MihonLocalSource.sourceId, replace: true)
        XCTAssertFalse(migrated)
        XCTAssertTrue(try XCTUnwrap(store.manga(id: current.id)).favorite)
    }

    /// One migration of a title at a time.
    func testASecondMigrationOfTheSameTitleIsRefused() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let current = try readTitle(store)
        let first = try localTitle(chapters: 2), second = try localTitle(chapters: 2)
        async let one = store.migrateManga(currentId: current.id, to: first, sourceId: MihonLocalSource.sourceId, replace: true)
        let two = await store.migrateManga(currentId: current.id, to: second, sourceId: MihonLocalSource.sourceId, replace: true)
        let results = await [one, two]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(store.mangas.filter { $0.source == MihonLocalSource.sourceId && $0.favorite && [first.url, second.url].contains($0.url) }.count, 1)
    }

    /// The old source's default mode (咚漫's webtoon) stays behind, a chosen one comes along; queued
    /// downloads are cancelled with the downloaded ones; tracks merge by tracker.
    func testModeDownloadsAndTracks() async throws {
        let tester = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let webtoon = try XCTUnwrap(tester.mangas.first { $0.favorite && $0.source == MihonSeedData.dongmanSourceId && $0.readingModeOverride == .webtoon })
        let target = try localTitle(chapters: 2)
        _ = await tester.migrateManga(currentId: webtoon.id, to: target, sourceId: MihonLocalSource.sourceId, replace: false)
        XCTAssertEqual(tester.mangas.first { $0.url == target.url }?.readingModeOverride, .defaultMode, "咚漫's own default stays with 咚漫")

        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let current = try readTitle(store)
        let index = try XCTUnwrap(store.mangas.firstIndex { $0.id == current.id })
        store.mangas[index].readingModeOverride = .rightToLeft
        let queued = try XCTUnwrap(store.chaptersByManga[current.id]?.first { !store.downloadedChapterIds.contains($0.id) })
        store.enqueueChapterDownload(manga: current, chapter: queued)
        store.tracksByManga[current.id] = [Track(id: 9_900_001, mangaId: current.id, trackerId: 2, remoteId: 1, title: "A", lastChapterRead: 3, totalChapters: 10, status: .reading)]
        let other = try localTitle(chapters: 3)
        let existing = store.upsertCatalogMangaToStore(other, sourceId: MihonLocalSource.sourceId)
        store.tracksByManga[existing.id] = [Track(id: 9_900_002, mangaId: existing.id, trackerId: 1, remoteId: 2, title: "B", lastChapterRead: 1, totalChapters: 10, status: .reading)]
        let migrated = await store.migrateManga(currentId: current.id, to: other, sourceId: MihonLocalSource.sourceId, replace: true)
        XCTAssertTrue(migrated)
        XCTAssertEqual(store.manga(id: existing.id)?.readingModeOverride, .rightToLeft, "a mode the user chose")
        XCTAssertEqual(store.downloadState(for: queued, in: current), .notDownloaded, "the queue let go of it")
        XCTAssertEqual(Set(store.tracksByManga[existing.id]?.map(\.trackerId) ?? []), [1, 2], "merged, not replaced")
    }

    /// Upstream aborts when the target cannot be fetched: the library keeps its title.
    func testUnfetchableTargetMigratesNothing() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let current = try readTitle(store)
        let missing = SManga(url: "不存在的作品-\(UUID().uuidString.prefix(6))", title: "不存在的作品")
        let migrated = await store.migrateManga(currentId: current.id, to: missing, sourceId: MihonLocalSource.sourceId, replace: true)
        XCTAssertFalse(migrated)
        XCTAssertTrue(try XCTUnwrap(store.manga(id: current.id)).favorite)
        XCTAssertFalse(store.mangas.contains { $0.url == missing.url && $0.favorite })
    }
}
