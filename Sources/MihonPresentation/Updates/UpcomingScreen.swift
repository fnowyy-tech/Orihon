import SwiftUI
import MihonDomain
import MihonData

// MARK: - 1:1 Mihon Upcoming (mihon.feature.upcoming: calendar · day headings · items)

/// Upstream `UpcomingScreen`: library titles by the day they are expected to update (`FetchInterval`), under a month
/// calendar whose days show how many; a day with titles scrolls the list to them.
public struct UpcomingScreen: View {
    @Environment(MihonRepositoryStore.self) private var store
    @Environment(\.mihonColors) private var colors
    @Environment(\.mihonNavigator) private var navigator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var month = MihonLocalDate(Date(), in: .current).firstOfMonth
    @State private var showsFilter = false

    private static let guideURL = URL(string: "https://mihon.app/docs/faq/updates/upcoming")!

    public init() {}

    public var body: some View {
        let today = MihonLocalDate(Date(), in: .current)
        let days = Self.days(store.upcomingManga())
        let events = Dictionary(days.map { ($0.day, $0.titles.count) }, uniquingKeysWith: +)
        let hasFilters = !store.upcomingIncludedCategories.isEmpty || !store.upcomingExcludedCategories.isEmpty

        VStack(spacing: 0) {
            MihonTopAppBar(title: "即将推出", navigation: .back { dismiss() }) {
                MihonIconButton("line.3.horizontal.decrease", tint: hasFilters ? colors.active : nil, label: "筛选") {
                    showsFilter = true
                }
                MihonIconButton("questionmark.circle", label: "即将推出的指南") { openURL(Self.guideURL) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        UpcomingCalendar(month: $month, today: today, events: events) { day in
                            guard events[day] != nil else { return }
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(Self.headingId(day), anchor: .top) }
                        }
                        .padding(.bottom, 8)
                        ForEach(days, id: \.day) { group in
                            dateHeading(group.day, count: group.titles.count, today: today)
                                .id(Self.headingId(group.day))
                            ForEach(group.titles) { manga in
                                UpcomingItem(manga: manga, coverUrl: store.coverUrl(for: manga)) {
                                    navigator.openManga(manga.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(colors.background)
        .sheet(isPresented: $showsFilter) {
            MihonCategoryTriStateSheet(
                message: "同时属于包含和排除分类的标题将不予显示。",
                anchorPrefix: "upcomingFilter",
                appliesImmediately: true,
                included: store.upcomingIncludedCategories,
                excluded: store.upcomingExcludedCategories,
                onSave: { included, excluded in
                    store.upcomingIncludedCategories = included
                    store.upcomingExcludedCategories = excluded
                }
            ) { showsFilter = false }
                .environment(store)
                .mihonSheetChrome(colors)
        }
        .mihonTestAnchor("upcoming.screen")
    }

    /// Upstream `DateHeading`: the relative day and a count badge.
    private func dateHeading(_ day: MihonLocalDate, count: Int, today: MihonLocalDate) -> some View {
        HStack(spacing: 0) {
            Text(MihonDateText.relativeDay(day, today: today))
                .font(MihonType.bodyMedium.weight(.semibold))
                .foregroundStyle(colors.onSurfaceVariant)
                .padding(8)
                .padding(.leading, 8)
            MihonBadge(text: "\(count)", color: colors.primary, contentColor: colors.onPrimary)
            Spacer(minLength: 0)
        }
        .mihonTestAnchor("upcoming.day.\(day)")
    }

    /// Headings scroll by an ID of their own: the calendar's days use the bare dates.
    static func headingId(_ day: MihonLocalDate) -> String { "heading-\(day)" }

    /// Titles by the day of their next update, earliest first (they come sorted).
    static func days(_ titles: [Manga], in timeZone: TimeZone = .current) -> [(day: MihonLocalDate, titles: [Manga])] {
        var result: [(day: MihonLocalDate, titles: [Manga])] = []
        for manga in titles {
            guard let next = manga.nextUpdate else { continue }
            let day = MihonLocalDate(next, in: timeZone)
            if result.last?.day == day {
                result[result.count - 1].titles.append(manga)
            } else {
                result.append((day, [manga]))
            }
        }
        return result
    }
}

/// Upstream `UpcomingItem`: a 96 pt row, cover and title.
private struct UpcomingItem: View {
    let manga: Manga
    let coverUrl: String?
    let onClick: () -> Void
    @Environment(\.mihonColors) private var colors

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 24) {
                MangaCoverView(title: manga.title, thumbnailUrl: coverUrl)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                Text(manga.title)
                    .font(MihonType.bodyMedium.weight(.semibold))
                    .foregroundStyle(colors.onSurface)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(MihonStateLayerStyle(shape: Rectangle()))
        .mihonTestAnchor("upcoming.\(manga.id)")
    }
}

/// Upstream `Calendar`: the month and its arrows, the weekdays from the locale's first, and the days — today ringed,
/// days gone by dimmed, up to three dots for the titles due.
private struct UpcomingCalendar: View {
    @Binding var month: MihonLocalDate
    let today: MihonLocalDate
    let events: [MihonLocalDate: Int]
    let onClickDay: (MihonLocalDate) -> Void
    @Environment(\.mihonColors) private var colors

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }()

    private var weekdays: [Int] {
        // ISO numbers (Monday 1 … Sunday 7) from the locale's first day; Calendar counts Sunday as 1.
        let first = (Calendar.current.firstWeekday + 5) % 7 + 1
        return (0..<7).map { ($0 + first - 1) % 7 + 1 }
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        let lead = weekdays.firstIndex(of: month.isoDayOfWeek) ?? 0
        let days = (0..<month.daysUntil(month.plusMonthsFromFirst(1))).map(month.plusDays)
        VStack(spacing: 4) {
            HStack {
                Text(Self.monthFormatter.string(from: month.startOfDay(in: .current)))
                    .font(MihonType.titleLarge)
                    .foregroundStyle(colors.onSurface)
                    .contentTransition(.numericText())
                Spacer()
                MihonIconButton("chevron.left", label: "上个月") {
                    withAnimation(.easeInOut(duration: 0.2)) { month = month.plusMonthsFromFirst(-1) }
                }
                MihonIconButton("chevron.right", label: "下个月") {
                    withAnimation(.easeInOut(duration: 0.2)) { month = month.plusMonthsFromFirst(1) }
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 16)
            LazyVGrid(columns: columns, spacing: 0) {
                // IDs of three types (weekday numbers, blank names, days), so none repeats in the lazy grid.
                ForEach(weekdays, id: \.self) { weekday in
                    Text(["一", "二", "三", "四", "五", "六", "日"][weekday - 1])
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.onSurface)
                        .frame(maxWidth: .infinity)
                }
                ForEach((0..<lead).map { "blank-\($0)" }, id: \.self) { _ in Color.clear.frame(height: 1) }
                ForEach(days, id: \.self) { day in
                    dayCell(day)
                }
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
    }

    /// A circle of a fixed size (upstream's `circleLayout` around the number), centred in its column.
    private func dayCell(_ day: MihonLocalDate) -> some View {
        Button { onClickDay(day) } label: {
            ZStack {
                Text("\(day.day)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(day < today ? colors.onBackground.opacity(MihonAlpha.disabled) : colors.onBackground)
                    .fixedSize()
                HStack(spacing: 2) {
                    ForEach(0..<min(events[day] ?? 0, 3), id: \.self) { index in
                        Circle()
                            .fill(colors.primary.opacity(Double(index + 1) * 0.3))
                            .frame(width: 4.5, height: 4.5)
                    }
                }
                .offset(y: 12)
            }
            .frame(width: 36, height: 36)
            .overlay {
                if day == today {
                    Circle().strokeBorder(colors.onBackground, lineWidth: 1)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(MihonStateLayerStyle(shape: Circle()))
        .frame(maxWidth: .infinity, minHeight: 40)
        .mihonTestAnchor("upcoming.calendar.\(day)")
    }
}
