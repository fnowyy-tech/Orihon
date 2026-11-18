import SwiftUI
import MihonData
import MihonPresentation
#if os(macOS)
import AppKit
#else
import UIKit
import UserNotifications
#endif

@main
public struct MihonApp: App {
    /// Created once per process. Building the store inside the scene (formerly `MihonRootView.init`) made each
    /// scene update create another store whose launch tasks changed observed state and re-ran the scene — a
    /// loop that created hundreds of stores per second, each starting its own network requests.
    @State private var store = MihonRepositoryStore(
        showsDemoFeatures: MihonFeatureFlags.showsDemoFeatures,
        persistsState: true
    )
    #if os(iOS)
    @UIApplicationDelegateAdaptor(MihonAppDelegate.self) private var appDelegate
    #endif

    public init() {
        #if DEBUG
        let smokeTest = MihonSmokeTest.requestedDuration != nil
        MihonSmokeTest.scheduleIfRequested()
        #else
        let smokeTest = false
        #endif
        #if os(macOS)
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            // A smoke-test run stays in the background instead of taking focus.
            if !smokeTest {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
    }

    public var body: some Scene {
        WindowGroup("Orihon") {
            MihonRootView(store: store)
                #if os(macOS)
                // Desktop preview window only: on iOS the scene is the screen (e.g. the 466×678 pt
                // iPhone Duo cover display), and a minimum frame would push content off screen.
                .frame(minWidth: 393, minHeight: 720)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 860)
        #else
        .backgroundTask(.appRefresh(MihonLibraryUpdateScheduler.taskIdentifier)) { [store] in
            await MihonLibraryUpdateScheduler.runInBackground(store)
        }
        #endif
    }
}

#if os(iOS)
/// Notifications: "new chapters" also show while the app is open, and tapping one opens 更新.
final class MihonAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { MihonDeepLinks.shared.openUpdates() }
    }
}
#endif
