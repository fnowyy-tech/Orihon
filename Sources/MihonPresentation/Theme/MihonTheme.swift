import SwiftUI
import MihonData

// MARK: - Material 3 Color Scheme (1:1 with upstream `eu.kanade.presentation.theme.colorscheme`)

public struct MihonColorScheme: Equatable {
    enum Role: Hashable {
        case primary, onPrimary, primaryContainer, onPrimaryContainer
        case secondary, onSecondary, secondaryContainer, onSecondaryContainer
        case tertiary, onTertiary, tertiaryContainer, onTertiaryContainer
        case background, onBackground, surface, onSurface, surfaceVariant, onSurfaceVariant
        case outline, outlineVariant, error, onError, inverseSurface, inverseOnSurface
        case surfaceContainerLowest, surfaceContainerLow, surfaceContainer, surfaceContainerHigh, surfaceContainerHighest
    }

    public let isDark: Bool
    public let primary: Color
    public let onPrimary: Color
    public let primaryContainer: Color
    public let onPrimaryContainer: Color
    public let secondary: Color
    public let onSecondary: Color
    public let secondaryContainer: Color
    public let onSecondaryContainer: Color
    public let tertiary: Color
    public let onTertiary: Color
    public let tertiaryContainer: Color
    public let onTertiaryContainer: Color
    public let background: Color
    public let onBackground: Color
    public let surface: Color
    public let onSurface: Color
    public let surfaceVariant: Color
    public let onSurfaceVariant: Color
    public let outline: Color
    public let outlineVariant: Color
    public let error: Color
    public let onError: Color
    public let inverseSurface: Color
    public let inverseOnSurface: Color
    public let surfaceContainerLowest: Color
    public let surfaceContainerLow: Color
    public let surfaceContainer: Color
    public let surfaceContainerHigh: Color
    public let surfaceContainerHighest: Color
    /// `surfaceColorAtElevation(1.dp / 3.dp)` — surface tinted with primary (used by app bars, reader bars, rail).
    public let surfaceElevation1: Color
    public let surfaceElevation3: Color

    /// Upstream `MaterialTheme.colorScheme.active` (filter icons when filters are applied).
    public var active: Color { isDark ? Color(hex: 0xFFEB3B) : Color(hex: 0xFFC107) }

    public init(palette: MihonThemePalette, dark: Bool, pureBlack: Bool) {
        var raw = Self.rawScheme(for: palette, dark: dark)
        if dark && pureBlack {
            // 1:1 with `BaseColorScheme.getColorScheme(isAmoled = true, overrideDarkSurfaceContainers = true)`
            raw[.background] = 0x000000
            raw[.onBackground] = 0xFFFFFF
            raw[.surface] = 0x000000
            raw[.onSurface] = 0xFFFFFF
            raw[.surfaceVariant] = 0x0C0C0C
            raw[.surfaceContainerLowest] = 0x0C0C0C
            raw[.surfaceContainerLow] = 0x0C0C0C
            raw[.surfaceContainer] = 0x0C0C0C
            raw[.surfaceContainerHigh] = 0x131313
            raw[.surfaceContainerHighest] = 0x1B1B1B
        }
        func c(_ role: Role) -> Color { Color(hex: raw[role] ?? 0xFF00FF) }
        isDark = dark
        primary = c(.primary)
        onPrimary = c(.onPrimary)
        primaryContainer = c(.primaryContainer)
        onPrimaryContainer = c(.onPrimaryContainer)
        secondary = c(.secondary)
        onSecondary = c(.onSecondary)
        secondaryContainer = c(.secondaryContainer)
        onSecondaryContainer = c(.onSecondaryContainer)
        tertiary = c(.tertiary)
        onTertiary = c(.onTertiary)
        tertiaryContainer = c(.tertiaryContainer)
        onTertiaryContainer = c(.onTertiaryContainer)
        background = c(.background)
        onBackground = c(.onBackground)
        surface = c(.surface)
        onSurface = c(.onSurface)
        surfaceVariant = c(.surfaceVariant)
        onSurfaceVariant = c(.onSurfaceVariant)
        outline = c(.outline)
        outlineVariant = c(.outlineVariant)
        error = c(.error)
        onError = c(.onError)
        inverseSurface = c(.inverseSurface)
        inverseOnSurface = c(.inverseOnSurface)
        surfaceContainerLowest = c(.surfaceContainerLowest)
        surfaceContainerLow = c(.surfaceContainerLow)
        surfaceContainer = c(.surfaceContainer)
        surfaceContainerHigh = c(.surfaceContainerHigh)
        surfaceContainerHighest = c(.surfaceContainerHighest)
        let surfaceHex = raw[.surface] ?? 0
        let tintHex = raw[.primary] ?? 0
        surfaceElevation1 = Color(hex: Self.mix(surfaceHex, tintHex, alpha: Self.tonalAlpha(elevation: 1)))
        surfaceElevation3 = Color(hex: Self.mix(surfaceHex, tintHex, alpha: Self.tonalAlpha(elevation: 3)))
    }

