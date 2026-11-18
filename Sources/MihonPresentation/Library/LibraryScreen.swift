import SwiftUI
import MihonDomain
import MihonData

// MARK: - 1:1 Mihon Library Screen (LibraryToolbar + PrimaryScrollableTabRow + LibraryPager + action mode)

public struct LibraryScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    @State private var selectedCategoryId: Int64?
    @State private var pagerPosition: Int64?
    @State private var searchQuery: String = ""
    @State private var isSearching = false
    @State private var showSettingsSheet = false
    @State private var showCategorySheet = false
    @State private var selection: Set<Int64> = []

    public init() {}

    private var isActionMode: Bool { !selection.isEmpty }

    public var body: some View {
        let categories = store.visibleLibraryCategories()
        let activeCategoryId = resolvedCategory(in: categories)

        VStack(spacing: 0) {
            toolbar(categories: categories, activeCategoryId: activeCategoryId)

            if store.isUpdatingLibrary {
                MihonLinearProgress(progress: store.libraryUpdateProgress)
            }

            if store.showCategoryTabs && categories.count > 1 {
                MihonTabRow(
                    tabs: categories.map { cat in
                        MihonTab(
                            id: cat.id,
                            title: cat.name,
                            badgeCount: store.showMangaCountInCategory
                                ? store.libraryItems(forCategory: cat.id, searchQuery: searchQuery).count
                                : nil
                        )
                    },
                    selection: Binding(
                        get: { activeCategoryId ?? categories.first?.id ?? 0 },
                        set: { newValue in
                            selectedCategoryId = newValue
                            withAnimation(.snappy(duration: 0.3)) { pagerPosition = newValue }
                        }
                    ),
                    scrollable: true,
                    unselectedColor: colors.onSurface
                )
            }

            pager(categories: categories)
        }
        .background(colors.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isActionMode {
                LibraryBottomActionMenu(
                    onChangeCategory: { showCategorySheet = true },
                    onMarkRead: { markSelection(read: true) },
                    onMarkUnread: { markSelection(read: false) },
                    onDownload: downloadSelection,
                    onDelete: removeSelectionFromLibrary
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isActionMode)
        .preference(key: MihonHideBottomBarKey.self, value: isActionMode)
        .sheet(isPresented: $showSettingsSheet) {
            LibrarySettingsSheet()
                .environment(store)
                .mihonSheetChrome(colors)
        }
        .sheet(isPresented: $showCategorySheet) {
            ChangeCategorySheet(mangaIds: Array(selection)) {
                selection.removeAll()
            }
            .environment(store)
            .mihonSheetChrome(colors, detents: [.medium])
        }
    }

    private func resolvedCategory(in categories: [MangaCategory]) -> Int64? {
        if let selectedCategoryId, categories.contains(where: { $0.id == selectedCategoryId }) {
            return selectedCategoryId
        }
        return categories.first?.id
    }

    // MARK: App bar (normal / search / action mode)

    @ViewBuilder
    private func toolbar(categories: [MangaCategory], activeCategoryId: Int64?) -> some View {
        if isActionMode {
            MihonTopAppBar(
                title: "\(selection.count)",
                navigation: .close { selection.removeAll() },
                background: colors.surfaceElevation3
            ) {
                MihonIconButton("checkmark.rectangle.stack") {
                    let items = store.libraryItems(forCategory: activeCategoryId ?? -1, searchQuery: searchQuery)
                    selection.formUnion(items.map(\.id))
                }
                .help("全选")
                MihonIconButton("square.on.square") {
                    let ids = Set(store.libraryItems(forCategory: activeCategoryId ?? -1, searchQuery: searchQuery).map(\.id))
                    selection = ids.symmetricDifference(selection)
                }
                .help("反选")
            }
        } else if isSearching {
            MihonSearchAppBar(query: $searchQuery, onClose: { isSearching = false })
        } else {
            let total = store.libraryItems(forCategory: -1, searchQuery: "").count
            MihonTopAppBar(title: "书架") {
                if store.showMangaCountInCategory && !(store.showCategoryTabs && categories.count > 1) {
                    MihonPill(text: "\(total)")
                        .padding(.trailing, 4)
                }
                MihonIconButton("magnifyingglass") { isSearching = true }
                    .help("搜索")
                MihonIconButton(
                    "line.3.horizontal.decrease",
                    tint: store.libraryFilter.hasActiveFilters ? colors.active : nil
                ) {
                    showSettingsSheet = true
                }
                .help("筛选")
                Menu {
                    Button("更新书架") { Task { await store.refreshLibraryUpdates() } }
                    Button("更新分类") { Task { await store.refreshLibraryUpdates(categoryId: activeCategoryId) } }
                    Button("随机打开作品") {
                        if let random = store.libraryItems(forCategory: activeCategoryId ?? -1, searchQuery: "").randomElement() {
                            navigator.openManga(random.id)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 18))
                        .foregroundStyle(colors.onSurfaceVariant)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Category pager (1:1 with `LibraryPager` HorizontalPager)

    @ViewBuilder
    private func pager(categories: [MangaCategory]) -> some View {
        if categories.isEmpty {
            MihonEmptyScreen(message: "书架为空")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(categories) { category in
                        LibraryCategoryPage(
                            categoryId: category.id,
                            searchQuery: searchQuery,
                            selection: $selection
                        )
                        .containerRelativeFrame(.horizontal)
                        .id(category.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $pagerPosition)
            .scrollDisabled(categories.count <= 1)
            // A horizontal scroll view extends under side safe areas (the iPhone Duo cover display's sensor
            // bar), which would show a sliver of the next category page there.
            .clipped()
            .onChange(of: pagerPosition) { _, newValue in
                if let newValue, newValue != selectedCategoryId {
                    selectedCategoryId = newValue
                }
            }
            .onAppear {
                if pagerPosition == nil { pagerPosition = resolvedCategory(in: categories) }
            }
        }
    }

    // MARK: Action-mode operations

    private func markSelection(read: Bool) {
        for id in selection {
            let ids = Set((store.chaptersByManga[id] ?? []).map(\.id))
            store.setChaptersRead(mangaId: id, chapterIds: ids, read: read)
        }
        selection.removeAll()
    }

    private func downloadSelection() {
        for id in selection {
            guard let manga = store.manga(id: id) else { continue }
            let unread = store.filteredAndSortedChapters(for: manga).filter { !$0.read }
            store.enqueueChapterDownloads(manga: manga, chapters: unread)
        }
        selection.removeAll()
    }

    private func removeSelectionFromLibrary() {
        for id in selection {
            store.removeFromLibrary(mangaId: id)
        }
        selection.removeAll()
    }
}

// MARK: - One category page (grid or list)

private struct LibraryCategoryPage: View {
    let categoryId: Int64
    let searchQuery: String
    @Binding var selection: Set<Int64>
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonNavigator) private var navigator

    var body: some View {
        let items = store.libraryItems(forCategory: categoryId, searchQuery: searchQuery)
        Group {
            if items.isEmpty {
                ScrollView {
                    MihonEmptyScreen(message: emptyMessage)
                        .frame(minHeight: 420)
                }
            } else {
                ScrollView(.vertical) {
                    if store.libraryDisplayMode == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                LibraryListItem(
                                    item: item,
                                    isSelected: selection.contains(item.id),
                                    isShownInDetailPane: navigator.selectedMangaId == item.id,
                                    onClick: { click(item) },
                                    onLongClick: { toggle(item.id) }
                                )
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(items) { item in
                                LibraryGridItem(
                                    item: item,
                                    mode: store.libraryDisplayMode,
                                    isSelected: selection.contains(item.id),
                                    isShownInDetailPane: navigator.selectedMangaId == item.id,
                                    onClick: { click(item) },
                                    onLongClick: { toggle(item.id) }
                                )
                            }
                        }
                        .padding(8)
                    }
                }
                .refreshable {
                    // Upstream refreshes the category on screen (`-1` is every title, with the tabs hidden).
                    await store.refreshLibraryUpdates(categoryId: categoryId == -1 ? nil : categoryId)
                }
            }
        }
    }

    private var emptyMessage: String {
        if !searchQuery.isEmpty { return "没有结果" }
        if store.libraryFilter.hasActiveFilters { return "没有符合筛选条件的作品" }
        return store.mangas.contains(where: \.favorite) ? "此分类为空" : "书架为空"
    }

    private var columns: [GridItem] {
        let count = store.columnsPerRowPortrait
        if count <= 0 {
            return [GridItem(.adaptive(minimum: 128), spacing: 4)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: min(10, count))
    }

    private func click(_ item: LibraryMangaItem) {
        if selection.isEmpty {
            navigator.openManga(item.id)
        } else {
            toggle(item.id)
        }
    }

    private func toggle(_ id: Int64) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

// MARK: - Grid item (1:1 with `MangaCompactGridItem` / `MangaComfortableGridItem`)

struct LibraryGridItem: View {
    let item: LibraryMangaItem
    let mode: LibraryDisplayMode
    let isSelected: Bool
    var isShownInDetailPane = false
    let onClick: () -> Void
    let onLongClick: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            if mode == .comfortableGrid {
                Text(item.manga.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(isSelected ? colors.onSecondary : colors.onSurface)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)
                .fill(isSelected ? colors.secondary : (isShownInDetailPane ? colors.secondary.opacity(colors.isDark ? 0.16 : 0.22) : .clear))
        )
        .mihonClickable(cornerRadius: MihonShape.small, onLongClick: onLongClick, onClick: onClick)
        .mihonTestAnchor("library.\(item.id)")
    }

    private var continueAction: (() -> Void)? {
        guard store.showContinueReadingButton, item.unreadCount > 0, let next = item.nextChapter else { return nil }
        return { navigator.openReader(item.manga, next) }
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                MangaCoverView(title: item.manga.title, thumbnailUrl: store.coverUrl(for: item.manga))
                    .opacity(isSelected ? 0.76 : 1)
            }
            .overlay(alignment: .bottom) {
                if mode == .compactGrid {
                    compactTitleOverlay
                } else if let continueAction {
                    HStack {
                        Spacer()
                        ContinueReadingButton(size: 32, iconSize: 16, action: continueAction)
                            .padding(6)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                MihonLibraryStartBadges(
                    downloadCount: item.downloadCount,
                    unreadCount: item.unreadCount,
                    showDownload: store.showDownloadBadge,
                    showUnread: store.showUnreadBadge
                )
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                MihonLibraryEndBadges(
                    isLocal: item.isLocal,
                    language: item.sourceLanguage,
                    showLocal: store.showLocalBadge,
                    showLanguage: store.showLanguageBadge
                )
                .padding(4)
            }
    }

    /// Bottom 33% scrim `0x00000000 → 0xAA000000` with the title (and continue button) on top.
    private var compactTitleOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, Color(hex: 0x000000, alpha: 0xAA / 255.0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.33)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: MihonShape.extraSmall, bottomTrailingRadius: MihonShape.extraSmall))
                compactTitleRow
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .allowsHitTesting(continueAction != nil)
    }

    private var compactTitleRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
                Text(item.manga.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineSpacing(3)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                if let continueAction {
                    ContinueReadingButton(size: 28, iconSize: 14, action: continueAction)
                        .padding(.trailing, 6)
                        .padding(.bottom, 6)
                }
        }
    }
}

/// `ContinueReadingButton` — FilledIconButton, primaryContainer @ 90%, small (8pt) corners.
struct ContinueReadingButton: View {
    let size: CGFloat
    let iconSize: CGFloat
    let action: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: iconSize * 0.8, weight: .bold))
                .foregroundStyle(colors.onPrimaryContainer)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous).fill(colors.primaryContainer.opacity(0.9)))
        }
        .buttonStyle(MihonStateLayerStyle(shape: RoundedRectangle(cornerRadius: MihonShape.small, style: .continuous)))
        .help("继续")
    }
}

