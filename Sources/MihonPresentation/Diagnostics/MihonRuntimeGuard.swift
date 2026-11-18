import Foundation
import OSLog

// MARK: - SwiftUI runtime-issue self check
//
// SwiftUI reports undefined-behaviour bugs (AttributeGraph cycles, state mutated during a view update,
// NavigationStack paths written several times per frame, …) only as unified-log messages of the *current*
// process. `OSLogStore(scope: .currentProcessIdentifier)` can read those back, so tests and DEBUG builds
// turn them into visible failures instead of silent console noise.

public struct MihonRuntimeIssue: Hashable, Sendable, CustomStringConvertible {
    public let date: Date
    public let subsystem: String
    public let category: String
    public let message: String

    public var description: String { "[\(subsystem):\(category)] \(message)" }
}

public enum MihonRuntimeGuard {
    /// Subsystems whose error / fault entries always indicate a SwiftUI misuse.
    static let watchedSubsystems: Set<String> = ["com.apple.SwiftUI", "com.apple.attributegraph", "com.apple.runtime-issues"]

    /// Known SwiftUI runtime-issue phrases (some are logged at `default` level).
    static let knownPhrases = [
        "cycle detected",
        "Publishing changes from within view updates",
        "Modifying state during view update",
        "tried to update multiple times per frame",
        "Bound preference",
        "undefined behavior"
    ]

    /// Entries whose message matches these phrases are framework noise, not app bugs.
    static let ignoredPhrases = [
        "Unable to obtain a task name port right",
        // The UI self-test's own anchors (`mihonTestAnchor`, test runs only): a transition can move one twice in a
        // frame (hidden, then shown), which says nothing about the app's views.
        "onChange(of: MihonAnchorGeometry)"
    ]

    /// Unified-log timestamps run on the log's own clock (observed ~50 ms behind `Date()`), so callers compare
    /// against a checkpoint taken from the log itself rather than a wall-clock `Date`.
    public static func checkpoint() -> Date {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(timeIntervalSinceEnd: -2)) else {
            return Date()
        }
        var latest: Date?
        for entry in entries where latest.map({ entry.date > $0 }) ?? true {
            latest = entry.date
        }
        return latest ?? Date()
    }

    /// Issues logged strictly after `checkpoint`, plus the newest timestamp seen (the next checkpoint).
    public static func scan(after checkpoint: Date) -> (issues: [MihonRuntimeIssue], latest: Date) {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return ([], checkpoint)
        }
        // Start near the checkpoint instead of enumerating the whole process log on every scan
        // (with a second of slack for clock skew; older entries are still filtered out below).
        let position = checkpoint == .distantPast ? nil : store.position(date: checkpoint.addingTimeInterval(-1))
        guard let entries = try? store.getEntries(at: position) else {
            return ([], checkpoint)
        }
        var latest = checkpoint
        var result: [MihonRuntimeIssue] = []
        for case let entry as OSLogEntryLog in entries where entry.date > checkpoint {
            if entry.date > latest { latest = entry.date }
            let watched = watchedSubsystems.contains(entry.subsystem)
            let severe = entry.level == .error || entry.level == .fault
            let message = entry.composedMessage
            let matchesPhrase = knownPhrases.contains { message.localizedCaseInsensitiveContains($0) }
            guard (watched && (severe || matchesPhrase)) || (watched == false && matchesPhrase && entry.subsystem.hasPrefix("com.apple.")) else {
                continue
            }
            if ignoredPhrases.contains(where: { message.contains($0) }) { continue }
            result.append(MihonRuntimeIssue(date: entry.date, subsystem: entry.subsystem, category: entry.category, message: message))
        }
        return (result, latest)
    }

    /// Convenience for one-off checks: everything after `checkpoint`.
    public static func issues(after checkpoint: Date) -> [MihonRuntimeIssue] {
        scan(after: checkpoint).issues
    }
}

#if DEBUG
/// DEBUG builds poll their own log and surface SwiftUI runtime issues while you click around,
/// so problems are noticed at the moment they happen rather than discovered later in Console.app.
@MainActor
public final class MihonRuntimeIssueMonitor {
    public static let shared = MihonRuntimeIssueMonitor()

    private var task: Task<Void, Never>?
    private var reported: Set<MihonRuntimeIssue> = []
    public private(set) var issues: [MihonRuntimeIssue] = []

    public func start(interval: TimeInterval = 3, onIssue: @escaping @MainActor (MihonRuntimeIssue) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            var cursor = await Task.detached(priority: .utility) { MihonRuntimeGuard.checkpoint() }.value
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let since = cursor
                let (found, latest) = await Task.detached(priority: .utility) { MihonRuntimeGuard.scan(after: since) }.value
                cursor = latest
                guard let self else { return }
                for issue in found where !self.reported.contains(issue) {
                    self.reported.insert(issue)
                    self.issues.append(issue)
                    FileHandle.standardError.write(Data("[MihonRuntimeGuard] \(issue)\n".utf8))
                    onIssue(issue)
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
