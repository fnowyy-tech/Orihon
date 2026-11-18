import Foundation
import Observation
import MihonDomain

// MARK: - Settings persistence
//
// The library is saved as a snapshot file (`MihonDiskPersistenceManager`); settings and per-device state live in
// one JSON value in `UserDefaults`. Every field is optional and decoded on its own, so a setting a later build adds
// — or a value it no longer knows — only falls back to that setting's default.

struct MihonSettingsSnapshot: Codable, Equatable {
    var themePalette: MihonThemePalette?
    var darkMode: DarkModePreference?
    var pureBlackDarkMode: Bool?
    var incognitoMode: Bool?
    var downloadedOnlyMode: Bool?
    var requireBiometricLock: Bool?
    /// Builds before 20: a switch, now `secureScreen` (read only, to carry an "on" over as `.always`).
    var secureScreenInAppSwitcher: Bool?
    var lockAppAfter: Int?
    var secureScreen: SecureScreenMode?
    var stubSourceNames: [Int64: String]?
    var autoUpdateInterval: Int?
    var lastLibraryUpdateAt: Date?
    var libraryUpdateDeviceRestrictions: Set<LibraryUpdateDeviceRestriction>?
    var libraryUpdateMangaRestrictions: Set<LibraryUpdateMangaRestriction>?
    var libraryUpdateIncludedCategories: Set<Int64>?
    var libraryUpdateExcludedCategories: Set<Int64>?
    var libraryUpdateRefreshesMetadata: Bool?
    var libraryUpdateCheckedAt: [Int64: Date]?
    var upcomingIncludedCategories: Set<Int64>?
    var upcomingExcludedCategories: Set<Int64>?
    var downloadNewChapters: Bool?
    var downloadAheadCount: Int?
    var migrationFlags: Set<MihonRepositoryStore.MigrationFlag>?
    var autoBackupInterval: Int?
    var lastAutoBackupAt: Date?

    var libraryDisplayMode: LibraryDisplayMode?
    var librarySortOption: LibrarySortOption?
    var librarySortAscending: Bool?
    var libraryFilter: LibraryFilterState?
    var showUnreadBadge: Bool?
    var showDownloadBadge: Bool?
    var showLocalBadge: Bool?
    var showLanguageBadge: Bool?
    var showCategoryTabs: Bool?
    var showMangaCountInCategory: Bool?
    var showContinueReadingButton: Bool?
    var columnsPerRowPortrait: Int?

    var defaultReadingMode: ReadingMode?
    var readerTapZone: TapZoneType?
    var readerBackground: ReaderBackgroundColor?
    var readerScaleType: ReaderScaleType?
    var cropBorders: Bool?
    var showPageNumber: Bool?
    var keepScreenOn: Bool?
    var showTapZonesOverlayOnLaunch: Bool?
    var volumeKeysScroll: Bool?
    var doubleTapToZoom: Bool?
    var skipReadChapters: Bool?
    var skipFilteredChapters: Bool?
    var skipDuplicateChapters: Bool?
    var colorFilter: ReaderColorFilterState?
    var mangaDexDataSaver: Bool?

    var duoPostureMode: iPhoneDuoPostureMode?
    var duoDualPageBehavior: DuoDualPageSpreadBehavior?
    var shiftDoublePageCover: Bool?
    var invertDoublePageOrder: Bool?
    var duoHingeGutterWidth: Double?
    var showDuoSpineShadow: Bool?
    var duoPageTurnEffect: Bool?
    var duoPageTurnStyle: DuoPageTurnStyle?
    /// Build 29 saved its curl default with every other setting: the style is restored only once picked by hand.
    var duoPageTurnStylePicked: Bool?

    var deleteAfterReading: Bool?
    var downloadedChapterIds: Set<Int64>?
    var enabledLanguages: Set<String>?
    var showNsfwSources: Bool?
    var pinnedSourceIds: Set<Int64>?
    var lastUsedSourceId: Int64?
    var defaultLibraryCategory: Int64?
    /// The download queue's chapters, in order.
    var queuedChapterIds: [Int64]?
    var chaptersPendingDeletion: Set<Int64>?
}

