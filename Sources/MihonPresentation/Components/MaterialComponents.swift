import SwiftUI
import MihonDomain
import MihonData

// MARK: - Platform helpers

extension View {
    /// Root tab screens draw their own Material top app bar (root screens never pop, so swipe-back is unaffected).
    @ViewBuilder
    func mihonHideSystemNavigationBar() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #elseif os(macOS)
        self.toolbar(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }

    @ViewBuilder
    func mihonInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Material bottom sheet chrome on top of the native sheet (keeps native drag / detents).
    func mihonSheetChrome(_ colors: MihonColorScheme, detents: Set<PresentationDetent> = [.medium, .large]) -> some View {
        self
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationBackground(colors.surfaceContainerLow)
            .presentationCornerRadius(MihonShape.extraLarge)
    }
}

// MARK: - State layer (Material "ripple" substitute)

/// Pressed-state overlay used by every tappable Material surface (8% / 12% onSurface).
public struct MihonStateLayerStyle<S: Shape>: ButtonStyle {
    let shape: S
    var pressedOpacity: Double = 0.12

    public init(shape: S, pressedOpacity: Double = 0.12) {
        self.shape = shape
        self.pressedOpacity = pressedOpacity
    }

    public func makeBody(configuration: Configuration) -> some View {
        StateLayerBody(configuration: configuration, shape: shape, pressedOpacity: pressedOpacity)
    }

    private struct StateLayerBody: View {
        let configuration: ButtonStyleConfiguration
        let shape: S
        let pressedOpacity: Double
        @Environment(\.mihonColors) private var colors

        var body: some View {
            configuration.label
                .contentShape(shape)
                .background(shape.fill(colors.onSurface.opacity(configuration.isPressed ? pressedOpacity : 0)))
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

public extension ButtonStyle where Self == MihonStateLayerStyle<Rectangle> {
    static var mihonRow: MihonStateLayerStyle<Rectangle> { MihonStateLayerStyle(shape: Rectangle()) }
}

/// 1:1 with Compose `combinedClickable(onClick, onLongClick)` including the long-press haptic.
///
/// Built on `Button` rather than `onTapGesture`: inside a `ScrollView` a button cooperates with scrolling and
/// press highlighting, exposes the button trait to VoiceOver / keyboard, and lets nested buttons (continue
/// reading, download indicator, "最近更新") keep their own actions. The long press runs simultaneously and
/// swallows the trailing click so a long press never also opens the item.
struct MihonCombinedClickable: ViewModifier {
    let onClick: () -> Void
    let onLongClick: (() -> Void)?
    var cornerRadius: CGFloat = 0
    @State private var suppressNextClick = false
    @State private var longPressTick = 0

    func body(content: Content) -> some View {
        Button {
            if suppressNextClick {
                suppressNextClick = false
                return
            }
            onClick()
        } label: {
            content.contentShape(Rectangle())
        }
        .buttonStyle(MihonClickableStyle(cornerRadius: cornerRadius) {
            // The release after a long press may not produce a click (finger moved): never leave it armed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { suppressNextClick = false }
        })
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard let onLongClick else { return }
                suppressNextClick = true
                longPressTick &+= 1
                onLongClick()
            },
            including: onLongClick == nil ? .subviews : .all
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: longPressTick)
        .accessibilityAction(named: Text("选择")) { onLongClick?() }
    }
}

/// State-layer press feedback that reports when a press ends.
private struct MihonClickableStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let onPressEnded: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        ClickableBody(configuration: configuration, cornerRadius: cornerRadius, onPressEnded: onPressEnded)
    }

    private struct ClickableBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let onPressEnded: () -> Void
        @Environment(\.mihonColors) private var colors

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(colors.onSurface.opacity(configuration.isPressed ? 0.10 : 0))
                )
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    if !pressed { onPressEnded() }
                }
        }
    }
}

extension View {
    func mihonClickable(cornerRadius: CGFloat = 0, onLongClick: (() -> Void)? = nil, onClick: @escaping () -> Void) -> some View {
        modifier(MihonCombinedClickable(onClick: onClick, onLongClick: onLongClick, cornerRadius: cornerRadius))
    }
}

