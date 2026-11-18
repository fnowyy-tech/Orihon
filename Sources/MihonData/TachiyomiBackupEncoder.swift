import Foundation
import MihonDomain

// MARK: - Backups for Mihon / Tachiyomi on Android (`.tachibk`)

/// `TachiyomiBackupDecoder` the other way round: a backup payload as upstream's `Backup` (kotlinx protobuf in
/// gzip), so Mihon on Android restores it. Upstream `BackupCreator` with its default options, less what this port
/// does not have in upstream's terms: tracking (trackers are not real here yet; Komga syncs progress by itself),
/// app and source settings (their keys are Android's) and extension repos (tester builds never show them, and how
/// Mihon stores them has changed between versions). Kept: titles with their chapters, categories and history; the
/// categories; the names of the sources.
public enum TachiyomiBackupEncoder {
    public enum Failure: Error, LocalizedError {
        case empty

        public var errorDescription: String? { "书架里没有可以备份的作品或分类" }
    }

    public static func fileName(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "Orihon_\(formatter.string(from: date)).tachibk"
    }

    /// Upstream `BackupWriter` order: the entries, then the categories and sources.
    public static func encode(_ payload: MihonBackupPayload, sourceNames: [Int64: String]) throws -> Data {
        // Titles name their categories by `order` (upstream `MangaBackupCreator`), so each gets one of its own:
        // here two categories can share one after a deletion.
        let categories = payload.backupCategories
            .filter { !$0.isSystemCategory }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        var orderByCategoryId: [Int64: Int64] = [:]
        for (index, category) in categories.enumerated() {
            orderByCategoryId[category.id] = Int64(index + 1)
        }
        guard !payload.backupManga.isEmpty || !categories.isEmpty else { throw Failure.empty }

        let chaptersByManga = Dictionary(grouping: payload.backupChapters, by: \.mangaId)
        let historyByManga = Dictionary(grouping: payload.backupHistory, by: \.mangaId)
        var backup = ProtobufWriter()
        var sourceIds: [Int64] = []
        for manga in payload.backupManga {
            backup.message(1) { entry in
                write(
                    manga,
                    chapters: chaptersByManga[manga.id] ?? [],
                    history: historyByManga[manga.id] ?? [],
                    categoryOrders: (payload.mangaCategoriesMap[manga.id] ?? []).compactMap { orderByCategoryId[$0] },
                    to: &entry
                )
            }
            if !sourceIds.contains(manga.source) { sourceIds.append(manga.source) }
        }
        for category in categories {
            backup.message(2) { entry in
                entry.string(1, category.name)
                entry.int(2, orderByCategoryId[category.id] ?? 0)
                entry.int(3, category.id)
                if category.flags != 0 { entry.int(100, category.flags) }
            }
        }
        for sourceId in sourceIds {
            backup.message(101) { entry in
                if let name = sourceNames[sourceId], !name.isEmpty { entry.string(1, name) }
                entry.int(2, sourceId)
            }
        }
        return MihonGzip.compress(backup.data)
    }

