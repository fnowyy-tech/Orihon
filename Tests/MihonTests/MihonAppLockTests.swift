import XCTest
import SwiftUI
@testable import MihonData
@testable import MihonPresentation

/// Upstream `SecureActivityDelegate`: when the app locks, when it asks for Face ID, and the secure screen.
@MainActor
final class MihonAppLockTests: XCTestCase {
    /// Records the prompts and answers them with `outcome`.
    private final class FakeAuthenticator {
        var outcome: MihonAuthenticator.Outcome = .success
        var prompts = 0
    }

    private func makeLock(locked: Bool, _ fake: FakeAuthenticator) -> MihonAppLock {
        MihonAppLock(locked: locked) { _ in
            fake.prompts += 1
            return fake.outcome
        }
    }

    /// The prompt runs in a task of its own; let it finish.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testLockAfterRules() {
        XCTAssertTrue(MihonAppLockPolicy.locksOnReturn(lockAfter: 0, away: 0), "总是")
        XCTAssertFalse(MihonAppLockPolicy.locksOnReturn(lockAfter: -1, away: 86_400), "从不")
        XCTAssertFalse(MihonAppLockPolicy.locksOnReturn(lockAfter: 5, away: 299))
        XCTAssertTrue(MihonAppLockPolicy.locksOnReturn(lockAfter: 5, away: 300))
        XCTAssertEqual(MihonAppLockPolicy.lockAfterChoices.map(MihonAppLockPolicy.title(lockAfter:)),
                       ["总是", "1 分钟后", "2 分钟后", "5 分钟后", "10 分钟后", "从不"])
    }

    func testSecureScreenModes() {
        XCTAssertTrue(MihonAppLockPolicy.hidesContent(mode: .always, incognito: false))
        XCTAssertTrue(MihonAppLockPolicy.hidesContent(mode: .incognito, incognito: true))
        XCTAssertFalse(MihonAppLockPolicy.hidesContent(mode: .incognito, incognito: false))
        XCTAssertFalse(MihonAppLockPolicy.hidesContent(mode: .never, incognito: true))
    }

    func testStartsLockedAndAsksOnce() async {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.requireBiometricLock = true
        let fake = FakeAuthenticator()
        fake.outcome = .failed
        let lock = makeLock(locked: true, fake)
        XCTAssertTrue(lock.covers(store))

        lock.scenePhaseChanged(.active, store: store)
        await settle()
        XCTAssertEqual(fake.prompts, 1, "asked by itself at launch")
        XCTAssertTrue(lock.isLocked, "a cancelled prompt keeps it locked")

        // The prompt itself makes the scene inactive for a moment; coming back must not ask again by itself.
        lock.scenePhaseChanged(.inactive, store: store)
        lock.scenePhaseChanged(.active, store: store)
        await settle()
        XCTAssertEqual(fake.prompts, 1)

        fake.outcome = .success
        await lock.unlock(store: store)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(lock.covers(store))
    }

    func testReturningFromTheBackgroundLocksPerLockAfter() async {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.requireBiometricLock = true
        store.lockAppAfter = 5
        let fake = FakeAuthenticator()
        let lock = makeLock(locked: false, fake)
        let start = ContinuousClock.now

        lock.scenePhaseChanged(.inactive, store: store, now: start)
        lock.scenePhaseChanged(.active, store: store, now: start.advanced(by: .seconds(600)))
        XCTAssertFalse(lock.isLocked, "Control Center or a system sheet is not the background")

        lock.scenePhaseChanged(.background, store: store, now: start)
        lock.scenePhaseChanged(.active, store: store, now: start.advanced(by: .seconds(120)))
        XCTAssertFalse(lock.isLocked, "back within 5 minutes")

        lock.scenePhaseChanged(.background, store: store, now: start)
        lock.scenePhaseChanged(.inactive, store: store, now: start.advanced(by: .seconds(400)))
        lock.scenePhaseChanged(.active, store: store, now: start.advanced(by: .seconds(400)))
        XCTAssertTrue(lock.isLocked, "away for longer")
        await settle()
        XCTAssertEqual(fake.prompts, 1)
        XCTAssertFalse(lock.isLocked, "the prompt succeeded")

        store.requireBiometricLock = false
        lock.scenePhaseChanged(.background, store: store, now: start)
        lock.scenePhaseChanged(.active, store: store, now: start.advanced(by: .seconds(4_000)))
        XCTAssertFalse(lock.isLocked, "the lock was switched off")
    }

    func testDeviceWithoutPasscodeTurnsTheLockOff() async {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.requireBiometricLock = true
        let fake = FakeAuthenticator()
        fake.outcome = .unavailable
        let lock = makeLock(locked: true, fake)
        await lock.unlock(store: store)
        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(store.requireBiometricLock, "upstream turns the lock off when the device cannot authenticate")
    }

    func testSecureScreenCoversOnlyWhileAway() {
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        let lock = makeLock(locked: false, FakeAuthenticator())
        store.secureScreen = .incognito
        lock.scenePhaseChanged(.inactive, store: store)
        XCTAssertFalse(lock.covers(store), "incognito mode is off")
        store.incognitoMode = true
        XCTAssertTrue(lock.covers(store))
        lock.scenePhaseChanged(.active, store: store)
        XCTAssertFalse(lock.covers(store), "shown again in the foreground")
        store.secureScreen = .never
        lock.scenePhaseChanged(.background, store: store)
        XCTAssertFalse(lock.covers(store))
    }

    func testLockSettingsAreSavedAndOldSwitchCarriesOver() throws {
        let saved = MihonSettingsSnapshot(requireBiometricLock: true, lockAppAfter: 10, secureScreen: .never)
        let decoded = try JSONDecoder().decode(MihonSettingsSnapshot.self, from: JSONEncoder().encode(saved))
        let store = MihonRepositoryStore(bootstrapNetwork: false)
        store.apply(decoded)
        XCTAssertTrue(store.requireBiometricLock)
        XCTAssertEqual(store.lockAppAfter, 10)
        XCTAssertEqual(store.secureScreen, .never)

        let old = try JSONDecoder().decode(MihonSettingsSnapshot.self, from: Data(#"{"secureScreenInAppSwitcher":true,"lockAppAfter":7}"#.utf8))
        let upgraded = MihonRepositoryStore(bootstrapNetwork: false)
        upgraded.apply(old)
        XCTAssertEqual(upgraded.secureScreen, .always, "the old switch, on")
        XCTAssertEqual(upgraded.lockAppAfter, 0, "not one of the choices: the default")
        XCTAssertEqual(MihonRepositoryStore(bootstrapNetwork: false).secureScreen, .incognito, "upstream's default")
    }
}