// MARK: - Icon button (48pt touch target, 24pt glyph)

public struct MihonIconButton: View {
    let systemName: String
    var tint: Color?
    var size: CGFloat = 20
    var isEnabled: Bool = true
    var label: String?
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    public init(_ systemName: String, tint: Color? = nil, size: CGFloat = 20, isEnabled: Bool = true, label: String? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.tint = tint
        self.size = size
        self.isEnabled = isEnabled
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle((tint ?? colors.onSurfaceVariant).opacity(isEnabled ? 1 : MihonAlpha.disabled))
                .frame(width: 40, height: 40)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(MihonStateLayerStyle(shape: Circle().inset(by: 4)))
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label ?? Self.defaultLabels[systemName] ?? systemName))
        .mihonTestAnchor("icon.\(label ?? Self.defaultLabels[systemName] ?? systemName)")
    }

    /// Labels for icon-only actions (VoiceOver, and the in-process UI self-test driver).
    static let defaultLabels: [String: String] = [
        "arrow.left": "返回",
        "xmark": "关闭",
        "magnifyingglass": "搜索",
        "line.3.horizontal.decrease": "筛选",
        "arrow.clockwise": "刷新",
        "trash": "删除",
        "globe": "语言",
        "gearshape": "设置",
        "pin": "置顶",
        "pin.fill": "取消置顶",
        "bookmark": "添加书签",
        "bookmark.fill": "删除书签",
        "checkmark.rectangle.stack": "全选",
        "square.on.square": "反选"
    ]
}

// MARK: - Top app bars (1:1 with `AppBar` / `SearchToolbar` / action mode)

public enum MihonAppBarNavigation {
    case back(() -> Void)
    case close(() -> Void)

    var systemName: String {
        switch self {
        case .back: return "arrow.left"
        case .close: return "xmark"
        }
    }

    var action: () -> Void {
        switch self {
        case .back(let action), .close(let action): return action
        }
    }
}

public struct MihonTopAppBar<Actions: View>: View {
    let title: String
    var subtitle: String?
    var navigation: MihonAppBarNavigation?
    var background: Color?
    var titleOpacity: Double = 1
    @ViewBuilder var actions: () -> Actions
    @Environment(\.mihonColors) private var colors

    public init(
        title: String,
        subtitle: String? = nil,
        navigation: MihonAppBarNavigation? = nil,
        background: Color? = nil,
        titleOpacity: Double = 1,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.navigation = navigation
        self.background = background
        self.titleOpacity = titleOpacity
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let navigation {
                MihonIconButton(navigation.systemName, tint: colors.onSurface, action: navigation.action)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(subtitle == nil ? MihonType.titleLarge : MihonType.titleMedium)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(MihonType.bodyMedium)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .opacity(titleOpacity)
            .padding(.leading, navigation == nil ? 12 : 4)
            Spacer(minLength: 4)
            HStack(spacing: 0, content: actions)
        }
        .padding(.horizontal, 4)
        .frame(height: 64)
        .background((background ?? colors.surface).ignoresSafeArea(edges: .top))
    }
}

public extension MihonTopAppBar where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, navigation: MihonAppBarNavigation? = nil, background: Color? = nil) {
        self.init(title: title, subtitle: subtitle, navigation: navigation, background: background) { EmptyView() }
    }
}

public struct MihonSearchAppBar: View {
    @Binding var query: String
    var placeholder: String = "搜索…"
    var onClose: () -> Void
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        HStack(spacing: 0) {
            MihonIconButton("arrow.left", tint: colors.onSurface) {
                query = ""
                onClose()
            }
            TextField("", text: $query, prompt: Text(placeholder).foregroundStyle(colors.onSurfaceVariant))
                .textFieldStyle(.plain)
                .font(MihonType.bodyLarge)
                .foregroundStyle(colors.onSurface)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { onSubmit?() }
                .autocorrectionDisabled()
                .padding(.leading, 4)
            if !query.isEmpty {
                MihonIconButton("xmark", tint: colors.onSurfaceVariant) { query = "" }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 64)
        .background(colors.surface.ignoresSafeArea(edges: .top))
        // A search that opens with its query filled in shows results; the keyboard would cover them.
        .onAppear { if query.isEmpty { focused = true } }
    }
}

