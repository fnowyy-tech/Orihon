import SwiftUI
import MihonDomain
import MihonData

// MARK: - 1:1 Mihon Updates Tab (last-update info · day headers · `UpdatesUiItem` · action mode)

public struct UpdatesScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    @State private var selection: Set<Int64> = []

    public init() {}

    public var body: some View {
        let updates = store.recentUpdates()
        let groups = grouped(updates)

        VStack(spacing: 0) {
            if selection.isEmpty {
                MihonTopAppBar(title: "更新") {
                    MihonIconButton("calendar", label: "显示即将推出的更新") { navigator.push(.upcoming) }
                        .help("显示即将推出的更新")
                    MihonIconButton("arrow.clockwise") { Task { await store.refreshLibraryUpdates() } }
                        .help("更新书架")
                }
            } else {
                MihonTopAppBar(title: "\(selection.count)", navigation: .close { selection.removeAll() }, background: colors.surfaceElevation3) {
                    MihonIconButton("checkmark.rectangle.stack") { selection = Set(updates.map(\.id)) }
                    MihonIconButton("square.on.square") { selection = Set(updates.map(\.id)).symmetricDifference(selection) }
                }
            }
            if store.isUpdatingLibrary {
                MihonLinearProgress(progress: store.libraryUpdateProgress)
            }

            if updates.isEmpty {
                MihonEmptyScreen(message: "最近没有更新")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Upstream's "Library last updated": when an update last ran, not when a list last changed.
                        if let last = store.lastLibraryUpdateAt {
                            Text("书架上次更新：\(MihonRelativeTime.string(last))")
                                .font(MihonType.bodySmall)
                                .foregroundStyle(colors.onSurfaceVariant)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        ForEach(groups, id: \.title) { group in
                            MihonListGroupHeader(group.title)
                            ForEach(group.items) { item in
                                UpdatesUiItem(
                                    update: item,
                                    isSelected: selection.contains(item.id),
                                    onClick: {
                                        if selection.isEmpty {
                                            navigator.openReader(item.manga, item.chapter)
                                        } else {
                                            toggle(item.id)
                                        }
                                    },
                                    onLongClick: { toggle(item.id) },
                                    onClickCover: { navigator.openManga(item.manga.id) }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .refreshable { await store.refreshLibraryUpdates() }
            }
        }
        .background(colors.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty {
                actionMenu(updates.filter { selection.contains($0.id) })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection.isEmpty)
        .preference(key: MihonHideBottomBarKey.self, value: !selection.isEmpty)
    }

    private func toggle(_ id: Int64) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private struct Group {
        let title: String
        let items: [UpdateWithRelations]
    }

    private func grouped(_ items: [UpdateWithRelations]) -> [Group] {
        var result: [Group] = []
        for item in items {
            let title = MihonDateText.day(item.chapter.dateFetch)
            if result.last?.title == title {
                result[result.count - 1] = Group(title: title, items: result[result.count - 1].items + [item])
            } else {
                result.append(Group(title: title, items: [item]))
            }
        }
        return result
    }

    private func actionMenu(_ selected: [UpdateWithRelations]) -> some View {
        let anyUnbookmarked = selected.contains { !$0.chapter.bookmark }
        let anyUnread = selected.contains { !$0.chapter.read }
        return HStack(spacing: 0) {
            MihonBottomActionButton(title: anyUnbookmarked ? "为章节添加书签" : "为章节删除书签", systemImage: anyUnbookmarked ? "bookmark" : "bookmark.slash") {
                for item in selected where item.chapter.bookmark != anyUnbookmarked {
                    store.toggleChapterBookmark(mangaId: item.manga.id, chapterId: item.chapter.id)
                }
                selection.removeAll()
            }
            MihonBottomActionButton(title: anyUnread ? "标记为已读" : "标记为未读", systemImage: anyUnread ? "checkmark.circle" : "arrow.uturn.backward.circle") {
                for item in selected {
                    store.setChaptersRead(mangaId: item.manga.id, chapterIds: [item.chapter.id], read: anyUnread)
                }
                selection.removeAll()
            }
            MihonBottomActionButton(title: "下载", systemImage: "arrow.down.circle") {
                for item in selected { store.enqueueChapterDownload(manga: item.manga, chapter: item.chapter) }
                selection.removeAll()
            }
            MihonBottomActionButton(title: "删除", systemImage: "trash") {
                for item in selected { store.removeChapterDownload(chapterId: item.chapter.id) }
                selection.removeAll()
            }
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

private struct UpdatesUiItem: View {
    let update: UpdateWithRelations
    let isSelected: Bool
    let onClick: () -> Void
    let onLongClick: () -> Void
    let onClickCover: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        // Read the live chapter so read/bookmark toggles reflect immediately.
        let chapter = store.chaptersByManga[update.manga.id]?.first { $0.id == update.chapter.id } ?? update.chapter
        let textAlpha = chapter.read ? MihonAlpha.disabled : 1
        HStack(spacing: 0) {
            MangaCoverView(title: update.manga.title, thumbnailUrl: store.coverUrl(for: update.manga))
                .aspectRatio(1, contentMode: .fit)
                .padding(.vertical, 6)
                .onTapGesture(perform: onClickCover)

            VStack(alignment: .leading, spacing: 0) {
                Text(update.manga.title)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface.opacity(textAlpha))
                    .lineLimit(1)
                HStack(spacing: 0) {
                    if !chapter.read {
                        Circle().fill(colors.primary).frame(width: 8, height: 8).padding(.trailing, 4)
                    }
                    if chapter.bookmark {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(colors.primary)
                            .padding(.trailing, 2)
                    }
                    Text(chapter.name)
                        .font(MihonType.bodySmall)
                        .foregroundStyle(colors.onSurface.opacity(textAlpha))
                        .lineLimit(1)
                    if !chapter.read && chapter.lastPageRead > 0 {
                        MihonDotSeparator().font(MihonType.bodySmall)
                        Text("第 \(chapter.lastPageRead + 1) 页")
                            .font(MihonType.bodySmall)
                            .foregroundStyle(colors.onSurface.opacity(MihonAlpha.disabled))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            if update.manga.source != 0 {
                ChapterDownloadIndicator(manga: update.manga, chapter: chapter)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(isSelected ? colors.secondary.opacity(colors.isDark ? 0.16 : 0.22) : .clear)
        .mihonClickable(onLongClick: onLongClick, onClick: onClick)
    }
}

enum MihonRelativeTime {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }
}
