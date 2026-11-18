import XCTest
import SwiftUI
import AppKit
@testable import MihonDomain
@testable import MihonAPKEngine
@testable import MihonData
@testable import MihonPresentation

final class MihonTests: XCTestCase {

    func testAPKBinaryAndDalvikDexInspection() throws {
        let inspector = APKBinaryDexInspector()
        let sampleExt = ExtensionModel(
            name: "拷贝漫画 (CopyManga)",
            pkgName: "eu.kanade.tachiyomi.extension.zh.copymanga",
            versionName: "1.4.42",
            versionCode: 42,
            lang: "zh",
            isNsfw: false,
            apkName: "tachiyomi-zh.copymanga-v1.4.42.apk",
            sources: [
                ExtensionSourceDescriptor(
                    id: 1001,
                    name: "拷贝漫画 (CopyManga)",
                    lang: "zh",
                    baseUrl: "https://www.mangacopy.com",
                    isNsfw: false,
                    className: "eu.kanade.tachiyomi.extension.zh.copymanga.CopyManga",
                    popularSelector: "div.exemptComicItem",
                    chapterSelector: "div.tab-pane ul li a",
                    pageSelector: "ul.comicContent-list li img"
                )
            ]
        )

        let apkData = inspector.buildSyntheticMihonExtensionApk(for: sampleExt)
        XCTAssertGreaterThan(apkData.count, 200)

        let inspection = try inspector.inspectAndroidPackage(
            apkData: apkData,
            artifactPath: "/Documents/Extensions/tachiyomi-zh.copymanga-v1.4.42.apk"
        )

        XCTAssertEqual(inspection.tool, "inspect_android_package")
        XCTAssertEqual(inspection.manifest.packageName, "eu.kanade.tachiyomi.extension.zh.copymanga")
        XCTAssertEqual(
            inspection.manifest.tachiyomiExtensionClass,
            "eu.kanade.tachiyomi.extension.zh.copymanga.CopyManga"
        )
        XCTAssertEqual(inspection.dexMetrics.count, 1)
        XCTAssertEqual(inspection.dexMetrics.first?.dexVersion, "035")
        XCTAssertGreaterThan(inspection.dexMetrics.first?.stringIdsCount ?? 0, 10)
        XCTAssertEqual(inspection.discoveredClasses.count, 1)
        XCTAssertTrue(inspection.extractedStringPool.contains("https://www.mangacopy.com"))
    }

    func testAPKSourceSynthesizerAndCatalogQueries() async throws {
        let synthesizer = APKSourceSynthesizer()
        let sampleExt = ExtensionModel(
            name: "MangaDex",
            pkgName: "eu.kanade.tachiyomi.extension.all.mangadex",
            versionName: "1.4.198",
            versionCode: 198,
            lang: "all",
            apkName: "tachiyomi-all.mangadex.apk"
        )

        let (inspection, sources) = try await synthesizer.analyzeAndSynthesizeExtension(extensionModel: sampleExt)
        XCTAssertFalse(inspection.evidenceId.isEmpty)
        XCTAssertEqual(sources.count, 1)

        let source = sources[0]
        let popularPage = try await source.getPopularManga(page: 1)
        XCTAssertFalse(popularPage.mangas.isEmpty)

        let chapters = try await source.getChapterList(manga: popularPage.mangas[0])
        XCTAssertEqual(chapters.count, 24)

        let pages = try await source.getPageList(chapter: chapters[0])
        XCTAssertEqual(pages.count, 18)
    }

    @MainActor
    func testAllApkArchetypesAndMultiSourceFactoryAlignment() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        await store.bootstrapInstalledAPKSources()

        // Verify all seeded APKs (CopyManga, MangaDex multi-source, BaoziMH, ManhuaDB, ShonenJumpPlus, AsuraScans, DM5, Kuaikan, Bilibili, Colamanga, Bato.to, Manganato, Komga)
        XCTAssertGreaterThanOrEqual(store.extensions.count, 13)

