import Foundation
import MihonDomain

// MARK: - Mihon / Tachiyomi backups (`.tachibk`)

/// Upstream's backup file: gzip around kotlinx protobuf of `Backup` (`app/…/data/backup/models`). Read into this
/// port's backup payload, so it restores through the same merge as the port's own JSON backups. Kept: titles,
/// chapters, categories, history, reading mode, chapter sort and filters. Skipped: tracking (trackers are not real
/// here yet), app and source preferences, extension repos.
public enum TachiyomiBackupDecoder {
    public enum Failure: Error, LocalizedError {
        case notABackup

        public var errorDescription: String? { "不是有效的 Mihon / Tachiyomi 备份文件" }
    }

    /// A whole library inflates to tens of megabytes; this only stops a file built to exhaust memory.
    static let maxDecompressedSize = 256 << 20

    /// `.tachibk` (and Tachiyomi's older `.proto.gz`) are gzip; the port's own backups are JSON.
    public static func isTachiyomiBackup(_ data: Data) -> Bool {
        MihonGzip.isGzip(data)
    }

    public struct Result: Sendable {
        public var payload: MihonBackupPayload
        /// Upstream `BackupSource`: the names of the backup's sources, for titles from sources this build lacks.
        public var sourceNames: [Int64: String]
    }

    public static func decode(_ data: Data) throws -> Result {
        guard isTachiyomiBackup(data) else { throw Failure.notABackup }
        do {
            return try decodeMessage(ProtobufMessage(MihonGzip.decompress(data, limit: maxDecompressedSize)))
        } catch {
            // A damaged nested message is the backup's fault too, not the extension index's (whose errors these are).
            throw Failure.notABackup
        }
    }

    private static func decodeMessage(_ backup: ProtobufMessage) throws -> Result {

        // Titles name their categories by `order` (upstream `BackupRestorer` matches them the same way).
        var categories: [MangaCategory] = []
        var categoryIdByOrder: [Int64: Int64] = [:]
        for (index, category) in try backup.messages(2).enumerated() {
            let order = category.int(2) ?? Int64(index)
            let id = Int64(index + 1)
            categories.append(MangaCategory(id: id, name: category.string(1) ?? "", order: Int(clamping: order), flags: category.int(100) ?? 0))
            categoryIdByOrder[order] = id
        }

        var sourceNames: [Int64: String] = [:]
        for source in try backup.messages(101) {
            if let id = source.int(2), let name = source.string(1), !name.isEmpty { sourceNames[id] = name }
        }

        var mangas: [Manga] = []
        var chapters: [Chapter] = []
        var history: [HistoryEntry] = []
        var mangaCategories: [Int64: [Int64]] = [:]
        var nextChapterId: Int64 = 1
        for entry in try backup.messages(1) {
            guard let source = entry.int(1), let url = entry.string(2) else { continue }
            let mangaId = Int64(mangas.count + 1)
            let chapterFlags = entry.int(101) ?? 0
            let viewerFlags = entry.int(103) ?? entry.int(14) ?? 0
            let dateAdded = entry.int(13).flatMap(date(milliseconds:))
            let nextUpdate = entry.int(113).flatMap(date(milliseconds:))
            let lastModifiedAt = entry.int(106).flatMap(date(seconds:)) ?? Date(timeIntervalSince1970: 0)
            let favoriteModifiedAt = entry.int(107).flatMap(date(seconds:))
            mangas.append(Manga(
                id: mangaId,
                source: source,
                url: url,
                title: entry.string(3) ?? "",
                artist: entry.string(4),
                author: entry.string(5),
                description: entry.string(6),
                genre: entry.strings(7),
                status: MangaStatus(rawValue: Int(clamping: entry.int(8) ?? 0)) ?? .unknown,
                thumbnailUrl: entry.string(9),
                favorite: entry.bool(100) ?? true,
                nextUpdate: nextUpdate,
                dateAdded: dateAdded,
                viewerFlags: viewerFlags,
                chapterFlags: chapterFlags,
                updateStrategy: UpdateStrategy(rawValue: Int(clamping: entry.int(105) ?? 0)) ?? .alwaysUpdate,
                // Fetched again on first open: details may have changed since.
                initialized: false,
                lastModifiedAt: lastModifiedAt,
                favoriteModifiedAt: favoriteModifiedAt,
                notes: entry.string(110) ?? "",
                readingModeOverride: ReadingMode(rawValue: Int(viewerFlags & 0x7)) ?? .defaultMode,
                chapterSortMode: sortMode(chapterFlags),
                chapterSortAscending: chapterFlags & 0x1 != 0,
                chapterDisplayMode: chapterFlags & 0x10_0000 != 0 ? .chapterNumber : .sourceTitle,
                filterUnread: filter(chapterFlags, include: 0x2, exclude: 0x4),
                filterDownloaded: filter(chapterFlags, include: 0x8, exclude: 0x10),
                filterBookmarked: filter(chapterFlags, include: 0x20, exclude: 0x40)
            ))
            mangaCategories[mangaId] = entry.ints(17).compactMap { categoryIdByOrder[$0] }

            var chapterIdByUrl: [String: Int64] = [:]
            for chapter in try entry.messages(16) {
                guard let chapterUrl = chapter.string(1) else { continue }
                let id = nextChapterId
                nextChapterId += 1
                chapterIdByUrl[chapterUrl] = id
                chapters.append(Chapter(
                    id: id,
                    mangaId: mangaId,
                    url: chapterUrl,
                    name: chapter.string(2) ?? "",
                    scanlator: chapter.string(3),
                    read: chapter.bool(4) ?? false,
                    bookmark: chapter.bool(5) ?? false,
                    lastPageRead: Int(clamping: chapter.int(6) ?? 0),
                    totalPages: 0,
                    chapterNumber: Double(chapter.float(9) ?? 0),
                    sourceOrder: Int(clamping: chapter.int(10) ?? 0),
                    dateFetch: chapter.int(7).flatMap(date(milliseconds:)) ?? SChapter.undatedUpload,
                    dateUpload: chapter.int(8).flatMap(date(milliseconds:)) ?? SChapter.undatedUpload,
                    lastModifiedAt: chapter.int(11).flatMap(date(seconds:)) ?? Date(timeIntervalSince1970: 0)
                ))
            }
            for read in try entry.messages(104) {
                guard let chapterUrl = read.string(1), let chapterId = chapterIdByUrl[chapterUrl],
                      let readAt = read.int(2).flatMap(date(milliseconds:)) else { continue }
                history.append(HistoryEntry(
                    id: Int64(history.count + 1),
                    chapterId: chapterId,
                    mangaId: mangaId,
                    readAt: readAt,
                    readDurationSeconds: (read.int(3) ?? 0) / 1000
                ))
            }
        }

        let payload = MihonBackupPayload(
            appVersion: "Mihon (.tachibk)",
            backupManga: mangas,
            backupCategories: categories,
            mangaCategoriesMap: mangaCategories,
            backupChapters: chapters,
            backupHistory: history,
            backupTracks: [],
            backupExtensionRepos: []
        )
        return Result(payload: payload, sourceNames: sourceNames)
    }

