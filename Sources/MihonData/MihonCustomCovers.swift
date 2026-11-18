import Foundation

// MARK: - Custom covers (upstream `CoverCache`'s custom covers)

/// A page set as a title's cover (the reader's 设为封面), kept apart from the source's cover URL so refreshing the
/// title does not undo it. In Application Support, which iOS never purges; under XCTest in a temporary folder, like
/// the image cache.
public enum MihonCustomCovers {
    public static let directory: URL = {
        let fileManager = FileManager.default
        let base = NSClassFromString("XCTestCase") != nil
            ? fileManager.temporaryDirectory.appendingPathComponent("MihonTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
                .appendingPathComponent("Mihon-iOS", isDirectory: true)
        return base.appendingPathComponent("Covers", isDirectory: true)
    }()

    static func file(_ mangaId: Int64) -> URL {
        directory.appendingPathComponent("\(mangaId).jpg")
    }

    /// Every custom cover's version (its modification time in ms), read once when the store starts.
    static func versions() -> [Int64: Int64] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        var versions: [Int64: Int64] = [:]
        for url in urls where url.pathExtension == "jpg" {
            guard let id = Int64(url.deletingPathExtension().lastPathComponent),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            versions[id] = Int64(modified.timeIntervalSince1970 * 1000)
        }
        return versions
    }

    /// The cover's URL with its version, so a replaced cover is not shown from the memory cache. Built anew each
    /// launch (never saved): iOS moves the app's container on reinstall.
    static func url(_ mangaId: Int64, version: Int64) -> String {
        file(mangaId).absoluteString + "?v=\(version)"
    }

    public static func isCustomCoverUrl(_ url: String) -> Bool {
        url.hasPrefix(directory.absoluteString)
    }

    /// The bytes behind a custom cover URL — files in the covers folder only.
    static func data(forUrl url: String) -> Data? {
        guard isCustomCoverUrl(url), let path = URL(string: url)?.path else { return nil }
        // Standardized first: "Covers/../x" starts like a cover but is not one.
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return nil }
        return try? Data(contentsOf: file)
    }
}
