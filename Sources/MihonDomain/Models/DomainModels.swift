import Foundation

// MARK: - Manga Status & Update Strategy (1:1 with eu.kanade.tachiyomi.source.model.SManga)

public enum MangaStatus: Int, Codable, CaseIterable, Sendable {
    case unknown = 0
    case ongoing = 1
    case completed = 2
    case licensed = 3
    case publishingFinished = 4
    case cancelled = 5
    case onHiatus = 6

    public var localizedTitle: String {
        switch self {
        case .unknown: return "未知"
        case .ongoing: return "连载中"
        case .completed: return "已完结"
        case .licensed: return "版权屏蔽"
        case .publishingFinished: return "出版完毕"
        case .cancelled: return "已中止"
        case .onHiatus: return "休刊中"
        }
    }

    public var systemImage: String {
        switch self {
        case .unknown: return "nosign"
        case .ongoing: return "clock"
        case .completed: return "checkmark.circle"
        case .licensed: return "dollarsign"
        case .publishingFinished: return "checkmark"
        case .cancelled: return "xmark"
        case .onHiatus: return "pause.fill"
        }
    }
}

public enum UpdateStrategy: Int, Codable, CaseIterable, Sendable {
    case alwaysUpdate = 0
    case onlyFetchOnce = 1

    public var localizedTitle: String {
        switch self {
        case .alwaysUpdate: return "持续检查更新"
        case .onlyFetchOnce: return "仅获取一次"
        }
    }
}

// MARK: - Viewer & Chapter Bitmask Flags (1:1 with Mihon Manga.viewerFlags / chapterFlags)

public enum ReadingMode: Int, Codable, CaseIterable, Sendable {
    case defaultMode = 0
    case leftToRight = 1
    case rightToLeft = 2
    case vertical = 3
    case webtoon = 4
    case continuousVertical = 5

    public var localizedTitle: String {
        switch self {
        case .defaultMode: return "默认"
        case .leftToRight: return "单页式（从左到右）"
        case .rightToLeft: return "单页式（从右到左）"
        case .vertical: return "单页式（从上到下）"
        case .webtoon: return "条漫"
        case .continuousVertical: return "条漫（页间有空隙）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .defaultMode: return "默认"
        case .leftToRight: return "左右 · 从左到右"
        case .rightToLeft: return "左右 · 从右到左"
        case .vertical: return "上下翻页"
        case .webtoon: return "上下滚动 · 条漫"
        case .continuousVertical: return "上下滚动 · 有间隙"
        }
    }

    public var iconName: String {
        switch self {
        case .defaultMode: return "book"
        case .leftToRight: return "arrow.right.square"
        case .rightToLeft: return "arrow.left.square"
        case .vertical: return "arrow.down.square"
        case .webtoon: return "scroll"
        case .continuousVertical: return "rectangle.grid.1x2"
        }
    }

    /// Page-turn axis: horizontal paging vs vertical paging / scrolling.
    public var isVerticalDirection: Bool {
        self == .vertical || self == .webtoon || self == .continuousVertical
    }

    public var detail: String {
        switch self {
        case .defaultMode: return "使用全局默认阅读模式"
        case .leftToRight: return "左右滑动翻页，适合欧美漫画、国漫"
        case .rightToLeft: return "左右滑动翻页，从右往左读，适合日漫"
        case .vertical: return "上下滑动，一次翻一整页"
        case .webtoon: return "上下连续滚动，页与页无缝衔接，适合条漫"
        case .continuousVertical: return "上下连续滚动，页与页之间保留间隙"
        }
    }
}

public enum TapZoneType: Int, Codable, CaseIterable, Sendable {
    case defaultZone = 0
    case lShaped = 1
    case kindle = 2
    case edge = 3
    case rightAndLeft = 4
    case disabled = 5

    public var localizedTitle: String {
        switch self {
        case .defaultZone: return "默认"
        case .lShaped: return "L 形"
        case .kindle: return "Kindle 式"
        case .edge: return "边缘"
        case .rightAndLeft: return "左右"
        case .disabled: return "禁用"
        }
    }
}

