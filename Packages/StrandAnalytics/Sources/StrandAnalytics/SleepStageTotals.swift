import Foundation

/// Decode a sleep session's `stagesJSON` (either the on-device segment array `[{start,end,stage}]` or
/// the imported minute dict `{light,deep,rem,awake}`) into stage MINUTE totals, and aggregate a night's
/// blocks into the sleep-derived daily fields. Pure + deterministic, so the daily-aggregate recompute
/// that honors a user's wake-time edit can run off the stored (reshaped) stages — no raw streams needed.
public enum SleepStageTotals {

    public struct Minutes: Equatable {
        public var awake: Double, light: Double, deep: Double, rem: Double
        public var asleep: Double { light + deep + rem }
        public var inBed: Double { asleep + awake }
        public init(awake: Double = 0, light: Double = 0, deep: Double = 0, rem: Double = 0) {
            self.awake = awake; self.light = light; self.deep = deep; self.rem = rem
        }
    }

    /// Stage minutes for one session's `stagesJSON`, or nil if it decodes to nothing usable. The on-device
    /// stager calls awake "wake"; the importer "awake" — both map to `awake`.
    public static func minutes(fromStagesJSON json: String?) -> Minutes? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] {                 // segment array (computed)
            var m = Minutes()
            for seg in arr {
                guard let s = (seg["start"] as? NSNumber)?.intValue,
                      let e = (seg["end"] as? NSNumber)?.intValue, e > s,
                      let name = seg["stage"] as? String else { continue }
                let mins = Double(e - s) / 60.0
                switch name {
                case "wake", "awake": m.awake += mins
                case "light": m.light += mins
                case "deep": m.deep += mins
                case "rem": m.rem += mins
                default: continue
                }
            }
            return m.inBed > 0 ? m : nil
        }
        if let dict = obj as? [String: Any] {                  // minute dict (imported)
            func v(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
            let m = Minutes(awake: v("awake"), light: v("light"), deep: v("deep"), rem: v("rem"))
            return m.inBed > 0 ? m : nil
        }
        return nil
    }

    /// The sleep-derived daily fields for a night made of these blocks' `stagesJSON`, or nil if none
    /// decode. `efficiency` is asleep / in-bed (TST / Σ stage minutes) in [0,1]. For the segment stages
    /// noop stores (which TILE the window, last segment clamped to the wake), Σ stage minutes equals the
    /// clock span, so this coincides with `AnalyticsEngine.analyzeDay`'s TST/(end−start); it is not the
    /// literal same expression, and would diverge only for malformed non-tiling stages.
    public struct DailySleep: Equatable {
        public let totalSleepMin: Double, efficiency: Double
        public let deepMin: Double, remMin: Double, lightMin: Double
    }

    public static func dailyAggregate(_ stagesJSONs: [String?]) -> DailySleep? {
        var total = Minutes()
        var any = false
        for j in stagesJSONs {
            if let m = minutes(fromStagesJSON: j) {
                total.awake += m.awake; total.light += m.light
                total.deep += m.deep; total.rem += m.rem
                any = true
            }
        }
        guard any, total.inBed > 0 else { return nil }
        return DailySleep(totalSleepMin: total.asleep, efficiency: total.asleep / total.inBed,
                          deepMin: total.deep, remMin: total.rem, lightMin: total.light)
    }

    // MARK: - Canonical main-night selection (#525)

    /// Local hour (inclusive) at/after which a sleep onset counts as the start of a real OVERNIGHT
    /// (≥ 20:00). Below `overnightEndHour` (< 10:00) also counts. This is the exact window the Sleep
    /// tab's `SleepView.isOvernightOnset` uses — kept here as the single shared definition so the
    /// daily aggregate and the on-screen "your night" figure pick the SAME block. (#525)
    public static let overnightStartHour = 20
    /// Local hour (exclusive) before which a sleep onset still counts as overnight (an early-morning
    /// wake-and-bed). A block onset in [overnightEndHour, overnightStartHour) is daytime — a nap.
    public static let overnightEndHour = 10

    /// One candidate block for main-night selection. The `start` is the EFFECTIVE onset (a user wake/
    /// bed edit moves `end`, never the detected onset key), and `tzOffsetSeconds` turns it local so the
    /// overnight test reads the user's clock, not UTC.
    public struct NightBlock {
        public let start: Int, end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var durationS: Int { end - start }
    }

    /// True when a block's onset falls in the overnight window (≥ `overnightStartHour` or
    /// < `overnightEndHour`, local). Mirrors `SleepView.isOvernightOnset` so the analytics rollup and
    /// the Sleep tab agree on which block is the night. `offsetSec` is seconds EAST of UTC. (#525)
    public static func isOvernightOnset(_ ts: Int, offsetSec: Int) -> Bool {
        let local = ts + offsetSec
        let secOfDay = ((local % 86_400) + 86_400) % 86_400
        let hour = secOfDay / 3_600
        return hour >= overnightStartHour || hour < overnightEndHour
    }

    /// Index of the day's MAIN night among `blocks`: the LONGEST block, preferring an OVERNIGHT-anchored
    /// onset so a long lazy afternoon nap can't out-rank a slightly shorter real night. This is the SAME
    /// rule the Sleep tab's hero / `editTarget` / `mainBlock` use, so the daily total and the on-screen
    /// "your night" figure resolve to the identical block. Returns nil only for an empty list. Ties are
    /// broken toward the EARLIER block (stable, deterministic) so two equal-length blocks always pick the
    /// same winner across platforms. (#525)
    public static func mainNightIndex(_ blocks: [NightBlock], offsetSec: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        var bestIdx = 0
        for i in 1..<blocks.count {
            let cand = blocks[i], best = blocks[bestIdx]
            let candON = isOvernightOnset(cand.start, offsetSec: offsetSec)
            let bestON = isOvernightOnset(best.start, offsetSec: offsetSec)
            let candWins: Bool
            if candON != bestON {
                candWins = candON                                   // an overnight block always beats a daytime one
            } else if cand.durationS != best.durationS {
                candWins = cand.durationS > best.durationS          // same kind → the longer wins
            } else {
                candWins = cand.start < best.start                  // exact tie → earlier onset (stable)
            }
            if candWins { bestIdx = i }
        }
        return bestIdx
    }

    /// The night's daily sleep aggregate, substituting any USER-EDITED block for its detected twin
    /// before summing, then UNIONING in any user-added block that has no detected twin. `detected` is
    /// the auto-detected blocks (their stable startTs + stages); `edited` maps a block's startTs → its
    /// hand-corrected (reshaped) stages — a wake-time edit never moves startTs, so the edited block
    /// lands exactly on its detected twin. `manual` is user-added blocks (e.g. a hand-logged nap) that
    /// the detector never found; each is keyed by its own stable startTs and FOLDED IN so its minutes
    /// count toward the day's totals (a detector-found nap already folds via `detected`). De-duped by
    /// startTs so a block already represented in `detected` (or substituted via `edited`) is never
    /// double-counted. Returns the aggregate plus whether an edit OR a manual block actually contributed
    /// (so the caller only overrides the day when it did), or nil when nothing decodes. This is the
    /// integration seam between the edit and the daily recompute — kept pure so it's unit-tested with
    /// synthetic data, no store or stager needed. (#518 / #508)
    public static func dailyAggregateHonoringEdits(
        detected: [(startTs: Int, stagesJSON: String?)],
        edited: [Int: String?],
        manual: [(startTs: Int, stagesJSON: String?)] = [],
        // The block's effective onset (a wake/bed edit moves end, not the detected start key) plus the
        // device's UTC offset, so the MAIN-NIGHT pick reads the user's local clock. When a caller can't
        // supply onsets, leave nil and the legacy SUM-of-all-blocks behaviour is preserved (no regression
        // for older callers); the day rollup passes them so the daily total matches the Sleep tab. (#525)
        onsetByStart: [Int: Int]? = nil,
        offsetSec: Int = 0
    ) -> (sleep: DailySleep, editApplied: Bool)? {
        // Substitute an edited block's stages ONLY when the edit has usable (non-nil) stages — an edit
        // that reshaped to nil must fall back to the detected stages, never drop the block (which would
        // collapse the night's sleep total). `editApplied` likewise reflects a real substitution. We keep
        // each block's identity (its startTs + effective stages) so the main-night pick can run after.
        var applied = false
        // (startTs, effective stages) for every block on the day — detected (edit-substituted) then any
        // twinless manual block UNIONED in. Identity is preserved for the main-night selection.
        var blocks: [(startTs: Int, stagesJSON: String?)] = detected.map { d in
            if let stages = edited[d.startTs] ?? nil {   // flatten String?? → String?, then require non-nil
                applied = true
                return (startTs: d.startTs, stagesJSON: stages)
            }
            return (startTs: d.startTs, stagesJSON: d.stagesJSON)
        }
        // Union: a user-added block the detector never found (no detected twin) must still be on the day
        // so the main-night pick (or the legacy sum) sees it — otherwise a manually-logged nap is dropped.
        // Match on the stable startTs and add ONLY rows absent from `detected`, with usable stages.
        let detectedStarts = Set(detected.map(\.startTs))
        for m in manual where !detectedStarts.contains(m.startTs) {
            if let stages = m.stagesJSON {
                blocks.append((startTs: m.startTs, stagesJSON: stages))
                applied = true
            }
        }
        // Canonical per-day total (#525): when the caller supplies block onsets, the daily figure is the
        // MAIN NIGHT only (the longest, overnight-preferring block — the SAME block the Sleep tab shows),
        // so Intelligence / Sleep Need / the debt ledger / the card all read the same number as the Sleep
        // tab. Nap blocks stay their own session rows elsewhere; they are NOT summed into this figure.
        // No onsets supplied → the legacy sum-of-all-blocks total (older callers unchanged).
        if let onsetByStart {
            // Pick by the same rule as the Sleep tab — overnight-preferring, then longest (measured by
            // each block's decoded in-bed minutes) — and report ONLY that block's totals as the day's
            // figure. A day's naps are unaffected here; they remain their own session rows.
            if let idx = mainNightIndexByStages(blocks, onsetByStart: onsetByStart, offsetSec: offsetSec),
               let agg = dailyAggregate([blocks[idx].stagesJSON]) {
                return (agg, applied)
            }
            return nil
        }
        guard let agg = dailyAggregate(blocks.map(\.stagesJSON)) else { return nil }
        return (agg, applied)
    }

    /// Index into `blocks` of the day's MAIN night, ranked by the SAME rule the Sleep tab uses
    /// (overnight-preferring, then longest), but measuring "longest" by each block's decoded asleep+awake
    /// minutes (its real in-bed span) rather than a synthetic end. `onsetByStart` gives each block's
    /// effective onset for the overnight test. Blocks whose stages don't decode are still candidates with
    /// a 0-minute span, so a day of only-undecodable blocks still resolves deterministically. (#525)
    static func mainNightIndexByStages(_ blocks: [(startTs: Int, stagesJSON: String?)],
                                       onsetByStart: [Int: Int], offsetSec: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        func span(_ b: (startTs: Int, stagesJSON: String?)) -> Double {
            minutes(fromStagesJSON: b.stagesJSON)?.inBed ?? 0
        }
        func onset(_ b: (startTs: Int, stagesJSON: String?)) -> Int { onsetByStart[b.startTs] ?? b.startTs }
        var bestIdx = 0
        for i in 1..<blocks.count {
            let cand = blocks[i], best = blocks[bestIdx]
            let candON = isOvernightOnset(onset(cand), offsetSec: offsetSec)
            let bestON = isOvernightOnset(onset(best), offsetSec: offsetSec)
            let candSpan = span(cand), bestSpan = span(best)
            let candWins: Bool
            if candON != bestON {
                candWins = candON
            } else if candSpan != bestSpan {
                candWins = candSpan > bestSpan
            } else {
                candWins = onset(cand) < onset(best)
            }
            if candWins { bestIdx = i }
        }
        return bestIdx
    }
}