    /// Compose `ColorScheme.surfaceColorAtElevation`: alpha = (4.5 * ln(elevation + 1) + 2) / 100
    static func tonalAlpha(elevation: Double) -> Double {
        (4.5 * log(elevation + 1) + 2) / 100
    }

    static func mix(_ base: UInt32, _ overlay: UInt32, alpha: Double) -> UInt32 {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) }
        func blend(_ shift: UInt32) -> UInt32 {
            UInt32((channel(base, shift) * (1 - alpha) + channel(overlay, shift) * alpha).rounded()) << shift
        }
        return blend(16) | blend(8) | blend(0)
    }

    // swiftlint:disable line_length
    /// Exact M3 color roles ported from `eu.kanade.presentation.theme.colorscheme.*ColorScheme.kt`.
    static func rawScheme(for palette: MihonThemePalette, dark: Bool) -> [Role: UInt32] {
        switch (palette, dark) {
        case (.mihonDefault, true): return [.primary: 0xB0C6FF, .onPrimary: 0x002D6E, .primaryContainer: 0x00429B, .onPrimaryContainer: 0xD9E2FF, .secondary: 0xB0C6FF, .onSecondary: 0x002D6E, .secondaryContainer: 0x00429B, .onSecondaryContainer: 0xD9E2FF, .tertiary: 0x7ADC77, .onTertiary: 0x003909, .tertiaryContainer: 0x005312, .onTertiaryContainer: 0x95F990, .background: 0x1B1B1F, .onBackground: 0xE3E2E6, .surface: 0x1B1B1F, .onSurface: 0xE3E2E6, .surfaceVariant: 0x211F26, .onSurfaceVariant: 0xC5C6D0, .outline: 0x8F9099, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xE3E2E6, .inverseOnSurface: 0x1B1B1F, .surfaceContainerLowest: 0x1A181D, .surfaceContainerLow: 0x1E1C22, .surfaceContainer: 0x211F26, .surfaceContainerHigh: 0x292730, .surfaceContainerHighest: 0x302E38]
        case (.mihonDefault, false): return [.primary: 0x0058CA, .onPrimary: 0xFFFFFF, .primaryContainer: 0xD9E2FF, .onPrimaryContainer: 0x001945, .secondary: 0x0058CA, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xD9E2FF, .onSecondaryContainer: 0x001945, .tertiary: 0x006E1B, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0x95F990, .onTertiaryContainer: 0x002203, .background: 0xFEFBFF, .onBackground: 0x1B1B1F, .surface: 0xFEFBFF, .onSurface: 0x1B1B1F, .surfaceVariant: 0xF3EDF7, .onSurfaceVariant: 0x44464F, .outline: 0x757780, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x303034, .inverseOnSurface: 0xF2F0F4, .surfaceContainerLowest: 0xF5F1F8, .surfaceContainerLow: 0xF7F2FA, .surfaceContainer: 0xF3EDF7, .surfaceContainerHigh: 0xFCF7FF, .surfaceContainerHighest: 0xFCF7FF]
        case (.catppuccin, true): return [.primary: 0xCBA6F7, .onPrimary: 0x11111B, .primaryContainer: 0xCBA6F7, .onPrimaryContainer: 0x11111B, .secondary: 0xB4BEFE, .onSecondary: 0x11111B, .secondaryContainer: 0x313244, .onSecondaryContainer: 0xCBA6F7, .tertiary: 0xA6E3A1, .onTertiary: 0x11111B, .tertiaryContainer: 0x1E1E2E, .onTertiaryContainer: 0xCDD6F4, .background: 0x181825, .onBackground: 0xCDD6F4, .surface: 0x181825, .onSurface: 0xCDD6F4, .surfaceVariant: 0x1E1E2E, .onSurfaceVariant: 0xCDD6F4, .outline: 0xCBA6F7, .outlineVariant: 0x585B70, .error: 0xF38BA8, .onError: 0x11111B, .inverseSurface: 0xEFF1F5, .inverseOnSurface: 0x4C4F69, .surfaceContainerLowest: 0x181825, .surfaceContainerLow: 0x1E1E2E, .surfaceContainer: 0x1E1E2E, .surfaceContainerHigh: 0x1E1E2E, .surfaceContainerHighest: 0x313244]
        case (.catppuccin, false): return [.primary: 0x8839EF, .onPrimary: 0xDCE0E8, .primaryContainer: 0x8839EF, .onPrimaryContainer: 0xDCE0E8, .secondary: 0x7287FD, .onSecondary: 0xDCE0E8, .secondaryContainer: 0xCDD0DA, .onSecondaryContainer: 0x8839EF, .tertiary: 0x40A02B, .onTertiary: 0xDCE0E8, .tertiaryContainer: 0xEFF1F5, .onTertiaryContainer: 0x4C4F69, .background: 0xE6E9EF, .onBackground: 0x4C4F69, .surface: 0xE6E9EF, .onSurface: 0x4C4F69, .surfaceVariant: 0xEFF1F5, .onSurfaceVariant: 0x4C4F69, .outline: 0x8839EF, .outlineVariant: 0xACB0BE, .error: 0xD20F39, .onError: 0xDCE0E8, .inverseSurface: 0x1E1E2E, .inverseOnSurface: 0xCDD6F4, .surfaceContainerLowest: 0xE6E9EF, .surfaceContainerLow: 0xEFF1F5, .surfaceContainer: 0xEFF1F5, .surfaceContainerHigh: 0xEFF1F5, .surfaceContainerHighest: 0xCDD0DA]
        case (.greenApple, true): return [.primary: 0x7ADB8F, .onPrimary: 0x003917, .primaryContainer: 0x017737, .onPrimaryContainer: 0xFFFFFF, .secondary: 0x7ADB8F, .onSecondary: 0x003917, .secondaryContainer: 0x017737, .onSecondaryContainer: 0xFFFFFF, .tertiary: 0xFFB3AC, .onTertiary: 0x680008, .tertiaryContainer: 0xC7282A, .onTertiaryContainer: 0xFFFFFF, .background: 0x0F1510, .onBackground: 0xDFE4DB, .surface: 0x0F1510, .onSurface: 0xDFE4DB, .surfaceVariant: 0x3F493F, .onSurfaceVariant: 0xBECABC, .outline: 0x889487, .outlineVariant: 0x3F493F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xDFE4DB, .inverseOnSurface: 0x2C322C, .surfaceContainerLowest: 0x0A0F0B, .surfaceContainerLow: 0x181D18, .surfaceContainer: 0x1C211C, .surfaceContainerHigh: 0x262B26, .surfaceContainerHighest: 0x313630]
        case (.greenApple, false): return [.primary: 0x005927, .onPrimary: 0xFFFFFF, .primaryContainer: 0x188140, .onPrimaryContainer: 0xFFFFFF, .secondary: 0x005927, .onSecondary: 0xFFFFFF, .secondaryContainer: 0x97F7A9, .onSecondaryContainer: 0x000000, .tertiary: 0x9D0012, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0xD33131, .onTertiaryContainer: 0xFFFFFF, .background: 0xF6FBF2, .onBackground: 0x181D18, .surface: 0xF6FBF2, .onSurface: 0x181D18, .surfaceVariant: 0xDAE6D7, .onSurfaceVariant: 0x3F493F, .outline: 0x6F7A6E, .outlineVariant: 0xBECABC, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x2C322C, .inverseOnSurface: 0xEDF2E9, .surfaceContainerLowest: 0xFFFFFF, .surfaceContainerLow: 0xF0F5EC, .surfaceContainer: 0xEAEFE6, .surfaceContainerHigh: 0xE4EAE1, .surfaceContainerHighest: 0xDFE4DB]
        case (.lavender, true): return [.primary: 0xA177FF, .onPrimary: 0x3D0090, .primaryContainer: 0xA177FF, .onPrimaryContainer: 0xFFFFFF, .secondary: 0xA177FF, .onSecondary: 0xFFFFFF, .secondaryContainer: 0x423271, .onSecondaryContainer: 0xA177FF, .tertiary: 0xCDBDFF, .onTertiary: 0x360096, .tertiaryContainer: 0x5512D8, .onTertiaryContainer: 0xEFE6FF, .background: 0x111129, .onBackground: 0xE7E0EC, .surface: 0x111129, .onSurface: 0xE7E0EC, .surfaceVariant: 0x3D2F6B, .onSurfaceVariant: 0xCBC3D6, .outline: 0x958E9F, .outlineVariant: 0x4A4453, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xE7E0EC, .inverseOnSurface: 0x322F38, .surfaceContainerLowest: 0x15132D, .surfaceContainerLow: 0x171531, .surfaceContainer: 0x1D193B, .surfaceContainerHigh: 0x241F41, .surfaceContainerHighest: 0x282446]
        case (.lavender, false): return [.primary: 0x6D41C8, .onPrimary: 0xFFFFFF, .primaryContainer: 0x7B46AF, .onPrimaryContainer: 0x130038, .secondary: 0x7B46AF, .onSecondary: 0xEDE2FF, .secondaryContainer: 0xC9B0E6, .onSecondaryContainer: 0x7B46AF, .tertiary: 0xEDE2FF, .onTertiary: 0x7B46AF, .tertiaryContainer: 0x6D3BF0, .onTertiaryContainer: 0xFFFFFF, .background: 0xEDE2FF, .onBackground: 0x1D1A22, .surface: 0xEDE2FF, .onSurface: 0x1D1A22, .surfaceVariant: 0xE4D5F8, .onSurfaceVariant: 0x4A4453, .outline: 0x7B7485, .outlineVariant: 0xCBC3D6, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x322F38, .inverseOnSurface: 0xF5EEFA, .surfaceContainerLowest: 0xDACCEC, .surfaceContainerLow: 0xDED0F1, .surfaceContainer: 0xE4D5F8, .surfaceContainerHigh: 0xEADCFD, .surfaceContainerHighest: 0xEEE2FF]
        case (.midnightDusk, true): return [.primary: 0xF02475, .onPrimary: 0xFFFFFF, .primaryContainer: 0xBD1C5C, .onPrimaryContainer: 0xFFFFFF, .secondary: 0xF02475, .onSecondary: 0x16151D, .secondaryContainer: 0x66183C, .onSecondaryContainer: 0xF02475, .tertiary: 0x55971C, .onTertiary: 0x16151D, .tertiaryContainer: 0x386412, .onTertiaryContainer: 0xE5E1E5, .background: 0x16151D, .onBackground: 0xE5E1E5, .surface: 0x16151D, .onSurface: 0xE5E1E5, .surfaceVariant: 0x281624, .onSurfaceVariant: 0xD6C1C4, .outline: 0x9F8C8F, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0x333043, .inverseOnSurface: 0xFFFFFF, .surfaceContainerLowest: 0x221320, .surfaceContainerLow: 0x251522, .surfaceContainer: 0x281624, .surfaceContainerHigh: 0x2D1C2A, .surfaceContainerHighest: 0x2F1F2C]
        case (.midnightDusk, false): return [.primary: 0xBB0054, .onPrimary: 0xFFFFFF, .primaryContainer: 0xFFD9E1, .onPrimaryContainer: 0x3F0017, .secondary: 0xBB0054, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xEFBAD4, .onSecondaryContainer: 0xD1377C, .tertiary: 0x006638, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0x00894B, .onTertiaryContainer: 0x2D1600, .background: 0xFFFBFF, .onBackground: 0x1C1B1F, .surface: 0xFFFBFF, .onSurface: 0x1C1B1F, .surfaceVariant: 0xF9E6F1, .onSurfaceVariant: 0x524346, .outline: 0x847376, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x313033, .inverseOnSurface: 0xF4F0F4, .surfaceContainerLowest: 0xDAC0CD, .surfaceContainerLow: 0xE8D1DD, .surfaceContainer: 0xF9E6F1, .surfaceContainerHigh: 0xFCF3F8, .surfaceContainerHighest: 0xFEF9FC]
        case (.monochrome, true): return [.primary: 0xFFFFFF, .onPrimary: 0x000000, .primaryContainer: 0xFFFFFF, .onPrimaryContainer: 0x000000, .secondary: 0xFFFFFF, .onSecondary: 0x000000, .secondaryContainer: 0x777777, .onSecondaryContainer: 0x000000, .tertiary: 0x777777, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0xFFFFFF, .onTertiaryContainer: 0x000000, .background: 0x000000, .onBackground: 0xFFFFFF, .surface: 0x000000, .onSurface: 0xFFFFFF, .surfaceVariant: 0x000000, .onSurfaceVariant: 0xFFFFFF, .outline: 0xFFFFFF, .outlineVariant: 0xFFFFFF, .error: 0xFFFFFF, .onError: 0x000000, .inverseSurface: 0xFFFFFF, .inverseOnSurface: 0x000000, .surfaceContainerLowest: 0x000000, .surfaceContainerLow: 0x000000, .surfaceContainer: 0x000000, .surfaceContainerHigh: 0x000000, .surfaceContainerHighest: 0x000000]
        case (.monochrome, false): return [.primary: 0x000000, .onPrimary: 0xFFFFFF, .primaryContainer: 0x000000, .onPrimaryContainer: 0xFFFFFF, .secondary: 0x000000, .onSecondary: 0xFFFFFF, .secondaryContainer: 0x888888, .onSecondaryContainer: 0xFFFFFF, .tertiary: 0x888888, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0x000000, .onTertiaryContainer: 0xFFFFFF, .background: 0xFFFFFF, .onBackground: 0x000000, .surface: 0xFFFFFF, .onSurface: 0x000000, .surfaceVariant: 0xFFFFFF, .onSurfaceVariant: 0x000000, .outline: 0x000000, .outlineVariant: 0x000000, .error: 0x000000, .onError: 0xFFFFFF, .inverseSurface: 0x000000, .inverseOnSurface: 0xFFFFFF, .surfaceContainerLowest: 0xFFFFFF, .surfaceContainerLow: 0xFFFFFF, .surfaceContainer: 0xFFFFFF, .surfaceContainerHigh: 0xFFFFFF, .surfaceContainerHighest: 0xFFFFFF]
        case (.nord, true): return [.primary: 0x88C0D0, .onPrimary: 0x2E3440, .primaryContainer: 0x88C0D0, .onPrimaryContainer: 0x2E3440, .secondary: 0x81A1C1, .onSecondary: 0x2E3440, .secondaryContainer: 0x506275, .onSecondaryContainer: 0x88C0D0, .tertiary: 0x5E81AC, .onTertiary: 0x000000, .tertiaryContainer: 0x5E81AC, .onTertiaryContainer: 0x000000, .background: 0x2E3440, .onBackground: 0xECEFF4, .surface: 0x2E3440, .onSurface: 0xECEFF4, .surfaceVariant: 0x414C5C, .onSurfaceVariant: 0xECEFF4, .outline: 0x6D717B, .outlineVariant: 0x90939A, .error: 0xFFB4AB, .onError: 0x2E3440, .inverseSurface: 0xD8DEE9, .inverseOnSurface: 0x2E3440, .surfaceContainerLowest: 0x373F4D, .surfaceContainerLow: 0x3E4756, .surfaceContainer: 0x414C5C, .surfaceContainerHigh: 0x4E5766, .surfaceContainerHighest: 0x505968]
        case (.nord, false): return [.primary: 0x5E81AC, .onPrimary: 0x000000, .primaryContainer: 0x5E81AC, .onPrimaryContainer: 0x000000, .secondary: 0x81A1C1, .onSecondary: 0x2E3440, .secondaryContainer: 0x91B4D7, .onSecondaryContainer: 0x2E3440, .tertiary: 0x88C0D0, .onTertiary: 0x2E3440, .tertiaryContainer: 0x88C0D0, .onTertiaryContainer: 0x2E3440, .background: 0xECEFF4, .onBackground: 0x2E3440, .surface: 0xE5E9F0, .onSurface: 0x2E3440, .surfaceVariant: 0xDAE0EA, .onSurfaceVariant: 0x2E3440, .outline: 0x2E3440, .outlineVariant: 0xD8DEE9, .error: 0xBA1A1A, .onError: 0xECEFF4, .inverseSurface: 0x3B4252, .inverseOnSurface: 0xECEFF4, .surfaceContainerLowest: 0xD1D7E0, .surfaceContainerLow: 0xD6DCE6, .surfaceContainer: 0xDAE0EA, .surfaceContainerHigh: 0xE9EDF3, .surfaceContainerHighest: 0xF2F4F8]
        case (.strawberryDaiquiri, true): return [.primary: 0xFFB2B8, .onPrimary: 0x67001D, .primaryContainer: 0xD53855, .onPrimaryContainer: 0xFFFFFF, .secondary: 0xED4A65, .onSecondary: 0x201A1A, .secondaryContainer: 0x91002A, .onSecondaryContainer: 0xFFFFFF, .tertiary: 0xE8C08E, .onTertiary: 0x201A1A, .tertiaryContainer: 0x775930, .onTertiaryContainer: 0xFFF7F1, .background: 0x201A1A, .onBackground: 0xF7DCDD, .surface: 0x201A1A, .onSurface: 0xF7DCDD, .surfaceVariant: 0x322727, .onSurfaceVariant: 0xE1BEC0, .outline: 0xA9898B, .outlineVariant: 0x594042, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xF7DCDD, .inverseOnSurface: 0x3D2C2D, .surfaceContainerLowest: 0x2C2222, .surfaceContainerLow: 0x302525, .surfaceContainer: 0x322727, .surfaceContainerHigh: 0x3C2F2F, .surfaceContainerHighest: 0x463737]
        case (.strawberryDaiquiri, false): return [.primary: 0xA10833, .onPrimary: 0xFFFFFF, .primaryContainer: 0xD53855, .onPrimaryContainer: 0xFFFFFF, .secondary: 0xA10833, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xD53855, .onSecondaryContainer: 0xF6EAED, .tertiary: 0x5F441D, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0x87683D, .onTertiaryContainer: 0xFFFFFF, .background: 0xFAFAFA, .onBackground: 0x261819, .surface: 0xFAFAFA, .onSurface: 0x261819, .surfaceVariant: 0xF6EAED, .onSurfaceVariant: 0x594042, .outline: 0x8D7071, .outlineVariant: 0xE1BEC0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x3D2C2D, .inverseOnSurface: 0xFFECED, .surfaceContainerLowest: 0xF7DCDD, .surfaceContainerLow: 0xFDE2E3, .surfaceContainer: 0xF6EAED, .surfaceContainerHigh: 0xFFF0F0, .surfaceContainerHighest: 0xFFFFFF]
        case (.tako, true): return [.primary: 0xF3B375, .onPrimary: 0x38294E, .primaryContainer: 0xF3B375, .onPrimaryContainer: 0x38294E, .secondary: 0xF3B375, .onSecondary: 0x38294E, .secondaryContainer: 0x5C4D4B, .onSecondaryContainer: 0xF3B375, .tertiary: 0x66577E, .onTertiary: 0xF3B375, .tertiaryContainer: 0x4E4065, .onTertiaryContainer: 0xEDDCFF, .background: 0x21212E, .onBackground: 0xE3E0F2, .surface: 0x21212E, .onSurface: 0xE3E0F2, .surfaceVariant: 0x2A2A3C, .onSurfaceVariant: 0xCBC4CE, .outline: 0x958F99, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xE5E1E6, .inverseOnSurface: 0x1B1B1E, .surfaceContainerLowest: 0x20202E, .surfaceContainerLow: 0x262636, .surfaceContainer: 0x2A2A3C, .surfaceContainerHigh: 0x303044, .surfaceContainerHighest: 0x36364D]
        case (.tako, false): return [.primary: 0x66577E, .onPrimary: 0xF3B375, .primaryContainer: 0x66577E, .onPrimaryContainer: 0xF3B375, .secondary: 0x66577E, .onSecondary: 0xF3B375, .secondaryContainer: 0xC8BED0, .onSecondaryContainer: 0x66577E, .tertiary: 0xF3B375, .onTertiary: 0x574360, .tertiaryContainer: 0xFDD6B0, .onTertiaryContainer: 0x221437, .background: 0xF7F5FF, .onBackground: 0x1B1B22, .surface: 0xF7F5FF, .onSurface: 0x1B1B22, .surfaceVariant: 0xE8E0EB, .onSurfaceVariant: 0x49454E, .outline: 0x7A757E, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x313033, .inverseOnSurface: 0xF3EFF4, .surfaceContainerLowest: 0xD7D0DA, .surfaceContainerLow: 0xDFD8E2, .surfaceContainer: 0xE8E0EB, .surfaceContainerHigh: 0xEEE6F1, .surfaceContainerHighest: 0xF7EEFA]
        case (.tealTurquoise, true): return [.primary: 0x40E0D0, .onPrimary: 0x000000, .primaryContainer: 0x40E0D0, .onPrimaryContainer: 0x000000, .secondary: 0x40E0D0, .onSecondary: 0x000000, .secondaryContainer: 0x18544E, .onSecondaryContainer: 0x40E0D0, .tertiary: 0xBF1F2F, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0x200508, .onTertiaryContainer: 0xBF1F2F, .background: 0x202125, .onBackground: 0xDFDEDA, .surface: 0x202125, .onSurface: 0xDFDEDA, .surfaceVariant: 0x233133, .onSurfaceVariant: 0xDFDEDA, .outline: 0x899391, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xDFDEDA, .inverseOnSurface: 0x202125, .surfaceContainerLowest: 0x202C2E, .surfaceContainerLow: 0x222F31, .surfaceContainer: 0x233133, .surfaceContainerHigh: 0x28383A, .surfaceContainerHighest: 0x2F4244]
        case (.tealTurquoise, false): return [.primary: 0x008080, .onPrimary: 0xFFFFFF, .primaryContainer: 0x008080, .onPrimaryContainer: 0xFFFFFF, .secondary: 0x008080, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xCFE5E4, .onSecondaryContainer: 0x008080, .tertiary: 0xFF7F7F, .onTertiary: 0x000000, .tertiaryContainer: 0x2A1616, .onTertiaryContainer: 0xFF7F7F, .background: 0xFAFAFA, .onBackground: 0x050505, .surface: 0xFAFAFA, .onSurface: 0x050505, .surfaceVariant: 0xEBF3F1, .onSurfaceVariant: 0x050505, .outline: 0x6F7977, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x050505, .inverseOnSurface: 0xFAFAFA, .surfaceContainerLowest: 0xE1E9E7, .surfaceContainerLow: 0xE6EEEC, .surfaceContainer: 0xEBF3F1, .surfaceContainerHigh: 0xF0F8F6, .surfaceContainerHighest: 0xF7FFFD]
        case (.tidalWave, true): return [.primary: 0x5ED4FC, .onPrimary: 0x003544, .primaryContainer: 0x004D61, .onPrimaryContainer: 0xB8EAFF, .secondary: 0x5ED4FC, .onSecondary: 0x003544, .secondaryContainer: 0x004D61, .onSecondaryContainer: 0xB8EAFF, .tertiary: 0x92F7BC, .onTertiary: 0x001C3B, .tertiaryContainer: 0xC3FADA, .onTertiaryContainer: 0x78FFD6, .background: 0x001C3B, .onBackground: 0xD5E3FF, .surface: 0x001C3B, .onSurface: 0xD5E3FF, .surfaceVariant: 0x082B4B, .onSurfaceVariant: 0xBFC8CC, .outline: 0x8A9296, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xFFE3C4, .inverseOnSurface: 0x001C3B, .surfaceContainerLowest: 0x072642, .surfaceContainerLow: 0x072947, .surfaceContainer: 0x082B4B, .surfaceContainerHigh: 0x093257, .surfaceContainerHighest: 0x0A3861]
        case (.tidalWave, false): return [.primary: 0x006780, .onPrimary: 0xFFFFFF, .primaryContainer: 0xB4D4DF, .onPrimaryContainer: 0x001F28, .secondary: 0x006780, .onSecondary: 0xFFFFFF, .secondaryContainer: 0x9AE1FF, .onSecondaryContainer: 0x001F28, .tertiary: 0x92F7BC, .onTertiary: 0x001C3B, .tertiaryContainer: 0xC3FADA, .onTertiaryContainer: 0x78FFD6, .background: 0xFDFBFF, .onBackground: 0x001C3B, .surface: 0xFDFBFF, .onSurface: 0x001C3B, .surfaceVariant: 0xE8EFF5, .onSurfaceVariant: 0x40484C, .outline: 0x70787C, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x020400, .inverseOnSurface: 0xFFE3C4, .surfaceContainerLowest: 0xE2E8EC, .surfaceContainerLow: 0xE5ECF1, .surfaceContainer: 0xE8EFF5, .surfaceContainerHigh: 0xEDF4FA, .surfaceContainerHighest: 0xF5FAFF]
        case (.tokyoNight, true): return [.primary: 0x82AAFF, .onPrimary: 0x1B1D2B, .primaryContainer: 0x444A73, .onPrimaryContainer: 0x9AB8FF, .secondary: 0x86E1FC, .onSecondary: 0x1B1D2B, .secondaryContainer: 0x444A73, .onSecondaryContainer: 0xB2EBFF, .tertiary: 0xC099FF, .onTertiary: 0x1B1D2B, .tertiaryContainer: 0x444A73, .onTertiaryContainer: 0xCAABFF, .background: 0x222436, .onBackground: 0xC8D3F5, .surface: 0x222436, .onSurface: 0xC8D3F5, .surfaceVariant: 0x444A73, .onSurfaceVariant: 0x828BB8, .outline: 0x828BB8, .outlineVariant: 0x444A73, .error: 0xFF757F, .onError: 0x1B1D2B, .inverseSurface: 0xC8D3F5, .inverseOnSurface: 0x222436, .surfaceContainerLowest: 0x1E202F, .surfaceContainerLow: 0x292C44, .surfaceContainer: 0x2D304B, .surfaceContainerHigh: 0x363B5D, .surfaceContainerHighest: 0x3F466F]
        case (.tokyoNight, false): return [.primary: 0x2E7DE9, .onPrimary: 0xFFFFFF, .primaryContainer: 0x92A6D5, .onPrimaryContainer: 0x15386A, .secondary: 0x007197, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xA9C6D3, .onSecondaryContainer: 0x006A83, .tertiary: 0x9854F1, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0xCFBFEA, .onTertiaryContainer: 0x7847BD, .background: 0xE1E2E7, .onBackground: 0x3760BF, .surface: 0xE1E2E7, .onSurface: 0x3760BF, .surfaceVariant: 0xC4C8DA, .onSurfaceVariant: 0x6172B0, .outline: 0x68709A, .outlineVariant: 0xA8AECB, .error: 0xF52A65, .onError: 0xFFFFFF, .inverseSurface: 0x3760BF, .inverseOnSurface: 0xE1E2E7, .surfaceContainerLowest: 0xE4E5E9, .surfaceContainerLow: 0xD0D5E3, .surfaceContainer: 0xC1C9DF, .surfaceContainerHigh: 0xC4C8DA, .surfaceContainerHighest: 0xA1A6C5]
        case (.yinYang, true): return [.primary: 0xFFFFFF, .onPrimary: 0x5A5A5A, .primaryContainer: 0xFFFFFF, .onPrimaryContainer: 0x000000, .secondary: 0xFFFFFF, .onSecondary: 0x5A5A5A, .secondaryContainer: 0x717171, .onSecondaryContainer: 0xE4E4E4, .tertiary: 0x000000, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0x00419E, .onTertiaryContainer: 0xD8E2FF, .background: 0x1E1E1E, .onBackground: 0xE6E6E6, .surface: 0x1E1E1E, .onSurface: 0xE6E6E6, .surfaceVariant: 0x313131, .onSurfaceVariant: 0xD1D1D1, .outline: 0x999999, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xE6E6E6, .inverseOnSurface: 0x1E1E1E, .surfaceContainerLowest: 0x2A2A2A, .surfaceContainerLow: 0x2D2D2D, .surfaceContainer: 0x313131, .surfaceContainerHigh: 0x383838, .surfaceContainerHighest: 0x3F3F3F]
        case (.yinYang, false): return [.primary: 0x000000, .onPrimary: 0xFFFFFF, .primaryContainer: 0x000000, .onPrimaryContainer: 0xFFFFFF, .secondary: 0x000000, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xDDDDDD, .onSecondaryContainer: 0x0C0C0C, .tertiary: 0xFFFFFF, .onTertiary: 0x000000, .tertiaryContainer: 0xD8E2FF, .onTertiaryContainer: 0x001947, .background: 0xFDFDFD, .onBackground: 0x222222, .surface: 0xFDFDFD, .onSurface: 0x222222, .surfaceVariant: 0xE8E8E8, .onSurfaceVariant: 0x515151, .outline: 0x838383, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x333333, .inverseOnSurface: 0xF4F4F4, .surfaceContainerLowest: 0xCFCFCF, .surfaceContainerLow: 0xDADADA, .surfaceContainer: 0xE8E8E8, .surfaceContainerHigh: 0xECECEC, .surfaceContainerHighest: 0xEFEFEF]
        case (.yotsuba, true): return [.primary: 0xFFB59D, .onPrimary: 0x5F1600, .primaryContainer: 0x862200, .onPrimaryContainer: 0xFFDBCF, .secondary: 0xFFB59D, .onSecondary: 0x5F1600, .secondaryContainer: 0x862200, .onSecondaryContainer: 0xFFDBCF, .tertiary: 0xD7C68D, .onTertiary: 0x3A2F05, .tertiaryContainer: 0x524619, .onTertiaryContainer: 0xF5E2A7, .background: 0x211A18, .onBackground: 0xEDE0DD, .surface: 0x211A18, .onSurface: 0xEDE0DD, .surfaceVariant: 0x332723, .onSurfaceVariant: 0xD8C2BC, .outline: 0xA08C87, .outlineVariant: 0x44464F, .error: 0xFFB4AB, .onError: 0x690005, .inverseSurface: 0xEDE0DD, .inverseOnSurface: 0x211A18, .surfaceContainerLowest: 0x2E221F, .surfaceContainerLow: 0x312521, .surfaceContainer: 0x332723, .surfaceContainerHigh: 0x413531, .surfaceContainerHighest: 0x4C403D]
        case (.yotsuba, false): return [.primary: 0xAE3200, .onPrimary: 0xFFFFFF, .primaryContainer: 0xFFDBCF, .onPrimaryContainer: 0x3B0A00, .secondary: 0xAE3200, .onSecondary: 0xFFFFFF, .secondaryContainer: 0xEBCDC2, .onSecondaryContainer: 0x3B0A00, .tertiary: 0x6B5E2F, .onTertiary: 0xFFFFFF, .tertiaryContainer: 0xF5E2A7, .onTertiaryContainer: 0x231B00, .background: 0xFCFCFC, .onBackground: 0x211A18, .surface: 0xFCFCFC, .onSurface: 0x211A18, .surfaceVariant: 0xF6EBE7, .onSurfaceVariant: 0x53433F, .outline: 0x85736E, .outlineVariant: 0xC5C6D0, .error: 0xBA1A1A, .onError: 0xFFFFFF, .inverseSurface: 0x362F2D, .inverseOnSurface: 0xFBEEEB, .surfaceContainerLowest: 0xECE3E0, .surfaceContainerLow: 0xF1E7E4, .surfaceContainer: 0xF6EBE7, .surfaceContainerHigh: 0xFAF4F2, .surfaceContainerHighest: 0xFBF6F4]
        }
    }
    // swiftlint:enable line_length
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

