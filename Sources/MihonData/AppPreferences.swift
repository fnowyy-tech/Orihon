import Foundation
import SwiftUI
import MihonDomain

// MARK: - Mihon 1:1 Theme Palettes & Appearance Preferences

/// 1:1 with upstream `AppTheme` (Monet is Android-only and therefore omitted).
public enum MihonThemePalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case mihonDefault = "默认"
    case catppuccin = "Catppuccin"
    case greenApple = "青苹果"
    case lavender = "薰衣草"
    case midnightDusk = "午夜幽暗"
    case monochrome = "单色"
    case nord = "Nord"
    case strawberryDaiquiri = "草莓黛绮莉"
    case tako = "Tako"
    case tealTurquoise = "青绿"
    case tidalWave = "浪潮"
    case tokyoNight = "东京夜色"
    case yinYang = "阴阳"
    case yotsuba = "四叶草"

    public var id: String { rawValue }
}

public enum DarkModePreference: String, Codable, CaseIterable, Sendable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum ReaderBackgroundColor: String, Codable, CaseIterable, Sendable {
    case black = "黑色"
    case darkGray = "灰色"
    case white = "白色"
    case automatic = "自动"
}

public enum ReaderScaleType: String, Codable, CaseIterable, Sendable {
    case fitScreen = "适应屏幕"
    case fitWidth = "适应宽度"
    case fitHeight = "适应高度"
    case originalSize = "原始大小"
    case smartFit = "智能填充"
}

public struct ReaderColorFilterState: Codable, Hashable, Sendable {
    public var isEnabled: Bool = false
    public var grayscale: Bool = false
    public var inverted: Bool = false
    public var customBrightness: Double = 0.0 // -0.5 to +0.3
    public var redOverlay: Double = 0.0
    public var greenOverlay: Double = 0.0
    public var blueOverlay: Double = 0.0
    public var overlayAlpha: Double = 0.0

    public init() {}
}

// MARK: - iPhone Duo (Foldable / Dual-Screen Book Posture) Adaptation Models

public enum iPhoneDuoPostureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case autoDetect = "自动识别"
    case unfoldedBook = "展开（双屏书本）"
    case foldedSingle = "折叠（单屏）"
    case tabletopTent = "悬停（帐篷）"

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .autoDetect: return "自动"
        case .unfoldedBook: return "双屏"
        case .foldedSingle: return "单屏"
        case .tabletopTent: return "悬停"
        }
    }

    public var iconName: String {
        switch self {
        case .autoDetect: return "rectangle.split.2x1"
        case .unfoldedBook: return "book.pages"
        case .foldedSingle: return "iphone"
        case .tabletopTent: return "laptopcomputer"
        }
    }
}

public enum DuoDualPageSpreadBehavior: String, Codable, CaseIterable, Sendable {
    case autoWhenUnfolded = "展开时自动双页"
    case alwaysDualPage = "始终双页"
    case singlePageOnly = "始终单页"
}

/// How a book spread turns on the iPhone Duo: a sheet curling over the spine like a printed book, or both pages
/// sliding together.
public enum DuoPageTurnStyle: String, Codable, CaseIterable, Sendable {
    case slide = "平移"
    case curl = "仿真卷页"

    /// The name in settings (the saved value stays the raw one): the curl is still being tested.
    public var label: String { self == .curl ? "仿真卷页（测试中）" : rawValue }
}

// MARK: - Security (upstream `SecurityPreferences`)

/// Upstream `SecureScreenMode`: when the app hides its content from the app switcher.
public enum SecureScreenMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case always = "总是"
    case incognito = "无痕模式"
    case never = "从不"

    public var id: String { rawValue }
}

/// Upstream `SecureActivityDelegate`'s rules for Face ID / passcode and the secure screen.
public enum MihonAppLockPolicy {
    /// Upstream `LockAfterValues`, in minutes: 0 locks on every return, -1 only when the app starts.
    public static let lockAfterChoices = [0, 1, 2, 5, 10, -1]

    public static func title(lockAfter minutes: Int) -> String {
        switch minutes {
        case 0: return "总是"
        case -1: return "从不"
        default: return "\(minutes) 分钟后"
        }
    }

    /// Whether coming back after `away` seconds in the background asks to unlock again.
    public static func locksOnReturn(lockAfter minutes: Int, away: TimeInterval) -> Bool {
        switch minutes {
        case -1: return false
        case 0: return true
        default: return away >= TimeInterval(minutes) * 60
        }
    }

    public static func hidesContent(mode: SecureScreenMode, incognito: Bool) -> Bool {
        mode == .always || (mode == .incognito && incognito)
    }
}