// MARK: - List item (1:1 with `MangaListItem`: 56pt row, square cover)

struct LibraryListItem: View {
    let item: LibraryMangaItem
    let isSelected: Bool
    var isShownInDetailPane = false
    let onClick: () -> Void
    let onLongClick: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    var body: some View {
        HStack(spacing: 0) {
            MangaCoverView(title: item.manga.title, thumbnailUrl: store.coverUrl(for: item.manga))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: .infinity)
            Text(item.manga.title)
                .font(MihonType.bodyMedium)
                .foregroundStyle(colors.onSurface)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            HStack(spacing: 0) {
                MihonLibraryStartBadges(
                    downloadCount: item.downloadCount,
                    unreadCount: item.unreadCount,
                    showDownload: store.showDownloadBadge,
                    showUnread: store.showUnreadBadge
                )
                MihonLibraryEndBadges(
                    isLocal: item.isLocal,
                    language: item.sourceLanguage,
                    showLocal: store.showLocalBadge,
                    showLanguage: store.showLanguageBadge
                )
            }
            if store.showContinueReadingButton, item.unreadCount > 0, let next = item.nextChapter {
                ContinueReadingButton(size: 28, iconSize: 14) {
                    navigator.openReader(item.manga, next)
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background((isSelected || isShownInDetailPane) ? colors.secondary.opacity(colors.isDark ? 0.16 : 0.22) : .clear)
        .mihonClickable(onLongClick: onLongClick, onClick: onClick)
        .mihonTestAnchor("library.\(item.id)")
    }
}

// MARK: - Bottom action menu (1:1 with `LibraryBottomActionMenu`)

struct LibraryBottomActionMenu: View {
    let onChangeCategory: () -> Void
    let onMarkRead: () -> Void
    let onMarkUnread: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        HStack(spacing: 0) {
            MihonBottomActionButton(title: "设置分类", systemImage: "tag", action: onChangeCategory)
            MihonBottomActionButton(title: "标记为已读", systemImage: "checkmark.circle", action: onMarkRead)
            MihonBottomActionButton(title: "标记为未读", systemImage: "arrow.uturn.backward.circle", action: onMarkUnread)
            MihonBottomActionButton(title: "下载", systemImage: "arrow.down.circle", action: onDownload)
            MihonBottomActionButton(title: "删除", systemImage: "trash", action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: MihonShape.large, topTrailingRadius: MihonShape.large)
                .fill(colors.surfaceContainerHigh)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Icon-only action that reveals its label on long press (upstream `toConfirm` behaviour).
struct MihonBottomActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var showLabel = false
    @Environment(\.mihonColors) private var colors

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
            if showLabel {
                Text(title)
                    .font(MihonType.labelSmall)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(colors.onSurface)
        .frame(maxWidth: .infinity, minHeight: 48)
        .mihonClickable(
            cornerRadius: MihonShape.medium,
            onLongClick: {
                withAnimation(.easeOut(duration: 0.15)) { showLabel = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    withAnimation(.easeIn(duration: 0.15)) { showLabel = false }
                }
            },
            onClick: action
        )
        .accessibilityLabel(Text(title))
        .help(title)
        .mihonTestAnchor("action.\(title)")
    }
}

// MARK: - Library settings sheet (1:1 with `LibrarySettingsDialog`: 筛选 / 排序 / 显示)

public struct LibrarySettingsSheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @State private var tab: Int64 = 0

    public init() {}

    public var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            MihonTabRow(
                tabs: [MihonTab(id: 0, title: "筛选"), MihonTab(id: 1, title: "排序"), MihonTab(id: 2, title: "显示")],
                selection: $tab,
                background: colors.surfaceContainerLow
            )
            .padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case 0:
                        MihonTriStateItem("已下载", state: $store.libraryFilter.filterDownloaded, isEnabled: !store.downloadedOnlyMode)
                        MihonTriStateItem("未读", state: $store.libraryFilter.filterUnread)
                        MihonTriStateItem("阅读过", state: $store.libraryFilter.filterStarted)
                        MihonTriStateItem("已添加书签", state: $store.libraryFilter.filterBookmarked)
                        MihonTriStateItem("已完结", state: $store.libraryFilter.filterCompleted)
                        if store.showsDemoFeatures {
                            MihonTriStateItem("已记录进度", state: $store.libraryFilter.filterTracked)
                        }
                    case 1:
                        ForEach(LibrarySortOption.allCases, id: \.self) { option in
                            MihonSortItem(
                                option.rawValue,
                                descending: store.librarySortOption == option ? !store.librarySortAscending : nil
                            ) {
                                if store.librarySortOption == option {
                                    store.librarySortAscending.toggle()
                                } else {
                                    store.librarySortOption = option
                                    store.librarySortAscending = option == .alphabetical
                                }
                            }
                        }
                    default:
                        displayPage(store: store)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(colors.surfaceContainerLow)
    }

    @ViewBuilder
    private func displayPage(store: MihonRepositoryStore) -> some View {
        @Bindable var store = store
        MihonChipRow("显示模式") {
            ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                MihonFilterChip(label: mode.rawValue, selected: store.libraryDisplayMode == mode) {
                    store.libraryDisplayMode = mode
                }
            }
        }
        if store.libraryDisplayMode != .list {
            MihonSliderItem(
                "每行项目数",
                value: Binding(
                    get: { Double(store.columnsPerRowPortrait) },
                    set: { store.columnsPerRowPortrait = Int($0.rounded()) }
                ),
                in: 0...10,
                step: 1,
                valueText: store.columnsPerRowPortrait == 0 ? "默认" : "\(store.columnsPerRowPortrait)"
            )
        }
        MihonHeadingItem("角标")
        MihonCheckboxItem("已下载的章节数", checked: store.showDownloadBadge) { store.showDownloadBadge.toggle() }
        MihonCheckboxItem("未读章节", checked: store.showUnreadBadge) { store.showUnreadBadge.toggle() }
        if store.showsDemoFeatures {
            MihonCheckboxItem("本地图源", checked: store.showLocalBadge) { store.showLocalBadge.toggle() }
        }
        MihonCheckboxItem("语言", checked: store.showLanguageBadge) { store.showLanguageBadge.toggle() }
        MihonHeadingItem("分类标签")
        MihonCheckboxItem("显示分类标签", checked: store.showCategoryTabs) { store.showCategoryTabs.toggle() }
        MihonCheckboxItem("显示作品数", checked: store.showMangaCountInCategory) { store.showMangaCountInCategory.toggle() }
        MihonHeadingItem("其他")
        MihonCheckboxItem("继续阅读按钮", checked: store.showContinueReadingButton) { store.showContinueReadingButton.toggle() }
    }
}