public enum ChapterSortMode: String, Codable, CaseIterable, Sendable {
    case source = "按图源"
    case chapterNumber = "按章节编号"
    case uploadDate = "按上传日期"
    case alphabetical = "按章节名称"
}

public enum ChapterDisplayMode: String, Codable, CaseIterable, Sendable {
    case sourceTitle = "图源标题"
    case chapterNumber = "章节编号"
}

public enum TriStateFilter: Int, Codable, CaseIterable, Sendable {
    case disabled = 0
    case include = 1
    case exclude = 2

    public mutating func toggle() {
        switch self {
        case .disabled: self = .include
        case .include: self = .exclude
        case .exclude: self = .disabled
        }
    }
}

// MARK: - Core Domain Entities

public struct Manga: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var source: Int64
    public var url: String
    public var title: String
    public var artist: String?
    public var author: String?
    public var description: String?
    public var genre: [String]
    public var status: MangaStatus
    public var thumbnailUrl: String?
    public var favorite: Bool
    public var lastUpdate: Date?
    public var nextUpdate: Date?
    public var fetchInterval: Int
    public var dateAdded: Date?
    public var viewerFlags: Int64
    public var chapterFlags: Int64
    public var coverLastModified: Date
    public var updateStrategy: UpdateStrategy
    public var initialized: Bool
    public var lastModifiedAt: Date
    public var favoriteModifiedAt: Date?
    public var version: Int64
    public var notes: String

    // Per-manga reader overrides
    public var readingModeOverride: ReadingMode
    public var chapterSortMode: ChapterSortMode
    public var chapterSortAscending: Bool
    public var chapterDisplayMode: ChapterDisplayMode
    public var filterUnread: TriStateFilter
    public var filterDownloaded: TriStateFilter
    public var filterBookmarked: TriStateFilter

    public init(
        id: Int64,
        source: Int64,
        url: String,
        title: String,
        artist: String? = nil,
        author: String? = nil,
        description: String? = nil,
        genre: [String] = [],
        status: MangaStatus = .unknown,
        thumbnailUrl: String? = nil,
        favorite: Bool = false,
        lastUpdate: Date? = nil,
        nextUpdate: Date? = nil,
        // Upstream: 0 until a chapter list works it out (`FetchInterval`); negative is one the user set.
        fetchInterval: Int = 0,
        dateAdded: Date? = nil,
        viewerFlags: Int64 = 0,
        chapterFlags: Int64 = 0,
        coverLastModified: Date = Date(),
        updateStrategy: UpdateStrategy = .alwaysUpdate,
        initialized: Bool = true,
        lastModifiedAt: Date = Date(),
        favoriteModifiedAt: Date? = nil,
        version: Int64 = 1,
        notes: String = "",
        readingModeOverride: ReadingMode = .defaultMode,
        // Upstream's default (`CHAPTER_SORTING_SOURCE`): the source's own list, so unnumbered episodes (afterwords,
        // extras) stay where the site puts them.
        chapterSortMode: ChapterSortMode = .source,
        chapterSortAscending: Bool = false,
        chapterDisplayMode: ChapterDisplayMode = .sourceTitle,
        filterUnread: TriStateFilter = .disabled,
        filterDownloaded: TriStateFilter = .disabled,
        filterBookmarked: TriStateFilter = .disabled
    ) {
        self.id = id
        self.source = source
        self.url = url
        self.title = title
        self.artist = artist
        self.author = author
        self.description = description
        self.genre = genre
        self.status = status
        self.thumbnailUrl = thumbnailUrl
        self.favorite = favorite
        self.lastUpdate = lastUpdate
        self.nextUpdate = nextUpdate
        self.fetchInterval = fetchInterval
        self.dateAdded = dateAdded
        self.viewerFlags = viewerFlags
        self.chapterFlags = chapterFlags
        self.coverLastModified = coverLastModified
        self.updateStrategy = updateStrategy
        self.initialized = initialized
        self.lastModifiedAt = lastModifiedAt
        self.favoriteModifiedAt = favoriteModifiedAt
        self.version = version
        self.notes = notes
        self.readingModeOverride = readingModeOverride
        self.chapterSortMode = chapterSortMode
        self.chapterSortAscending = chapterSortAscending
        self.chapterDisplayMode = chapterDisplayMode
        self.filterUnread = filterUnread
        self.filterDownloaded = filterDownloaded
        self.filterBookmarked = filterBookmarked
    }
}

