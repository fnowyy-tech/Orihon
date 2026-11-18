import SwiftUI
import MihonDomain
import MihonData

// MARK: - 1:1 Mihon History Tab (search · delete all · day headers · `HistoryItem`)

public struct HistoryScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator

    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var showClearAll = false
    @State private var pendingDelete: HistoryWithRelations?
    /// A title being added to the library, while its categories are chosen.
    @State private var addingMangaId: Int64?

    public init() {}

    public var body: some View {
        let history = store.readingHistory(searchQuery: searchQuery)
        VStack(spacing: 0) {
            if isSearching {
                MihonSearchAppBar(query: $searchQuery, onClose: { isSearching = false })
            } else {
                MihonTopAppBar(title: "历史") {
                    MihonIconButton("magnifyingglass") { isSearching = true }
                        .help("搜索")
                    MihonIconButton("trash", isEnabled: !store.historyEntries.isEmpty) { showClearAll = true }
                        .help("清除历史记录")
                }
            }

            if history.isEmpty {
                MihonEmptyScreen(message: searchQuery.isEmpty ? "最近没有阅读" : "没有结果")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups(history), id: \.title) { group in
                            MihonListGroupHeader(group.title)
                            ForEach(group.items) { entry in
                                HistoryItem(
                                    history: entry,
                                    onClickCover: { navigator.openManga(entry.manga.id) },
                                    onClickResume: { resume(entry) },
                                    onClickDelete: { pendingDelete = entry },
                                    onClickFavorite: {
                                        if store.asksCategoriesOnAdd {
                                            addingMangaId = entry.manga.id
                                        } else {
                                            store.addToLibrary(mangaId: entry.manga.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .background(colors.background)
        .sheet(isPresented: Binding(get: { addingMangaId != nil }, set: { if !$0 { addingMangaId = nil } })) {
            if let id = addingMangaId {
                ChangeCategorySheet(mangaIds: [id], addsToLibrary: true)
                    .environment(store)
                    .mihonSheetChrome(colors, detents: [.medium])
            }
        }
        .confirmationDialog("清除历史记录", isPresented: $showClearAll, titleVisibility: .visible) {
            Button("清除", role: .destructive) { store.clearAllHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定吗？所有历史记录都将丢失。")
        }
        .confirmationDialog(
            "移除",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("移除这条记录", role: .destructive) { store.deleteHistoryEntry(id: entry.id) }
            Button("移除这部作品的所有历史", role: .destructive) { store.deleteAllHistory(forMangaId: entry.manga.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这将移除该章节的阅读日期。确定吗？")
        }
    }

    /// Resume the history chapter, or once it is finished the chapter after it (upstream `GetNextChapters`).
    private func resume(_ entry: HistoryWithRelations) {
        guard let chapter = store.chapterToResume(mangaId: entry.manga.id, fromChapterId: entry.chapter.id) else {
            store.showStatusBanner("没有下一章了")
            return
        }
        navigator.openReader(entry.manga, chapter)
    }

    private struct Group {
        let title: String
        let items: [HistoryWithRelations]
    }

    private func groups(_ items: [HistoryWithRelations]) -> [Group] {
        var result: [Group] = []
        for item in items {
            let title = MihonDateText.day(item.readAt)
            if result.last?.title == title {
                result[result.count - 1] = Group(title: title, items: result[result.count - 1].items + [item])
            } else {
                result.append(Group(title: title, items: [item]))
            }
        }
        return result
    }
}

private struct HistoryItem: View {
    let history: HistoryWithRelations
    let onClickCover: () -> Void
    let onClickResume: () -> Void
    let onClickDelete: () -> Void
    let onClickFavorite: () -> Void
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors

    var body: some View {
        HStack(spacing: 0) {
            MangaCoverView(title: history.manga.title, thumbnailUrl: store.coverUrl(for: history.manga))
                .aspectRatio(2 / 3, contentMode: .fit)
                .onTapGesture(perform: onClickCover)

            VStack(alignment: .leading, spacing: 4) {
                Text(history.manga.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(2)
                Text(subtitle)
                    .font(MihonType.bodyMedium)
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, MihonPadding.medium)
            .padding(.trailing, MihonPadding.small)

            if !history.manga.favorite {
                MihonIconButton("heart", tint: colors.onSurface, action: onClickFavorite)
                    .help("添加到书架")
            }
            MihonIconButton("trash", tint: colors.onSurface, action: onClickDelete)
                .help("删除")
        }
        .padding(.horizontal, MihonPadding.medium)
        .padding(.vertical, MihonPadding.small)
        .frame(height: 96)
        .mihonClickable(onClick: onClickResume)
    }

    private var subtitle: String {
        let time = MihonDateText.time(history.readAt)
        if history.chapter.chapterNumber > -1 {
            return "第 \(MihonDateText.chapterNumber(history.chapter.chapterNumber)) 章 - \(time)"
        }
        return time
    }
}