    /// Upstream `Manga.CHAPTER_SORTING_*`.
    static func sortMode(_ flags: Int64) -> ChapterSortMode {
        switch flags & 0x300 {
        case 0x100: return .chapterNumber
        case 0x200: return .uploadDate
        case 0x300: return .alphabetical
        default: return .source
        }
    }

    static func filter(_ flags: Int64, include: Int64, exclude: Int64) -> TriStateFilter {
        if flags & include != 0 { return .include }
        if flags & exclude != 0 { return .exclude }
        return .disabled
    }

    /// Upstream keeps dates as epoch milliseconds, modification times as epoch seconds (SQL `strftime('%s')`);
    /// 0 means none.
    static func date(milliseconds: Int64) -> Date? {
        milliseconds > 0 ? Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) : nil
    }

    static func date(seconds: Int64) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }
}

/// One decoded protobuf message: its fields by number (the last one wins for singular fields, as in protobuf).
struct ProtobufMessage {
    private var fields: [Int: [ProtobufReader.Value]] = [:]
    /// Far above a real backup (a field per title or chapter); a file of tiny fields would otherwise take gigabytes.
    static let maxFields = 2_000_000

    init(_ data: Data) throws {
        var reader = ProtobufReader(data: data)
        var count = 0
        while let field = try reader.nextField() {
            count += 1
            guard count <= Self.maxFields else { throw TachiyomiBackupDecoder.Failure.notABackup }
            fields[field.number, default: []].append(field.value)
        }
    }

    /// int32 / int64 / enum (varint, two's complement for negatives).
    func int(_ number: Int) -> Int64? {
        guard case .varint(let value)? = fields[number]?.last else { return nil }
        return Int64(bitPattern: value)
    }

    func bool(_ number: Int) -> Bool? {
        int(number).map { $0 != 0 }
    }

    func float(_ number: Int) -> Float? {
        guard case .fixed32(let bits)? = fields[number]?.last else { return nil }
        return Float(bitPattern: bits)
    }

    func string(_ number: Int) -> String? {
        guard case .bytes(let data)? = fields[number]?.last else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func strings(_ number: Int) -> [String] {
        (fields[number] ?? []).compactMap { value in
            guard case .bytes(let data) = value else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Repeated integers, one field each or packed into one.
    func ints(_ number: Int) -> [Int64] {
        (fields[number] ?? []).flatMap { value -> [Int64] in
            switch value {
            case .varint(let raw):
                return [Int64(bitPattern: raw)]
            case .bytes(let packed):
                var reader = ProtobufVarintReader(packed)
                var values: [Int64] = []
                while let raw = reader.next() { values.append(Int64(bitPattern: raw)) }
                return values
            default:
                return []
            }
        }
    }

    func messages(_ number: Int) throws -> [ProtobufMessage] {
        try (fields[number] ?? []).compactMap { value in
            guard case .bytes(let data) = value else { return nil }
            return try ProtobufMessage(data)
        }
    }
}

/// Varints back to back (a packed repeated field).
struct ProtobufVarintReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func next() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift <= 63 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }
}