public struct Chapter: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var mangaId: Int64
    public var url: String
    public var name: String
    public var scanlator: String?
    public var read: Bool
    public var bookmark: Bool
    public var lastPageRead: Int
    public var totalPages: Int
    public var chapterNumber: Double
    public var sourceOrder: Int
    public var dateFetch: Date
    public var dateUpload: Date
    public var lastModifiedAt: Date
    public var version: Int64

    public init(
        id: Int64,
        mangaId: Int64,
        url: String,
        name: String,
        scanlator: String? = nil,
        read: Bool = false,
        bookmark: Bool = false,
        lastPageRead: Int = 0,
        totalPages: Int = 18,
        chapterNumber: Double = -1,
        sourceOrder: Int = 0,
        dateFetch: Date = Date(),
        dateUpload: Date = Date(),
        lastModifiedAt: Date = Date(),
        version: Int64 = 1
    ) {
        self.id = id
        self.mangaId = mangaId
        self.url = url
        self.name = name
        self.scanlator = scanlator
        self.read = read
        self.bookmark = bookmark
        self.lastPageRead = lastPageRead
        self.totalPages = totalPages
        self.chapterNumber = chapterNumber
        self.sourceOrder = sourceOrder
        self.dateFetch = dateFetch
        self.dateUpload = dateUpload
        self.lastModifiedAt = lastModifiedAt
        self.version = version
    }
}

public struct MangaCategory: Identifiable, Codable, Hashable, Sendable {
    public static let defaultCategoryId: Int64 = 0

    public var id: Int64
    public var name: String
    public var order: Int
    public var flags: Int64

    public var isSystemCategory: Bool {
        id == Self.defaultCategoryId
    }

    public init(id: Int64, name: String, order: Int, flags: Int64 = 0) {
        self.id = id
        self.name = name
        self.order = order
        self.flags = flags
    }
}

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var chapterId: Int64
    public var mangaId: Int64
    public var readAt: Date
    public var readDurationSeconds: Int64

    public init(id: Int64, chapterId: Int64, mangaId: Int64, readAt: Date = Date(), readDurationSeconds: Int64 = 0) {
        self.id = id
        self.chapterId = chapterId
        self.mangaId = mangaId
        self.readAt = readAt
        self.readDurationSeconds = readDurationSeconds
    }
}

public struct HistoryWithRelations: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var manga: Manga
    public var chapter: Chapter
    public var readAt: Date
    public var readDurationSeconds: Int64

    public init(id: Int64, manga: Manga, chapter: Chapter, readAt: Date, readDurationSeconds: Int64) {
        self.id = id
        self.manga = manga
        self.chapter = chapter
        self.readAt = readAt
        self.readDurationSeconds = readDurationSeconds
    }
}

public struct UpdateWithRelations: Identifiable, Hashable, Sendable {
    public var id: Int64 { chapter.id }
    public var manga: Manga
    public var chapter: Chapter
    public var isDownloaded: Bool

    public init(manga: Manga, chapter: Chapter, isDownloaded: Bool) {
        self.manga = manga
        self.chapter = chapter
        self.isDownloaded = isDownloaded
    }
}

// MARK: - Tracking Models (1:1 with Mihon Tracker Manager)

public enum TrackStatus: Int, Codable, CaseIterable, Sendable {
    case reading = 1
    case completed = 2
    case onHold = 3
    case dropped = 4
    case planToRead = 5
    case rereading = 6

    public var localizedTitle: String {
        switch self {
        case .reading: return "阅读中"
        case .completed: return "已读完"
        case .onHold: return "暂停"
        case .dropped: return "弃坑"
        case .planToRead: return "计划阅读"
        case .rereading: return "重温"
        }
    }
}

public struct TrackerServiceInfo: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var iconSystemName: String
    public var brandColorHex: String
    public var isLoggedIn: Bool
    public var username: String?
    public var baseUrl: String

    public init(
        id: Int64,
        name: String,
        iconSystemName: String,
        brandColorHex: String,
        isLoggedIn: Bool = false,
        username: String? = nil,
        baseUrl: String
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.brandColorHex = brandColorHex
        self.isLoggedIn = isLoggedIn
        self.username = username
        self.baseUrl = baseUrl
    }
}

