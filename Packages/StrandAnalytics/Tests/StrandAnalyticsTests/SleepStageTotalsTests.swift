import XCTest
import Foundation
import WhoopStore
@testable import StrandAnalytics

final class SleepStageTotalsTests: XCTestCase {

    func testMinutesFromSegmentArray() throws {
        let json = """
        [{"start":0,"end":600,"stage":"light"},
         {"start":600,"end":1200,"stage":"deep"},
         {"start":1200,"end":1500,"stage":"wake"}]
        """
        let m = try XCTUnwrap(SleepStageTotals.minutes(fromStagesJSON: json))
        XCTAssertEqual(m.light, 10, accuracy: 0.001)
        XCTAssertEqual(m.deep, 10, accuracy: 0.001)
        XCTAssertEqual(m.awake, 5, accuracy: 0.001)   // "wake" → awake
        XCTAssertEqual(m.asleep, 20, accuracy: 0.001)
        XCTAssertEqual(m.inBed, 25, accuracy: 0.001)
    }

    func testMinutesFromMinuteDict() throws {
        let m = try XCTUnwrap(SleepStageTotals.minutes(fromStagesJSON:
            #"{"awake":20,"light":200,"deep":80,"rem":90}"#))
        XCTAssertEqual(m.asleep, 370, accuracy: 0.001)
        XCTAssertEqual(m.inBed, 390, accuracy: 0.001)
    }

    func testDailyAggregateSumsBlocksAndComputesEfficiency() throws {
        let agg = try XCTUnwrap(SleepStageTotals.dailyAggregate([
            #"{"awake":10,"light":100,"deep":40,"rem":50}"#,   // a nap-ish block
            #"{"awake":10,"light":100,"deep":40,"rem":40}"#,
        ]))
        XCTAssertEqual(agg.totalSleepMin, 370, accuracy: 0.001)   // (190 + 180)
        XCTAssertEqual(agg.deepMin, 80, accuracy: 0.001)
        XCTAssertEqual(agg.efficiency, 370.0 / 390.0, accuracy: 0.0001)
    }

    func testNilAndGarbage() {
        XCTAssertNil(SleepStageTotals.minutes(fromStagesJSON: nil))
        XCTAssertNil(SleepStageTotals.minutes(fromStagesJSON: "nope"))
        XCTAssertNil(SleepStageTotals.dailyAggregate([nil, "garbage"]))
    }

    // MARK: - the integration seam: detected blocks + edits → corrected daily

    private let detectedNight = "2026-06-14T23:24"  // doc only
    private func detected(_ startTs: Int, _ stages: String) -> (startTs: Int, stagesJSON: String?) {
        (startTs: startTs, stagesJSON: stages)
    }

    func testHonoringEditsNoEditsLeavesDetectedSumAndFlagsFalse() throws {
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [:]))
        XCTAssertFalse(r.editApplied)
        XCTAssertEqual(r.sleep.totalSleepMin, 392, accuracy: 0.001)   // 214+82+96
    }