public extension MihonThemePalette {
    /// Swatch colours for the theme picker (dark scheme primary/secondary).
    var primaryColor: Color { MihonColorScheme(palette: self, dark: true, pureBlack: false).primary }
    var secondaryColor: Color { MihonColorScheme(palette: self, dark: true, pureBlack: false).secondaryContainer }
}

// MARK: - Environment

private struct MihonColorSchemeKey: EnvironmentKey {
    static let defaultValue = MihonColorScheme(palette: .mihonDefault, dark: true, pureBlack: false)
}

public extension EnvironmentValues {
    var mihonColors: MihonColorScheme {
        get { self[MihonColorSchemeKey.self] }
        set { self[MihonColorSchemeKey.self] = newValue }
    }
}

/// Resolves the active palette from the store + system appearance and injects it (1:1 with `TachiyomiTheme`).
public struct MihonThemeProvider: ViewModifier {
    let palette: MihonThemePalette
    let pureBlack: Bool
    @Environment(\.colorScheme) private var systemScheme

    public func body(content: Content) -> some View {
        let colors = MihonColorScheme(palette: palette, dark: systemScheme == .dark, pureBlack: pureBlack)
        content
            .environment(\.mihonColors, colors)
            .tint(colors.primary)
    }
}

public extension View {
    func mihonTheme(_ palette: MihonThemePalette, pureBlack: Bool) -> some View {
        modifier(MihonThemeProvider(palette: palette, pureBlack: pureBlack))
    }
}

