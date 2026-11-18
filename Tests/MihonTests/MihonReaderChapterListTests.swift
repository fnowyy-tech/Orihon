import XCTest
@testable import MihonDomain
@testable import MihonData

/// Upstream `ReaderViewModel.loadChapterList`: the chapters the reader's previous / next pass through.
@MainActor
final class MihonReaderChapterListTests: XCTestCase {
    /// A title whose source lists chapters newest first; `chapters` are (number, scanlator, read) oldest first.
    private func make(_ chapters: [(Double, String?, Bool)]) -> (MihonRepositoryStore, Int64, [Chapter]) {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = store.upsertCatalogMangaToStore(SManga(url: "/reader-list", title: "列表"), sourceId: MihonSeedData.MangaDexSourceId.simplifiedChinese)
        let list = chapters.enumerated().map { index, entry in
            Chapter(id: 880_000 + Int64(index), mangaId: manga.id, url: "/c/\(index)", name: "第\(entry.0)话",
                    scanlator: entry.1, read: entry.2, chapterNumber: entry.0, sourceOrder: chapters.count - 1 - index)
        }
        store.chaptersByManga[manga.id] = list
        return (store, manga.id, list)
    }

    private func numbers(_ chapters: [Chapter]) -> [String] {
        chapters.map { "\(Int($0.chapterNumber))\($0.scanlator ?? "")" }
    }

    func testSkipsReadAndFilteredChaptersButKeepsTheOpenOne() throws {
        let (store, mangaId, list) = make([(1, nil, false), (2, nil, true), (3, nil, true), (4, nil, false), (5, nil, false)])
        XCTAssertFalse(store.skipReadChapters, "upstream's default")
        XCTAssertTrue(store.skipFilteredChapters, "upstream's default")
        XCTAssertEqual(numbers(store.readerChapters(mangaId: mangaId, currentChapterId: list[2].id)), ["1", "2", "3", "4", "5"])

        store.skipReadChapters = true
        XCTAssertEqual(numbers(store.readerChapters(mangaId: mangaId, currentChapterId: list[2].id)), ["1", "3", "4", "5"],
                       "chapter 3 is read but open")

        store.skipReadChapters = false
        let at = try XCTUnwrap(store.mangas.firstIndex { $0.id == mangaId })
        store.mangas[at].filterUnread = .include
        XCTAssertEqual(numbers(store.readerChapters(mangaId: mangaId, currentChapterId: list[0].id)), ["1", "4", "5"],
                       "the title shows unread chapters only")
        store.skipFilteredChapters = false
        XCTAssertEqual(store.readerChapters(mangaId: mangaId, currentChapterId: list[0].id).count, 5)
    }

    func testDuplicatesKeepTheOpenChapterOrItsScanlator() {
        let (store, mangaId, list) = make([(1, "A", false), (1, "B", false), (2, "A", false), (2, "B", false), (3, "A", false)])
        store.skipDuplicateChapters = true
        XCTAssertEqual(numbers(store.readerChapters(mangaId: mangaId, currentChapterId: list[3].id)), ["1B", "2B", "3A"],
                       "the open chapter, else its scanlator's, else the first")
        XCTAssertEqual(numbers(store.readerChapters(mangaId: mangaId, currentChapterId: list[2].id)), ["1A", "2A", "3A"])
    }

    func testDownloadedOnlyKeepsDownloadedChapters() {
        let (store, mangaId, list) = make([(1, nil, false), (2, nil, false), (3, nil, false), (4, nil, false)])
        store.downloadedChapterIds = [list[0].id, list[3].id]
        store.downloadedOnlyMode = true
        XCTAssertEqual(numbers(store.readerChapters(mangaId: mangaId, currentChapterId: list[2].id)), ["1", "3", "4"])
    }
}