// MARK: - Library updates (upstream `LibraryUpdateJob`)

/// What a library update found: for the snackbar, and the notification of a background update.
public struct LibraryUpdateResult: Sendable, Equatable {
    public struct Title: Sendable, Equatable {
        public var mangaId: Int64
        public var title: String
        public var chapterNames: [String]
        /// The new chapters (upstream downloads them when "Download new chapters" is on).
        public var chapterIds: [Int64] = []
    }

    public var newChapters = 0
    public var failures = 0
    public var titles: [Title] = []
    /// Titles 智能更新 left out (`LibraryUpdateMangaRestriction`).
    public var skipped = 0

    public init(newChapters: Int = 0, failures: Int = 0, titles: [Title] = [], skipped: Int = 0) {
        self.newChapters = newChapters
        self.failures = failures
        self.titles = titles
        self.skipped = skipped
    }

    /// Upstream's "new chapters" notification: one title with its chapters, or the titles.
    public var notificationBody: String? {
        guard let first = titles.first else { return nil }
        if titles.count == 1 {
            let names = first.chapterNames.prefix(3).joined(separator: "、")
            let more = first.chapterNames.count > 3 ? " 等 \(first.chapterNames.count) 个章节" : ""
            return "\(first.title)：\(names)\(more)"
        }
        let shown = titles.prefix(3).map(\.title).joined(separator: "、")
        return titles.count > 3 ? "\(shown) 等 \(titles.count) 部作品" : shown
    }
}

/// Upstream's automatic update intervals, in hours (0: off).
public enum MihonLibraryUpdateInterval {
    public static let choices = [0, 12, 24, 48, 72, 168]

    public static func title(hours: Int) -> String {
        switch hours {
        case 0: return "关闭"
        case 12: return "每 12 小时"
        case 24: return "每天"
        case 168: return "每周"
        default: return "每 \(hours / 24) 天"
        }
    }
}

// MARK: - Library update restrictions (upstream `LibraryPreferences`)

/// Upstream `autoUpdateDeviceRestrictions` (自动更新的系统限制): what an automatic update waits for. Upstream hands
/// them to WorkManager as constraints; iOS has none for a background refresh, so a run that starts without them
/// does nothing and asks for the next one.
public enum LibraryUpdateDeviceRestriction: String, Codable, CaseIterable, Sendable {
    case onlyOnWiFi = "wifi"
    case networkNotMetered = "network_not_metered"
    case charging = "ac"

    /// Upstream's default: Wi-Fi only.
    public static let defaults: Set<Self> = [.onlyOnWiFi]

    public var title: String {
        switch self {
        case .onlyOnWiFi: return "仅连接 Wi-Fi 时"
        case .networkNotMetered: return "仅通过不按流量计费的网络"
        case .charging: return "充电时"
        }
    }

    /// Whether an automatic update may run now. Wired Ethernet counts as Wi-Fi: it is not the cellular data the
    /// setting is there to save.
    public static func allow(_ restrictions: Set<Self>, network: MihonNetworkState, isCharging: Bool) -> Bool {
        guard network.isConnected else { return false }
        if restrictions.contains(.onlyOnWiFi) && !network.isWiFi { return false }
        if restrictions.contains(.networkNotMetered) && network.isMetered { return false }
        if restrictions.contains(.charging) && !isCharging { return false }
        return true
    }
}

/// The network a background refresh starts on (from `NWPath`).
public struct MihonNetworkState: Sendable, Equatable {
    public var isConnected: Bool
    /// Wi-Fi or wired Ethernet.
    public var isWiFi: Bool
    /// Cellular or a personal hotspot (`isExpensive`), or Low Data Mode (`isConstrained`).
    public var isMetered: Bool

    public init(isConnected: Bool, isWiFi: Bool, isMetered: Bool) {
        self.isConnected = isConnected
        self.isWiFi = isWiFi
        self.isMetered = isMetered
    }
}

/// Upstream `autoUpdateMangaRestrictions` (智能更新): titles every library update — manual or automatic — skips.
/// All four by default, as upstream.
public enum LibraryUpdateMangaRestriction: String, Codable, CaseIterable, Sendable {
    case hasUnread = "manga_fully_read"
    case notStarted = "manga_started"
    case completed = "manga_ongoing"
    case outsideReleasePeriod = "manga_outside_release_period"

    public static let defaults = Set(allCases)

    public var title: String {
        switch self {
        case .hasUnread: return "跳过有未读章节的作品"
        case .notStarted: return "跳过尚未开始阅读的作品"
        case .completed: return "跳过已完结的作品"
        case .outsideReleasePeriod: return "预测下次更新时间"
        }
    }
}
