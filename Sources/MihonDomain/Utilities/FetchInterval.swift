import Foundation

// MARK: - Upstream `FetchInterval`, `ReleaseSchedule` and `ReleasePattern` (tachiyomi.domain.manga.interactor)

/// A calendar day (kotlinx `LocalDate`), counted in days from 1970-01-01 in the proleptic Gregorian calendar.
public struct MihonLocalDate: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var epochDay: Int

    public init(epochDay: Int) {
        self.epochDay = epochDay
    }

    /// Howard Hinnant's `days_from_civil`.
    public init(year: Int, month: Int, day: Int) {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        epochDay = era * 146_097 + dayOfEra - 719_468
    }

    /// `yyyy-MM-dd`.
    public init?(_ iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The day `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        let local = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        epochDay = Int((local / 86_400).rounded(.down))
    }

    /// Howard Hinnant's `civil_from_days`.
    private var civil: (year: Int, month: Int, day: Int) {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    public var year: Int { civil.year }
    public var month: Int { civil.month }
    /// The day of the month.
    public var day: Int { civil.day }
    /// ISO day number: Monday 1 … Sunday 7.
    public var isoDayOfWeek: Int { (epochDay + 3).floorMod(7) + 1 }

    public func plusDays(_ days: Int) -> MihonLocalDate { MihonLocalDate(epochDay: epochDay + days) }

    public func daysUntil(_ other: MihonLocalDate) -> Int { other.epochDay - epochDay }

    public var firstOfMonth: MihonLocalDate { MihonLocalDate(year: year, month: month, day: 1) }

    public var lastOfMonth: MihonLocalDate { firstOfMonth.plusMonthsFromFirst(1).plusDays(-1) }

    /// Months from the first of a month (kotlinx `plus(DatePeriod(months:))` on a day 1, which never clamps).
    public func plusMonthsFromFirst(_ months: Int) -> MihonLocalDate {
        let total = year * 12 + (month - 1) + months
        return MihonLocalDate(year: total.floorDiv(12), month: total.floorMod(12) + 1, day: 1)
    }

    /// Local midnight in `timeZone` (kotlinx `atStartOfDayIn`).
    public func startOfDay(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let civil = civil
        return calendar.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day))
            ?? Date(timeIntervalSince1970: Double(epochDay) * 86_400 - Double(timeZone.secondsFromGMT()))
    }

    public static func < (lhs: MihonLocalDate, rhs: MihonLocalDate) -> Bool { lhs.epochDay < rhs.epochDay }

    public var description: String {
        let civil = civil
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }
}

extension Int {
    /// Kotlin `mod`: the remainder takes the divisor's sign.
    func floorMod(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder
    }

    /// `Math.floorDiv`.
    func floorDiv(_ divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0) && ((self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// Upstream's `ceilDiv`: `-floorDiv(-a, b)`.
    func ceilDiv(_ divisor: Int) -> Int {
        -(-self).floorDiv(divisor)
    }
}

/// The days an entry is expected to release on.
public enum ReleasePattern: Hashable, Sendable {
    /// Releases every `days` days, in step with `onSchedule`.
    case everyDays(days: Int, onSchedule: MihonLocalDate)
    /// Releases on a few ISO weekdays (Monday 1 … Sunday 7).
    case weekdays(Set<Int>)
    /// Releases for `length` days in a row, every `every` days in step with `onSchedule`.
    case batches(every: Int, onSchedule: MihonLocalDate, length: Int)
    /// Releases on these days of every month, or a month's last day for those past it.
    case daysOfMonth(Set<Int>)
    /// Releases on an ISO weekday of the `week`th week of every month, or its last week for `lastWeek`.
    case weekdayOfMonth(week: Int, dayOfWeek: Int)

    public static let lastWeek = -1

    /// The first expected release day after `date`.
    func nextAfter(_ date: MihonLocalDate) -> MihonLocalDate {
        switch self {
        case let .everyDays(days, onSchedule):
            return date.plusDays(days - onSchedule.daysUntil(date).floorMod(days))
        case let .weekdays(days):
            var day = date.plusDays(1)
            while !days.contains(day.isoDayOfWeek) { day = day.plusDays(1) }
            return day
        case let .batches(every, onSchedule, length):
            let offset = onSchedule.daysUntil(date).floorMod(every)
            return date.plusDays(offset + 1 < length ? 1 : every - offset)
        case .daysOfMonth, .weekdayOfMonth:
            var month = date.firstOfMonth
            while true {
                if let next = daysIn(month).sorted().first(where: { $0 > date }) { return next }
                month = month.plusMonthsFromFirst(1)
            }
        }
    }

    /// The last expected release day before `date`.
    func previousBefore(_ date: MihonLocalDate) -> MihonLocalDate {
        switch self {
        case let .everyDays(days, onSchedule):
            return date.plusDays(-((onSchedule.daysUntil(date) - 1).floorMod(days) + 1))
        case let .weekdays(days):
            var day = date.plusDays(-1)
            while !days.contains(day.isoDayOfWeek) { day = day.plusDays(-1) }
            return day
        case let .batches(every, onSchedule, length):
            let dayBefore = date.plusDays(-1)
            let offset = onSchedule.daysUntil(dayBefore).floorMod(every)
            return dayBefore.plusDays(-max(0, offset - length + 1))
        case .daysOfMonth, .weekdayOfMonth:
            var month = date.firstOfMonth
            while true {
                if let previous = daysIn(month).sorted(by: >).first(where: { $0 < date }) { return previous }
                month = month.plusMonthsFromFirst(-1)
            }
        }
    }

    /// The expected release day closest to `date`, which a release on `date` stands in for.
    func nearest(_ date: MihonLocalDate) -> MihonLocalDate {
        // Release days are a day or two apart, so a release between them is more likely an extra than an early one
        if case .weekdays = self { return date }
        let before = previousBefore(date.plusDays(1))
        let after = nextAfter(date.plusDays(-1))
        // A release halfway between is taken as late, so the next check comes sooner
        return before.daysUntil(date) <= date.daysUntil(after) ? before : after
    }

    /// The release days of a monthly pattern in the month starting on `firstOfMonth`.
    private func daysIn(_ firstOfMonth: MihonLocalDate) -> [MihonLocalDate] {
        switch self {
        case let .daysOfMonth(days):
            let lastDay = firstOfMonth.lastOfMonth.day
            var result: [MihonLocalDate] = []
            for day in days.sorted() {
                let date = firstOfMonth.plusDays(min(day, lastDay) - 1)
                if !result.contains(date) { result.append(date) }
            }
            return result
        case let .weekdayOfMonth(week, dayOfWeek):
            if week == Self.lastWeek {
                let lastOfMonth = firstOfMonth.lastOfMonth
                return [lastOfMonth.plusDays(-(lastOfMonth.isoDayOfWeek - dayOfWeek).floorMod(7))]
            }
            let daysAhead = (dayOfWeek - firstOfMonth.isoDayOfWeek).floorMod(7)
            return [firstOfMonth.plusDays(daysAhead + (week - 1) * 7)]
        default:
            return []
        }
    }

    private static let minReleases = 4
    private static let maxWeekdays = 3
    private static let coverage = 0.8
    private static let dayOfMonthTolerance = 3
    private static let monthlyGaps = 26...35
    private static let twiceMonthlyGaps = 12...18
    private static let batchHistory = 40
    private static let batchGap = 2
    private static let batchCount = 6
    private static let minBatches = 3

    /// A calendar pattern a plain day interval can't follow in `days`, newest first: a few fixed weekdays, days or a
    /// weekday of the month, or releases in batches, which can take longer than `days` to show up in `history`.
    static func detect(days: [MihonLocalDate], history: [MihonLocalDate], medianGap: Int) -> ReleasePattern? {
        guard days.count >= minReleases else { return nil }
        // Batches come first, since their days can look like a few weekdays or a monthly schedule
        if let batches = batches(history) { return batches }
        if monthlyGaps.contains(medianGap) { return monthly(days) }
        if twiceMonthlyGaps.contains(medianGap) { return twiceMonthly(days) }
        return weekdays(days, medianGap: medianGap)
    }

    private static func monthly(_ days: [MihonLocalDate]) -> ReleasePattern? {
        let daysOfMonth = days.map(\.day)
        if daysOfMonth.max()! - daysOfMonth.min()! <= dayOfMonthTolerance {
            return .daysOfMonth([median(daysOfMonth)])
        }
        // The last day of the month moves between the 28th and the 31st
        if daysOfMonth.allSatisfy({ $0 >= 28 }) { return .daysOfMonth([31]) }
        return weekdayOfMonth(days)
    }

    private static func weekdayOfMonth(_ days: [MihonLocalDate]) -> ReleasePattern? {
        guard let dayOfWeek = mostCommon(days, \.isoDayOfWeek) else { return nil }
        // A fifth week isn't in every month, so those days only count as the last week
        if let week = mostCommon(days, { ($0.day - 1) / 7 + 1 }), week < 5 {
            return .weekdayOfMonth(week: week, dayOfWeek: dayOfWeek)
        }
        let lastWeek = days.filter { $0.day + 7 > $0.lastOfMonth.day }.count
        return Double(lastWeek) >= Double(days.count) * coverage ? .weekdayOfMonth(week: Self.lastWeek, dayOfWeek: dayOfWeek) : nil
    }

    private static func twiceMonthly(_ days: [MihonLocalDate]) -> ReleasePattern? {
        let daysOfMonth = days.map(\.day).sorted()
        // The first widest gap (Kotlin `maxBy`)
        var split = 1
        for index in 1..<daysOfMonth.count where daysOfMonth[index] - daysOfMonth[index - 1] > daysOfMonth[split] - daysOfMonth[split - 1] {
            split = index
        }
        let halves = [Array(daysOfMonth[..<split]), Array(daysOfMonth[split...])]
        if halves.contains(where: { $0.count < 2 || $0.last! - $0.first! > dayOfMonthTolerance }) { return nil }
        return .daysOfMonth(Set(halves.map(median)))
    }

    private static func weekdays(_ days: [MihonLocalDate], medianGap: Int) -> ReleasePattern? {
        var weekdays: Set<Int> = []
        var covered = 0
        // Most frequent first; ties keep their first appearance (Kotlin's `sortedByDescending` is stable)
        let byFrequency = counts(days, \.isoDayOfWeek).enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
        for (dayOfWeek, count) in byFrequency {
            if Double(covered) >= Double(days.count) * coverage { break }
            weekdays.insert(dayOfWeek)
            covered += count
        }
        // One weekday is a weekly interval, and an irregular schedule spreads over most of the week
        guard (2...maxWeekdays).contains(weekdays.count), Double(covered) >= Double(days.count) * coverage else { return nil }
        // Releasing on several weekdays means more than one release a week
        if medianGap > 7 / weekdays.count + 1 { return nil }
        return .weekdays(weekdays)
    }

    /// Runs of releases a day or two apart, starting at a steady interval and mostly longer than a day.
    private static func batches(_ history: [MihonLocalDate]) -> ReleasePattern? {
        var runs: [[MihonLocalDate]] = []
        for day in history.prefix(batchHistory).reversed() {
            if let last = runs.last?.last, last.daysUntil(day) <= batchGap {
                runs[runs.count - 1].append(day)
            } else {
                runs.append([day])
            }
        }
        let recent = Array(runs.suffix(batchCount))
        if recent.count < minBatches || recent.filter({ $0.count > 1 }).count * 2 < recent.count { return nil }

        let gaps = zip(recent, recent.dropFirst()).map { older, newer in older[0].daysUntil(newer[0]) }
        let every = median(gaps)
        let length = median(recent.map { $0[0].daysUntil($0[$0.count - 1]) + 1 })
        if every < length * 2 || gaps.contains(where: { abs($0 - every) > every / 4 }) { return nil }
        return .batches(every: every, onSchedule: recent[recent.count - 1][0], length: length)
    }

    static func median(_ values: [Int]) -> Int {
        values.sorted()[(values.count - 1) / 2]
    }

    /// How often each key occurs, in order of first appearance (Kotlin's `groupingBy().eachCount()`); the sorts and
    /// picks above keep that order among ties, as Kotlin's stable sort and `maxBy` do.
    private static func counts<Key: Hashable>(_ days: [MihonLocalDate], _ key: (MihonLocalDate) -> Key) -> [(key: Key, count: Int)] {
        var result: [(key: Key, count: Int)] = []
        var index: [Key: Int] = [:]
        for day in days {
            let value = key(day)
            if let at = index[value] {
                result[at].count += 1
            } else {
                index[value] = result.count
                result.append((value, 1))
            }
        }
        return result
    }

    /// The most common key, if at least `coverage` of the days share it.
    private static func mostCommon<Key: Hashable>(_ days: [MihonLocalDate], _ key: (MihonLocalDate) -> Key) -> Key? {
        var best: (key: Key, count: Int)?
        for entry in counts(days, key) where entry.count > (best?.count ?? 0) {
            best = entry
        }
        guard let best, Double(best.count) >= Double(days.count) * coverage else { return nil }
        return best.key
    }
}

/// How often an entry releases, and so when to check it for the next release.
struct ReleaseSchedule: Equatable {
    /// Days between releases, which is what the fetch interval shows.
    var interval: Int
    /// The most recent release day, which the next ones are counted from.
    var lastRelease: MihonLocalDate?
    var pattern: ReleasePattern
    /// Days past the expected day a release can still come, from how late recent ones were.
    var lateness = 0
    /// Whether checks spread out once releases stop coming, which a schedule set by the user doesn't.
    var backsOff = true
    /// Lengths in days of earlier breaks in releases, which a break like a season's end is expected to last again.
    var pastBreaks: [Int] = []

    private static let defaultInterval = 7
    private static let hiatusCycles = 4
    private static let minReleases = 3
    private static let fewChapters = 8
    private static let fewChaptersReleases = 3
    private static let recentReleases = 10
    private static let phaseReleases = 5

    /// The next day to check for a release, as of `today`. Today counts, so a due release keeps being checked for.
    func nextCheck(_ today: MihonLocalDate) -> MihonLocalDate {
        let anchor = lastRelease ?? today
        let daysSinceRelease = anchor.daysUntil(today)
        let isOnBreak = backsOff && daysSinceRelease > interval * Self.hiatusCycles
        // Around when earlier breaks ended, this one likely ends too, so the schedule is followed again
        if isOnBreak && !pastBreaks.contains(where: { ($0 - interval...$0 + interval).contains(daysSinceRelease) }) {
            // Past a few missed releases the schedule no longer holds, so checks spread out until it resumes
            let backedOff = backOff(daysSinceRelease)
            let next = anchor.plusDays(daysSinceRelease.ceilDiv(backedOff) * backedOff)
            let breakEnd = pastBreaks.map { anchor.plusDays($0 - interval) }.filter { $0 > today }.min()
            return min(next, breakEnd ?? next)
        }

        let due = pattern.nextAfter(pattern.nearest(anchor))
        if (due...due.plusDays(lateness)).contains(today) { return today }
        var next = due
        while next < today { next = pattern.nextAfter(next) }
        return capped(next, from: today)
    }

    /// The next day to check after a check `today` found a release. The release is dated by its newest chapter, since
    /// a check can turn up one that came out on an earlier day; it stands in for the expected day nearest to it, so an
    /// early, late or extra release leaves the schedule in place.
    func nextCheckAfterRelease(_ today: MihonLocalDate) -> MihonLocalDate {
        let release = lastRelease.map { min($0, today) } ?? today
        // What was found is out already, so checking again today would only find it again
        var next = pattern.nextAfter(pattern.nearest(release))
        while next <= today { next = pattern.nextAfter(next) }
        return capped(next, from: today)
    }

    // Months and batches can be further apart than a check should ever wait
    private func capped(_ date: MihonLocalDate, from today: MihonLocalDate) -> MihonLocalDate {
        min(date, today.plusDays(FetchInterval.maxInterval))
    }

    private func backOff(_ daysSinceRelease: Int) -> Int {
        var backedOff = interval
        while backedOff < FetchInterval.maxInterval && daysSinceRelease > backedOff * Self.hiatusCycles {
            backedOff *= 2
        }
        return min(backedOff, FetchInterval.maxInterval)
    }

    /// A schedule the user set to every `interval` days, counted from `lastRelease`.
    static func fixed(interval: Int, lastRelease: MihonLocalDate) -> ReleaseSchedule {
        ReleaseSchedule(
            interval: interval, lastRelease: lastRelease,
            pattern: .everyDays(days: interval, onSchedule: lastRelease), backsOff: false
        )
    }

    /// Estimates the schedule from the recent release days of `chapters`, by upload date or else fetch date.
    static func estimate(_ chapters: [Chapter], timeZone: TimeZone, today: MihonLocalDate) -> ReleaseSchedule {
        let recent = chapters.count <= fewChapters ? fewChaptersReleases : recentReleases
        // Sources that date chapters ahead of their release would otherwise pull the schedule into the future
        let latestPlausibleDay = today.plusDays(1)
        func releaseDays(_ dates: [Date]) -> [MihonLocalDate] {
            Set(dates.map { MihonLocalDate($0, in: timeZone) }.filter { $0 <= latestPlausibleDay }).sorted(by: >)
        }

        // An undated chapter (upload date 0) has no upload day.
        let uploadDays = releaseDays(chapters.map(\.dateUpload).filter { $0.timeIntervalSince1970 > 0 })
        let fetchDays = releaseDays(chapters.map(\.dateFetch))
        let history: [MihonLocalDate]
        if uploadDays.count >= minReleases {
            history = uploadDays
        } else if fetchDays.count >= minReleases {
            history = fetchDays
        } else {
            let lastRelease = uploadDays.first ?? fetchDays.first
            return ReleaseSchedule(
                interval: defaultInterval, lastRelease: lastRelease,
                pattern: .everyDays(days: defaultInterval, onSchedule: lastRelease ?? today)
            )
        }
        let days = Array(history.prefix(recent))

        let gaps = zip(days, days.dropFirst()).map { newer, older in older.daysUntil(newer) }.sorted()
        let medianGap = gaps[(gaps.count - 1) / 2]
        let detected = ReleasePattern.detect(days: days, history: history, medianGap: medianGap)
        // Within a batch releases are a day apart, but it's the batches that come every so often
        var batchEvery: Int?
        if case let .batches(every, _, _)? = detected { batchEvery = every }
        let interval = min(max(batchEvery ?? medianGap, 1), FetchInterval.maxInterval)
        return ReleaseSchedule(
            interval: interval,
            lastRelease: days[0],
            pattern: detected ?? .everyDays(days: interval, onSchedule: medianPhase(Array(days.prefix(phaseReleases)), interval: interval)),
            lateness: min(max(gaps[gaps.count - 1] - interval, 0), interval / 2),
            pastBreaks: zip(history, history.dropFirst())
                .map { newer, older in older.daysUntil(newer) }
                .filter { $0 > interval * hiatusCycles }
        )
    }

    /// The release in `days`, newest first, that the others land closest to in step with `interval`, so one early
    /// or late release doesn't shift the schedule. Ties go to the newest, which follows a schedule that moved.
    private static func medianPhase(_ days: [MihonLocalDate], interval: Int) -> MihonLocalDate {
        func offset(_ from: MihonLocalDate, _ to: MihonLocalDate) -> Int {
            let mod = from.daysUntil(to).floorMod(interval)
            return min(mod, interval - mod)
        }
        var phase = days[0]
        var best = Int.max
        for candidate in days {
            let total = days.reduce(0) { $0 + offset(candidate, $1) }
            if total < best {
                best = total
                phase = candidate
            }
        }
        let onPhase = days.filter { offset(phase, $0) == 0 }.count
        return onPhase * 5 >= days.count * 3 ? phase : days[0]
    }
}

/// When to check a title for new chapters next, and its fetch interval (upstream `FetchInterval`).
public enum FetchInterval {
    public static let maxInterval = 28
    private static let gracePeriodDays = 1

    /// A day either side of today: library updates check titles whose next update falls in it.
    public static func window(today: MihonLocalDate, timeZone: TimeZone) -> ClosedRange<Date> {
        let start = today.startOfDay(in: timeZone)
        let grace = TimeInterval(gracePeriodDays) * 86_400
        return start.addingTimeInterval(-grace)...start.addingTimeInterval(grace)
    }

    /// The title's next update and fetch interval. A negative `fetchInterval` is one the user set, in days.
    ///
    /// - Parameter foundRelease: whether the check that led here found new chapters.
    public static func update(
        for manga: Manga,
        chapters: [Chapter],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        window: ClosedRange<Date>? = nil,
        foundRelease: Bool = false
    ) -> (nextUpdate: Date, fetchInterval: Int) {
        let today = MihonLocalDate(now, in: timeZone)
        let currentWindow = window ?? Self.window(today: MihonLocalDate(Date(), in: timeZone), timeZone: timeZone)
        let schedule: ReleaseSchedule
        if manga.fetchInterval < 0 {
            // The check that found a release is the entry's last update
            let lastUpdate = foundRelease ? today : manga.lastUpdate.map { MihonLocalDate($0, in: timeZone) }
            schedule = .fixed(interval: -manga.fetchInterval, lastRelease: lastUpdate ?? today)
        } else {
            schedule = .estimate(chapters, timeZone: timeZone, today: today)
        }

        let expected = manga.nextUpdate
        let expectedDay = expected.map { MihonLocalDate($0, in: timeZone) }
        // A release on or after the expected day means the next one is counted from it instead
        var isAwaitingRelease = false
        if let expected, let expectedDay,
           expected >= currentWindow.lowerBound, expected <= currentWindow.upperBound.addingTimeInterval(0.001) {
            isAwaitingRelease = schedule.lastRelease.map { $0 < expectedDay } ?? true
        }
        let nextUpdate: Date
        if foundRelease {
            nextUpdate = schedule.nextCheckAfterRelease(today).startOfDay(in: timeZone)
        } else if isAwaitingRelease, let expected {
            nextUpdate = expected
        } else {
            nextUpdate = schedule.nextCheck(today).startOfDay(in: timeZone)
        }
        return (nextUpdate, manga.fetchInterval < 0 ? manga.fetchInterval : schedule.interval)
    }
}
