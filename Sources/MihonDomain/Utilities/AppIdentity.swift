import Foundation

/// The app's identity at run time. The bundle id is set when the app is packaged (`Packaging/iOS/testflight.sh`), so
/// everything named after it — log subsystem, Keychain service, background task — follows the installed app.
public enum MihonAppIdentity {
    /// The running bundle's id; a neutral one where there is none (tests, command-line tools).
    public static let bundleId = Bundle.main.bundleIdentifier ?? "com.example.tachiyomi"
}