extension MihonSettingsSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        self.init()
        themePalette = value(.themePalette)
        darkMode = value(.darkMode)
        pureBlackDarkMode = value(.pureBlackDarkMode)
        incognitoMode = value(.incognitoMode)
        downloadedOnlyMode = value(.downloadedOnlyMode)
        requireBiometricLock = value(.requireBiometricLock)
        secureScreenInAppSwitcher = value(.secureScreenInAppSwitcher)
        lockAppAfter = value(.lockAppAfter)
        secureScreen = value(.secureScreen)
        stubSourceNames = value(.stubSourceNames)
        autoUpdateInterval = value(.autoUpdateInterval)
        lastLibraryUpdateAt = value(.lastLibraryUpdateAt)
        libraryUpdateDeviceRestrictions = value(.libraryUpdateDeviceRestrictions)
        libraryUpdateMangaRestrictions = value(.libraryUpdateMangaRestrictions)
        libraryUpdateIncludedCategories = value(.libraryUpdateIncludedCategories)
        libraryUpdateExcludedCategories = value(.libraryUpdateExcludedCategories)
        libraryUpdateRefreshesMetadata = value(.libraryUpdateRefreshesMetadata)
        libraryUpdateCheckedAt = value(.libraryUpdateCheckedAt)
        upcomingIncludedCategories = value(.upcomingIncludedCategories)
        upcomingExcludedCategories = value(.upcomingExcludedCategories)
        downloadNewChapters = value(.downloadNewChapters)
        downloadAheadCount = value(.downloadAheadCount)
        migrationFlags = value(.migrationFlags)
        autoBackupInterval = value(.autoBackupInterval)
        lastAutoBackupAt = value(.lastAutoBackupAt)
        libraryDisplayMode = value(.libraryDisplayMode)
        librarySortOption = value(.librarySortOption)
        librarySortAscending = value(.librarySortAscending)
        libraryFilter = value(.libraryFilter)
        showUnreadBadge = value(.showUnreadBadge)
        showDownloadBadge = value(.showDownloadBadge)
        showLocalBadge = value(.showLocalBadge)
        showLanguageBadge = value(.showLanguageBadge)
        showCategoryTabs = value(.showCategoryTabs)
        showMangaCountInCategory = value(.showMangaCountInCategory)
        showContinueReadingButton = value(.showContinueReadingButton)
        columnsPerRowPortrait = value(.columnsPerRowPortrait)
        defaultReadingMode = value(.defaultReadingMode)
        readerTapZone = value(.readerTapZone)
        readerBackground = value(.readerBackground)
        readerScaleType = value(.readerScaleType)
        cropBorders = value(.cropBorders)
        showPageNumber = value(.showPageNumber)
        keepScreenOn = value(.keepScreenOn)
        showTapZonesOverlayOnLaunch = value(.showTapZonesOverlayOnLaunch)
        volumeKeysScroll = value(.volumeKeysScroll)
        doubleTapToZoom = value(.doubleTapToZoom)
        skipReadChapters = value(.skipReadChapters)
        skipFilteredChapters = value(.skipFilteredChapters)
        skipDuplicateChapters = value(.skipDuplicateChapters)
        colorFilter = value(.colorFilter)
        mangaDexDataSaver = value(.mangaDexDataSaver)
        duoPostureMode = value(.duoPostureMode)
        duoDualPageBehavior = value(.duoDualPageBehavior)
        shiftDoublePageCover = value(.shiftDoublePageCover)
        invertDoublePageOrder = value(.invertDoublePageOrder)
        duoHingeGutterWidth = value(.duoHingeGutterWidth)
        showDuoSpineShadow = value(.showDuoSpineShadow)
        duoPageTurnEffect = value(.duoPageTurnEffect)
        duoPageTurnStyle = value(.duoPageTurnStyle)
        duoPageTurnStylePicked = value(.duoPageTurnStylePicked)
        deleteAfterReading = value(.deleteAfterReading)
        downloadedChapterIds = value(.downloadedChapterIds)
        enabledLanguages = value(.enabledLanguages)
        showNsfwSources = value(.showNsfwSources)
        pinnedSourceIds = value(.pinnedSourceIds)
        lastUsedSourceId = value(.lastUsedSourceId)
        defaultLibraryCategory = value(.defaultLibraryCategory)
        queuedChapterIds = value(.queuedChapterIds)
        chaptersPendingDeletion = value(.chaptersPendingDeletion)
    }
}

extension MihonRepositoryStore {
    static let settingsKey = "MihonSettings"

