import Foundation

// MARK: - Oura account-export JSON parser
//
// Oura's Account → Export Data download is a single JSON document keyed by category. The categories
// this lane reads (documented Oura account-export / API-V2 shapes; NOOP's own clean parser):
//
//   "sleep"            — sleep PERIODS (one per nap/main sleep): bedtime_start / bedtime_end (ISO8601),
//                        day, total_sleep_duration / deep/light/rem_sleep_duration / awake_time (SECONDS),
//                        efficiency (%), average_heart_rate, lowest_heart_rate, average_hrv (rMSSD ms),
//                        average_breath. Oura gives stage DURATIONS, not a per-segment hypnogram, so the
//                        session carries the breakdown without a stage timeline (we never fake one).
//   "daily_readiness"  — day, score (Oura's OWN readiness — REFERENCE only, never NOOP Charge),
//                        temperature_deviation (°C), contributors.resting_heart_rate.
//   "daily_activity"   — day, steps, active_calories, total_calories.
//   "daily_sleep"      — day, score (sleep score — reference only).
//
// Some exports nest each category as `{ "data": [ ... ] }`; we accept both `[...]` and `{data:[...]}`.

enum OuraExportParser {

    /// True if a top-level dict has at least one Oura category whose elements look Oura-shaped. Used by
    /// brand detection so a renamed JSON still routes to Oura.
    static func looksLikeOura(_ dict: [String: Any]) -> Bool {
        for key in ["sleep", "daily_readiness", "daily_activity", "daily_sleep", "readiness", "activity"] {
            guard let arr = categoryArray(dict, key), let first = arr.first else { continue }
            if first["bedtime_start"] != nil || first["total_sleep_duration"] != nil
                || first["contributors"] != nil || first["temperature_deviation"] != nil
                || (first["day"] != nil && (first["score"] != nil || first["steps"] != nil)) {
                return true
            }
        }
        return false
    }

    static func parse(_ files: [String: Data]) -> (days: [WearableDailyRow], sleeps: [WearableSleepSession]) {
        var byDay: [String: WearableDailyRow] = [:]
        var sleeps: [WearableSleepSession] = []

        func day(_ key: String) -> WearableDailyRow { byDay[key] ?? WearableDailyRow(day: key) }

        for data in files.values {
            guard let root = WearableJSON.object(data) else { continue }

            // Sleep periods → sleep sessions + a per-day sleep rollup.
            for s in categoryArray(root, "sleep") ?? [] {
                guard let session = sleepSession(s) else { continue }
                sleeps.append(session)
                // Fold the night onto its calendar day (Oura's "day" = the wake day).
                let key = WearableJSON.str(s, "day") ?? WearableExportImporter.dayString(session.end)
                var row = day(key)
                row.totalSleepMin = row.totalSleepMin ?? session.totalSleepMin
                row.deepMin = row.deepMin ?? session.deepMin
                row.lightMin = row.lightMin ?? session.lightMin
                row.remMin = row.remMin ?? session.remMin
                row.awakeMin = row.awakeMin ?? session.awakeMin
                row.efficiencyPct = row.efficiencyPct ?? session.efficiencyPct
                row.avgHrvMs = row.avgHrvMs ?? session.avgHrvMs
                // Oura's lowest sleeping HR is the closest thing to a resting HR when readiness lacks one.
                if row.restingHr == nil { row.restingHr = session.lowestHr }
                byDay[key] = row
            }

            // Daily readiness → RHR + temperature deviation + reference readiness score.
            for r in categoryArray(root, "daily_readiness") ?? categoryArray(root, "readiness") ?? [] {
                guard let key = WearableJSON.str(r, "day") else { continue }
                var row = day(key)
                if let contrib = r["contributors"] as? [String: Any] {
                    row.restingHr = WearableJSON.posInt(contrib, "resting_heart_rate") ?? row.restingHr
                }
                row.restingHr = WearableJSON.posInt(r, "resting_heart_rate") ?? row.restingHr
                row.skinTempDevC = WearableJSON.dbl(r, "temperature_deviation") ?? row.skinTempDevC
                row.readinessScore = WearableJSON.posInt(r, "score") ?? row.readinessScore
                byDay[key] = row
            }

            // Daily sleep → reference sleep score only (the night's metrics come from "sleep").
            for d in categoryArray(root, "daily_sleep") ?? [] {
                guard let key = WearableJSON.str(d, "day") else { continue }
                var row = day(key)
                row.sleepScore = WearableJSON.posInt(d, "score") ?? row.sleepScore
                byDay[key] = row
            }

            // Daily activity → steps + calories.
            for a in categoryArray(root, "daily_activity") ?? categoryArray(root, "activity") ?? [] {
                guard let key = WearableJSON.str(a, "day") else { continue }
                var row = day(key)
                row.steps = WearableJSON.posInt(a, "steps") ?? row.steps
                row.activeKcal = WearableJSON.posDbl(a, "active_calories") ?? row.activeKcal
                row.totalKcal = WearableJSON.posDbl(a, "total_calories") ?? row.totalKcal
                byDay[key] = row
            }
        }

        return (Array(byDay.values), sleeps)
    }

    // MARK: - Helpers

    /// Pull a category out of the root, accepting both a bare array and a `{ "data": [...] }` wrapper.
    private static func categoryArray(_ root: [String: Any], _ key: String) -> [[String: Any]]? {
        if let arr = root[key] as? [[String: Any]] { return arr }
        if let wrap = root[key] as? [String: Any], let arr = wrap["data"] as? [[String: Any]] { return arr }
        return nil
    }

    private static func sleepSession(_ s: [String: Any]) -> WearableSleepSession? {
        guard let start = WhoopTime.parse(WearableJSON.str(s, "bedtime_start"), offsetMinutes: 0),
              let end = WhoopTime.parse(WearableJSON.str(s, "bedtime_end"), offsetMinutes: 0),
              end > start else { return nil }

        // Durations are SECONDS in the export → minutes.
        func min(_ k: String) -> Double? { WearableJSON.posDbl(s, k).map { $0 / 60.0 } }

        return WearableSleepSession(
            start: start,
            end: end,
            deepMin: min("deep_sleep_duration"),
            lightMin: min("light_sleep_duration"),
            remMin: min("rem_sleep_duration"),
            awakeMin: min("awake_time"),
            totalSleepMin: min("total_sleep_duration"),
            efficiencyPct: WearableJSON.posDbl(s, "efficiency"),
            avgHr: WearableJSON.posInt(s, "average_heart_rate"),
            lowestHr: WearableJSON.posInt(s, "lowest_heart_rate"),
            avgHrvMs: WearableJSON.posDbl(s, "average_hrv"),
            respRateBpm: WearableJSON.posDbl(s, "average_breath"),
            sleepScore: nil,
            stages: [])
    }
}
