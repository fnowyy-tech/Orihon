import XCTest
@testable import MihonDomain
@testable import MihonData
@testable import MihonPresentation

/// Automatic library updates: what an update reports, the notification, and the schedule.
final class MihonLibraryUpdateTests: XCTestCase {
    func testNotificationText() {
        XCTAssertNil(LibraryUpdateResult().notificationBody, "nothing new, no notification")
        let one = LibraryUpdateResult(newChapters: 4, titles: [.init(mangaId: 1, title: "海贼王", chapterNames: ["第1100话", "第1101话", "第1102话", "第1103话"])])
        XCTAssertEqual(one.notificationBody, "海贼王：第1100话、第1101话、第1102话 等 4 个章节")
        let two = LibraryUpdateResult(newChapters: 2, titles: [
            .init(mangaId: 1, title: "海贼王", chapterNames: ["第1100话"]),
            .init(mangaId: 2, title: "咒术回战", chapterNames: ["第270话"]),
        ])
        XCTAssertEqual(two.notificationBody, "海贼王、咒术回战")
        let many = LibraryUpdateResult(newChapters: 4, titles: (1...4).map { .init(mangaId: Int64($0), title: "作品\($0)", chapterNames: ["新"]) })
        XCTAssertEqual(many.notificationBody, "作品1、作品2、作品3 等 4 部作品")
        XCTAssertEqual(MihonLibraryUpdateScheduler.notificationBody(many, hidingTitles: true), "4 个新章节", "the app is locked")
        XCTAssertEqual(MihonLibraryUpdateScheduler.notificationBody(many, hidingTitles: false), many.notificationBody)
    }

