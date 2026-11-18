import XCTest
@testable import MihonData

/// Upstream's automatic backups: every `autoBackupInterval` hours, the last four kept.
@MainActor
final class MihonAutoBackupTests: XCTestCase {
    func testKeepsTheLastFourAndLeavesOtherFilesAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MihonAutoBackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("我的备份.json"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for hour in 0..<6 {
            try MihonAutoBackup.write(Data("\(hour)".utf8), at: start.addingTimeInterval(TimeInterval(hour) * 3600), in: folder)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names.filter(MihonAutoBackup.isAutoBackupName).count, 4)
        XCTAssertTrue(names.contains("我的备份.json"), "the user's own file stays")
        XCTAssertTrue(names.contains(MihonAutoBackup.fileName(start.addingTimeInterval(5 * 3600))), "the newest stays")
        XCTAssertFalse(names.contains(MihonAutoBackup.fileName(start)), "the oldest went")
        XCTAssertEqual(MihonAutoBackup.intervalChoices.map(MihonAutoBackup.title(hours:)), ["关闭", "每 6 小时", "每 12 小时", "每天", "每 2 天", "每周"])
    }

    /// Backups written under the app's earlier name count with the new ones and go by date, not by name ("T" sorts
    /// after "O": by name, the old ones would pass for the newest and the new ones would be pruned).
    func testEarlierNamedBackupsArePrunedByDate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MihonAutoBackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = MihonAutoBackup.fileName(start).replacingOccurrences(of: "Orihon_", with: "Tachiyomi_")
        let earlierLater = MihonAutoBackup.fileName(start.addingTimeInterval(3600)).replacingOccurrences(of: "Orihon_", with: "Tachiyomi_")
        for name in [earlier, earlierLater] {
            try Data("old".utf8).write(to: folder.appendingPathComponent(name))
        }
        for hour in 2..<6 {
            try MihonAutoBackup.write(Data("\(hour)".utf8), at: start.addingTimeInterval(TimeInterval(hour) * 3600), in: folder)
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(MihonAutoBackup.isAutoBackupName(earlier), "the earlier name still counts")
        XCTAssertEqual(names, Set((2..<6).map { MihonAutoBackup.fileName(start.addingTimeInterval(TimeInterval($0) * 3600)) }),
                       "the four newest stay, whatever their name; the two older ones went")
        XCTAssertTrue(MihonAutoBackup.fileName(start).hasPrefix("Orihon_"))
    }

    func testBacksUpOnlyWhenDue() async throws {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        XCTAssertEqual(store.autoBackupInterval, 12, "on by default, every 12 hours (upstream)")
        let now = Date()
        let first = await store.performAutomaticBackupIfDue(now: now)
        let file = try XCTUnwrap(first)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertGreaterThan(try store.libraryTitleCount(inBackup: Data(contentsOf: file)), 0, "a restorable backup")
        let again = await store.performAutomaticBackupIfDue(now: now.addingTimeInterval(3600))
        XCTAssertNil(again, "not due within 12 hours")
        store.autoBackupInterval = 0
        let off = await store.performAutomaticBackupIfDue(now: now.addingTimeInterval(86_400))
        XCTAssertNil(off)
    }

    /// A session showing the seed library (its saved one unreadable) must not back that up — nor prune real backups.
    func testNoBackupFromAnUnreadLibrary() async {
        let store = MihonRepositoryStore(bootstrapNetwork: false, showsDemoFeatures: false)
        store.persistenceBlocked = true
        let file = await store.performAutomaticBackupIfDue()
        XCTAssertNil(file)
    }
}