// MARK: - Navigation bar (bottom) & rail (side) — 1:1 with `NavigationSuiteScaffold`

public struct MihonNavigationItem: Identifiable, Hashable {
    public let id: Int
    public let title: String
    public let icon: String
    public let selectedIcon: String
    public var badge: Int?

    public init(id: Int, title: String, icon: String, selectedIcon: String, badge: Int? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.selectedIcon = selectedIcon
        self.badge = badge
    }
}

private struct MihonNavigationIndicatorIcon: View {
    let item: MihonNavigationItem
    let selected: Bool
    let indicatorWidth: CGFloat
    @Environment(\.mihonColors) private var colors

    var body: some View {
        ZStack {
            Capsule()
                .fill(colors.secondaryContainer)
                .frame(width: indicatorWidth, height: 32)
                .scaleEffect(x: selected ? 1 : 0.4, y: 1)
                .opacity(selected ? 1 : 0)
            Image(systemName: selected ? item.selectedIcon : item.icon)
                .font(.system(size: 19, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
                .overlay(alignment: .topTrailing) {
                    if let badge = item.badge, badge > 0 {
                        MihonNavigationBadge(count: badge)
                            .offset(x: 14, y: -8)
                    }
                }
        }
        .frame(height: 32)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: selected)
    }
}

/// M3 large badge used on navigation destinations.
public struct MihonNavigationBadge: View {
    let count: Int
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(MihonType.labelSmall)
            .foregroundStyle(colors.onError)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(colors.error))
            .fixedSize()
    }
}

public struct MihonNavigationBar: View {
    let items: [MihonNavigationItem]
    @Binding var selection: Int
    var onReselect: (Int) -> Void = { _ in }
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    if selected { onReselect(item.id) } else { selection = item.id }
                } label: {
                    VStack(spacing: 4) {
                        MihonNavigationIndicatorIcon(item: item, selected: selected, indicatorWidth: 64)
                        Text(item.title)
                            .font(MihonType.labelMedium)
                            .foregroundStyle(selected ? colors.onSurface : colors.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .mihonTestAnchor("nav.\(item.title)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 80)
        .background(colors.surfaceContainer.ignoresSafeArea(edges: [.bottom, .horizontal]))
    }
}

public struct MihonNavigationRail: View {
    let items: [MihonNavigationItem]
    @Binding var selection: Int
    var onReselect: (Int) -> Void = { _ in }
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ForEach(items) { item in
                let selected = item.id == selection
                Button {
                    if selected { onReselect(item.id) } else { selection = item.id }
                } label: {
                    VStack(spacing: 4) {
                        MihonNavigationIndicatorIcon(item: item, selected: selected, indicatorWidth: 56)
                        Text(item.title)
                            .font(MihonType.labelMedium)
                            .foregroundStyle(selected ? colors.onSurface : colors.onSurfaceVariant)
                            .lineLimit(1)
                    }
                    .frame(width: 80, height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .mihonTestAnchor("nav.\(item.title)")
            }
            Spacer(minLength: 0)
        }
        .frame(width: 80)
        .frame(maxHeight: .infinity)
        .background(colors.surfaceElevation3.ignoresSafeArea(edges: [.top, .bottom, .leading]))
    }
}

// MARK: - Tab rows (1:1 with `PrimaryTabRow` / `PrimaryScrollableTabRow` + `TabText`)

public struct MihonTab: Identifiable, Hashable {
    public let id: Int64
    public let title: String
    public var badgeCount: Int?

    public init(id: Int64, title: String, badgeCount: Int? = nil) {
        self.id = id
        self.title = title
        self.badgeCount = badgeCount
    }
}

private struct MihonTabBoundsKey: PreferenceKey {
    static let defaultValue: [Int64: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int64: Anchor<CGRect>], nextValue: () -> [Int64: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

public struct MihonTabRow: View {
    let tabs: [MihonTab]
    @Binding var selection: Int64
    var scrollable: Bool = false
    var unselectedColor: Color?
    var background: Color?
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        Group {
            if scrollable {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(tabs) { tab in
                                tabButton(tab).id(tab.id)
                            }
                        }
                        .overlayPreferenceValue(MihonTabBoundsKey.self, alignment: .topLeading) { indicator($0) }
                    }
                    .onChange(of: selection) { _, newValue in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                    // Horizontal scroll content would run under side safe areas (the Duo cover screen's strip).
                    .clipped()
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        tabButton(tab).frame(maxWidth: .infinity)
                    }
                }
                .overlayPreferenceValue(MihonTabBoundsKey.self, alignment: .topLeading) { indicator($0) }
            }
        }
        .background(background ?? colors.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.surfaceVariant).frame(height: 1)
        }
    }

    private func tabButton(_ tab: MihonTab) -> some View {
        let selected = tab.id == selection
        return Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { selection = tab.id }
        } label: {
            HStack(spacing: 0) {
                Text(tab.title)
                    .font(MihonType.titleSmall)
                    .lineLimit(1)
                if let count = tab.badgeCount {
                    MihonPill(text: "\(count)")
                }
            }
            .foregroundStyle(selected ? colors.primary : (unselectedColor ?? colors.onSurfaceVariant))
            // Content-width indicator (PrimaryTabRow): measured on the label, drawn once by the row overlay.
            .anchorPreference(key: MihonTabBoundsKey.self, value: .bounds) { [tab.id: $0] }
            .padding(.horizontal, 16)
            .frame(minWidth: scrollable ? 90 : nil, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(MihonStateLayerStyle(shape: Rectangle(), pressedOpacity: 0.08))
        .mihonTestAnchor("tab.\(tab.title)")
    }
}

