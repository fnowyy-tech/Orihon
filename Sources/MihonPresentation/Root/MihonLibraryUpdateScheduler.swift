import SwiftUI
import OSLog
import UserNotifications
import MihonDomain
import MihonData
#if os(iOS)
import BackgroundTasks
import Network
import os
#endif

// MARK: - Automatic library updates (upstream `LibraryUpdateJob` on a schedule)

/// iOS runs a background refresh when it sees fit — at the earliest an interval after the last update — and gives it
/// about half a minute; the update stops when that runs out and the titles it did not reach are checked next time.
/// New chapters are announced like upstream's "new chapters" notification; tapping it opens 更新.
public enum MihonLibraryUpdateScheduler {
    /// Also in Info.plist's `BGTaskSchedulerPermittedIdentifiers` (set with the bundle id when packaged).
    public static let taskIdentifier = MihonAppIdentity.bundleId + ".libraryUpdate"
    static let log = Logger(subsystem: MihonAppIdentity.bundleId, category: "LibraryUpdate")

    /// Asks for the next run (or cancels it when automatic updates are off).
    @MainActor
    public static func schedule(_ store: MihonRepositoryStore, now: Date = Date()) {
        #if os(iOS)
        guard store.autoUpdateInterval > 0 else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextRun(interval: store.autoUpdateInterval, lastUpdate: store.lastLibraryUpdateAt, now: now)
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("next automatic update after \(request.earliestBeginDate?.description ?? "-", privacy: .public)")
        } catch {
            log.error("could not schedule the automatic update: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    #if os(iOS)
    /// The network right now: the first path an `NWPathMonitor` reports — or, with none in a few seconds, offline (the
    /// run is dropped and asked for again).
    static func currentNetwork(timeout: TimeInterval = 3) async -> MihonNetworkState {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let reported = OSAllocatedUnfairLock(initialState: false)
            // Only the first answer counts; the handler goes with the monitor so neither outlives this.
            let report: @Sendable (MihonNetworkState) -> Void = { state in
                guard reported.withLock({ done in defer { done = true }; return !done }) else { return }
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: state)
            }
            monitor.pathUpdateHandler = { path in
                report(MihonNetworkState(
                    isConnected: path.status == .satisfied,
                    isWiFi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                    isMetered: path.isExpensive || path.isConstrained
                ))
            }
            monitor.start(queue: DispatchQueue(label: MihonAppIdentity.bundleId + ".network-path"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                report(MihonNetworkState(isConnected: false, isWiFi: false, isMetered: false))
            }
        }
    }
    #endif

    /// An interval after the last update, and not right away (iOS ignores requests for the next few minutes anyway).
    static func nextRun(interval hours: Int, lastUpdate: Date?, now: Date) -> Date {
        let due = (lastUpdate ?? now).addingTimeInterval(TimeInterval(hours) * 3600)
        return max(due, now.addingTimeInterval(15 * 60))
    }

    /// The background refresh: update, save, notify, and ask for the next run.
    @MainActor
    public static func runInBackground(_ store: MihonRepositoryStore) async {
        guard store.autoUpdateInterval > 0 else { return }
        #if os(iOS)
        // Upstream's WorkManager constraints. iOS cannot wait for them, so this run is dropped and the next asked for:
        // it stays due, so that is a quarter of an hour on.
        let network = await currentNetwork()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        guard LibraryUpdateDeviceRestriction.allow(store.libraryUpdateDeviceRestrictions, network: network, isCharging: isCharging) else {
            log.info("automatic update skipped: device restrictions (Wi-Fi \(network.isWiFi), metered \(network.isMetered), charging \(isCharging))")
            schedule(store)
            return
        }
        #endif
        log.info("automatic update started")
        let result = await store.refreshLibraryUpdates(reportsResult: false)
        log.info("automatic update: \(result.newChapters) new chapters in \(result.titles.count) titles, \(result.failures) failed, cancelled \(Task.isCancelled)")
        store.saveNow()
        schedule(store)
        await notify(result, hidingTitles: store.requireBiometricLock)
    }

    /// With the app locked, the notification names no titles (upstream's "hide notification content").
    static func notificationBody(_ result: LibraryUpdateResult, hidingTitles: Bool) -> String? {
        guard let titles = result.notificationBody else { return nil }
        return hidingTitles ? "\(result.newChapters) 个新章节" : titles
    }

    static func notify(_ result: LibraryUpdateResult, hidingTitles: Bool) async {
        guard let body = notificationBody(result, hidingTitles: hidingTitles) else { return }
        let content = UNMutableNotificationContent()
        content.title = "发现新章节"
        content.body = body
        content.sound = .default
        content.threadIdentifier = "library-update"
        let request = UNNotificationRequest(identifier: "library-update-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Upstream asks for the notification permission when automatic updates are switched on.
    public static func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}

/// What a tapped notification asks the app to show (the delegate lives in the app target).
@MainActor @Observable
public final class MihonDeepLinks {
    public static let shared = MihonDeepLinks()
    /// Bumped by a tapped "new chapters" notification: the root view opens 更新.
    public private(set) var openUpdatesRequest = 0

    public func openUpdates() {
        openUpdatesRequest += 1
    }
}