public struct Track: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var mangaId: Int64
    public var trackerId: Int64
    public var remoteId: Int64
    public var title: String
    public var lastChapterRead: Double
    public var totalChapters: Int
    public var status: TrackStatus
    public var score: Double
    public var remoteUrl: String
    public var startDate: Date?
    public var finishDate: Date?
    public var isPrivate: Bool

    public init(
        id: Int64,
        mangaId: Int64,
        trackerId: Int64,
        remoteId: Int64,
        title: String,
        lastChapterRead: Double = 0,
        totalChapters: Int = 0,
        status: TrackStatus = .reading,
        score: Double = 0,
        remoteUrl: String = "",
        startDate: Date? = nil,
        finishDate: Date? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.mangaId = mangaId
        self.trackerId = trackerId
        self.remoteId = remoteId
        self.title = title
        self.lastChapterRead = lastChapterRead
        self.totalChapters = totalChapters
        self.status = status
        self.score = score
        self.remoteUrl = remoteUrl
        self.startDate = startDate
        self.finishDate = finishDate
        self.isPrivate = isPrivate
    }
}

// MARK: - Download Queue Models

public enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case notDownloaded = "未下载"
    case queue = "排队中"
    case downloading = "下载中"
    case downloaded = "已下载"
    case error = "下载出错"
}

public struct DownloadItem: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64 { chapter.id }
    public var manga: Manga
    public var chapter: Chapter
    public var sourceName: String
    public var status: DownloadStatus
    public var downloadedPages: Int
    public var totalPages: Int
    public var errorMessage: String?

    public var progress: Double {
        guard totalPages > 0 else { return 0 }
        return min(1.0, Double(downloadedPages) / Double(totalPages))
    }

    public init(
        manga: Manga,
        chapter: Chapter,
        sourceName: String,
        status: DownloadStatus = .queue,
        downloadedPages: Int = 0,
        totalPages: Int = 18,
        errorMessage: String? = nil
    ) {
        self.manga = manga
        self.chapter = chapter
        self.sourceName = sourceName
        self.status = status
        self.downloadedPages = downloadedPages
        self.totalPages = totalPages
        self.errorMessage = errorMessage
    }
}

// MARK: - Extension Package Models

public enum ExtensionInstallState: String, Codable, CaseIterable, Sendable {
    case available = "可安装"
    case downloadingApk = "正在下载 APK..."
    case parsingApk = "正在解析 APK..."
    case installed = "已安装"
    case hasUpdate = "可更新"
    case untrusted = "待信任"
}

public struct ExtensionSourceDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var lang: String
    public var baseUrl: String
    public var isNsfw: Bool
    public var className: String
    public var multiSrcTemplate: String?
    public var popularPath: String
    public var latestPath: String
    public var searchPath: String
    public var popularSelector: String
    public var chapterSelector: String
    public var pageSelector: String

    public init(
        id: Int64,
        name: String,
        lang: String,
        baseUrl: String,
        isNsfw: Bool = false,
        className: String = "",
        multiSrcTemplate: String? = nil,
        popularPath: String = "/popular",
        latestPath: String = "/latest",
        searchPath: String = "/search?q={query}",
        popularSelector: String = "div.manga-item",
        chapterSelector: String = "ul.chapter-list li a",
        pageSelector: String = "div.reader-area img"
    ) {
        self.id = id
        self.name = name
        self.lang = lang
        self.baseUrl = baseUrl
        self.isNsfw = isNsfw
        self.className = className
        self.multiSrcTemplate = multiSrcTemplate
        self.popularPath = popularPath
        self.latestPath = latestPath
        self.searchPath = searchPath
        self.popularSelector = popularSelector
        self.chapterSelector = chapterSelector
        self.pageSelector = pageSelector
    }
}