extension MihonTabRow {
    /// A single indicator positioned from anchor preferences: it slides between tabs without
    /// `matchedGeometryEffect`, which can feed geometry back into layout inside scroll views.
    @ViewBuilder
    fileprivate func indicator(_ anchors: [Int64: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let anchor = anchors[selection] {
                let rect = proxy[anchor]
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                    .fill(colors.primary)
                    .frame(width: max(24, rect.width), height: 3)
                    .offset(x: rect.midX - max(24, rect.width) / 2, y: proxy.size.height - 3)
                    .animation(.spring(duration: 0.3, bounce: 0.15), value: rect)
            }
        }
        .allowsHitTesting(false)
    }
}

/// `Pill` — fully rounded counter (category item counts, chapter counts).
public struct MihonPill: View {
    let text: String
    var color: Color?
    var contentColor: Color?
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(contentColor ?? colors.onSurface)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color ?? colors.onBackground.opacity(colors.isDark ? 0.12 : 0.08)))
            .padding(.leading, 4)
    }
}

// MARK: - Cover badges (1:1 with `Badge` / `BadgeGroup`)

public struct MihonBadge: View {
    var text: String?
    var systemImage: String?
    let color: Color
    let contentColor: Color

    public init(text: String, color: Color, contentColor: Color) {
        self.text = text
        self.color = color
        self.contentColor = contentColor
    }

    public init(systemImage: String, color: Color, contentColor: Color) {
        self.systemImage = systemImage
        self.color = color
        self.contentColor = contentColor
    }

    public var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(height: 14)
            }
        }
        .foregroundStyle(contentColor)
        .lineLimit(1)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(color)
    }
}

public struct MihonBadgeGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 0, content: content)
            .clipShape(RoundedRectangle(cornerRadius: MihonShape.extraSmall, style: .continuous))
    }
}

// MARK: - Buttons

public enum MihonButtonKind {
    case filled, tonal, outlined, text
}

public struct MihonButtonStyle: ButtonStyle {
    let kind: MihonButtonKind
    var contentColor: Color?

    public init(_ kind: MihonButtonKind, contentColor: Color? = nil) {
        self.kind = kind
        self.contentColor = contentColor
    }

    public func makeBody(configuration: Configuration) -> some View {
        MihonButtonBody(configuration: configuration, kind: kind, contentColor: contentColor)
    }

