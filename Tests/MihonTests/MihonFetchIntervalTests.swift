import XCTest
@testable import MihonDomain

/// Upstream's `FetchIntervalTest` (domain/src/test/…/manga/interactor), case for case: the release schedule that
/// decides when a library update checks a title next.
final class MihonFetchIntervalTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2020-01-01T00:00:00Z
    private let testTime = Date(timeIntervalSince1970: 1_577_836_800)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private lazy var chapter = Chapter(id: 0, mangaId: 0, url: "", name: "", dateFetch: testTime, dateUpload: testTime)

    func testReturnsDefaultIntervalOf7DaysWhenNotEnoughDistinctDays() {
        let withUploadDate = (1...50).map { _ in chapterWithTime(1 * day) }
        XCTAssertEqual(interval(withUploadDate), 7)
        XCTAssertEqual(interval(withoutUploadDate(withUploadDate)), 7)
    }

    func testReturnsIntervalBasedOnMoreRecentChapters() {
        let oldChapters = (1...5).map { chapterWithTime(Double($0 * 7) * day) } // Would have interval of 7 days
        let newChapters = (1...10).map { chapterWithTime(lastUploadDate(oldChapters) + Double($0) * day) }
        XCTAssertEqual(interval(oldChapters + newChapters), 1)
    }

    func testReturnsIntervalBasedOnSmallerSubsetOfRecentChaptersIfVeryFewChapters() {
        let oldChapters = (1...3).map { chapterWithTime(Double($0 * 7) * day) }
        // Significant gap between chapters
        let newChapters = (1...3).map { chapterWithTime(lastUploadDate(oldChapters) + 365 * day + Double($0 * 7) * day) }
        XCTAssertEqual(interval(oldChapters + newChapters), 7)
    }

    func testReturnsIntervalOf7DaysWhenMultipleChaptersIn1Day() {
        XCTAssertEqual(interval((1...10).map { _ in chapterWithTime(10 * hour) }), 7)
    }

    func testReturnsIntervalOf7DaysWhenMultipleChaptersIn2Days() {
        let chapters = (1...2).map { _ in chapterWithTime(1 * day) } + (1...5).map { _ in chapterWithTime(2 * day) }
        XCTAssertEqual(interval(chapters), 7)
    }

    func testReturnsIntervalOf1DayWhenChaptersAreReleasedEvery1Day() {
        XCTAssertEqual(interval((1...20).map { chapterWithTime(Double($0) * day) }), 1)
    }

    func testReturnsIntervalOf1DayWhenDeltaIsLessThan1Day() {
        XCTAssertEqual(interval((1...20).map { chapterWithTime(Double(15 * $0) * hour) }), 1)
    }

    func testReturnsIntervalOf2DaysWhenChaptersAreReleasedEvery2Days() {
        XCTAssertEqual(interval((1...20).map { chapterWithTime(Double(2 * $0) * day) }), 2)
    }

    func testReturnsIntervalWithFlooredValueWhenIntervalIsDecimal() {
        let withUploadDate = (1...5).map { chapterWithTime(Double(25 * $0) * hour) }
        XCTAssertEqual(interval(withUploadDate), 1)
        XCTAssertEqual(interval(withoutUploadDate(withUploadDate)), 1)
    }

    func testReturnsIntervalOf2DaysWhenChaptersAreReleasedJustBelowEvery2Days() {
        XCTAssertEqual(interval((1...20).map { chapterWithTime(Double(43 * $0) * hour) }), 2)
    }

    func testFollowsReleasesOnAFewFixedWeekdays() {
        let mondaysAndThursdays = every(days: 1, from: "2019-12-02", to: "2020-01-20")
            .filter { $0.isoDayOfWeek == 1 || $0.isoDayOfWeek == 4 }
        let chapters = chaptersOn(mondaysAndThursdays)

        XCTAssertEqual(ReleaseSchedule.estimate(chapters, timeZone: utc, today: date("2020-01-21")).pattern, .weekdays([1, 4]))
        XCTAssertEqual(nextUpdate(today: "2020-01-21", chapters), date("2020-01-23"))
    }

    func testFollowsReleasesOnADayOfTheMonth() {
        let chapters = chaptersOn(["2019-09-15", "2019-10-15", "2019-11-14", "2019-12-15", "2020-01-16"].map(date), perDay: 2)
        XCTAssertEqual(nextUpdate(today: "2020-01-20", chapters), date("2020-02-15"))
    }

    func testFollowsReleasesOnTheLastDayOfTheMonth() {
        let chapters = chaptersOn(["2019-09-30", "2019-10-31", "2019-11-30", "2019-12-31", "2020-01-31"].map(date), perDay: 2)
        XCTAssertEqual(nextUpdate(today: "2020-02-05", chapters), date("2020-02-29"))
    }

    func testFollowsReleasesOnTwoDaysOfTheMonth() {
        let days = ["2019-10-01", "2019-10-15", "2019-11-01", "2019-11-16", "2019-12-01", "2019-12-15", "2020-01-01"]
        let chapters = chaptersOn((days + ["2020-01-15"]).map(date), perDay: 2)

        XCTAssertEqual(ReleaseSchedule.estimate(chapters, timeZone: utc, today: date("2020-01-20")).pattern, .daysOfMonth([1, 15]))
        XCTAssertEqual(nextUpdate(today: "2020-01-20", chapters), date("2020-02-01"))
    }

    func testFollowsReleasesOnAWeekdayOfTheMonth() {
        let firstSaturdays = ["2019-09-07", "2019-10-05", "2019-11-02", "2019-12-07", "2020-01-04"]
        XCTAssertEqual(nextUpdate(today: "2020-01-10", chaptersOn(firstSaturdays.map(date), perDay: 2)), date("2020-02-01"))
    }

    func testFollowsReleasesOnAWeekdayOfTheLastWeekOfTheMonth() {
        let lastFridays = ["2019-09-27", "2019-10-25", "2019-11-29", "2019-12-27", "2020-01-31"]
        XCTAssertEqual(nextUpdate(today: "2020-02-03", chaptersOn(lastFridays.map(date), perDay: 2)), date("2020-02-28"))
    }

    func testFollowsReleasesInBatches() {
        // Three days of releases every three weeks
        let batches = every(days: 21, from: "2019-09-02", to: "2019-12-16").flatMap { start in (0...2).map { start.plusDays($0) } }
        let chapters = chaptersOn(batches.filter { $0 <= date("2019-12-17") })

        XCTAssertEqual(nextUpdate(today: "2019-12-17", chapters, foundRelease: true), date("2019-12-18"))
        XCTAssertEqual(nextUpdate(today: "2019-12-18", chaptersOn(batches), foundRelease: true), date("2020-01-06"))
    }

    func testChecksAgainAroundWhenAnEarlierBreakEnded() {
        // A season of weekly releases, a 98 day break, and another season
        let chapters = chaptersOn(weekly(from: "2019-01-02", to: "2019-03-27") + weekly(from: "2019-07-03", to: "2019-09-25"))

        XCTAssertEqual(nextUpdate(today: "2019-12-20", chapters), date("2019-12-25"))
        XCTAssertEqual(nextUpdate(today: "2019-12-26", chapters), date("2020-01-01"))
    }

    func testNeverWaitsMoreThan28DaysBetweenChecks() {
        let lastDays = ["2019-09-30", "2019-10-31", "2019-11-30", "2019-12-31", "2020-01-31"]
        let chapters = chaptersOn(lastDays.map(date), perDay: 2)
        XCTAssertEqual(nextUpdate(today: "2020-01-31", chapters, foundRelease: true), date("2020-02-28"))
    }

    func testKeepsCheckingOnTheExpectedDay() {
        let chapters = chaptersOn(weekly(from: "2019-12-04", to: "2019-12-25"))
        XCTAssertEqual(nextUpdate(today: "2020-01-01", chapters), date("2020-01-01"))
    }

    func testKeepsANextUpdateInTheWindowWhileNothingNewCameOut() {
        let chapters = chaptersOn(weekly(from: "2019-12-04", to: "2019-12-25"))
        XCTAssertEqual(nextUpdate(today: "2020-01-02", chapters, expecting("2020-01-01")), date("2020-01-01"))
    }

    func testCountsFromAReleaseOnTheExpectedDay() {
        let chapters = chaptersOn(weekly(from: "2019-12-04", to: "2020-01-01"))
        XCTAssertEqual(nextUpdate(today: "2020-01-01", chapters, expecting("2020-01-01")), date("2020-01-08"))
    }

    func testKeepsTheScheduleForAReleaseUploadedTheDayBeforeItWasFound() {
        let chapters = chaptersOn(weekly(from: "2019-10-02", to: "2019-12-25") + [date("2019-12-31")])
        XCTAssertEqual(nextUpdate(today: "2020-01-01", chapters, expecting("2020-01-01"), foundRelease: true), date("2020-01-08"))
    }

    func testKeepsTheScheduleAfterAReleaseShortlyBeforeTheExpectedDay() {
        let chapters = chaptersOn(weekly(from: "2019-10-02", to: "2019-12-25") + [date("2019-12-30")])
        XCTAssertEqual(nextUpdate(today: "2019-12-30", chapters, expecting("2020-01-01"), foundRelease: true), date("2020-01-08"))
    }

    func testKeepsTheScheduleAfterALateRelease() {
        let chapters = chaptersOn(weekly(from: "2019-12-04", to: "2019-12-25") + [date("2020-01-03")])
        XCTAssertEqual(nextUpdate(today: "2020-01-03", chapters, expecting("2020-01-01"), foundRelease: true), date("2020-01-08"))
    }

    func testKeepsExpectingTheReleaseAfterAnExtraOneWellBeforeIt() {
        let chapters = chaptersOn(weekly(from: "2019-10-02", to: "2020-01-01") + [date("2020-01-02")])
        XCTAssertEqual(nextUpdate(today: "2020-01-02", chapters, expecting("2020-01-08"), foundRelease: true), date("2020-01-08"))
    }

    func testFollowsTheScheduleAgainWhenReleasesResumeAfterAHiatus() {
        let chapters = chaptersOn(weekly(from: "2019-09-11", to: "2019-10-02") + [date("2020-01-01")])
        XCTAssertEqual(nextUpdate(today: "2020-01-01", chapters, expecting("2020-01-22"), foundRelease: true), date("2020-01-08"))
    }

    func testFollowsTheScheduleOnceReleasesKeepComingEarly() {
        let history = every(days: 5, from: "2019-10-01", to: "2019-12-15")
        let chapters = chaptersOn(history + every(days: 5, from: "2019-12-19", to: "2019-12-29"))
        XCTAssertEqual(nextUpdate(today: "2019-12-29", chapters, expecting("2019-12-30"), foundRelease: true), date("2020-01-03"))
    }

    func testKeepsCheckingForAnOverdueReleaseWhileRecentOnesCameThatLate() {
        let chapters = chaptersOn(afterGaps(from: "2019-10-18", 6, 5, 8, 6, 5, 6, 8, 6, 5))
        // Due on the 18th from a median gap of 6, and gaps have run to 8
        XCTAssertEqual(nextUpdate(today: "2019-12-20", chapters, expecting("2019-12-18")), date("2019-12-20"))
    }

    func testCountsFromAnEarlyReleaseWithACustomInterval() {
        var manga = expecting("2020-01-01")
        manga.fetchInterval = -7
        XCTAssertEqual(nextUpdate(today: "2019-12-31", [], manga, foundRelease: true), date("2020-01-07"))
    }

    func testSpreadsOutChecksDuringAHiatus() {
        let chapters = chaptersOn(weekly(from: "2019-09-11", to: "2019-10-02"))
        XCTAssertEqual(nextUpdate(today: "2020-01-01", chapters), date("2020-01-22"))
    }

    func testIgnoresChaptersDatedInTheFuture() {
        let chapters = chaptersOn(weekly(from: "2019-12-04", to: "2019-12-25") + [date("2020-06-01")])
        XCTAssertEqual(nextUpdate(today: "2020-01-01", chapters), date("2020-01-01"))
    }

    // MARK: - This port's calendar day

    func testLocalDateArithmetic() {
        XCTAssertEqual(date("1970-01-01").epochDay, 0)
        XCTAssertEqual(date("2020-02-29").plusDays(1), date("2020-03-01"))
        XCTAssertEqual(date("2020-01-31").lastOfMonth, date("2020-01-31"))
        XCTAssertEqual(date("2019-02-10").lastOfMonth, date("2019-02-28"))
        XCTAssertEqual(date("2020-12-15").firstOfMonth.plusMonthsFromFirst(1), date("2021-01-01"))
        XCTAssertEqual(date("2020-01-15").firstOfMonth.plusMonthsFromFirst(-1), date("2019-12-01"))
        XCTAssertEqual(date("2026-10-28").isoDayOfWeek, 3, "a Wednesday")
        XCTAssertEqual(date("1969-12-31").description, "1969-12-31")
        XCTAssertEqual((-3).floorMod(7), 4)
        XCTAssertEqual((-3).floorDiv(7), -1)
        XCTAssertEqual(10.ceilDiv(4), 3)
        // Shanghai's 2020-01-01 begins at 16:00 UTC the day before.
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(MihonLocalDate(Date(timeIntervalSince1970: 1_577_808_000), in: shanghai), date("2020-01-01"))
        XCTAssertEqual(date("2020-01-01").startOfDay(in: shanghai), Date(timeIntervalSince1970: 1_577_808_000))
    }

    // MARK: - Helpers (upstream's)

    private func date(_ iso: String) -> MihonLocalDate {
        MihonLocalDate(iso)!
    }

    private func nextUpdate(
        today: String,
        _ chapters: [Chapter],
        _ manga: Manga = Manga(id: 1, source: 0, url: "", title: "", fetchInterval: 0),
        foundRelease: Bool = false
    ) -> MihonLocalDate {
        let day = date(today)
        let update = FetchInterval.update(
            for: manga,
            chapters: chapters,
            now: day.startOfDay(in: utc).addingTimeInterval(10 * hour),
            timeZone: utc,
            window: FetchInterval.window(today: day, timeZone: utc),
            foundRelease: foundRelease
        )
        return MihonLocalDate(update.nextUpdate, in: utc)
    }

    private func expecting(_ day: String) -> Manga {
        Manga(id: 1, source: 0, url: "", title: "", nextUpdate: date(day).startOfDay(in: utc), fetchInterval: 0)
    }

    private func interval(_ chapters: [Chapter]) -> Int {
        ReleaseSchedule.estimate(chapters, timeZone: utc, today: MihonLocalDate(Date(), in: utc)).interval
    }

    private func weekly(from: String, to: String) -> [MihonLocalDate] {
        every(days: 7, from: from, to: to)
    }

    private func every(days: Int, from: String, to: String) -> [MihonLocalDate] {
        Array(stride(from: date(from).epochDay, through: date(to).epochDay, by: days).map(MihonLocalDate.init(epochDay:)))
    }

    private func afterGaps(from: String, _ gaps: Int...) -> [MihonLocalDate] {
        gaps.reduce(into: [date(from)]) { days, gap in days.append(days[days.count - 1].plusDays(gap)) }
    }

    private func chaptersOn(_ days: [MihonLocalDate], perDay: Int = 1) -> [Chapter] {
        days.flatMap { day -> [Chapter] in
            let time = day.startOfDay(in: utc).addingTimeInterval(12 * hour)
            return (0..<perDay).map { _ in
                var copy = chapter
                copy.dateFetch = time
                copy.dateUpload = time
                return copy
            }
        }
    }

    private func chapterWithTime(_ offset: TimeInterval) -> Chapter {
        var copy = chapter
        copy.dateFetch = testTime.addingTimeInterval(offset)
        copy.dateUpload = copy.dateFetch
        return copy
    }

    private func withoutUploadDate(_ chapters: [Chapter]) -> [Chapter] {
        chapters.map { chapter in
            var copy = chapter
            copy.dateUpload = SChapter.undatedUpload
            return copy
        }
    }

    private func lastUploadDate(_ chapters: [Chapter]) -> TimeInterval {
        chapters[chapters.count - 1].dateUpload.timeIntervalSince(testTime)
    }
}