public struct ExtensionModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String { pkgName }
    public var name: String
    public var pkgName: String
    public var versionName: String
    public var versionCode: Int
    public var libVersion: Double
    public var lang: String
    public var isNsfw: Bool
    public var apkName: String
    /// Direct APK download URL published by `index.pb` (`Resources.apkUrl`); legacy repos derive it from `apkName`.
    public var apkUrl: String?
    public var iconUrl: String?
    public var repoUrl: String
    public var installState: ExtensionInstallState
    public var sources: [ExtensionSourceDescriptor]
    public var apkMetadataSummary: String?

    public init(
        name: String,
        pkgName: String,
        versionName: String,
        versionCode: Int,
        libVersion: Double = 1.4,
        lang: String,
        isNsfw: Bool = false,
        apkName: String,
        apkUrl: String? = nil,
        iconUrl: String? = nil,
        repoUrl: String = "https://raw.githubusercontent.com/keiyoushi/extensions/repo",
        installState: ExtensionInstallState = .available,
        sources: [ExtensionSourceDescriptor] = [],
        apkMetadataSummary: String? = nil
    ) {
        self.name = name
        self.pkgName = pkgName
        self.versionName = versionName
        self.versionCode = versionCode
        self.libVersion = libVersion
        self.lang = lang
        self.isNsfw = isNsfw
        self.apkName = apkName
        self.apkUrl = apkUrl
        self.iconUrl = iconUrl
        self.repoUrl = repoUrl
        self.installState = installState
        self.sources = sources
        self.apkMetadataSummary = apkMetadataSummary
    }
}

public struct ExtensionRepo: Identifiable, Codable, Hashable, Sendable {
    public var id: String { baseUrl }
    public var baseUrl: String
    public var name: String
    public var shortName: String?
    public var website: String
    public var signingKeyFingerprint: String

    public init(
        baseUrl: String,
        name: String,
        shortName: String? = nil,
        website: String,
        signingKeyFingerprint: String
    ) {
        self.baseUrl = baseUrl
        self.name = name
        self.shortName = shortName
        self.website = website
        self.signingKeyFingerprint = signingKeyFingerprint
    }
}

// MARK: - Library Presentation & Filtering Models

public enum LibraryDisplayMode: String, Codable, CaseIterable, Sendable {
    case compactGrid = "紧凑网格"
    case comfortableGrid = "松散网格"
    case coverOnlyGrid = "封面网格"
    case list = "列表"

    public var iconName: String {
        switch self {
        case .compactGrid: return "square.grid.3x3.fill"
        case .comfortableGrid: return "rectangle.grid.3x2.fill"
        case .coverOnlyGrid: return "photo.on.rectangle.angled"
        case .list: return "list.bullet"
        }
    }
}

public enum LibrarySortOption: String, Codable, CaseIterable, Sendable {
    case alphabetical = "名称"
    case lastRead = "最近阅读"
    case lastUpdated = "检查更新时间"
    case unreadCount = "未读章数"
    case totalChapters = "章节数"
    case latestChapter = "作品更新时间"
    case chapterFetchDate = "章节获取时间"
    case dateAdded = "收藏日期"
    case trackerMeanScore = "记录平台评分"
}

public struct LibraryFilterState: Codable, Hashable, Sendable {
    public var filterDownloaded: TriStateFilter = .disabled
    public var filterUnread: TriStateFilter = .disabled
    public var filterStarted: TriStateFilter = .disabled
    public var filterBookmarked: TriStateFilter = .disabled
    public var filterCompleted: TriStateFilter = .disabled
    public var filterTracked: TriStateFilter = .disabled

    public var hasActiveFilters: Bool {
        filterDownloaded != .disabled ||
        filterUnread != .disabled ||
        filterStarted != .disabled ||
        filterBookmarked != .disabled ||
        filterCompleted != .disabled ||
        filterTracked != .disabled
    }

    public init() {}
}

public struct LibraryMangaItem: Identifiable, Hashable, Sendable {
    public var id: Int64 { manga.id }
    public var manga: Manga
    public var unreadCount: Int
    public var downloadCount: Int
    public var totalChapters: Int
    public var hasBookmarks: Bool
    public var isTracked: Bool
    public var latestUploadDate: Date?
    /// When the newest chapter was fetched (upstream `chapterFetchedAt`).
    public var latestFetchDate: Date?
    public var lastReadDate: Date?
    public var categories: [Int64]
    public var sourceLanguage: String
    public var isLocal: Bool
    /// Next chapter to resume (memoized by the store so grid cells never sort chapters inside `body`).
    public var nextChapter: Chapter?
    public var hasReadChapters: Bool