    private struct MihonButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: MihonButtonKind
        let contentColor: Color?
        @Environment(\.mihonColors) private var colors
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fg: Color
            let bg: Color
            switch kind {
            case .filled: fg = colors.onPrimary; bg = colors.primary
            case .tonal: fg = colors.onSecondaryContainer; bg = colors.secondaryContainer
            case .outlined, .text: fg = contentColor ?? colors.primary; bg = .clear
            }
            return configuration.label
                .font(MihonType.labelLarge)
                .lineLimit(1)
                .foregroundStyle(isEnabled ? fg : colors.onSurface.opacity(MihonAlpha.disabled))
                .padding(.horizontal, kind == .text ? 12 : 24)
                .frame(minHeight: 40)
                .background(Capsule().fill(isEnabled ? bg : (bg == .clear ? .clear : colors.onSurface.opacity(0.12))))
                .overlay {
                    if kind == .outlined {
                        Capsule().strokeBorder(colors.outlineVariant, lineWidth: 1)
                    }
                }
                .overlay(Capsule().fill(fg.opacity(configuration.isPressed ? 0.12 : 0)))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

// MARK: - Extended FAB (1:1 with `SmallExtendedFloatingActionButton`)

public struct MihonExtendedFAB: View {
    let text: String
    let systemImage: String
    var expanded: Bool = true
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                if expanded {
                    Text(text)
                        .font(MihonType.labelLarge)
                        .lineLimit(1)
                        .padding(.leading, 12)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(colors.onPrimaryContainer)
            .padding(.leading, 16)
            .padding(.trailing, expanded ? 20 : 16)
            .frame(minWidth: 56, minHeight: 56)
            .background(
                RoundedRectangle(cornerRadius: MihonShape.large, style: .continuous)
                    .fill(colors.primaryContainer)
                    .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 3)
            )
            .contentShape(RoundedRectangle(cornerRadius: MihonShape.large, style: .continuous))
        }
        .buttonStyle(MihonStateLayerStyle(shape: RoundedRectangle(cornerRadius: MihonShape.large, style: .continuous)))
        .animation(.spring(duration: 0.32, bounce: 0.15), value: expanded)
        .mihonTestAnchor("fab.\(text)")
    }
}

// MARK: - Chips

public struct MihonFilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.scale.combined(with: .opacity))
                }
                Text(label)
                    .font(MihonType.labelLarge)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)
            .padding(.leading, selected ? 8 : 16)
            .padding(.trailing, 16)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)
                    .fill(selected ? colors.secondaryContainer : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)
                    .strokeBorder(selected ? .clear : colors.outline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous))
        }
        .buttonStyle(MihonStateLayerStyle(shape: RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)))
        .animation(.easeInOut(duration: 0.18), value: selected)
        .mihonTestAnchor("chip.\(label)")
    }
}

/// `SuggestionChip` used for manga genres.
public struct MihonTagChip: View {
    let text: String
    var action: () -> Void = {}
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        Button(action: action) {
            Text(text)
                .font(MihonType.bodySmall)
                .foregroundStyle(colors.onSurfaceVariant)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)
                        .strokeBorder(colors.outlineVariant, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous))
        }
        .buttonStyle(MihonStateLayerStyle(shape: RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)))
        .padding(.vertical, 4)
    }
}

// MARK: - Flow layout (Compose `FlowRow`)

public struct MihonFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 0

    public init(spacing: CGFloat = 8, lineSpacing: CGFloat = 0) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Settings items (1:1 with `presentation-core/components/SettingsItems.kt`)

public enum MihonSettingsPadding {
    public static let horizontal: CGFloat = 24
    public static let vertical: CGFloat = 10
}

public struct MihonHeadingItem: View {
    let text: String
    @Environment(\.mihonColors) private var colors

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MihonSettingsPadding.horizontal)
            .padding(.vertical, MihonSettingsPadding.vertical)
    }
}

private struct MihonBaseSettingsItem<Widget: View>: View {
    let label: String
    var isEnabled: Bool = true
    let action: () -> Void
    @ViewBuilder let widget: () -> Widget
    @Environment(\.mihonColors) private var colors