    /// Reading this registers an Observation dependency on every setting (see `trackSettings`).
    var settingsSnapshot: MihonSettingsSnapshot {
        MihonSettingsSnapshot(
            themePalette: themePalette, darkMode: darkMode, pureBlackDarkMode: pureBlackDarkMode,
            incognitoMode: incognitoMode, downloadedOnlyMode: downloadedOnlyMode,
            requireBiometricLock: requireBiometricLock, lockAppAfter: lockAppAfter, secureScreen: secureScreen,
            stubSourceNames: stubSourceNames, autoUpdateInterval: autoUpdateInterval, lastLibraryUpdateAt: lastLibraryUpdateAt,
            libraryUpdateDeviceRestrictions: libraryUpdateDeviceRestrictions,
            libraryUpdateMangaRestrictions: libraryUpdateMangaRestrictions,
            libraryUpdateIncludedCategories: libraryUpdateIncludedCategories,
            libraryUpdateExcludedCategories: libraryUpdateExcludedCategories,
            libraryUpdateRefreshesMetadata: libraryUpdateRefreshesMetadata,
            libraryUpdateCheckedAt: libraryUpdateCheckedAt,
            upcomingIncludedCategories: upcomingIncludedCategories,
            upcomingExcludedCategories: upcomingExcludedCategories,
            downloadNewChapters: downloadNewChapters, downloadAheadCount: downloadAheadCount, migrationFlags: migrationFlags,
            autoBackupInterval: autoBackupInterval, lastAutoBackupAt: lastAutoBackupAt,
            libraryDisplayMode: libraryDisplayMode, librarySortOption: librarySortOption,
            librarySortAscending: librarySortAscending, libraryFilter: libraryFilter,
            showUnreadBadge: showUnreadBadge, showDownloadBadge: showDownloadBadge, showLocalBadge: showLocalBadge,
            showLanguageBadge: showLanguageBadge, showCategoryTabs: showCategoryTabs,
            showMangaCountInCategory: showMangaCountInCategory, showContinueReadingButton: showContinueReadingButton,
            columnsPerRowPortrait: columnsPerRowPortrait,
            defaultReadingMode: defaultReadingMode, readerTapZone: readerTapZone, readerBackground: readerBackground,
            readerScaleType: readerScaleType, cropBorders: cropBorders, showPageNumber: showPageNumber,
            keepScreenOn: keepScreenOn, showTapZonesOverlayOnLaunch: showTapZonesOverlayOnLaunch,
            volumeKeysScroll: volumeKeysScroll, doubleTapToZoom: doubleTapToZoom,
            skipReadChapters: skipReadChapters, skipFilteredChapters: skipFilteredChapters,
            skipDuplicateChapters: skipDuplicateChapters, colorFilter: colorFilter,
            mangaDexDataSaver: mangaDexDataSaver,
            duoPostureMode: duoPostureMode, duoDualPageBehavior: duoDualPageBehavior,
            shiftDoublePageCover: shiftDoublePageCover, invertDoublePageOrder: invertDoublePageOrder,
            duoHingeGutterWidth: duoHingeGutterWidth, showDuoSpineShadow: showDuoSpineShadow,
            duoPageTurnEffect: duoPageTurnEffect, duoPageTurnStyle: duoPageTurnStyle,
            duoPageTurnStylePicked: duoPageTurnStylePicked,
            deleteAfterReading: deleteAfterReading, downloadedChapterIds: downloadedChapterIds,
            enabledLanguages: enabledLanguages, showNsfwSources: showNsfwSources,
            pinnedSourceIds: pinnedSourceIds, lastUsedSourceId: lastUsedSourceId,
            defaultLibraryCategory: defaultLibraryCategory, queuedChapterIds: downloadQueue.map(\.id),
            chaptersPendingDeletion: chaptersPendingDeletion
        )
    }