    /// Upstream `BackupManga`. Fields kotlinx requires (no default value) are always written, even when zero.
    private static func write(
        _ manga: Manga,
        chapters: [Chapter],
        history: [HistoryEntry],
        categoryOrders: [Int64],
        to entry: inout ProtobufWriter
    ) {
        let viewerFlags = (manga.viewerFlags & ~0x7) | Int64(manga.readingModeOverride.rawValue)
        entry.int(1, manga.source)
        entry.string(2, manga.url)
        entry.string(3, manga.title)
        if let artist = manga.artist { entry.string(4, artist) }
        if let author = manga.author { entry.string(5, author) }
        if let description = manga.description { entry.string(6, description) }
        for genre in manga.genre { entry.string(7, genre) }
        entry.int(8, Int64(manga.status.rawValue))
        if let thumbnailUrl = manga.thumbnailUrl { entry.string(9, thumbnailUrl) }
        // Upstream's `favoriteAt`: only titles in the library have one.
        if manga.favorite, let dateAdded = manga.dateAdded { entry.int(13, milliseconds(dateAdded)) }
        entry.int(14, viewerFlags & 0x7)

        var urlByChapterId: [Int64: String] = [:]
        for chapter in chapters {
            urlByChapterId[chapter.id] = chapter.url
            entry.message(16) { backupChapter in
                backupChapter.string(1, chapter.url)
                backupChapter.string(2, chapter.name)
                if let scanlator = chapter.scanlator { backupChapter.string(3, scanlator) }
                backupChapter.bool(4, chapter.read)
                backupChapter.bool(5, chapter.bookmark)
                backupChapter.int(6, Int64(max(0, chapter.lastPageRead)))
                backupChapter.int(7, milliseconds(chapter.dateFetch))
                backupChapter.int(8, chapter.dateUpload == SChapter.undatedUpload ? 0 : milliseconds(chapter.dateUpload))
                backupChapter.float(9, Float(chapter.chapterNumber))
                backupChapter.int(10, Int64(chapter.sourceOrder))
            }
        }
        for order in categoryOrders { entry.int(17, order) }

        entry.bool(100, manga.favorite)
        entry.int(101, chapterFlags(manga))
        entry.int(103, viewerFlags)
        // History is backed up by chapter URL: a chapter no longer listed takes its history with it (upstream).
        for read in history {
            guard let url = urlByChapterId[read.chapterId] else { continue }
            entry.message(104) { backupHistory in
                backupHistory.string(1, url)
                backupHistory.int(2, milliseconds(read.readAt))
                backupHistory.int(3, max(0, min(read.readDurationSeconds, Int64.max / 1000)) * 1000)
            }
        }
        entry.int(105, Int64(manga.updateStrategy.rawValue))
        if !manga.notes.isEmpty { entry.string(110, manga.notes) }
        entry.bool(111, manga.initialized)
        if let nextUpdate = manga.nextUpdate { entry.int(113, milliseconds(nextUpdate)) }
    }

    /// Upstream `Manga.CHAPTER_*` (the bits `TachiyomiBackupDecoder` reads); bits this port does not know are kept.
    static func chapterFlags(_ manga: Manga) -> Int64 {
        var flags = manga.chapterFlags & ~0x10_037F
        if manga.chapterSortAscending { flags |= 0x1 }
        flags |= bits(manga.filterUnread, include: 0x2, exclude: 0x4)
        flags |= bits(manga.filterDownloaded, include: 0x8, exclude: 0x10)
        flags |= bits(manga.filterBookmarked, include: 0x20, exclude: 0x40)
        switch manga.chapterSortMode {
        case .source: break
        case .chapterNumber: flags |= 0x100
        case .uploadDate: flags |= 0x200
        case .alphabetical: flags |= 0x300
        }
        if manga.chapterDisplayMode == .chapterNumber { flags |= 0x10_0000 }
        return flags
    }

    private static func bits(_ filter: TriStateFilter, include: Int64, exclude: Int64) -> Int64 {
        switch filter {
        case .disabled: return 0
        case .include: return include
        case .exclude: return exclude
        }
    }

    /// Clamped: a date from a damaged backup can be beyond what epoch milliseconds hold.
    private static func milliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite else { return 0 }
        return Int64(max(-9.2e18, min(9.2e18, value)))
    }
}

/// Protobuf as kotlinx writes it: varints (two's complement for negatives), fixed32 floats, length-delimited strings
/// and messages, repeated fields one by one (not packed).
struct ProtobufWriter {
    private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private mutating func tag(_ number: Int, _ wireType: UInt64) {
        varint(UInt64(number) << 3 | wireType)
    }

    mutating func int(_ number: Int, _ value: Int64) {
        tag(number, 0)
        varint(UInt64(bitPattern: value))
    }

    mutating func bool(_ number: Int, _ value: Bool) {
        int(number, value ? 1 : 0)
    }

    mutating func float(_ number: Int, _ value: Float) {
        tag(number, 5)
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ number: Int, _ value: Data) {
        tag(number, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ number: Int, _ value: String) {
        bytes(number, Data(value.utf8))
    }

    mutating func message(_ number: Int, _ build: (inout ProtobufWriter) -> Void) {
        var message = ProtobufWriter()
        build(&message)
        bytes(number, message.data)
    }
}