    var body: some View {
        Button(action: action) {
            HStack(spacing: MihonPadding.large) {
                widget()
                Text(label)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface.opacity(isEnabled ? 1 : MihonAlpha.disabled))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, MihonSettingsPadding.horizontal)
            .padding(.vertical, MihonSettingsPadding.vertical)
            .contentShape(Rectangle())
        }
        .buttonStyle(.mihonRow)
        .disabled(!isEnabled)
    }
}

/// Material checkbox glyph (18pt box, 2pt stroke).
public struct MihonCheckbox: View {
    let checked: Bool
    var indeterminateCross = false
    /// M3 `TriStateCheckbox` `Indeterminate`: filled, with a dash.
    var indeterminate = false
    var tint: Color?
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        let filled = checked || indeterminate
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(filled ? .clear : colors.onSurfaceVariant, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(filled ? (tint ?? colors.primary) : .clear))
            if filled {
                Image(systemName: indeterminate ? "minus" : (indeterminateCross ? "xmark" : "checkmark"))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(colors.onPrimary)
            }
        }
        .frame(width: 18, height: 18)
        .frame(width: 24, height: 24)
        .animation(.easeOut(duration: 0.12), value: checked)
    }
}

public struct MihonCheckboxItem: View {
    let label: String
    let checked: Bool
    let indeterminate: Bool
    let action: () -> Void

    public init(_ label: String, checked: Bool, indeterminate: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.checked = checked
        self.indeterminate = indeterminate
        self.action = action
    }

    public var body: some View {
        MihonBaseSettingsItem(label: label, action: action) {
            MihonCheckbox(checked: checked, indeterminate: indeterminate)
        }
    }
}

public struct MihonTriStateItem: View {
    let label: String
    @Binding var state: TriStateFilter
    var isEnabled: Bool = true
    @Environment(\.mihonColors) private var colors

    public init(_ label: String, state: Binding<TriStateFilter>, isEnabled: Bool = true) {
        self.label = label
        self._state = state
        self.isEnabled = isEnabled
    }

    public var body: some View {
        MihonBaseSettingsItem(label: label, isEnabled: isEnabled, action: { state.toggle() }) {
            switch state {
            case .disabled:
                MihonCheckbox(checked: false)
                    .opacity(isEnabled ? 1 : MihonAlpha.disabled)
            case .include:
                MihonCheckbox(checked: true)
            case .exclude:
                MihonCheckbox(checked: true, indeterminateCross: true, tint: colors.error)
            }
        }
    }
}

public struct MihonSortItem: View {
    let label: String
    /// `true` = descending arrow, `false` = ascending arrow, `nil` = not the active sort.
    let descending: Bool?
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    public init(_ label: String, descending: Bool?, action: @escaping () -> Void) {
        self.label = label
        self.descending = descending
        self.action = action
    }

    public var body: some View {
        MihonBaseSettingsItem(label: label, action: action) {
            Group {
                if let descending {
                    Image(systemName: descending ? "arrow.down" : "arrow.up")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(colors.primary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 24, height: 24)
        }
    }
}

public struct MihonRadioItem: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    public init(_ label: String, selected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        MihonBaseSettingsItem(label: label, action: action) {
            ZStack {
                Circle().strokeBorder(selected ? colors.primary : colors.onSurfaceVariant, lineWidth: 2)
                if selected {
                    Circle().fill(colors.primary).frame(width: 10, height: 10)
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: 24, height: 24)
        }
    }
}

public struct MihonChipRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    public init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MihonHeadingItem(label)
            MihonFlowLayout(spacing: MihonPadding.small, lineSpacing: MihonPadding.small) {
                content()
            }
            .padding(.horizontal, MihonSettingsPadding.horizontal)
            .padding(.bottom, MihonSettingsPadding.vertical)
        }
    }
}