// MARK: - Change category sheet (1:1 with `ChangeCategoryDialog`)

/// For several titles a category only some of them have starts mixed (–) and stays as each has it unless toggled;
/// confirming adds the ticked categories and removes the cleared ones. `addsToLibrary` also puts the title in the
/// library (upstream `moveMangaToCategoriesAndAddToLibrary`).
public struct ChangeCategorySheet: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.dismiss) private var dismiss
    public let mangaIds: [Int64]
    public var addsToLibrary: Bool
    public var onComplete: () -> Void
    @State private var states: [Int64: CheckState] = [:]
    @State private var mixedAtStart: Set<Int64> = []
    @State private var didLoad = false

    enum CheckState { case checked, mixed, unchecked }

    public init(mangaIds: [Int64], addsToLibrary: Bool = false, onComplete: @escaping () -> Void = {}) {
        self.mangaIds = mangaIds
        self.addsToLibrary = addsToLibrary
        self.onComplete = onComplete
    }

    private var userCategories: [MangaCategory] {
        store.categories.filter { !$0.isSystemCategory }.sorted { $0.order < $1.order }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置分类")
                .font(MihonType.headlineSmall)
                .foregroundStyle(colors.onSurface)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)
            if userCategories.isEmpty {
                Text("你还没有分类。可在「设置 → 书架 → 编辑分类」中添加。")
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(.horizontal, 24)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(userCategories) { cat in
                        let state = states[cat.id] ?? .unchecked
                        MihonCheckboxItem(cat.name, checked: state == .checked, indeterminate: state == .mixed) {
                            toggle(cat.id)
                        }
                        .mihonTestAnchor("category.\(cat.name)")
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(MihonButtonStyle(.text))
                Button("确定") {
                    confirm()
                    onComplete()
                    dismiss()
                }
                .buttonStyle(MihonButtonStyle(.text))
                .mihonTestAnchor("dialog.确定")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(colors.surfaceContainerLow)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            for cat in userCategories {
                let having = mangaIds.filter { (store.mangaCategories[$0] ?? []).contains(cat.id) }.count
                if having == 0 {
                    states[cat.id] = .unchecked
                } else if having == mangaIds.count {
                    states[cat.id] = .checked
                } else {
                    states[cat.id] = .mixed
                    mixedAtStart.insert(cat.id)
                }
            }
        }
    }

    /// Checked ⇄ cleared; a category that started mixed cycles mixed → cleared → checked → mixed (upstream
    /// `CheckboxState.TriState`).
    private func toggle(_ id: Int64) {
        switch states[id] ?? .unchecked {
        case .checked: states[id] = mixedAtStart.contains(id) ? .mixed : .unchecked
        case .mixed: states[id] = .unchecked
        case .unchecked: states[id] = .checked
        }
    }

    private func confirm() {
        let adding = Set(states.filter { $0.value == .checked }.map(\.key))
        let removing = Set(states.filter { $0.value == .unchecked }.map(\.key))
        if addsToLibrary, mangaIds.count == 1, let id = mangaIds.first {
            store.addToLibrary(mangaId: id, categoryIds: userCategories.map(\.id).filter(adding.contains))
        } else {
            store.changeCategories(mangaIds: mangaIds, adding: adding, removing: removing)
        }
    }
}