    public init(
        manga: Manga,
        unreadCount: Int,
        downloadCount: Int,
        totalChapters: Int,
        hasBookmarks: Bool,
        isTracked: Bool,
        latestUploadDate: Date?,
        lastReadDate: Date?,
        categories: [Int64],
        sourceLanguage: String,
        isLocal: Bool,
        nextChapter: Chapter? = nil,
        hasReadChapters: Bool = false,
        latestFetchDate: Date? = nil
    ) {
        self.manga = manga
        self.unreadCount = unreadCount
        self.downloadCount = downloadCount
        self.totalChapters = totalChapters
        self.hasBookmarks = hasBookmarks
        self.isTracked = isTracked
        self.latestUploadDate = latestUploadDate
        self.lastReadDate = lastReadDate
        self.categories = categories
        self.sourceLanguage = sourceLanguage
        self.isLocal = isLocal
        self.nextChapter = nextChapter
        self.hasReadChapters = hasReadChapters
        self.latestFetchDate = latestFetchDate
    }
}

public struct LibraryStatistics: Sendable {
    public var inLibraryCount: Int
    public var completedMangaCount: Int
    public var startedMangaCount: Int
    public var localMangaCount: Int
    public var totalChaptersCount: Int
    public var readChaptersCount: Int
    public var downloadedChaptersCount: Int
    public var trackedMangaCount: Int
    public var meanTrackerScore: Double
    public var trackerCount: Int
    public var totalReadDurationSeconds: Int64

    public init(
        inLibraryCount: Int,
        completedMangaCount: Int,
        startedMangaCount: Int,
        localMangaCount: Int,
        totalChaptersCount: Int,
        readChaptersCount: Int,
        downloadedChaptersCount: Int,
        trackedMangaCount: Int,
        meanTrackerScore: Double,
        trackerCount: Int,
        totalReadDurationSeconds: Int64
    ) {
        self.inLibraryCount = inLibraryCount
        self.completedMangaCount = completedMangaCount
        self.startedMangaCount = startedMangaCount
        self.localMangaCount = localMangaCount
        self.totalChaptersCount = totalChaptersCount
        self.readChaptersCount = readChaptersCount
        self.downloadedChaptersCount = downloadedChaptersCount
        self.trackedMangaCount = trackedMangaCount
        self.meanTrackerScore = meanTrackerScore
        self.trackerCount = trackerCount
        self.totalReadDurationSeconds = totalReadDurationSeconds
    }
}

// MARK: - Backup & Restore Payload (.tachibk / .mihonbk JSON Schema)

public struct MihonBackupPayload: Codable, Sendable {
    public var version: Int
    public var createdAt: Date
    public var appVersion: String
    public var backupManga: [Manga]
    public var backupCategories: [MangaCategory]
    public var mangaCategoriesMap: [Int64: [Int64]]
    public var backupChapters: [Chapter]
    public var backupHistory: [HistoryEntry]
    public var backupTracks: [Track]
    public var backupExtensionRepos: [ExtensionRepo]

    public init(
        // 3: next updates come from upstream's release schedule (`FetchInterval`).
        version: Int = 3,
        createdAt: Date = Date(),
        appVersion: String = "Mihon-iOS 0.17.1",
        backupManga: [Manga],
        backupCategories: [MangaCategory],
        mangaCategoriesMap: [Int64: [Int64]],
        backupChapters: [Chapter],
        backupHistory: [HistoryEntry],
        backupTracks: [Track],
        backupExtensionRepos: [ExtensionRepo]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.backupManga = backupManga
        self.backupCategories = backupCategories
        self.mangaCategoriesMap = mangaCategoriesMap
        self.backupChapters = backupChapters
        self.backupHistory = backupHistory
        self.backupTracks = backupTracks
        self.backupExtensionRepos = backupExtensionRepos
    }
}