/// Material 3 slider (4pt active track, 16pt handle).
public struct MihonSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    /// Right-to-left readers: the minimum sits at the trailing edge (explicit, not environment mirroring).
    var reversed = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.mihonColors) private var colors

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0, reversed: Bool = false, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.step = step
        self.reversed = reversed
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - 20)
            let rawFraction = range.upperBound > range.lowerBound
                ? (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                : 0
            let fraction = reversed ? 1 - rawFraction : rawFraction
            let thumbX = 10 + width * fraction
            ZStack(alignment: .topLeading) {
                Capsule().fill(colors.secondaryContainer).frame(width: width, height: 4)
                    .offset(x: 10, y: geo.size.height / 2 - 2)
                // Active track runs from the minimum end to the thumb.
                Capsule().fill(colors.primary)
                    .frame(width: max(0, reversed ? width - (thumbX - 10) : thumbX - 10), height: 4)
                    .offset(x: reversed ? thumbX : 10, y: geo.size.height / 2 - 2)
                Capsule()
                    .fill(colors.primary)
                    .frame(width: 4, height: 28)
                    .offset(x: thumbX - 2, y: geo.size.height / 2 - 14)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onEditingChanged(true)
                        let fraction = (drag.location.x - 10) / width
                        update(fraction: reversed ? 1 - fraction : fraction)
                    }
                    .onEnded { _ in onEditingChanged(false) }
            )
        }
        .frame(height: 44)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func update(fraction: Double) {
        let clamped = min(1, max(0, fraction))
        var newValue = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        if step > 0 {
            newValue = (newValue / step).rounded() * step
        }
        newValue = min(range.upperBound, max(range.lowerBound, newValue))
        if newValue != value { value = newValue }
    }
}

public struct MihonSliderItem: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var valueText: String
    @Environment(\.mihonColors) private var colors

    public init(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, valueText: String) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
    }

    public var body: some View {
        HStack(spacing: MihonPadding.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface)
                Text(valueText)
                    .font(MihonType.bodySmall)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .monospacedDigit()
            }
            .frame(width: 110, alignment: .leading)
            MihonSlider(value: $value, in: range, step: step)
        }
        .padding(.horizontal, MihonSettingsPadding.horizontal)
        .padding(.vertical, 4)
    }
}

// MARK: - Switch & preference widgets (1:1 with `SwitchPreferenceWidget` / `TextPreferenceWidget`)

public struct MihonSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.mihonColors) private var colors

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? colors.primary : colors.surfaceContainerHighest)
                .overlay(Capsule().strokeBorder(isOn ? .clear : colors.outline, lineWidth: 2))
            Circle()
                .fill(isOn ? colors.onPrimary : colors.outline)
                .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(colors.onPrimaryContainer)
                    }
                }
                .padding(.horizontal, isOn ? 4 : 8)
        }
        .frame(width: 52, height: 32)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: isOn)
        .onTapGesture { isOn.toggle() }
    }
}

public struct MihonPreferenceRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var isEnabled: Bool = true
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.mihonColors) private var colors

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.action = action
        self.trailing = trailing
    }

    public var body: some View {
        let content = HStack(spacing: 0) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(colors.primary)
                    .frame(width: 24, height: 24)
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MihonType.bodySmall)
                        .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
                        .lineLimit(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            trailing()
                .padding(.trailing, 16)
        }
        .padding(.vertical, 16)
        .opacity(isEnabled ? 1 : MihonAlpha.disabled)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }
                .buttonStyle(.mihonRow)
                .disabled(!isEnabled)
                .mihonTestAnchor("pref.\(title)")
        } else {
            content
        }
    }
}

public extension MihonPreferenceRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, systemImage: String? = nil, isEnabled: Bool = true, action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, isEnabled: isEnabled, action: action) { EmptyView() }
    }
}

public struct MihonSwitchPreference: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    @Binding var isOn: Bool

    public init(title: String, subtitle: String? = nil, systemImage: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._isOn = isOn
    }

    public var body: some View {
        MihonPreferenceRow(title: title, subtitle: subtitle, systemImage: systemImage, action: { isOn.toggle() }) {
            MihonSwitch(isOn: $isOn)
        }
    }
}

/// `PreferenceGroupHeader` — primary coloured group label in settings screens.
public struct MihonPreferenceGroupHeader: View {
    let title: String
    @Environment(\.mihonColors) private var colors

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(colors.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}

// MARK: - Dividers, headers, empty & loading states

public struct MihonDivider: View {
    var inset: CGFloat = 0
    @Environment(\.mihonColors) private var colors

    public init(inset: CGFloat = 0) { self.inset = inset }