// MARK: - Material 3 type scale & shapes

public enum MihonType {
    public static let displayMedium = Font.system(size: 45, weight: .regular)
    public static let headlineSmall = Font.system(size: 24, weight: .regular)
    public static let titleLarge = Font.system(size: 22, weight: .regular)
    public static let titleMedium = Font.system(size: 16, weight: .medium)
    public static let titleSmall = Font.system(size: 14, weight: .medium)
    public static let bodyLarge = Font.system(size: 16, weight: .regular)
    public static let bodyMedium = Font.system(size: 14, weight: .regular)
    public static let bodySmall = Font.system(size: 12, weight: .regular)
    public static let labelLarge = Font.system(size: 14, weight: .medium)
    public static let labelMedium = Font.system(size: 12, weight: .medium)
    public static let labelSmall = Font.system(size: 11, weight: .medium)
}

public enum MihonShape {
    public static let extraSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let extraLarge: CGFloat = 28
}

/// `MaterialTheme.padding`
public enum MihonPadding {
    public static let extraSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 16
    public static let large: CGFloat = 24
    public static let extraLarge: CGFloat = 32
}

/// `DISABLED_ALPHA` / `SECONDARY_ALPHA` from `presentation-core`.
public enum MihonAlpha {
    public static let disabled: Double = 0.38
    public static let secondary: Double = 0.78
}