    func apply(_ s: MihonSettingsSnapshot) {
        if let v = s.themePalette { themePalette = v }
        if let v = s.darkMode { darkMode = v }
        if let v = s.pureBlackDarkMode { pureBlackDarkMode = v }
        if let v = s.incognitoMode { incognitoMode = v }
        if let v = s.downloadedOnlyMode { downloadedOnlyMode = v }
        if let v = s.requireBiometricLock { requireBiometricLock = v }
        if let v = s.secureScreen {
            secureScreen = v
        } else if s.secureScreenInAppSwitcher == true {
            secureScreen = .always
        }
        if let v = s.lockAppAfter, MihonAppLockPolicy.lockAfterChoices.contains(v) { lockAppAfter = v }
        if let v = s.stubSourceNames { stubSourceNames = v }
        if let v = s.autoUpdateInterval, MihonLibraryUpdateInterval.choices.contains(v) { autoUpdateInterval = v }
        if let v = s.lastLibraryUpdateAt { lastLibraryUpdateAt = v }
        if let v = s.libraryUpdateDeviceRestrictions { libraryUpdateDeviceRestrictions = v }
        if let v = s.libraryUpdateMangaRestrictions { libraryUpdateMangaRestrictions = v }
        if let v = s.libraryUpdateIncludedCategories { libraryUpdateIncludedCategories = v }
        if let v = s.libraryUpdateExcludedCategories { libraryUpdateExcludedCategories = v }
        if let v = s.libraryUpdateRefreshesMetadata { libraryUpdateRefreshesMetadata = v }
        if let v = s.libraryUpdateCheckedAt { libraryUpdateCheckedAt = v }
        if let v = s.upcomingIncludedCategories { upcomingIncludedCategories = v }
        if let v = s.upcomingExcludedCategories { upcomingExcludedCategories = v }
        if let v = s.downloadNewChapters { downloadNewChapters = v }
        if let v = s.downloadAheadCount, Self.downloadAheadChoices.contains(v) { downloadAheadCount = v }
        if let v = s.migrationFlags { migrationFlags = v }
        if let v = s.autoBackupInterval, MihonAutoBackup.intervalChoices.contains(v) { autoBackupInterval = v }
        if let v = s.lastAutoBackupAt { lastAutoBackupAt = v }
        if let v = s.libraryDisplayMode { libraryDisplayMode = v }
        if let v = s.librarySortOption { librarySortOption = v }
        if let v = s.librarySortAscending { librarySortAscending = v }
        if let v = s.libraryFilter { libraryFilter = v }
        if let v = s.showUnreadBadge { showUnreadBadge = v }
        if let v = s.showDownloadBadge { showDownloadBadge = v }
        if let v = s.showLocalBadge { showLocalBadge = v }
        if let v = s.showLanguageBadge { showLanguageBadge = v }
        if let v = s.showCategoryTabs { showCategoryTabs = v }
        if let v = s.showMangaCountInCategory { showMangaCountInCategory = v }
        if let v = s.showContinueReadingButton { showContinueReadingButton = v }
        if let v = s.columnsPerRowPortrait { columnsPerRowPortrait = v }
        if let v = s.defaultReadingMode { defaultReadingMode = v }
        if let v = s.readerTapZone { readerTapZone = v }
        if let v = s.readerBackground { readerBackground = v }
        if let v = s.readerScaleType { readerScaleType = v }
        if let v = s.cropBorders { cropBorders = v }
        if let v = s.showPageNumber { showPageNumber = v }
        if let v = s.keepScreenOn { keepScreenOn = v }
        if let v = s.showTapZonesOverlayOnLaunch { showTapZonesOverlayOnLaunch = v }
        if let v = s.volumeKeysScroll { volumeKeysScroll = v }
        if let v = s.doubleTapToZoom { doubleTapToZoom = v }
        if let v = s.skipReadChapters { skipReadChapters = v }
        if let v = s.skipFilteredChapters { skipFilteredChapters = v }
        if let v = s.skipDuplicateChapters { skipDuplicateChapters = v }
        if let v = s.colorFilter { colorFilter = v }
        if let v = s.mangaDexDataSaver { mangaDexDataSaver = v }
        if let v = s.duoPostureMode { duoPostureMode = v }
        if let v = s.duoDualPageBehavior { duoDualPageBehavior = v }
        if let v = s.shiftDoublePageCover { shiftDoublePageCover = v }
        if let v = s.invertDoublePageOrder { invertDoublePageOrder = v }
        if let v = s.duoHingeGutterWidth { duoHingeGutterWidth = v }
        if let v = s.showDuoSpineShadow { showDuoSpineShadow = v }
        if let v = s.duoPageTurnEffect { duoPageTurnEffect = v }
        if s.duoPageTurnStylePicked == true, let v = s.duoPageTurnStyle {
            duoPageTurnStyle = v
            duoPageTurnStylePicked = true
        }
        if let v = s.deleteAfterReading { deleteAfterReading = v }
        if let v = s.downloadedChapterIds { downloadedChapterIds = v }
        if let v = s.enabledLanguages { enabledLanguages = v }
        if let v = s.showNsfwSources { showNsfwSources = v }
        if let v = s.pinnedSourceIds { pinnedSourceIds = v }
        if let v = s.lastUsedSourceId { lastUsedSourceId = v }
        if let v = s.defaultLibraryCategory { defaultLibraryCategory = v }
        if let v = s.queuedChapterIds { queuedChapterIdsToRestore = v }
        if let v = s.chaptersPendingDeletion { chaptersPendingDeletion = v }
    }

    /// Applies the saved settings, then saves them again whenever one changes.
    func restoreAndTrackSettings(in defaults: UserDefaults = .standard) {
        restoreSettings(from: defaults)
        trackSettings(in: defaults)
    }

    func restoreSettings(from defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(MihonSettingsSnapshot.self, from: data) {
            apply(saved)
        }
    }

    /// `onChange` fires once, before the change lands: the save waits a main-actor turn (coalescing everything
    /// changed in that turn) and then tracks again.
    private func trackSettings(in defaults: UserDefaults) {
        let box = DefaultsBox(defaults: defaults)
        withObservationTracking {
            _ = settingsSnapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data = try? JSONEncoder().encode(self.settingsSnapshot) {
                    box.defaults.set(data, forKey: Self.settingsKey)
                }
                self.trackSettings(in: box.defaults)
            }
        }
    }
}

/// `UserDefaults` is documented as thread-safe but not annotated `Sendable`.
private struct DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
}