    func testHonoringEditsSubstitutesEditedBlockByStartTs() throws {
        // Detected says 6h32m; the user's edit (same startTs 1000) trimmed it to ~4h56m.
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [1000: #"{"awake":0,"light":118,"deep":82,"rem":96}"#]))
        XCTAssertTrue(r.editApplied, "a startTs match must apply the edit")
        XCTAssertEqual(r.sleep.totalSleepMin, 296, accuracy: 0.001, "totals come from the EDITED stages")
        XCTAssertEqual(r.sleep.lightMin, 118, accuracy: 0.001)
        XCTAssertEqual(r.sleep.efficiency, 296.0 / 296.0, accuracy: 0.001) // awake 0 → 100% efficient
    }

    func testHonoringEditsKeepsDetectedWhenEditMapsToNil() throws {
        // An edit whose reshaped stages came out nil must FALL BACK to the detected block, never drop it
        // (which would collapse the night's sleep total). (#318 review #4)
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: 1000, stagesJSON: #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [1000: nil]))
        XCTAssertFalse(r.editApplied, "a nil edit is not a usable substitution")
        XCTAssertEqual(r.sleep.totalSleepMin, 392, accuracy: 0.001, "detected stages kept, not dropped")
    }

    func testHonoringEditsIgnoresEditWithNonMatchingStartTs() throws {
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [9999: #"{"awake":0,"light":10,"deep":10,"rem":10}"#]))  // wrong key
        XCTAssertFalse(r.editApplied, "an edit that matches no detected block must not apply")
        XCTAssertEqual(r.sleep.totalSleepMin, 392, accuracy: 0.001)
    }

    func testHonoringEditsMultiBlockSubstitutesOnlyTheEditedBlock() throws {
        // A nap (startTs 100, untouched) + a main sleep (startTs 1000, edited shorter).
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [detected(100, #"{"awake":2,"light":30,"deep":10,"rem":8}"#),
                       detected(1000, #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [1000: #"{"awake":0,"light":118,"deep":82,"rem":96}"#]))
        XCTAssertTrue(r.editApplied)
        // nap asleep 48 + edited main asleep 296 = 344
        XCTAssertEqual(r.sleep.totalSleepMin, 344, accuracy: 0.001)
    }

    /// The point of the whole exercise: a shorter (hand-corrected) window yields a LOWER Rest composite,
    /// so the daily aggregate genuinely moves when sleep is trimmed — not just the Sleep tab's label.
    func testRestCompositeDropsWhenEditedWindowIsShorter() throws {
        func daily(_ s: SleepStageTotals.DailySleep) -> DailyMetric {
            DailyMetric(day: "2026-06-15", totalSleepMin: s.totalSleepMin, efficiency: s.efficiency,
                        deepMin: s.deepMin, remMin: s.remMin, lightMin: s.lightMin, disturbances: nil,
                        restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        }
        let detected = try XCTUnwrap(SleepStageTotals.dailyAggregate(
            [#"{"awake":24,"light":214,"deep":82,"rem":96}"#]))               // ~6h32m asleep
        let edited = try XCTUnwrap(SleepStageTotals.dailyAggregate(
            [#"{"awake":0,"light":118,"deep":82,"rem":96}"#]))                // woke ~2h earlier

        let before = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: daily(detected)))
        let after = try XCTUnwrap(AnalyticsEngine.Rest.composite(daily: daily(edited)))
        XCTAssertLessThan(after, before, "trimming sleep must lower the Rest composite")
    }

    // MARK: - #525 canonical main-night selection (numbers reconcile across screens)

    /// A "yyyy-MM-dd'T'HH:mm" UTC wall-clock as unix seconds. UTC offset 0 in these tests, so local == UTC.
    private func ts525(_ iso: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return Int(f.date(from: iso)!.timeIntervalSince1970)
    }

    func testMainNightPrefersOvernightOverLongerDaytimeNap() {
        let nightStart = ts525("2026-06-14T23:00")   // overnight onset
        let napStart   = ts525("2026-06-15T13:00")   // daytime onset
        // The nap is LONGER in clock span, but the overnight block must still win.
        let blocks = [
            SleepStageTotals.NightBlock(start: napStart,   end: napStart + 5 * 3600),  // 5h daytime
            SleepStageTotals.NightBlock(start: nightStart, end: nightStart + 4 * 3600), // 4h overnight
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1,
                       "the overnight block is the main night even when a nap is longer")
    }

    func testMainNightLongestAmongOvernightBlocks() {
        let a = ts525("2026-06-14T22:00")
        let b = ts525("2026-06-14T23:30")
        let blocks = [
            SleepStageTotals.NightBlock(start: a, end: a + 3 * 3600),  // 3h
            SleepStageTotals.NightBlock(start: b, end: b + 6 * 3600),  // 6h — longer overnight wins
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1)
    }

    func testMainNightEmptyAndTieAreDeterministic() {
        XCTAssertNil(SleepStageTotals.mainNightIndex([], offsetSec: 0))
        // Two equal-length overnight blocks → the EARLIER onset wins (stable across platforms).
        let a = ts525("2026-06-14T22:00"), b = ts525("2026-06-14T23:00")
        let blocks = [
            SleepStageTotals.NightBlock(start: b, end: b + 4 * 3600),
            SleepStageTotals.NightBlock(start: a, end: a + 4 * 3600),
        ]
        XCTAssertEqual(SleepStageTotals.mainNightIndex(blocks, offsetSec: 0), 1, "earlier onset breaks the tie")
    }

    /// THE #525 invariant: a day with an overnight + a nap reports CONSISTENT totals — the day's
    /// canonical figure equals the MAIN NIGHT's sleep, NOT the night+nap sum. The honoring-edits seam
    /// (with onsets supplied) and the standalone main-night aggregate agree to the minute.
    func testOvernightPlusNapReportsConsistentTotalsNotTheSum() throws {
        let nightStart = ts525("2026-06-14T23:00")
        let napStart   = ts525("2026-06-15T14:00")
        let nightStages = #"{"awake":24,"light":214,"deep":82,"rem":96}"#   // 392 min asleep
        let napStages   = #"{"awake":2,"light":30,"deep":10,"rem":8}"#      // 48 min asleep

        // What the Sleep tab's hero shows for this day = the main night's own aggregate.
        let mainOnly = try XCTUnwrap(SleepStageTotals.dailyAggregate([nightStages]))
        XCTAssertEqual(mainOnly.totalSleepMin, 392, accuracy: 0.001)

        // The honoring-edits seam (no edits, but onsets supplied) must report the SAME main-night total,
        // never the 392 + 48 = 440 sum the old code produced.
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: nightStart, stagesJSON: nightStages),
                       (startTs: napStart,   stagesJSON: napStages)],
            edited: [:],
            onsetByStart: [nightStart: nightStart, napStart: napStart],
            offsetSec: 0))
        XCTAssertFalse(r.editApplied)
        XCTAssertEqual(r.sleep.totalSleepMin, mainOnly.totalSleepMin, accuracy: 0.001,
                       "day total must equal the MAIN night, not the night+nap sum")
        XCTAssertEqual(r.sleep.deepMin, mainOnly.deepMin, accuracy: 0.001)
        XCTAssertEqual(r.sleep.remMin, mainOnly.remMin, accuracy: 0.001)
        XCTAssertNotEqual(r.sleep.totalSleepMin, 440, accuracy: 0.001, "must NOT sum the nap in")
    }

    /// A hand-corrected (trimmed) main night still wins the pick, and the day total tracks the EDITED
    /// main night — the nap is never folded into the headline figure.
    func testHonoringEditsMainNightModeTracksEditedNightNotNapSum() throws {
        let nightStart = ts525("2026-06-14T23:00")
        let napStart   = ts525("2026-06-15T14:00")
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: nightStart, stagesJSON: #"{"awake":24,"light":214,"deep":82,"rem":96}"#),
                       (startTs: napStart,   stagesJSON: #"{"awake":2,"light":30,"deep":10,"rem":8}"#)],
            edited: [nightStart: #"{"awake":0,"light":118,"deep":82,"rem":96}"#],   // trimmed to 296
            onsetByStart: [nightStart: nightStart, napStart: napStart],
            offsetSec: 0))
        XCTAssertTrue(r.editApplied)
        XCTAssertEqual(r.sleep.totalSleepMin, 296, accuracy: 0.001,
                       "day total tracks the EDITED main night, nap excluded from the headline figure")
    }

    /// Backward-compat: with NO onsets supplied the seam keeps the legacy sum-of-all-blocks total, so
    /// any caller still on the old signature is unchanged.
    func testHonoringEditsLegacySumWhenNoOnsets() throws {
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: 100,  stagesJSON: #"{"awake":2,"light":30,"deep":10,"rem":8}"#),
                       (startTs: 1000, stagesJSON: #"{"awake":24,"light":214,"deep":82,"rem":96}"#)],
            edited: [:]))
        XCTAssertEqual(r.sleep.totalSleepMin, 48 + 392, accuracy: 0.001, "no onsets → legacy sum")
    }
}