    public var body: some View {
        Rectangle()
            .fill(colors.outlineVariant)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// `ListGroupHeader` (Updates / History day buckets).
public struct MihonListGroupHeader: View {
    let text: String
    @Environment(\.mihonColors) private var colors

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(colors.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MihonPadding.medium)
            .padding(.vertical, MihonPadding.small)
    }
}

/// `EmptyScreen` with upstream's random kaomoji faces.
public struct MihonEmptyScreen: View {
    let message: String
    var actions: [(title: String, systemImage: String, action: () -> Void)] = []
    @State private var face = MihonEmptyScreen.faces.randomElement() ?? "(･o･;)"
    @Environment(\.mihonColors) private var colors

    static let faces = ["(･o･;)", "Σ(ಠ_ಠ)", "ಥ_ಥ", "(˘･_･˘)", "(；￣Д￣)", "(･Д･。", "(╬ಠ益ಠ)", "(╥﹏╥)", "(⋟﹏⋞)", "Ò︵Ó", " ˙ᯅ˙)", "(¬_¬)"]

    public init(message: String, actions: [(title: String, systemImage: String, action: () -> Void)] = []) {
        self.message = message
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(face)
                .font(MihonType.displayMedium)
                .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
                .environment(\.layoutDirection, .leftToRight)
            Text(message)
                .font(MihonType.bodyMedium)
                .foregroundStyle(colors.onSurface.opacity(MihonAlpha.secondary))
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            if !actions.isEmpty {
                HStack(spacing: MihonPadding.small) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                        Button(action: item.action) {
                            VStack(spacing: 4) {
                                Image(systemName: item.systemImage).font(.system(size: 20))
                                Text(item.title).font(MihonType.labelMedium)
                            }
                            .foregroundStyle(colors.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(MihonStateLayerStyle(shape: RoundedRectangle(cornerRadius: MihonShape.small)))
                    }
                }
                .padding(.top, 24)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Material circular progress indicator (indeterminate when `progress == nil`).
public struct MihonCircularProgress: View {
    var progress: Double?
    var size: CGFloat = 40
    var lineWidth: CGFloat = 4
    var color: Color?
    var trackColor: Color?
    @State private var rotation: Double = 0
    @Environment(\.mihonColors) private var colors

    public init(progress: Double? = nil, size: CGFloat = 40, lineWidth: CGFloat = 4, color: Color? = nil, trackColor: Color? = nil) {
        self.progress = progress
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
        self.trackColor = trackColor
    }

    public var body: some View {
        ZStack {
            if let trackColor {
                Circle().stroke(trackColor, lineWidth: lineWidth)
            }
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(color ?? colors.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(color ?? colors.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }
        }
        .frame(width: size, height: size)
    }
}

public struct MihonLoadingScreen: View {
    public init() {}
    public var body: some View {
        MihonCircularProgress()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thin linear progress (library update / reader page loading).
public struct MihonLinearProgress: View {
    var progress: Double?
    @State private var phase: CGFloat = -0.4
    @Environment(\.mihonColors) private var colors

    public init(progress: Double? = nil) { self.progress = progress }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(colors.secondaryContainer)
                if let progress {
                    Rectangle()
                        .fill(colors.primary)
                        .frame(width: geo.size.width * max(0, min(1, progress)))
                        .animation(.easeOut(duration: 0.25), value: progress)
                } else {
                    Rectangle()
                        .fill(colors.primary)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                                phase = 1.0
                            }
                        }
                }
            }
        }
        .frame(height: 4)
        .clipped()
    }
}

/// M3 Snackbar (status banner replacement).
public struct MihonSnackbar: View {
    let message: String
    @Environment(\.mihonColors) private var colors

    public init(message: String) { self.message = message }

    public var body: some View {
        Text(message)
            .font(MihonType.bodyMedium)
            .foregroundStyle(colors.inverseOnSurface)
            .lineLimit(3)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: MihonShape.extraSmall, style: .continuous)
                    .fill(colors.inverseSurface)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            )
            .frame(maxWidth: 560)
            .padding(.horizontal, 12)
    }
}

/// `DotSeparatorText`
public struct MihonDotSeparator: View {
    public init() {}
    public var body: some View { Text(" • ") }
}