    func testNextRunIsAnIntervalAfterTheLastUpdate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MihonLibraryUpdateScheduler.nextRun(interval: 24, lastUpdate: now.addingTimeInterval(-3600), now: now),
                       now.addingTimeInterval(23 * 3600))
        XCTAssertEqual(MihonLibraryUpdateScheduler.nextRun(interval: 12, lastUpdate: nil, now: now), now.addingTimeInterval(12 * 3600))
        XCTAssertEqual(MihonLibraryUpdateScheduler.nextRun(interval: 12, lastUpdate: now.addingTimeInterval(-86_400), now: now),
                       now.addingTimeInterval(15 * 60), "overdue: soon, not in the past")
        XCTAssertEqual(MihonLibraryUpdateInterval.choices.map(MihonLibraryUpdateInterval.title(hours:)),
                       ["关闭", "每 12 小时", "每天", "每 2 天", "每 3 天", "每周"])
    }

    /// The update reports the titles that got chapters (a local title: no network needed).
    @MainActor
    func testUpdateReportsNewChaptersByTitle() async throws {
        let name = "更新测试-\(UUID().uuidString.prefix(8))"
        let title = MihonLocalStorage.defaultRootDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: title.appendingPathComponent("第1话"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: title) }
        try Data([1]).write(to: title.appendingPathComponent("第1话/1.png"))

        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        // About reporting: 智能更新 would skip a title with an unread chapter, just fetched.
        store.libraryUpdateMangaRestrictions = []
        let manga = store.upsertCatalogMangaToStore(SManga(url: name, title: name), sourceId: MihonLocalSource.sourceId)
        store.addToLibrary(mangaId: manga.id, categoryIds: [])
        await store.refreshMangaFromSource(mangaId: manga.id)
        // Only this title: the seed library's would go to the network.
        for other in store.mangas where other.favorite && other.id != manga.id {
            store.removeFromLibrary(mangaId: other.id)
        }
        try FileManager.default.createDirectory(at: title.appendingPathComponent("第2话"), withIntermediateDirectories: true)
        try Data([1]).write(to: title.appendingPathComponent("第2话/1.png"))
        store.statusBannerMessage = nil
        store.libraryUpdateCheckedAt[-42] = Date()

        let result = await store.refreshLibraryUpdates(reportsResult: false)
        XCTAssertNotNil(store.libraryUpdateCheckedAt[manga.id], "the next update starts with titles checked longest ago")
        XCTAssertNil(store.libraryUpdateCheckedAt[-42], "titles gone are forgotten")
        XCTAssertEqual(result.newChapters, 1)
        XCTAssertEqual(result.titles.map(\.title), [name])
        XCTAssertEqual(result.titles.first?.chapterNames, ["第2话"])
        XCTAssertNil(store.statusBannerMessage, "a background update notifies instead")
        XCTAssertNotNil(store.lastLibraryUpdateAt)
    }

    /// Upstream "Auto download while reading": only when the current and the next chapter are downloaded, then the
    /// next N unread chapters counted from the next one (`getNextChapters(…, next).take(n)`). Demo titles download
    /// offline (simulated).
    @MainActor
    func testDownloadAheadFollowsUpstream() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let manga = try XCTUnwrap(store.mangas.first { manga in
            !store.isLiveSource(manga.source) && store.readingOrderChapters(mangaId: manga.id).filter { !$0.read }.count >= 5
        })
        let order = store.readingOrderChapters(mangaId: manga.id)
        let start = try XCTUnwrap(order.firstIndex { !$0.read })
        let current = order[start], next = order[start + 1]
        func queued(_ chapter: Chapter) -> Bool { store.downloadState(for: chapter, in: manga) != .notDownloaded }
        let following = order[(start + 2)...].filter { !$0.read }

        store.downloadAhead(after: current, in: manga)
        XCTAssertFalse(following.contains(where: queued), "off by default")
        store.downloadAheadCount = 3
        store.downloadAhead(after: current, in: manga)
        XCTAssertFalse(following.contains(where: queued), "reading online")
        store.downloadedChapterIds.insert(current.id)
        store.downloadAhead(after: current, in: manga)
        XCTAssertFalse(following.contains(where: queued), "the next chapter is not downloaded")
        store.downloadedChapterIds.insert(next.id)
        store.downloadAhead(after: current, in: manga)
        XCTAssertTrue(following.prefix(2).allSatisfy(queued), "three counted from the (downloaded) next one: two more")
        XCTAssertFalse(following.dropFirst(2).first.map(queued) ?? false, "no more than that")
    }

    /// Upstream `Downloader.queueChapters`: oldest first, so what is read next comes first.
    @MainActor
    func testDownloadsQueueOldestFirst() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let manga = try XCTUnwrap(store.mangas.first { manga in
            !store.isLiveSource(manga.source) && (store.chaptersByManga[manga.id] ?? []).filter { !store.downloadedChapterIds.contains($0.id) }.count >= 3
        })
        store.toggleDownloaderRunning()
        let pending = (store.chaptersByManga[manga.id] ?? []).filter { !store.downloadedChapterIds.contains($0.id) }
        let picked = Array(pending.sorted { $0.sourceOrder < $1.sourceOrder }.prefix(3))
        store.enqueueChapterDownloads(manga: manga, chapters: picked)
        let queuedIds = store.downloadQueue.map(\.chapter.id).filter { id in picked.contains { $0.id == id } }
        XCTAssertEqual(queuedIds, picked.sorted { $0.sourceOrder > $1.sourceOrder }.map(\.id))
    }

    /// A chapter a re-added listing took over (read before, same number) is not new — the one that is,
    /// gets named and downloaded.
    @MainActor
    func testReaddedChaptersAreNotNew() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = try XCTUnwrap(store.mangas.first { $0.favorite })
        store.chaptersByManga[manga.id] = [
            Chapter(id: 9_400_001, mangaId: manga.id, url: "/c/51-a", name: "第51话", read: true, chapterNumber: 51),
            Chapter(id: 9_400_002, mangaId: manga.id, url: "/c/49", name: "第49话", read: true, chapterNumber: 49),
        ]
        let fresh = store.syncNewChapters(mangaId: manga.id, sourceChapters: [
            SChapter(url: "/c/51-b", name: "第51话", chapterNumber: 51),
            SChapter(url: "/c/50", name: "第50话", chapterNumber: 50),
            SChapter(url: "/c/49", name: "第49话", chapterNumber: 49),
        ])
        XCTAssertEqual(fresh.map(\.url), ["/c/50"], "51 came back under another URL: read, not new")
    }

    @MainActor
    func testNewChaptersAreQueuedForTitlesInTheLibrary() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let manga = try XCTUnwrap(store.mangas.first { manga in
            manga.favorite && !store.isLiveSource(manga.source) && store.readingOrderChapters(mangaId: manga.id).contains { !$0.read }
        })
        let fresh = try XCTUnwrap(store.readingOrderChapters(mangaId: manga.id).last { !$0.read && !store.downloadedChapterIds.contains($0.id) })
        let result = LibraryUpdateResult(newChapters: 1, titles: [.init(mangaId: manga.id, title: manga.title, chapterNames: [fresh.name], chapterIds: [fresh.id])])
        store.queueNewChapterDownloads(result)
        XCTAssertNotEqual(store.downloadState(for: fresh, in: manga), .notDownloaded)

        let browsed = try XCTUnwrap(store.mangas.first { !$0.favorite && !(store.chaptersByManga[$0.id] ?? []).isEmpty } ?? {
            var copy = manga
            copy.id = 77_001
            copy.favorite = false
            store.mangas.append(copy)
            store.chaptersByManga[copy.id] = [Chapter(id: 9_300_001, mangaId: copy.id, url: "/x/1", name: "第1话")]
            return copy
        }())
        let browsedChapter = try XCTUnwrap(store.chaptersByManga[browsed.id]?.first)
        store.queueNewChapterDownloads(LibraryUpdateResult(newChapters: 1, titles: [.init(mangaId: browsed.id, title: browsed.title, chapterNames: [], chapterIds: [browsedChapter.id])]))
        XCTAssertEqual(store.downloadState(for: browsedChapter, in: browsed), .notDownloaded, "not in the library")

        let saved = MihonSettingsSnapshot(downloadNewChapters: true, downloadAheadCount: 5)
        let restored = MihonRepositoryStore(bootstrapNetwork: false)
        restored.apply(try JSONDecoder().decode(MihonSettingsSnapshot.self, from: JSONEncoder().encode(saved)))
        XCTAssertTrue(restored.downloadNewChapters)
        XCTAssertEqual(restored.downloadAheadCount, 5)
    }

    @MainActor
    func testAutoUpdateSettingIsSaved() throws {
        let saved = MihonSettingsSnapshot(autoUpdateInterval: 48)
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        XCTAssertEqual(store.autoUpdateInterval, 0, "off by default, as upstream")
        store.apply(try JSONDecoder().decode(MihonSettingsSnapshot.self, from: JSONEncoder().encode(saved)))
        XCTAssertEqual(store.autoUpdateInterval, 48)
        store.apply(try JSONDecoder().decode(MihonSettingsSnapshot.self, from: Data(#"{"autoUpdateInterval":5}"#.utf8)))
        XCTAssertEqual(store.autoUpdateInterval, 48, "not one of the choices: ignored")
    }

    // MARK: Smart update and categories (upstream `LibraryUpdateJob.addMangaToQueue`)

    private func chapters(_ mangaId: Int64, read: [Bool]) -> [Chapter] {
        read.enumerated().map { index, isRead in
            Chapter(id: 900_000 + mangaId * 100 + Int64(index), mangaId: mangaId, url: "/c/\(mangaId)/\(index)", name: "第\(index + 1)话", read: isRead)
        }
    }

    /// Each rule leaves out its titles; a title set to fetch once is left out once fetched, whatever the rules.
    @MainActor
    func testSmartUpdateSkipsWhatUpstreamSkips() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        XCTAssertEqual(store.libraryUpdateMangaRestrictions, Set(LibraryUpdateMangaRestriction.allCases), "upstream's default: all four")
        let window = FetchInterval.window(today: MihonLocalDate(Date(), in: .current), timeZone: .current)
        let ids = store.mangas.filter(\.favorite).prefix(7).map(\.id)
        XCTAssertEqual(ids.count, 7)
        func set(_ index: Int, read: [Bool], status: MangaStatus = .ongoing, nextUpdate: Date? = nil, strategy: UpdateStrategy = .alwaysUpdate) {
            let at = store.mangas.firstIndex { $0.id == ids[index] }!
            store.mangas[at].status = status
            store.mangas[at].nextUpdate = nextUpdate
            store.mangas[at].updateStrategy = strategy
            store.chaptersByManga[ids[index]] = chapters(ids[index], read: read)
        }
        set(0, read: [true, true])
        set(1, read: [true, false])
        set(2, read: [true], status: .completed)
        set(3, read: [true], nextUpdate: window.upperBound.addingTimeInterval(86_400))
        set(4, read: [true], strategy: .onlyFetchOnce)
        set(5, read: [], strategy: .onlyFetchOnce)
        set(6, read: [false, false])
        func skip(_ index: Int) -> MihonRepositoryStore.LibraryUpdateSkip? {
            store.libraryUpdateSkip(store.manga(id: ids[index])!, window: window)
        }
        XCTAssertNil(skip(0), "caught up")
        XCTAssertEqual(skip(1), .smartUpdate(.hasUnread))
        XCTAssertEqual(skip(2), .smartUpdate(.completed))
        XCTAssertEqual(skip(3), .smartUpdate(.outsideReleasePeriod))
        XCTAssertEqual(skip(4), .fetchedOnce)
        XCTAssertNil(skip(5), "fetched once means once: still to fetch")
        XCTAssertEqual(skip(6), .smartUpdate(.hasUnread), "an unstarted title has unread chapters too")

        store.libraryUpdateMangaRestrictions = [.notStarted]
        XCTAssertEqual(skip(6), .smartUpdate(.notStarted))
        XCTAssertNil(skip(1), "started")
        XCTAssertNil(skip(2))
        XCTAssertNil(skip(3))

        store.libraryUpdateMangaRestrictions = []
        XCTAssertEqual(ids.map { store.libraryUpdateSkip(store.manga(id: $0)!, window: window) }.compactMap { $0 }, [.fetchedOnce])
        store.libraryUpdateMangaRestrictions = LibraryUpdateMangaRestriction.defaults
        let queue = store.libraryUpdateQueue(categoryId: nil, window: window)
        XCTAssertTrue(queue.titles.contains { $0.id == ids[0] })
        XCTAssertFalse(queue.titles.contains { [1, 2, 3, 4, 6].map { ids[$0] }.contains($0.id) })
        XCTAssertEqual(Set([1, 2, 3, 6].map { ids[$0] }).subtracting(queue.skipped.map(\.id)), [], "the ones a rule skipped")
        XCTAssertFalse(queue.skipped.contains { $0.id == ids[4] }, "fetched once is not a 智能更新 skip")
    }

    /// A global update takes the included categories (all when none is) less the excluded ones; a category's own
    /// update takes that category whatever the lists say; a deleted category leaves both lists.
    @MainActor
    func testUpdateCategoriesIncludeAndExclude() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.libraryUpdateMangaRestrictions = []
        let window = FetchInterval.window(today: MihonLocalDate(Date(), in: .current), timeZone: .current)
        store.addCategory(name: "甲")
        store.addCategory(name: "乙")
        let a = try XCTUnwrap(store.categories.first { $0.name == "甲" }?.id)
        let b = try XCTUnwrap(store.categories.first { $0.name == "乙" }?.id)
        let ids = store.mangas.filter(\.favorite).map(\.id)
        for id in ids { store.setCategoriesForManga(mangaId: id, categoryIds: []) }
        store.setCategoriesForManga(mangaId: ids[0], categoryIds: [a])
        store.setCategoriesForManga(mangaId: ids[1], categoryIds: [b])
        store.setCategoriesForManga(mangaId: ids[2], categoryIds: [a, b])
        func queued(_ categoryId: Int64? = nil) -> Set<Int64> {
            Set(store.libraryUpdateQueue(categoryId: categoryId, window: window).titles.map(\.id))
        }

        XCTAssertEqual(queued(), Set(ids), "nothing chosen: everything")
        store.libraryUpdateIncludedCategories = [a]
        XCTAssertEqual(queued(), [ids[0], ids[2]])
        store.libraryUpdateExcludedCategories = [b]
        XCTAssertEqual(queued(), [ids[0]], "excluding wins over including")
        store.libraryUpdateIncludedCategories = []
        store.libraryUpdateExcludedCategories = [MangaCategory.defaultCategoryId]
        XCTAssertEqual(queued(), [ids[0], ids[1], ids[2]], "titles in no category are in 默认")
        store.libraryUpdateExcludedCategories = [b]
        XCTAssertEqual(queued(b), [ids[1], ids[2]], "a category's own update")

        store.libraryUpdateIncludedCategories = [a]
        store.deleteCategory(id: a)
        XCTAssertEqual(store.libraryUpdateIncludedCategories, [], "not left including a category that is gone")
        XCTAssertFalse(queued().isEmpty)
    }

    /// Upstream's WorkManager constraints, as a background refresh checks them.
    func testDeviceRestrictions() {
        let wifi = MihonNetworkState(isConnected: true, isWiFi: true, isMetered: false)
        let hotspot = MihonNetworkState(isConnected: true, isWiFi: true, isMetered: true)
        let cellular = MihonNetworkState(isConnected: true, isWiFi: false, isMetered: true)
        let offline = MihonNetworkState(isConnected: false, isWiFi: false, isMetered: false)
        let allow = LibraryUpdateDeviceRestriction.allow
        XCTAssertEqual(LibraryUpdateDeviceRestriction.defaults, [.onlyOnWiFi], "upstream's default")
        XCTAssertTrue(allow([.onlyOnWiFi], wifi, false))
        XCTAssertFalse(allow([.onlyOnWiFi], cellular, true))
        XCTAssertTrue(allow([.onlyOnWiFi], hotspot, false), "Wi-Fi to a phone's hotspot is still Wi-Fi")
        XCTAssertFalse(allow([.networkNotMetered], hotspot, false))
        XCTAssertFalse(allow([.networkNotMetered], cellular, false))
        XCTAssertTrue(allow([.networkNotMetered], wifi, false))
        XCTAssertFalse(allow([.charging], wifi, false))
        XCTAssertTrue(allow([.charging], cellular, true))
        XCTAssertTrue(allow([], cellular, false))
        XCTAssertFalse(allow([], offline, true), "never without a network")
    }

    /// Upstream `SyncChaptersWithSource`: a changed list is the title's last update and works its next one out; an
    /// unchanged one leaves both until the next update has passed or the user refreshes.
    @MainActor
    func testChapterSyncSchedulesTheNextUpdate() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let manga = store.upsertCatalogMangaToStore(SManga(url: "/schedule-test", title: "排期"), sourceId: MihonLocalSource.sourceId)
        let now = Date()
        let window = FetchInterval.window(today: MihonLocalDate(now, in: .current), timeZone: .current)
        // Weekly, the last one two days ago.
        var listing = (0..<10).map { week in
            SChapter(url: "/schedule-test/\(week)", name: "第\(10 - week)话", dateUpload: now.addingTimeInterval(-Double(2 + week * 7) * 86_400))
        }
        store.syncNewChapters(mangaId: manga.id, sourceChapters: listing)
        let first = try XCTUnwrap(store.manga(id: manga.id))
        XCTAssertEqual(first.fetchInterval, 7)
        let firstNext = try XCTUnwrap(first.nextUpdate)
        XCTAssertGreaterThan(firstNext, now, "due again in about five days")
        XCTAssertNotNil(first.lastUpdate)

        // Unchanged, next update ahead: nothing moves.
        let lastUpdate = first.lastUpdate
        store.syncNewChapters(mangaId: manga.id, sourceChapters: listing, fetchWindow: window)
        XCTAssertEqual(store.manga(id: manga.id)?.nextUpdate, firstNext)
        XCTAssertEqual(store.manga(id: manga.id)?.lastUpdate, lastUpdate, "the list did not change")

        // Unchanged but the next update has passed: worked out again.
        let at = try XCTUnwrap(store.mangas.firstIndex { $0.id == manga.id })
        store.mangas[at].nextUpdate = window.lowerBound.addingTimeInterval(-86_400)
        store.syncNewChapters(mangaId: manga.id, sourceChapters: listing, fetchWindow: window)
        XCTAssertEqual(store.manga(id: manga.id)?.nextUpdate, firstNext)

        // A new chapter is a release: counted from it.
        listing.insert(SChapter(url: "/schedule-test/new", name: "第11话", dateUpload: now), at: 0)
        let fresh = store.syncNewChapters(mangaId: manga.id, sourceChapters: listing, fetchWindow: window)
        XCTAssertEqual(fresh.map(\.name), ["第11话"])
        let afterRelease = try XCTUnwrap(store.manga(id: manga.id))
        XCTAssertGreaterThan(try XCTUnwrap(afterRelease.lastUpdate), try XCTUnwrap(lastUpdate))
        XCTAssertGreaterThan(try XCTUnwrap(afterRelease.nextUpdate), window.upperBound, "the next one is not due today")
    }

    /// A manual update that 智能更新 cut short says so, and where to change it.
    @MainActor
    func testManualUpdateReportsSkippedTitles() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let library = store.mangas.filter(\.favorite)
        for manga in library {
            store.chaptersByManga[manga.id] = chapters(manga.id, read: [false])
        }
        store.statusBannerMessage = nil
        let result = await store.refreshLibraryUpdates()
        // Every title has an unread chapter, so no network at all; those set to fetch once are left out uncounted.
        let counted = library.filter { $0.updateStrategy == .alwaysUpdate }.count
        XCTAssertGreaterThan(counted, 0)
        XCTAssertEqual(result.skipped, counted)
        XCTAssertEqual(store.statusBannerMessage, "书架更新完成，没有新章节。智能更新跳过了 \(counted) 部作品（设置 › 书架 › 智能更新）")
    }

    @MainActor
    func testUpdateRestrictionsAreSaved() throws {
        var saved = MihonSettingsSnapshot()
        saved.libraryUpdateDeviceRestrictions = [.charging, .networkNotMetered]
        saved.libraryUpdateMangaRestrictions = [.completed]
        saved.libraryUpdateIncludedCategories = [3]
        saved.libraryUpdateExcludedCategories = [0]
        saved.libraryUpdateRefreshesMetadata = true
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.apply(try JSONDecoder().decode(MihonSettingsSnapshot.self, from: JSONEncoder().encode(saved)))
        XCTAssertEqual(store.libraryUpdateDeviceRestrictions, [.charging, .networkNotMetered])
        XCTAssertEqual(store.libraryUpdateMangaRestrictions, [.completed])
        XCTAssertEqual(store.libraryUpdateIncludedCategories, [3])
        XCTAssertEqual(store.libraryUpdateExcludedCategories, [0])
        XCTAssertTrue(store.libraryUpdateRefreshesMetadata)
        XCTAssertEqual(store.settingsSnapshot.libraryUpdateMangaRestrictions, [.completed])
    }

    /// Next updates saved before the release schedule port are worked out again once, from the chapters: "not expected
    /// yet" must not trust them, and a title 智能更新 skips would never get a new one. Titles never fetched keep none.
    @MainActor
    func testOldNextUpdatesAreWorkedOutAgain() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let favorites = store.mangas.indices.filter { store.mangas[$0].favorite }
        let (fetched, unfetched) = (favorites[0], favorites[1])
        let old = Date().addingTimeInterval(40 * 86_400)
        store.mangas[fetched].nextUpdate = old
        store.mangas[unfetched].nextUpdate = old
        // Weekly, the last one two days ago, none read: skipped by 智能更新.
        store.chaptersByManga[store.mangas[fetched].id] = (0..<6).map { week in
            Chapter(id: 990_000 + Int64(week), mangaId: store.mangas[fetched].id, url: "/c/\(week)", name: "第\(6 - week)话",
                    dateUpload: Date().addingTimeInterval(-Double(2 + week * 7) * 86_400))
        }
        store.chaptersByManga[store.mangas[unfetched].id] = []

        store.migrateRestoredLibrary(fromSeedVersion: 6, seeded: [], seededCategories: [:])
        let next = try XCTUnwrap(store.mangas[fetched].nextUpdate)
        XCTAssertLessThan(next, Date().addingTimeInterval(8 * 86_400), "worked out again: in about five days")
        XCTAssertEqual(store.mangas[fetched].fetchInterval, 7)
        XCTAssertNil(store.mangas[unfetched].nextUpdate, "nothing to estimate from")
    }

    // MARK: Upcoming and the next update button (upstream `GetUpcomingManga`, `MangaActionRow`, `SetIntervalDialog`)

    /// Library titles expected from today on, ongoing or publishing finished, earliest first, in the shown categories.
    @MainActor
    func testUpcomingListsWhatUpstreamLists() throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        let ids = store.mangas.filter(\.favorite).prefix(6).map(\.id)
        let today = Calendar.current.startOfDay(for: Date())
        func set(_ index: Int, days: Double?, status: MangaStatus = .ongoing, favorite: Bool = true) {
            let at = store.mangas.firstIndex { $0.id == ids[index] }!
            store.mangas[at].nextUpdate = days.map { today.addingTimeInterval($0 * 86_400) }
            store.mangas[at].status = status
            store.mangas[at].favorite = favorite
        }
        for index in store.mangas.indices where !ids.contains(store.mangas[index].id) { store.mangas[index].nextUpdate = nil }
        set(0, days: 3)
        set(1, days: 0, status: .publishingFinished)
        set(2, days: 1, status: .completed)
        set(3, days: -1)
        set(4, days: 2, favorite: false)
        set(5, days: 5, status: .unknown)
        XCTAssertEqual(store.upcomingManga().map(\.id), [ids[1], ids[0]], "today's first; completed, past, outside the library and unknown left out")

        store.addCategory(name: "周更")
        let weekly = try XCTUnwrap(store.categories.first { $0.name == "周更" }?.id)
        store.setCategoriesForManga(mangaId: ids[0], categoryIds: [weekly])
        store.setCategoriesForManga(mangaId: ids[1], categoryIds: [])
        store.upcomingIncludedCategories = [weekly]
        XCTAssertEqual(store.upcomingManga().map(\.id), [ids[0]])
        store.upcomingIncludedCategories = []
        store.upcomingExcludedCategories = [MangaCategory.defaultCategoryId]
        XCTAssertEqual(store.upcomingManga().map(\.id), [ids[0]], "titles in no category count as 默认")
        store.deleteCategory(id: weekly)
        XCTAssertEqual(store.upcomingExcludedCategories, [MangaCategory.defaultCategoryId])
        store.upcomingIncludedCategories = [weekly]
        store.deleteCategory(id: weekly)
        XCTAssertTrue(store.upcomingIncludedCategories.isEmpty)
    }

    /// Upstream `toRelativeString` and the next update texts.
    func testUpcomingAndNextUpdateTexts() throws {
        let today = try XCTUnwrap(MihonLocalDate("2026-10-28"))
        XCTAssertEqual(MihonDateText.relativeDay(today, today: today), "今天")
        XCTAssertEqual(MihonDateText.relativeDay(today.plusDays(1), today: today), "1 天后")
        XCTAssertEqual(MihonDateText.relativeDay(today.plusDays(7), today: today), "7 天后")
        XCTAssertEqual(MihonDateText.relativeDay(today.plusDays(8), today: today), "2026/11/05")
        XCTAssertEqual(MihonDateText.relativeDay(today.plusDays(-3), today: today), "3 天前")
        XCTAssertEqual(MihonDateText.relativeDay(today.plusDays(-7), today: today), "2026/10/21")

        let now = Date()
        var manga = Manga(id: 1, source: 0, url: "", title: "", status: .ongoing, favorite: true, fetchInterval: 7)
        XCTAssertEqual(MihonDateText.nextUpdateLabel(manga, now: now), "无")
        XCTAssertEqual(MihonDateText.nextUpdateEstimate(manga, now: now), "此漫画或已完结，或无发行日期。")
        manga.nextUpdate = now.addingTimeInterval(3.5 * 86_400)
        XCTAssertEqual(MihonDateText.nextUpdateLabel(manga, now: now), "3 天")
        XCTAssertEqual(MihonDateText.nextUpdateEstimate(manga, now: now), "预计 3 天后更新，每 7 天检查一次。")
        manga.nextUpdate = now.addingTimeInterval(-86_400)
        XCTAssertEqual(MihonDateText.nextUpdateLabel(manga, now: now), "即将更新", "due already")
        manga.status = .completed
        XCTAssertEqual(MihonDateText.nextUpdateLabel(manga, now: now), "无", "upstream's expectedNextUpdate leaves completed titles out")
        manga.status = .ongoing
        manga.fetchInterval = -7
        XCTAssertEqual(MihonDateText.nextUpdateEstimate(manga, now: now), "此漫画或已完结，或无发行日期。", "an interval the user set")
    }

    func testUpcomingGroupsByDay() {
        let utc = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let titles = [
            Manga(id: 1, source: 0, url: "", title: "", nextUpdate: day),
            Manga(id: 2, source: 0, url: "", title: "", nextUpdate: day.addingTimeInterval(3_600)),
            Manga(id: 3, source: 0, url: "", title: "", nextUpdate: day.addingTimeInterval(86_400)),
        ]
        let days = UpcomingScreen.days(titles, in: utc)
        XCTAssertEqual(days.map { $0.titles.map(\.id) }, [[1, 2], [3]])
        XCTAssertEqual(days.map(\.day), [MihonLocalDate(day, in: utc), MihonLocalDate(day, in: utc).plusDays(1)])
    }
}
