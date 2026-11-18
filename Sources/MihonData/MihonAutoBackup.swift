import Foundation

// MARK: - Automatic backups (upstream `BackupCreateJob` / `BackupCreator`)

/// Every `autoBackupInterval` hours a backup file lands in an `autobackup` folder, and the last four are kept
/// (upstream `MAX_AUTO_BACKUPS`). On iOS the folder is `Documents/autobackup`, which the Files app shows under
/// 「我的 iPhone › Orihon」 next to `local`; a Mac keeps it in Application Support; XCTest in a temporary folder.
public enum MihonAutoBackup {
    /// Upstream's choices in hours (0: off); 12 is upstream's default.
    public static let intervalChoices = [0, 6, 12, 24, 48, 168]
    public static let defaultInterval = 12
    static let maxBackups = 4

    public static let directory: URL = {
        let fileManager = FileManager.default
        if NSClassFromString("XCTestCase") != nil {
            return fileManager.temporaryDirectory
                .appendingPathComponent("MihonTests-\(ProcessInfo.processInfo.processIdentifier)/autobackup", isDirectory: true)
        }
        #if os(iOS)
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("autobackup", isDirectory: true)
        #else
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Mihon-iOS/autobackup", isDirectory: true)
        #endif
    }()

    public static func title(hours: Int) -> String {
        switch hours {
        case 0: return "关闭"
        case 24: return "每天"
        case 48: return "每 2 天"
        case 168: return "每周"
        default: return "每 \(hours) 小时"
        }
    }

    /// The app's name and the date: `Orihon_2026-10-28_01-30.json`.
    static func fileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "Orihon_\(formatter.string(from: date)).json"
    }

    /// The date part of an automatic backup's name, which orders them; earlier versions wrote `Tachiyomi_<date>.json`,
    /// still counted (and pruned) with the rest.
    static func backupDate(_ name: String) -> Substring? {
        name.wholeMatch(of: #/(?:Orihon|Tachiyomi)_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2})\.json/#)?.output.1
    }

    static func isAutoBackupName(_ name: String) -> Bool {
        backupDate(name) != nil
    }

    /// Writes a new backup after dropping the oldest, so at most four remain. Files of other names (the user's own)
    /// are never touched. Blocking file I/O: call it off the main thread.
    @discardableResult
    static func write(_ data: Data, at date: Date, in directory: URL = directory) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(isAutoBackupName)
            .sorted { (backupDate($0) ?? "") > (backupDate($1) ?? "") }
        for name in existing.dropFirst(maxBackups - 1) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        let file = directory.appendingPathComponent(fileName(date))
        try data.write(to: file, options: .atomic)
        return file
    }
}
