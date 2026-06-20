import XCTest
import Foundation
@testable import StrandImport

/// Pins the offline file-import of a user's OWN Oura / Fitbit / Garmin data export onto NOOP's daily
/// metrics + sleep sessions. Tiny inline fixtures per brand (no real account data). HONEST DATA:
/// only fields the export carries are written; a brand's OWN score is reference-only, never Charge.
final class WearableExportImporterTests: XCTestCase {

    private func bytes(_ s: String) -> Data { s.data(using: .utf8)! }

    // MARK: - Oura

    func testOuraSleepReadinessActivityFold() {
        // Sleep period: 7h asleep (25200s) with stage durations + HRV/RHR; readiness gives RHR + temp
        // deviation + a readiness SCORE (reference); activity gives steps + calories.
        let json = """
        {
          "sleep": [
            {
              "day": "2026-06-01",
              "bedtime_start": "2026-05-31T23:15:00+00:00",
              "bedtime_end": "2026-06-01T06:30:00+00:00",
              "total_sleep_duration": 25200,
              "deep_sleep_duration": 5400,
              "light_sleep_duration": 13800,
              "rem_sleep_duration": 6000,
              "awake_time": 900,
              "efficiency": 92,
              "average_heart_rate": 54,
              "lowest_heart_rate": 48,
              "average_hrv": 65,
              "average_breath": 14.2
            }
          ],
          "daily_readiness": [
            { "day": "2026-06-01", "score": 81, "temperature_deviation": -0.2,
              "contributors": { "resting_heart_rate": 49 } }
          ],
          "daily_activity": [
            { "day": "2026-06-01", "steps": 8421, "active_calories": 520, "total_calories": 2450 }
          ]
        }
        """
        let r = WearableExportImporter.parse(brand: .oura, files: ["oura_2026.json": bytes(json)])

        XCTAssertEqual(r.brand, .oura)
        XCTAssertEqual(r.summary.sourceKind, .ouraImport)
        XCTAssertEqual(r.sleeps.count, 1)
        let s = r.sleeps[0]
        XCTAssertEqual(s.totalSleepMin!, 420, accuracy: 1e-6)   // 25200s → 420 min
        XCTAssertEqual(s.deepMin!, 90, accuracy: 1e-6)
        XCTAssertEqual(s.remMin!, 100, accuracy: 1e-6)
        XCTAssertEqual(s.efficiencyPct!, 92, accuracy: 1e-6)
        XCTAssertEqual(s.avgHrvMs!, 65, accuracy: 1e-6)
        XCTAssertEqual(s.lowestHr, 48)
        XCTAssertEqual(s.respRateBpm!, 14.2, accuracy: 1e-6)

        XCTAssertEqual(r.days.count, 1)
        let d = r.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.restingHr, 49)                          // readiness contributor wins
        XCTAssertEqual(d.skinTempDevC!, -0.2, accuracy: 1e-6)
        XCTAssertEqual(d.steps, 8421)
        XCTAssertEqual(d.activeKcal!, 520, accuracy: 1e-6)
        XCTAssertEqual(d.totalSleepMin!, 420, accuracy: 1e-6)    // sleep folded onto the day
        // Oura's OWN readiness score is kept as REFERENCE only — never surfaced as a NOOP score.
        XCTAssertEqual(d.readinessScore, 81)
    }

    func testOuraAcceptsDataWrapperAndDetectsBrandByContent() {
        let json = """
        { "sleep": { "data": [
            { "day": "2026-06-02", "bedtime_start": "2026-06-01T22:00:00+00:00",
              "bedtime_end": "2026-06-02T05:00:00+00:00", "total_sleep_duration": 21600 } ] } }
        """
        let files = ["export.json": bytes(json)]
        XCTAssertEqual(WearableExportImporter.detectBrand(files), .oura)
        let r = WearableExportImporter.parse(brand: .oura, files: files)
        XCTAssertEqual(r.sleeps.count, 1)
        XCTAssertEqual(r.sleeps[0].totalSleepMin!, 360, accuracy: 1e-6)
    }

    // MARK: - Fitbit

    func testFitbitSleepRestingHrSteps() {
        let sleep = """
        [ { "dateOfSleep": "2026-06-01", "startTime": "2026-05-31T23:00:00.000",
            "endTime": "2026-06-01T06:00:00.000", "minutesAsleep": 400, "minutesAwake": 20,
            "efficiency": 94,
            "levels": { "summary": {
              "deep": { "minutes": 80 }, "light": { "minutes": 220 },
              "rem": { "minutes": 100 }, "wake": { "minutes": 20 } } } } ]
        """
        let rhr = """
        [ { "dateTime": "2026-06-01T00:00:00.000", "value": { "date": "2026-06-01", "value": 51.5, "error": 5.0 } } ]
        """
        let steps = """
        [ { "dateTime": "2026-06-01 08:00:00", "value": "1200" },
          { "dateTime": "2026-06-01 09:00:00", "value": "800" } ]
        """
        let files = [
            "sleep-2026-06-01.json": bytes(sleep),
            "resting_heart_rate-2026-06-01.json": bytes(rhr),
            "steps-2026-06-01.json": bytes(steps),
        ]
        XCTAssertEqual(WearableExportImporter.detectBrand(files), .fitbit)
        let r = WearableExportImporter.parse(brand: .fitbit, files: files)

        XCTAssertEqual(r.summary.sourceKind, .fitbitImport)
        XCTAssertEqual(r.sleeps.count, 1)
        let s = r.sleeps[0]
        XCTAssertEqual(s.totalSleepMin!, 400, accuracy: 1e-6)
        XCTAssertEqual(s.deepMin!, 80, accuracy: 1e-6)
        XCTAssertEqual(s.remMin!, 100, accuracy: 1e-6)
        XCTAssertEqual(s.efficiencyPct!, 94, accuracy: 1e-6)

        XCTAssertEqual(r.days.count, 1)
        let d = r.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.restingHr, 51)                          // nested value.value, rounded
        XCTAssertEqual(d.steps, 2000)                            // intraday steps summed
        XCTAssertEqual(d.totalSleepMin!, 400, accuracy: 1e-6)
    }

    // MARK: - Garmin

    func testGarminWellnessSleepAndDaily() {
        // sleepData: epoch-MILLIS GMT timestamps + *SleepSeconds + an overall score (reference).
        // 2026-06-01 00:00:00Z = 1780272000000 ms; +7h end.
        let sleepStartMs = 1_780_272_000_000.0
        let sleepEndMs = sleepStartMs + 7 * 3600 * 1000
        let sleepData = """
        [ { "calendarDate": "2026-06-01", "sleepStartTimestampGMT": \(Int(sleepStartMs)),
            "sleepEndTimestampGMT": \(Int(sleepEndMs)),
            "deepSleepSeconds": 4800, "lightSleepSeconds": 14400, "remSleepSeconds": 5400,
            "awakeSleepSeconds": 600, "unmeasurableSeconds": 0, "overallSleepScore": 78 } ]
        """
        let daily = """
        [ { "calendarDate": "2026-06-01", "restingHeartRate": 47, "totalSteps": 9100,
            "totalDistanceMeters": 7300.5, "averageStressLevel": 31 } ]
        """
        let files = [
            "di_connect/di_connect_wellness/2026_sleepdata.json": bytes(sleepData),
            "di_connect/di_connect_wellness/2026_dailysummary.json": bytes(daily),
        ]
        XCTAssertEqual(WearableExportImporter.detectBrand(files), .garmin)
        let r = WearableExportImporter.parse(brand: .garmin, files: files)

        XCTAssertEqual(r.summary.sourceKind, .garminImport)
        XCTAssertEqual(r.sleeps.count, 1)
        let s = r.sleeps[0]
        XCTAssertEqual(s.deepMin!, 80, accuracy: 1e-6)           // 4800s
        XCTAssertEqual(s.lightMin!, 240, accuracy: 1e-6)         // 14400s
        XCTAssertEqual(s.remMin!, 90, accuracy: 1e-6)            // 5400s
        XCTAssertEqual(s.totalSleepMin!, 410, accuracy: 1e-6)    // 80+240+90
        XCTAssertEqual(s.sleepScore, 78)                          // reference, never Charge

        XCTAssertEqual(r.days.count, 1)
        let d = r.days[0]
        XCTAssertEqual(d.day, "2026-06-01")
        XCTAssertEqual(d.restingHr, 47)
        XCTAssertEqual(d.steps, 9100)
        XCTAssertEqual(d.distanceM!, 7300.5, accuracy: 1e-6)
        XCTAssertEqual(d.avgStress, 31)
    }

    // MARK: - Safety / honesty

    func testJunkAndZeroValuesAreRejectedSafely() {
        // Not a wearable export at all → no brand.
        XCTAssertNil(WearableExportImporter.detectBrand(["random.json": bytes("{\"foo\":1}")]))

        // Zero / missing HR and a malformed sleep period must not produce fabricated rows or crash.
        let json = """
        { "sleep": [
            { "day": "2026-06-03", "bedtime_start": "bad", "bedtime_end": "also-bad",
              "total_sleep_duration": 0, "average_heart_rate": 0 } ],
          "daily_readiness": [
            { "day": "2026-06-03", "score": 0, "contributors": { "resting_heart_rate": 0 } } ] }
        """
        let r = WearableExportImporter.parse(brand: .oura, files: ["oura.json": bytes(json)])
        XCTAssertEqual(r.sleeps.count, 0)                        // unparseable times → dropped
        // The readiness day still exists but carries no fabricated values (0 RHR/score → nil).
        if let d = r.days.first(where: { $0.day == "2026-06-03" }) {
            XCTAssertNil(d.restingHr)
            XCTAssertNil(d.readinessScore)
        }
    }

    func testHugeOutOfRangeNumberDoesNotTrap() {
        // A finite-but-out-of-Int-range number (1e19 > 9e18) must be dropped by the safeInt guard, never
        // trap the Int(Double) conversion. The valid sibling field still imports.
        let json = """
        { "daily_activity": [ { "day": "2026-06-04", "steps": 1e19, "active_calories": 500 } ] }
        """
        let r = WearableExportImporter.parse(brand: .oura, files: ["oura.json": bytes(json)])
        let d = r.days.first { $0.day == "2026-06-04" }
        XCTAssertNotNil(d)
        XCTAssertNil(d?.steps)                                   // 1e19 out of Int range → dropped
        XCTAssertEqual(d?.activeKcal, 500)                       // the valid field still imports
    }
}
