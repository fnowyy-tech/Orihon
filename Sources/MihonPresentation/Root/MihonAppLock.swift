import SwiftUI
import LocalAuthentication
import MihonData
#if canImport(UIKit)
import UIKit
#endif

// MARK: - App lock & secure screen (upstream `SecureActivityDelegate` + `UnlockActivity`)

/// Face ID / Touch ID / passcode, as upstream's `BIOMETRIC_WEAK | DEVICE_CREDENTIAL`.
enum MihonAuthenticator {
    enum Outcome: Equatable {
        case success
        case failed
        /// No passcode on the device: nothing to authenticate with.
        case unavailable
    }

    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch {
            return .failed
        }
    }
}

/// Upstream "Require unlock" with "Lock when idle", and "Secure screen". A new process starts locked; coming back
/// from the background locks again per `MihonAppLockPolicy`. Leaving the foreground for a moment (Control Center,
/// the Face ID sheet itself) never locks, but does raise the secure-screen cover.
@MainActor @Observable
final class MihonAppLock {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var isSceneActive = true
    /// A monotonic clock (running while the phone sleeps): setting the date back cannot skip the lock.
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    /// Asked by itself once per lock; after a cancel the 解锁 button asks again.
    @ObservationIgnored private var promptedForThisLock = false
    @ObservationIgnored private let authenticate: (String) async -> MihonAuthenticator.Outcome

    init(locked: Bool, authenticate: @escaping (String) async -> MihonAuthenticator.Outcome = MihonAuthenticator.authenticate) {
        isLocked = locked
        self.authenticate = authenticate
    }

    func covers(_ store: MihonRepositoryStore) -> Bool {
        isLocked || (!isSceneActive && MihonAppLockPolicy.hidesContent(mode: store.secureScreen, incognito: store.incognitoMode))
    }

    func scenePhaseChanged(_ phase: ScenePhase, store: MihonRepositoryStore, now: ContinuousClock.Instant = .now) {
        switch phase {
        case .background:
            isSceneActive = false
            if backgroundedAt == nil { backgroundedAt = now }
            // Upstream's automatic backup runs on a schedule; here leaving the app is one of the moments to check.
            Task { await store.performAutomaticBackupIfDue() }
        case .inactive:
            isSceneActive = false
        case .active:
            isSceneActive = true
            if let closedAt = backgroundedAt {
                backgroundedAt = nil
                let away = closedAt.duration(to: now)
                let seconds = TimeInterval(away.components.seconds) + TimeInterval(away.components.attoseconds) / 1e18
                if store.requireBiometricLock && !isLocked
                    && MihonAppLockPolicy.locksOnReturn(lockAfter: store.lockAppAfter, away: seconds) {
                    isLocked = true
                    promptedForThisLock = false
                }
            }
            if isLocked && !promptedForThisLock {
                promptedForThisLock = true
                Task { await unlock(store: store) }
            }
        @unknown default:
            break
        }
    }

    func unlock(store: MihonRepositoryStore) async {
        guard isLocked, !isAuthenticating else { return }
        guard store.requireBiometricLock else {
            isLocked = false
            return
        }
        isAuthenticating = true
        let outcome = await authenticate("解锁 Tachiyomi")
        isAuthenticating = false
        switch outcome {
        case .success:
            isLocked = false
        case .unavailable:
            // Upstream turns the lock off on a device that cannot authenticate.
            store.requireBiometricLock = false
            isLocked = false
            store.showStatusBanner("这台设备没有设置锁屏密码，已关闭应用锁")
        case .failed:
            break
        }
    }
}

/// What covers the app: the lock (logo + 解锁) or, for the secure screen, the logo alone.
struct MihonAppShieldView: View {
    let lock: MihonAppLock
    let store: MihonRepositoryStore
    @Environment(\.mihonColors) private var colors

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()
            VStack(spacing: 24) {
                MihonLogoMark()
                    .fill(colors.onSurface)
                    .frame(width: 64, height: 61)
                if lock.isLocked {
                    Text("Tachiyomi 已锁定")
                        .font(MihonType.titleMedium)
                        .foregroundStyle(colors.onSurface)
                    Button {
                        Task { await lock.unlock(store: store) }
                    } label: {
                        Label("解锁", systemImage: "lock.open")
                    }
                    .buttonStyle(MihonButtonStyle(.filled))
                    .disabled(lock.isAuthenticating)
                    .mihonTestAnchor("lock.unlock")
                }
            }
        }
    }
}

/// Draws the shield above everything: on iOS in a window of its own (sheets and the reader's full-screen cover
/// belong to the app's window, so an overlay in it would leave them uncovered); on a Mac over the main window.
struct MihonAppLockModifier: ViewModifier {
    let store: MihonRepositoryStore
    let lock: MihonAppLock
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let covered = lock.covers(store)
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                lock.scenePhaseChanged(phase, store: store)
            }
            #if canImport(UIKit)
            .onChange(of: covered, initial: true) { _, covered in
                if covered {
                    MihonShieldWindows.shared.show(lock: lock, store: store)
                } else {
                    MihonShieldWindows.shared.hide()
                }
            }
            #else
            .overlay {
                if covered {
                    MihonAppShieldView(lock: lock, store: store)
                }
            }
            #endif
    }
}

#if canImport(UIKit)
@MainActor
final class MihonShieldWindows {
    static let shared = MihonShieldWindows()
    private var windows: [UIWindow] = []

    func show(lock: MihonAppLock, store: MihonRepositoryStore) {
        guard windows.isEmpty else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.overrideUserInterfaceStyle = switch store.darkMode {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
            let host = UIHostingController(rootView:
                MihonAppShieldView(lock: lock, store: store)
                    .mihonTheme(store.themePalette, pureBlack: store.pureBlackDarkMode)
            )
            host.view.accessibilityViewIsModal = true
            window.rootViewController = host
            // Key, so a focused search's keyboard and the reader's hardware keys stop reaching the app behind it.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            window.makeKeyAndVisible()
            windows.append(window)
        }
    }

    func hide() {
        let scenes = windows.compactMap(\.windowScene)
        for window in windows {
            window.isHidden = true
        }
        windows.removeAll()
        for scene in scenes {
            scene.windows.first { $0.windowLevel == .normal && !$0.isHidden }?.makeKey()
        }
    }
}
#endif