        let synthesizer = APKSourceSynthesizer()
        for ext in store.extensions {
            let (inspection, synthesizedSources) = try await synthesizer.analyzeAndSynthesizeExtension(extensionModel: ext)
            XCTAssertFalse(inspection.evidenceId.isEmpty)
            XCTAssertEqual(inspection.manifest.packageName, ext.pkgName)
            XCTAssertGreaterThanOrEqual(synthesizedSources.count, max(1, ext.sources.count))
            for src in synthesizedSources {
                XCTAssertFalse(src.baseUrl.isEmpty)
                XCTAssertFalse(src.popularMangaSelector().isEmpty)
                XCTAssertFalse(src.chapterListSelector().isEmpty)
                XCTAssertFalse(src.pageListSelector().isEmpty)
            }
        }
    }

    @MainActor
    func testRepositoryStoreBackupAndRestoreRoundTrip() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let initialCount = store.mangas.count
        XCTAssertGreaterThanOrEqual(initialCount, 6)

        // Export Backup JSON
        let backupData = try store.createBackupJSONData()
        XCTAssertGreaterThan(backupData.count, 500)

        // Mutate store then restore
        store.mangas.removeAll()
        XCTAssertTrue(store.mangas.isEmpty)

        try store.restoreFromBackupJSONData(backupData)
        XCTAssertEqual(store.mangas.count, initialCount)
    }

    /// Tester builds (`showsDemoFeatures: false`) keep only what a live source serves.
    @MainActor
    func testStoreWithoutDemoFeaturesKeepsOnlyLiveContent() {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        XCTAssertGreaterThanOrEqual(store.libraryItems(forCategory: -1, searchQuery: "").count, 40)
        XCTAssertTrue(store.mangas.contains { $0.source == MihonSeedData.zaimanhuaSourceId }, "再漫画 shelf")
        let webtoons = store.mangas.filter { $0.source == MihonSeedData.dongmanSourceId }
        XCTAssertFalse(webtoons.isEmpty, "咚漫 shelf")
        XCTAssertTrue(webtoons.allSatisfy { $0.readingModeOverride == .webtoon && store.mangaCategories[$0.id] == [3] })
        XCTAssertTrue(store.mangas.allSatisfy { store.isLiveSource($0.source) }, "\(store.mangas.map(\.title))")
        XCTAssertEqual(Set(store.mangas.map(\.url)).count, store.mangas.count, "duplicate MangaDex entries")
        let sources = store.activeCatalogueSources()
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.allSatisfy(\.isLive), "\(sources.map(\.name))")
        XCTAssertTrue(store.historyEntries.isEmpty)
        XCTAssertTrue(store.tracksByManga.isEmpty)
        for category in store.categories where category.id != 0 {
            XCTAssertTrue(store.mangaCategories.values.contains { $0.contains(category.id) }, "empty category \(category.name)")
        }
    }

    /// Restoring never drops entries, not even those from sources this build lacks (like an uninstalled extension):
    /// the backup is merged in, and the titles already there stay.
    @MainActor
    func testRestoreKeepsEntriesFromUnavailableSources() throws {
        let full = MihonRepositoryStore(bootstrapNetwork: false)
        let backup = try full.createBackupJSONData()
        let tester = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let before = Set(tester.mangas.map { "\($0.source)|\($0.url)" })
        try tester.restoreFromBackupJSONData(backup)
        let after = Set(tester.mangas.map { "\($0.source)|\($0.url)" })
        XCTAssertTrue(before.isSubset(of: after))
        XCTAssertTrue(Set(full.mangas.map { "\($0.source)|\($0.url)" }).isSubset(of: after))
        XCTAssertEqual(Set(tester.mangas.map(\.id)).count, tester.mangas.count, "new titles get new ids")
    }

    /// A library saved by builds 1–5 (no seed version) loses its demo entries once and gets the MangaDex shelf
    /// under fresh ids; an up-to-date library is left as restored.
    @MainActor
    func testLibraryFromEarlierBuildIsMigratedOnce() throws {
        let backup = try MihonRepositoryStore(bootstrapNetwork: false).createBackupJSONData()
        let tester = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = tester.mangas
        let seededCategories = tester.mangaCategories

        try tester.replaceLibrary(with: backup)
        tester.migrateRestoredLibrary(fromSeedVersion: 2, seeded: seeded, seededCategories: seededCategories)
        XCTAssertTrue(tester.mangas.contains { !tester.isLiveSource($0.source) }, "an up-to-date library is left alone")

        try tester.replaceLibrary(with: backup)
        tester.migrateRestoredLibrary(fromSeedVersion: 0, seeded: seeded, seededCategories: seededCategories)
        XCTAssertTrue(tester.mangas.allSatisfy { tester.isLiveSource($0.source) })
        XCTAssertEqual(tester.mangas.count, seeded.count)
        XCTAssertEqual(Set(tester.mangas.map(\.id)).count, tester.mangas.count)
        XCTAssertEqual(Set(tester.mangas.map(\.url)).count, tester.mangas.count)
        let liveIds = Set(tester.mangas.map(\.id))
        XCTAssertTrue(Set(tester.chaptersByManga.keys).isSubset(of: liveIds))
        XCTAssertTrue(tester.historyEntries.allSatisfy { liveIds.contains($0.mangaId) })
        XCTAssertTrue(tester.tracksByManga.isEmpty)
        let seededEntry = try XCTUnwrap(seeded.first { $0.title == "鏈鋸人" })
        let added = try XCTUnwrap(tester.mangas.first { $0.title == "鏈鋸人" })
        XCTAssertNotNil(seededCategories[seededEntry.id])
        XCTAssertEqual(tester.mangaCategories[added.id], seededCategories[seededEntry.id])
    }

    /// A library saved by build 6 (seed version 2) gets only the 再漫画 and 咚漫 shelves added since; a MangaDex
    /// title the user deleted stays deleted.
    @MainActor
    func testLibraryFromSeedVersion2GetsOnlyNewShelves() throws {
        let tester = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = tester.mangas
        let seededCategories = tester.mangaCategories
        let newShelves: Set<Int64> = [MihonSeedData.zaimanhuaSourceId, MihonSeedData.dongmanSourceId]
        let deleted = try XCTUnwrap(seeded.first { MihonSeedData.seedVersion(of: $0.id) == 2 })
        tester.mangas.removeAll { newShelves.contains($0.source) || $0.id == deleted.id }
        let before = tester.mangas.count

        tester.mangas[0].chapterSortMode = .chapterNumber
        tester.mangas[1].chapterSortMode = .uploadDate
        tester.migrateRestoredLibrary(fromSeedVersion: 2, seeded: seeded, seededCategories: seededCategories)
        XCTAssertEqual(tester.mangas.count, before + seeded.filter { newShelves.contains($0.source) }.count)
        XCTAssertEqual(tester.mangas[0].chapterSortMode, .source, "the old default moves to upstream's")
        XCTAssertEqual(tester.mangas[1].chapterSortMode, .uploadDate, "a sort the user picked stays")
        XCTAssertFalse(tester.mangas.contains { $0.source == deleted.source && $0.url == deleted.url })
        XCTAssertEqual(Set(tester.mangas.map(\.id)).count, tester.mangas.count)
    }

    /// Settings survive a relaunch: a change is saved after the current main-actor turn, and a new store restores it.
    @MainActor
    func testSettingsAreSavedAndRestored() async throws {
        let suite = "MihonSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = MihonRepositoryStore(bootstrapNetwork: false)
        first.restoreAndTrackSettings(in: defaults)
        first.defaultReadingMode = .webtoon
        first.themePalette = .greenApple
        first.pinnedSourceIds = [42]
        first.downloadedChapterIds = [7, 8]
        for _ in 0..<20 where defaults.data(forKey: MihonRepositoryStore.settingsKey) == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        first.libraryDisplayMode = .list
        try await Task.sleep(nanoseconds: 200_000_000)

        let second = MihonRepositoryStore(bootstrapNetwork: false)
        second.restoreAndTrackSettings(in: defaults)
        XCTAssertEqual(second.defaultReadingMode, .webtoon)
        XCTAssertEqual(second.themePalette, .greenApple)
        XCTAssertEqual(second.pinnedSourceIds, [42])
        XCTAssertEqual(second.downloadedChapterIds, [7, 8])
        XCTAssertEqual(second.libraryDisplayMode, .list, "later changes are saved too")
    }

    /// A saved value this build no longer knows only resets that one setting.
    func testUnknownSettingValueKeepsTheOthers() throws {
        let json = #"{"themePalette":"no-such-theme","defaultReadingMode":4,"pinnedSourceIds":[1]}"#
        let snapshot = try JSONDecoder().decode(MihonSettingsSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.themePalette)
        XCTAssertEqual(snapshot.defaultReadingMode, .webtoon)
        XCTAssertEqual(snapshot.pinnedSourceIds, [1])
    }

    /// A source answering with no chapters (title taken down, everything paywalled) keeps what was saved.
    @MainActor
    func testEmptyChapterListKeepsSavedChapters() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let manga = try XCTUnwrap(store.mangas.first { !(store.chaptersByManga[$0.id] ?? []).isEmpty })
        let before = store.chaptersByManga[manga.id]
        XCTAssertEqual(store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: []), 0)
        XCTAssertEqual(store.chaptersByManga[manga.id], before)
    }

    /// A snapshot that no longer decodes is moved aside instead of being overwritten by the next save.
    func testUnreadableSnapshotIsMovedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mihon-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mihon_state_v2.json")
        try Data(#"{"version": "from a newer build"}"#.utf8).write(to: file)

        guard case .empty = MihonDiskPersistenceManager.loadSnapshotSynchronously(at: file) else {
            return XCTFail("an undecodable snapshot loads as no snapshot")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(kept[0].hasPrefix("mihon_state_v2.unreadable-") && kept[0].hasSuffix(".json"), kept[0])
    }

    /// Restoring a backup adds unknown extension repos but never changes a known repo's signing key.
    @MainActor
    func testBackupRestoreKeepsKnownRepoKeys() throws {
        let source = MihonRepositoryStore(bootstrapNetwork: false)
        source.extensionRepos[0].signingKeyFingerprint = String(repeating: "ab", count: 32)
        source.extensionRepos.append(ExtensionRepo(baseUrl: "https://example.invalid/repo", name: "Other", website: "", signingKeyFingerprint: String(repeating: "cd", count: 32)))
        let backup = try source.createBackupJSONData()

        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let keiyoushiKey = store.extensionRepos[0].signingKeyFingerprint
        try store.restoreFromBackupJSONData(backup)
        XCTAssertEqual(store.extensionRepos[0].signingKeyFingerprint, keiyoushiKey)
        XCTAssertEqual(store.extensionRepos.map(\.baseUrl).last, "https://example.invalid/repo")
    }

    /// A downloaded chapter opens from its saved page list (no network: offline, or a MangaDex@Home node that
    /// changed since), and removing the download deletes its pages and list.
    @MainActor
    func testDownloadedChapterReadsWithoutNetworkAndIsRemovedCompletely() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        let chapter = Chapter(id: 9_900_000 + Int64.random(in: 0..<99_999), mangaId: manga.id, url: "/chapter/test", name: "测试")
        store.chaptersByManga[manga.id, default: []].append(chapter)
        let urls = (1...3).map { "https://example.invalid/pages/\(UUID().uuidString)/\($0).png" }
        let png = try XCTUnwrap(Self.onePixelPNG())
        for url in urls { XCTAssertTrue(MihonTwoTierImageCache.shared.storeRawData(png, forKey: url)) }
        MihonTwoTierImageCache.shared.saveDownloadedPageList(chapterId: chapter.id, urls: urls)
        store.downloadedChapterIds.insert(chapter.id)

        let pages = try await store.pageList(for: manga, chapter: chapter)
        XCTAssertEqual(pages.map(\.imageUrl), urls)
        let image = await MihonTwoTierImageCache.shared.image(url: urls[0], target: .page(maxPixelSize: 64))
        XCTAssertNotNil(image, "served from the downloads folder")

        store.removeChapterDownload(chapterId: chapter.id)
        XCTAssertFalse(store.downloadedChapterIds.contains(chapter.id))
        XCTAssertNil(MihonTwoTierImageCache.shared.downloadedPageList(chapterId: chapter.id))
        XCTAssertTrue(urls.allSatisfy { !MihonTwoTierImageCache.shared.hasDiskEntry(for: $0) })
    }

    /// Pages are stored once per URL and chapters share them (two 咚漫 episodes repeat most of their images), so
    /// removing one download keeps the pages another still lists.
    func testRemovingADownloadKeepsPagesAnotherStillLists() throws {
        let cache = MihonTwoTierImageCache.shared
        let png = try XCTUnwrap(Self.onePixelPNG())
        let shared = (1...2).map { "https://example.invalid/shared/\(UUID().uuidString)/\($0).png" }
        let ownA = "https://example.invalid/a/\(UUID().uuidString).png"
        let ownB = "https://example.invalid/b/\(UUID().uuidString).png"
        for url in shared + [ownA, ownB] { XCTAssertTrue(cache.storeRawData(png, forKey: url)) }
        let a = 9_800_000 + Int64.random(in: 0..<99_999), b = a + 100_000
        cache.saveDownloadedPageList(chapterId: a, urls: shared + [ownA])
        cache.saveDownloadedPageList(chapterId: b, urls: shared + [ownB])

        cache.removeDownloadedChapter(chapterId: b)
        XCTAssertNil(cache.downloadedPageList(chapterId: b))
        XCTAssertFalse(cache.hasDiskEntry(for: ownB))
        XCTAssertTrue((shared + [ownA]).allSatisfy { cache.hasDiskEntry(for: $0) }, "chapter A still reads offline")
        cache.removeDownloadedChapter(chapterId: a)
        XCTAssertFalse((shared + [ownA]).contains { cache.hasDiskEntry(for: $0) })
    }

    /// What downloads cut short left (a page list the app quit before finishing, pages no list names) is swept, and
    /// deleting all downloads empties the folders.
    @MainActor
    func testDownloadFoldersAreSweptAndWiped() throws {
        let cache = MihonTwoTierImageCache.shared
        let png = try XCTUnwrap(Self.onePixelPNG())
        let listed = "https://example.invalid/listed/\(UUID().uuidString).png"
        let leftover = "https://example.invalid/leftover/\(UUID().uuidString).png"
        XCTAssertTrue(cache.storeRawData(png, forKey: listed))
        XCTAssertTrue(cache.storeRawData(png, forKey: leftover))
        let chapterId = 9_700_000 + Int64.random(in: 0..<99_999)
        cache.saveDownloadedPageList(chapterId: chapterId, urls: [listed])
        let cutShort = chapterId + 100_000
        cache.saveDownloadedPageList(chapterId: cutShort, urls: [leftover])
        cache.removeIncompleteDownloads(keeping: [chapterId])
        XCTAssertTrue(cache.hasDiskEntry(for: listed))
        XCTAssertFalse(cache.hasDiskEntry(for: leftover), "the list of a download the app quit during goes too")
        XCTAssertNil(cache.downloadedPageList(chapterId: cutShort))

        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.downloadedChapterIds.insert(chapterId)
        store.removeAllDownloads()
        XCTAssertTrue(store.downloadedChapterIds.isEmpty)
        XCTAssertFalse(cache.hasDiskEntry(for: listed))
        XCTAssertNil(cache.downloadedPageList(chapterId: chapterId))
    }

    /// Delete-after-reading waits until the reader closes: paging back offline still needs the chapter's files.
    @MainActor
    func testDeleteAfterReadingWaitsForTheReaderToClose() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.deleteAfterReading = true
        let manga = try XCTUnwrap(store.mangas.first)
        let chapter = Chapter(id: 9_600_000 + Int64.random(in: 0..<99_999), mangaId: manga.id, url: "/chapter/read", name: "读完")
        store.chaptersByManga[manga.id, default: []].append(chapter)
        let url = "https://example.invalid/read/\(UUID().uuidString).png"
        XCTAssertTrue(MihonTwoTierImageCache.shared.storeRawData(try XCTUnwrap(Self.onePixelPNG()), forKey: url))
        MihonTwoTierImageCache.shared.saveDownloadedPageList(chapterId: chapter.id, urls: [url])
        store.downloadedChapterIds.insert(chapter.id)

        store.recordReadingProgress(mangaId: manga.id, chapterId: chapter.id, pageIndex: 0, completedChapter: true)
        XCTAssertTrue(store.downloadedChapterIds.contains(chapter.id), "still open in the reader")
        XCTAssertTrue(MihonTwoTierImageCache.shared.hasDiskEntry(for: url))

        store.deletePendingReadChapters()
        XCTAssertFalse(store.downloadedChapterIds.contains(chapter.id))
        XCTAssertFalse(MihonTwoTierImageCache.shared.hasDiskEntry(for: url))
    }

    /// A chapter the source drops and adds back under another URL (a re-upload) keeps its read and bookmark state,
    /// fetch date, download and history, and is no update; a dropped chapter's download is deleted (upstream
    /// `SyncChaptersWithSource`).
    @MainActor
    func testReaddedChapterKeepsItsStateAndDownload() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        store.chaptersByManga[manga.id] = []
        store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: [
            SChapter(url: "/c/2", name: "Chapter 2", chapterNumber: 2),
            SChapter(url: "/c/1", name: "Chapter 1", chapterNumber: 1),
        ])
        let synced = try XCTUnwrap(store.chaptersByManga[manga.id])
        let one = try XCTUnwrap(synced.first { $0.url == "/c/1" })
        let two = try XCTUnwrap(synced.first { $0.url == "/c/2" })
        store.recordReadingProgress(mangaId: manga.id, chapterId: one.id, pageIndex: 3, completedChapter: true)
        store.toggleChapterBookmark(mangaId: manga.id, chapterId: one.id)
        let cache = MihonTwoTierImageCache.shared
        let png = try XCTUnwrap(Self.onePixelPNG())
        let pagesOne = ["https://example.invalid/r/\(UUID().uuidString).png"]
        let pagesTwo = ["https://example.invalid/r/\(UUID().uuidString).png"]
        for url in pagesOne + pagesTwo { XCTAssertTrue(cache.storeRawData(png, forKey: url)) }
        cache.saveDownloadedPageList(chapterId: one.id, urls: pagesOne)
        cache.saveDownloadedPageList(chapterId: two.id, urls: pagesTwo)
        store.downloadedChapterIds.formUnion([one.id, two.id])

        let inserted = store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: [
            SChapter(url: "/c/3", name: "Chapter 3", chapterNumber: 3),
            SChapter(url: "/c/1-reupload", name: "Chapter 1", chapterNumber: 1),
        ])
        XCTAssertEqual(inserted, 1, "only chapter 3 is new")
        let readded = try XCTUnwrap(store.chaptersByManga[manga.id]?.first { $0.url == "/c/1-reupload" })
        XCTAssertTrue(readded.read)
        XCTAssertTrue(readded.bookmark)
        XCTAssertEqual(readded.dateFetch, one.dateFetch)
        XCTAssertEqual(store.downloadedChapterIds, [readded.id])
        XCTAssertEqual(cache.downloadedPageList(chapterId: readded.id), pagesOne)
        XCTAssertNil(cache.downloadedPageList(chapterId: one.id))
        XCTAssertNil(cache.downloadedPageList(chapterId: two.id))
        XCTAssertFalse(cache.hasDiskEntry(for: pagesTwo[0]))
        XCTAssertFalse(store.historyEntries.contains { $0.chapterId == one.id })
        XCTAssertTrue(store.historyEntries.contains { $0.chapterId == readded.id })
        store.removeChapterDownload(chapterId: readded.id)
    }

    /// Downloads are filed by chapter id and a backup brings its own ids: merging finds the chapter by URL and keeps
    /// the id it has here, download included.
    @MainActor
    func testBackupRestoreKeepsDownloadsOfChaptersFoundAgain() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        let chapter = Chapter(id: 9_500_000 + Int64.random(in: 0..<99_999), mangaId: manga.id, url: "/chapter/kept", name: "保留")
        store.chaptersByManga[manga.id, default: []].append(chapter)
        let url = "https://example.invalid/kept/\(UUID().uuidString).png"
        XCTAssertTrue(MihonTwoTierImageCache.shared.storeRawData(try XCTUnwrap(Self.onePixelPNG()), forKey: url))
        MihonTwoTierImageCache.shared.saveDownloadedPageList(chapterId: chapter.id, urls: [url])
        store.downloadedChapterIds.insert(chapter.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try decoder.decode(MihonBackupPayload.self, from: store.createBackupJSONData())
        let newId = chapter.id + 1_000_000
        let index = try XCTUnwrap(payload.backupChapters.firstIndex { $0.id == chapter.id })
        payload.backupChapters[index].id = newId
        try store.restoreFromBackupJSONData(encoder.encode(payload))

        XCTAssertEqual(store.downloadedChapterIds, [chapter.id])
        XCTAssertEqual(MihonTwoTierImageCache.shared.downloadedPageList(chapterId: chapter.id), [url])
        XCTAssertFalse(store.chaptersByManga.values.joined().contains { $0.id == newId })
        store.removeChapterDownload(chapterId: chapter.id)
    }

    /// A saved library that exists but cannot be read is neither moved aside nor taken for a missing one: the
    /// launch must not save the seed library over it.
    func testSnapshotThatCannotBeReadIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mihon-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mihon_state_v2.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        guard case .unreadable = MihonDiskPersistenceManager.loadSnapshotSynchronously(at: file) else {
            return XCTFail("a file that cannot be read is not an empty library")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Builds 1–5 had a real engine for MangaDex in every language: the one-time cleanup keeps a title from a
    /// MangaDex source this build's catalogue lacks, and drops generated titles — also those of sources real today.
    @MainActor
    func testEarlierBuildCleanupKeepsOnlyMangaDexTitles() throws {
        let tester = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = tester.mangas
        let seededCategories = tester.mangaCategories
        let template = try XCTUnwrap(seeded.first)
        func entry(_ id: Int64, _ source: Int64, _ url: String) -> Manga {
            var manga = template
            manga.id = id
            manga.source = source
            manga.url = url
            manga.title = "条目 \(id)"
            return manga
        }
        tester.mangas = [
            entry(90_001, 7_777_777_777, "/manga/0f7c2f5e-3c1b-4a8e-9a3b-2d4e5f6a7b8c"),
            entry(90_002, 7_777_777_777, "/manga/12-3"),
            entry(90_003, 0, "/local/demo.cbz"),
            entry(90_004, MihonSeedData.zaimanhuaSourceId, "/manga/5-1"),
        ]
        tester.migrateRestoredLibrary(fromSeedVersion: 0, seeded: seeded, seededCategories: seededCategories)
        let kept = Set(tester.mangas.map { "\($0.source)|\($0.url)" })
        XCTAssertTrue(kept.contains("7777777777|/manga/0f7c2f5e-3c1b-4a8e-9a3b-2d4e5f6a7b8c"))
        XCTAssertFalse(kept.contains("7777777777|/manga/12-3"))
        XCTAssertFalse(kept.contains("0|/local/demo.cbz"))
        XCTAssertFalse(kept.contains("\(MihonSeedData.zaimanhuaSourceId)|/manga/5-1"))
    }

    /// Upstream library sort: each option compares ascending and descending reverses it (名称 ascending is A→Z);
    /// ties fall back to the title.
    @MainActor
    func testLibrarySortDirections() {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.librarySortOption = .alphabetical
        store.librarySortAscending = true
        let ascending = store.libraryItems(forCategory: -1, searchQuery: "").map(\.manga.title)
        XCTAssertGreaterThan(ascending.count, 2)
        XCTAssertEqual(ascending, ascending.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        store.librarySortAscending = false
        XCTAssertEqual(store.libraryItems(forCategory: -1, searchQuery: "").map(\.manga.title), ascending.reversed())

        // Nothing read yet: every title ties on 最近阅读, so the titles decide, in both directions.
        store.librarySortOption = .lastRead
        for direction in [true, false] {
            store.librarySortAscending = direction
            XCTAssertEqual(store.libraryItems(forCategory: -1, searchQuery: "").map(\.manga.title), ascending)
        }
    }

    /// Adding a title asks for categories while the user has some and the default-category setting is "always ask";
    /// otherwise it goes to the chosen category, or the default one (never to a deleted category).
    @MainActor
    func testAddingToLibraryFollowsTheDefaultCategorySetting() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first { $0.favorite })
        store.removeFromLibrary(mangaId: manga.id)
        XCTAssertFalse(try XCTUnwrap(store.manga(id: manga.id)).favorite)
        XCTAssertTrue(store.asksCategoriesOnAdd, "upstream's default: always ask")

        let category = try XCTUnwrap(store.categories.first { !$0.isSystemCategory })
        store.defaultLibraryCategory = category.id
        XCTAssertFalse(store.asksCategoriesOnAdd)
        store.toggleFavorite(mangaId: manga.id)
        XCTAssertTrue(try XCTUnwrap(store.manga(id: manga.id)).favorite)
        XCTAssertEqual(store.mangaCategories[manga.id], [category.id])

        store.removeFromLibrary(mangaId: manga.id)
        store.deleteCategory(id: category.id)
        XCTAssertTrue(store.asksCategoriesOnAdd, "the chosen category is gone")
        store.defaultLibraryCategory = MangaCategory.defaultCategoryId
        store.addToLibrary(mangaId: manga.id)
        XCTAssertEqual(store.mangaCategories[manga.id], [MangaCategory.defaultCategoryId])
        XCTAssertTrue(store.libraryItems(forCategory: MangaCategory.defaultCategoryId, searchQuery: "").contains { $0.id == manga.id })
    }

    /// Changing the categories of several titles only adds the ticked and removes the cleared ones: a category left
    /// mixed stays as each title has it.
    @MainActor
    func testChangingCategoriesOfSeveralTitlesKeepsMixedOnes() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let ids = store.categories.filter { !$0.isSystemCategory }.map(\.id)
        XCTAssertGreaterThanOrEqual(ids.count, 3)
        let titles = store.mangas.filter(\.favorite).prefix(2).map(\.id)
        store.setCategoriesForManga(mangaId: titles[0], categoryIds: [ids[0], ids[1]])
        store.setCategoriesForManga(mangaId: titles[1], categoryIds: [ids[1]])

        store.changeCategories(mangaIds: Array(titles), adding: [ids[2]], removing: [ids[1]])
        XCTAssertEqual(store.mangaCategories[titles[0]], [ids[0], ids[2]], "the mixed category stays")
        XCTAssertEqual(store.mangaCategories[titles[1]], [ids[2]])
    }

    /// 标记之前章节为已读 goes by the chapters' place in the list (upstream), so an unnumbered extra counts where it
    /// is listed.
    @MainActor
    func testMarkingPreviousChaptersReadGoesByListPosition() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        store.chaptersByManga[manga.id] = []
        store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: [
            SChapter(url: "/extra", name: "番外"),
            SChapter(url: "/3", name: "第3话", chapterNumber: 3),
            SChapter(url: "/2", name: "第2话", chapterNumber: 2),
            SChapter(url: "/1", name: "第1话", chapterNumber: 1),
        ])
        let current = try XCTUnwrap(store.manga(id: manga.id))
        let third = try XCTUnwrap(store.chaptersByManga[manga.id]?.first { $0.url == "/3" })
        store.markChaptersRead(before: third.id, in: current)
        let read = Set(store.chaptersByManga[manga.id]!.filter(\.read).map(\.url))
        XCTAssertEqual(read, ["/1", "/2"], "the extra listed after chapter 3 stays unread")

        let extra = try XCTUnwrap(store.chaptersByManga[manga.id]?.first { $0.url == "/extra" })
        store.markChaptersRead(before: extra.id, in: current)
        XCTAssertTrue(store.chaptersByManga[manga.id]!.filter { $0.url != "/extra" }.allSatisfy(\.read))
    }

    /// History resumes the history chapter while it is unfinished, then the chapter after it — read or not — and
    /// nothing after the last one (upstream `GetNextChapters`).
    @MainActor
    func testHistoryResumesTheChapterAfterAFinishedOne() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        store.chaptersByManga[manga.id] = []
        store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: (1...3).reversed().map {
            SChapter(url: "/\($0)", name: "第\($0)话", chapterNumber: Double($0))
        })
        let chapters = try XCTUnwrap(store.chaptersByManga[manga.id])
        let one = try XCTUnwrap(chapters.first { $0.url == "/1" })
        let two = try XCTUnwrap(chapters.first { $0.url == "/2" })
        let three = try XCTUnwrap(chapters.first { $0.url == "/3" })
        XCTAssertEqual(store.chapterToResume(mangaId: manga.id, fromChapterId: two.id)?.id, two.id)
        store.setChaptersRead(mangaId: manga.id, chapterIds: [two.id, three.id], read: true)
        XCTAssertEqual(store.chapterToResume(mangaId: manga.id, fromChapterId: two.id)?.id, three.id, "not chapter 1")
        XCTAssertNil(store.chapterToResume(mangaId: manga.id, fromChapterId: three.id))
        XCTAssertFalse(try XCTUnwrap(store.chaptersByManga[manga.id]?.first { $0.id == one.id }).read)
    }

    /// History shows one row per title — the chapter read last — and removing that row brings back the one read
    /// before (upstream `historyView`).
    @MainActor
    func testHistoryShowsOneRowPerTitle() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        store.chaptersByManga[manga.id] = []
        store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: (1...3).reversed().map {
            SChapter(url: "/h\($0)", name: "第\($0)话", chapterNumber: Double($0))
        })
        let chapters = try XCTUnwrap(store.chaptersByManga[manga.id])
        for url in ["/h1", "/h2"] {
            let chapter = try XCTUnwrap(chapters.first { $0.url == url })
            store.recordReadingProgress(mangaId: manga.id, chapterId: chapter.id, pageIndex: 0, completedChapter: false)
        }
        let rows = store.readingHistory().filter { $0.manga.id == manga.id }
        XCTAssertEqual(rows.map(\.chapter.url), ["/h2"])
        XCTAssertEqual(store.readingHistory(searchQuery: manga.title).filter { $0.manga.id == manga.id }.count, 1)
        XCTAssertTrue(store.readingHistory(searchQuery: "第1话").isEmpty, "the search matches titles, not chapters")

        store.deleteHistoryEntry(id: try XCTUnwrap(rows.first).id)
        XCTAssertEqual(store.readingHistory().filter { $0.manga.id == manga.id }.map(\.chapter.url), ["/h1"])
    }

    /// Adding to an empty queue starts the downloader even after a pause (upstream `autoStart && wasEmpty`); a queue
    /// saved when the app stopped comes back paused.
    @MainActor
    func testDownloadQueueStartsWhenFilledAndComesBackPaused() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let manga = try XCTUnwrap(store.mangas.first { !store.isLiveSource($0.source) && $0.source != 0 })
        let chapter = try XCTUnwrap(store.chaptersByManga[manga.id]?.first { !store.downloadedChapterIds.contains($0.id) })
        store.isDownloaderRunning = false
        store.enqueueChapterDownload(manga: manga, chapter: chapter)
        XCTAssertTrue(store.isDownloaderRunning)
        XCTAssertEqual(store.settingsSnapshot.queuedChapterIds, [chapter.id])
        store.clearDownloadQueue()

        store.queuedChapterIdsToRestore = [chapter.id]
        store.restoreDownloadQueue()
        XCTAssertEqual(store.downloadQueue.map(\.id), [chapter.id])
        XCTAssertFalse(store.isDownloaderRunning, "restored paused")
        store.clearDownloadQueue()
    }

    /// 仅限已下载内容 reads the downloaded filter as ✓ whatever it was set to (upstream), so a saved ✗ cannot empty the
    /// library; 章节获取时间 sorts by the newest chapter fetched.
    @MainActor
    func testDownloadedOnlyModeAndChapterFetchSort() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let titles = store.mangas.filter(\.favorite).prefix(2).map(\.id)
        store.chaptersByManga[titles[0]] = [Chapter(id: 9_400_001, mangaId: titles[0], url: "/a", name: "A", dateFetch: Date(timeIntervalSince1970: 1_000))]
        store.chaptersByManga[titles[1]] = [Chapter(id: 9_400_002, mangaId: titles[1], url: "/b", name: "B", dateFetch: Date(timeIntervalSince1970: 2_000))]
        store.downloadedChapterIds.insert(9_400_001)
        store.libraryFilter.filterDownloaded = .exclude
        store.downloadedOnlyMode = true
        XCTAssertEqual(store.libraryItems(forCategory: -1, searchQuery: "").map(\.id), [titles[0]])
        let manga = try XCTUnwrap(store.manga(id: titles[0]))
        XCTAssertEqual(store.filteredAndSortedChapters(for: manga).map(\.id), [9_400_001])

        store.downloadedOnlyMode = false
        store.libraryFilter.filterDownloaded = .disabled
        store.librarySortOption = .chapterFetchDate
        store.librarySortAscending = false
        let order = store.libraryItems(forCategory: -1, searchQuery: "").map(\.id).filter(titles.contains)
        XCTAssertEqual(order, [titles[1], titles[0]], "the newest fetch first")
    }

    /// Category names stay unique (upstream refuses a duplicate), and the default-category setting forgets a deleted
    /// category instead of pointing at whichever category gets its id next.
    @MainActor
    func testCategoryNamesAreUniqueAndDeletingTheDefaultResetsIt() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let existing = try XCTUnwrap(store.categories.first { !$0.isSystemCategory })
        let count = store.categories.count
        store.addCategory(name: " \(existing.name) ")
        XCTAssertEqual(store.categories.count, count)
        let other = try XCTUnwrap(store.categories.first { !$0.isSystemCategory && $0.id != existing.id })
        store.renameCategory(id: other.id, name: existing.name)
        XCTAssertEqual(store.categories.first { $0.id == other.id }?.name, other.name)

        store.defaultLibraryCategory = existing.id
        store.deleteCategory(id: existing.id)
        XCTAssertEqual(store.defaultLibraryCategory, -1)
    }

    /// A backup brings its own category ids: categories are matched by name and keep the ids they have here, so the
    /// default-category setting still names the same category.
    @MainActor
    func testRestoreKeepsTheDefaultCategoryByName() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let user = store.categories.filter { !$0.isSystemCategory }
        XCTAssertGreaterThanOrEqual(user.count, 2)
        store.defaultLibraryCategory = user[1].id

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try decoder.decode(MihonBackupPayload.self, from: store.createBackupJSONData())
        // The backup's categories carry each other's ids.
        let first = try XCTUnwrap(payload.backupCategories.firstIndex { $0.id == user[0].id })
        let second = try XCTUnwrap(payload.backupCategories.firstIndex { $0.id == user[1].id })
        payload.backupCategories[first].id = user[1].id
        payload.backupCategories[second].id = user[0].id
        try store.restoreFromBackupJSONData(encoder.encode(payload))

        XCTAssertEqual(store.defaultLibraryCategory, user[1].id)
        XCTAssertEqual(store.categories.filter { !$0.isSystemCategory }.map(\.id), user.map(\.id), "matched by name, none added")
    }

    /// The image cache is kept under its limit by dropping the files used longest ago (down to three quarters).
    func testDiskCacheTrimDropsTheLeastRecentlyUsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mihon-trim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MihonTwoTierImageCache(rootDirectory: root)
        let directory = root.appendingPathComponent("MihonChapterImageCache")
        for index in 0..<10 {
            let file = directory.appendingPathComponent("file\(index)")
            try Data(count: 1_000).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))], ofItemAtPath: file.path)
        }
        cache.trimDiskCache(pageLimit: 8_000)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(left, Set((4..<10).map { "file\($0)" }), "down to 6 000 bytes, oldest first")
        cache.trimDiskCache(pageLimit: 8_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 6, "under the limit: untouched")

        // Covers are trimmed apart from pages, and the library's are kept however old.
        let covers = root.appendingPathComponent("MihonCoverCache")
        let libraryCover = "https://example.invalid/library-cover.jpg"
        let kept = cache.cacheKey(for: libraryCover)
        for name in [kept, "old", "new"] {
            try Data(count: 1_000).write(to: covers.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: covers.appendingPathComponent(kept).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: covers.appendingPathComponent("old").path)
        cache.trimDiskCache(pageLimit: 8_000, coverLimit: 1_500, keepingCovers: [libraryCover])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: covers.path)), [kept, "new"])
    }

    /// Restoring merges (upstream `BackupRestorer`): titles already here stay, a chapter keeps whichever read and
    /// bookmark state is further along, the backup's new chapters, titles, categories and history are added.
    @MainActor
    func testRestoreMergesIntoTheLibrary() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let titles = store.mangas.filter(\.favorite).prefix(2).map(\.id)
        let kept = titles[0], other = titles[1]
        store.chaptersByManga[kept] = [Chapter(id: 9_300_001, mangaId: kept, url: "/m/1", name: "第1话", read: true)]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try decoder.decode(MihonBackupPayload.self, from: store.createBackupJSONData())

        // The backup (another device): chapter 1 unread but bookmarked, a chapter 2 read, a title of its own in a
        // category of its own, and without `other`.
        payload.backupManga.removeAll { $0.id == other }
        payload.backupChapters = [
            Chapter(id: 77, mangaId: kept, url: "/m/1", name: "第1话", bookmark: true),
            Chapter(id: 78, mangaId: kept, url: "/m/2", name: "第2话", read: true),
        ]
        payload.backupHistory = [HistoryEntry(id: 5, chapterId: 78, mangaId: kept, readAt: Date(timeIntervalSince1970: 2_000_000_000))]
        var extra = try XCTUnwrap(payload.backupManga.first)
        extra.id = 555
        extra.url = "/backup-only"
        extra.title = "备份里的作品"
        payload.backupManga.append(extra)
        payload.backupCategories.append(MangaCategory(id: 99, name: "备份分类", order: 9))
        payload.mangaCategoriesMap[555] = [99]
        try store.restoreFromBackupJSONData(encoder.encode(payload))

        XCTAssertTrue(store.manga(id: other)?.favorite == true, "a title missing from the backup stays")
        let chapters = try XCTUnwrap(store.chaptersByManga[kept])
        let first = try XCTUnwrap(chapters.first { $0.url == "/m/1" })
        XCTAssertEqual(first.id, 9_300_001)
        XCTAssertTrue(first.read && first.bookmark)
        let second = try XCTUnwrap(chapters.first { $0.url == "/m/2" })
        XCTAssertTrue(second.read)
        XCTAssertTrue(store.historyEntries.contains { $0.chapterId == second.id })
        let added = try XCTUnwrap(store.mangas.first { $0.url == "/backup-only" })
        XCTAssertNotEqual(added.id, 555, "a new id: 555 could be taken")
        let category = try XCTUnwrap(store.categories.first { $0.name == "备份分类" })
        XCTAssertEqual(store.mangaCategories[added.id], [category.id])
    }

    /// Upstream `mergeManga`: a restore only adds to the library. A title the backup has out of the library — even
    /// with a later change date — stays in it here (the restore dialog promises to keep what is there).
    @MainActor
    func testRestoreKeepsTitlesInTheLibrary() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = try XCTUnwrap(store.mangas.first { $0.favorite && $0.favoriteModifiedAt == nil })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try decoder.decode(MihonBackupPayload.self, from: store.createBackupJSONData())
        let index = try XCTUnwrap(payload.backupManga.firstIndex { $0.id == seeded.id })
        payload.backupManga[index].favorite = false
        payload.backupManga[index].favoriteModifiedAt = Date(timeIntervalSince1970: 1_900_000_000)
        try store.restoreFromBackupJSONData(encoder.encode(payload))
        XCTAssertTrue(try XCTUnwrap(store.manga(id: seeded.id)).favorite)
    }

    /// A title from a source this build has no engine for reads as 图源未安装 (upstream "Source not installed")
    /// instead of generated pages.
    @MainActor
    func testTitleFromAMissingSourceReportsIt() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        var manga = try XCTUnwrap(store.mangas.first)
        manga.id = 88_001
        manga.source = 7_777_777_777
        manga.url = "/missing"
        store.mangas.append(manga)
        let chapter = Chapter(id: 9_200_001, mangaId: manga.id, url: "/missing/1", name: "第1话")
        store.chaptersByManga[manga.id] = [chapter]
        do {
            _ = try await store.pageList(for: manga, chapter: chapter)
            XCTFail("no pages for a source this build lacks")
        } catch let error as ChapterPagesError {
            XCTAssertEqual(error, .sourceNotInstalled)
        }
    }

    /// Reading order follows the title's chapter sort, oldest first (upstream `getChapterSort`): by number alone an
    /// afterword recognized as 1 would come between chapters 1 and 2.
    @MainActor
    func testReadingOrderFollowsTheChapterSort() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first)
        XCTAssertEqual(manga.chapterSortMode, .source)
        store.chaptersByManga[manga.id] = []
        store.syncChaptersWithSource(mangaId: manga.id, sourceChapters: [
            SChapter(url: "/3", name: "第3话", chapterNumber: 3),
            SChapter(url: "/afterword", name: "【免费】第1季 后记", chapterNumber: 1),
            SChapter(url: "/2", name: "第2话", chapterNumber: 2),
            SChapter(url: "/1", name: "第1话", chapterNumber: 1),
        ])
        XCTAssertEqual(store.readingOrderChapters(mangaId: manga.id).map(\.url), ["/1", "/2", "/afterword", "/3"])
        XCTAssertEqual(store.nextUnreadChapter(for: manga.id)?.url, "/1")
    }

    /// A library saved before version 6 frees MangaDex titles that "completed" (the original) had set to fetch once.
    @MainActor
    func testMangaDexTitlesFinishedInTheOriginalUpdateAgain() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let seeded = store.mangas
        let seededCategories = store.mangaCategories
        let index = try XCTUnwrap(store.mangas.firstIndex { $0.source == MihonSeedData.MangaDexSourceId.simplifiedChinese })
        store.mangas[index].status = .completed
        store.mangas[index].updateStrategy = .onlyFetchOnce
        let dongman = try XCTUnwrap(store.mangas.firstIndex { $0.source == MihonSeedData.dongmanSourceId })
        store.mangas[dongman].updateStrategy = .onlyFetchOnce
        store.migrateRestoredLibrary(fromSeedVersion: 5, seeded: seeded, seededCategories: seededCategories)
        XCTAssertEqual(store.mangas[index].updateStrategy, .alwaysUpdate)
        XCTAssertEqual(store.mangas[index].status, .publishingFinished)
        XCTAssertEqual(store.mangas[dongman].updateStrategy, .onlyFetchOnce, "a finished 咚漫 title stays finished")
    }

    /// A backup file is checked before anything is replaced: its library's titles are counted, and a file that is
    /// not a backup is refused.
    @MainActor
    func testBackupFileIsCheckedBeforeRestoring() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let backup = try store.createBackupJSONData()
        XCTAssertEqual(try store.libraryTitleCount(inBackup: backup), store.mangas.filter(\.favorite).count)
        XCTAssertThrowsError(try store.libraryTitleCount(inBackup: Data(#"{"hello": "world"}"#.utf8)))
    }

    /// Only the Duo's inner display, open like a book, has a hinge down its middle; no single-screen iPhone is that
    /// wide, and the Duo's cover display is not either.
    func testHingeNeedsTheDuoInnerDisplayInLandscape() {
        XCTAssertTrue(MihonRepositoryStore.isOpenBookShaped(CGSize(width: 951, height: 669)))
        XCTAssertFalse(MihonRepositoryStore.isOpenBookShaped(CGSize(width: 669, height: 951)), "turned upright")
        XCTAssertFalse(MihonRepositoryStore.isOpenBookShaped(CGSize(width: 678, height: 466)), "cover display")
        XCTAssertFalse(MihonRepositoryStore.isOpenBookShaped(CGSize(width: 956, height: 440)), "iPhone Pro Max")
    }

    /// A shared image load stops once every caller waiting for it is cancelled (cells scrolled away, the reader's
    /// slider dragged on), and a caller arriving afterwards starts a new load instead of joining the dead one.
    func testCancelledImageLoadsStopAndLaterCallersStartAgain() async throws {
        let coordinator = MihonImageLoadCoordinator()
        let png = try XCTUnwrap(Self.onePixelPNG())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let started = Date()
        let first = Task {
            await coordinator.image(forKey: "page", priority: .utility) {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                return Task.isCancelled ? nil : image
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the load was cancelled, not waited out")

        let again = await coordinator.image(forKey: "page", priority: .utility) { image }
        XCTAssertNotNil(again)
    }

    private static func onePixelPNG() -> Data? {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Bytes that are not an image never reach the disk cache (a captive portal answering 200, say).
    func testImageCacheRefusesNonImages() {
        let key = "https://images.zaimanhua.com/img/test-\(UUID().uuidString).jpg?sign=1&t=2"
        XCTAssertFalse(MihonTwoTierImageCache.shared.storeRawData(Data("<html>login</html>".utf8), forKey: key))
        XCTAssertFalse(MihonTwoTierImageCache.shared.hasDiskEntry(for: key))
    }

    /// The library update runs to the end and counts what it finds (offline: live favourites are left out, demo
    /// entries simulate one new chapter).
    @MainActor
    func testLibraryUpdateCompletes() async {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        for index in store.mangas.indices where store.isLiveSource(store.mangas[index].source) {
            store.mangas[index].favorite = false
        }
        // The demo entries have unread chapters, which 智能更新 skips.
        store.libraryUpdateMangaRestrictions = []
        await store.refreshLibraryUpdates()
        XCTAssertFalse(store.isUpdatingLibrary)
        XCTAssertEqual(store.newUpdatesCount, 1)
        XCTAssertEqual(store.libraryUpdateProgress, 1, accuracy: 0.001)
    }

    @MainActor
    func testIncognitoModeSuppressesHistoryAndTrackerSync() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let historyCountBefore = store.historyEntries.count
        store.incognitoMode = true
        let before = try XCTUnwrap(store.chaptersByManga[101]?.first { !$0.read })
        let tracksBefore = store.tracksByManga[101]?.map(\.lastChapterRead)

        store.recordReadingProgress(mangaId: 101, chapterId: before.id, pageIndex: 17, completedChapter: true)
        // Incognito saves nothing (upstream `updateChapterProgress`): no history, page, read mark or tracker progress.
        XCTAssertEqual(store.historyEntries.count, historyCountBefore)
        let after = try XCTUnwrap(store.chaptersByManga[101]?.first { $0.id == before.id })
        XCTAssertFalse(after.read)
        XCTAssertEqual(after.lastPageRead, before.lastPageRead)
        XCTAssertEqual(store.tracksByManga[101]?.map(\.lastChapterRead), tracksBefore)
    }

    @MainActor
    func testIPhoneDuoPostureAndBookSpreadAdaptation() {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.duoPostureMode = .autoDetect

        // Folded single screen (e.g. 393 x 852)
        XCTAssertFalse(store.isUnfoldedDuo(viewportSize: CGSize(width: 393, height: 852), horizontalSizeClass: .compact))

        // Unfolded iPhone Duo book posture (e.g. 880 x 852 or regular size class)
        XCTAssertTrue(store.isUnfoldedDuo(viewportSize: CGSize(width: 880, height: 852), horizontalSizeClass: .regular))

        // Explicit posture override
        store.duoPostureMode = .unfoldedBook
        XCTAssertTrue(store.isUnfoldedDuo(viewportSize: CGSize(width: 393, height: 852), horizontalSizeClass: .compact))
    }

    @MainActor
    func testAutomatedIPhoneDuoVisualSnapshotsAndEndToEndFlow() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        await store.bootstrapInstalledAPKSources()

        // 1. Install an available extension via APK Engine
        if let manhuaDbExt = store.extensions.first(where: { $0.pkgName.contains("manhuadb") }) {
            await store.inspectAndInstallExtensionApk(manhuaDbExt)
        }
        let installedCount = store.extensions.filter { $0.installState == .installed }.count
        XCTAssertGreaterThanOrEqual(installedCount, 4)

        // 2. Render Snapshot 1: iPhone Duo Unfolded Book Split-Screen (880 x 852)
        store.duoPostureMode = .unfoldedBook
        let rootSnapshotView = MihonRootView(store: store)
            .frame(width: 880, height: 852)
            .environment(\.colorScheme, .dark)

        try saveViewSnapshot(
            view: rootSnapshotView,
            size: CGSize(width: 880, height: 852),
            path: "/tmp/iphone_duo_unfolded_split_library_detail.png"
        )

        // 3. Render Snapshot 2: iPhone Duo Dual-Page Book Spread Reader (880 x 852, showing Page 1 & Page 2 side by side)
        store.duoDualPageBehavior = .alwaysDualPage
        store.shiftDoublePageCover = false
        let manga = store.mangas[0]
        var chapter = store.chaptersByManga[manga.id]![0]
        chapter.lastPageRead = 0

        let readerView = MangaReaderScreen(
            manga: manga,
            initialChapter: chapter,
            onClose: {}
        )
        .environment(store)
        .frame(width: 880, height: 852)
        .environment(\.colorScheme, .dark)

        try saveViewSnapshot(
            view: readerView,
            size: CGSize(width: 880, height: 852),
            path: "/tmp/iphone_duo_unfolded_dual_page_reader.png"
        )

        // 4. Render Snapshot 3: APK APK/DEX Bytecode Inspector Sheet
        let copyExt = store.extensions[0]
        let inspectorSheetView = APKExtensionInspectorSheet(extensionModel: copyExt)
            .environment(store)
            .frame(width: 680, height: 760)
            .environment(\.colorScheme, .dark)

        try saveViewSnapshot(
            view: inspectorSheetView,
            size: CGSize(width: 680, height: 760),
            path: "/tmp/iphone_duo_apk_dex_inspector.png"
        )
    }

    @MainActor
    private func saveViewSnapshot<V: View>(view: V, size: CGSize, path: String) throws {
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Failed to create bitmap representation")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to encode PNG")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testChapterRecognitionAndSmartFetchInterval() {
        let num1 = ChapterRecognition.parseChapterNumber(
            mangaTitle: "Sousou no Frieren",
            chapterName: "Sousou no Frieren Vol. 5 Ch. 42.5 - Golden Land"
        )
        XCTAssertEqual(num1, 42.5, accuracy: 0.001)

        let num2 = ChapterRecognition.parseChapterNumber(
            mangaTitle: "葬送的芙莉莲",
            chapterName: "葬送的芙莉莲 第 128 话 帝国的阴影"
        )
        XCTAssertEqual(num2, 128.0, accuracy: 0.001)

        let now = Date()
        let weeklyChapters = (0..<6).map { i in
            Chapter(
                id: Int64(i),
                mangaId: 101,
                url: "/c/\(i)",
                name: "Ch.\(i)",
                dateUpload: now.addingTimeInterval(TimeInterval(-i * 7 * 86400))
            )
        }
        let schedule = ReleaseSchedule.estimate(weeklyChapters, timeZone: .current, today: MihonLocalDate(now, in: .current))
        XCTAssertEqual(schedule.interval, 7)
    }

    func testPixelLevelBorderCropperAndTallWebtoonSplitter() {
        // 1. Create a 200x200 image with a 20px white border and a 160x160 gray center
        let width = 200
        let height = 200
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Fill white border
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Fill inner manga panel (gray)
        context.setFillColor(red: 0.35, green: 0.35, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 20, y: 20, width: 160, height: 160))

        let rawImage = context.makeImage()!
        let cropped = MihonImageProcessor.cropWhiteOrBlackBorders(from: rawImage)
        XCTAssertLessThan(cropped.width, rawImage.width)
        XCTAssertLessThan(cropped.height, rawImage.height)
        XCTAssertEqual(cropped.width, 160, accuracy: 4)
        XCTAssertEqual(cropped.height, 160, accuracy: 4)

        // 2. Test Tall Webtoon Image Splitter (5000px height -> 2 GPU-safe slices)
        let tallCtx = CGContext(
            data: nil,
            width: 800,
            height: 5000,
            bitsPerComponent: 8,
            bytesPerRow: 800 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let tallImage = tallCtx.makeImage()!
        let slices = MihonImageProcessor.splitTallWebtoonImage(tallImage, maxSliceHeight: 3072)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].height, 3072)
        XCTAssertEqual(slices[1].height, 1928)
    }
}
