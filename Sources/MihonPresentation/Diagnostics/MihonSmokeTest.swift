import Foundation
import MihonData

#if DEBUG
/// `MIHON_SMOKE_TEST=<seconds>` runs the real app — a real `WindowGroup` scene with its window toolbar, state
/// restoration and navigation authority, none of which the in-process UI tests can host. The root view replays a
/// navigation script (duo pane, every tab, pushed settings pages, fold / unfold); then the app prints every SwiftUI
/// runtime issue the process logged and exits (status 1 if there was any). `<seconds>` caps the wait.
///
///     open -n -g -j -W --env MIHON_SMOKE_TEST=30 --stdout smoke.txt Orihon-Preview.app
///
/// `-g -j` keep the run in the background (hidden, no focus change); the app also skips activating itself.
public enum MihonSmokeTest {
    public static var requestedDuration: TimeInterval? {
        ProcessInfo.processInfo.environment["MIHON_SMOKE_TEST"].flatMap(TimeInterval.init)
    }

    @MainActor private static var scriptFinished = false

    /// Called by the root view once its navigation script is done.
    @MainActor
    public static func finishScript() {
        scriptFinished = true
    }

    @MainActor
    public static func scheduleIfRequested() {
        guard let duration = requestedDuration else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(duration)
            while !scriptFinished && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Let the last transition settle and its log entries flush.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let issues = await Task.detached(priority: .utility) { MihonRuntimeGuard.issues(after: .distantPast) }.value
            // More than one store means a view re-created it (each one starts its own network bootstrap).
            let stores = MihonRepositoryStore.instanceCount
            print("MIHON_SMOKE_TEST script=\(scriptFinished ? "finished" : "timed out") issues=\(issues.count) stores=\(stores)")
            for issue in issues {
                print("  • \(issue)")
            }
            fflush(stdout)
            exit(issues.isEmpty && scriptFinished && stores == 1 ? 0 : 1)
        }
    }
}
#endif
