package com.noop.analytics

import org.json.JSONArray
import org.json.JSONObject

/**
 * Decode a sleep session's `stagesJSON` into stage MINUTE totals, and aggregate a night's blocks into
 * the sleep-derived daily fields. Pure + deterministic, so the daily-aggregate recompute that honors a
 * user's bed/wake-time edit can run off the stored (reshaped) stages — no raw streams needed.
 *
 * Faithful Kotlin port of StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift (the iOS
 * `dailyAggregateHonoringEdits` seam from PR #395), adapted to Android's two stagesJSON shapes:
 *   - on-device COMPUTED (what the IntelligenceEngine writes via [AnalyticsEngine.encodeStages]):
 *     `[{start,end,stage}]` — per-segment unix SECONDS spans;
 *   - IMPORTED (WhoopCsvImporter.stagesJson): `[{stage,min}]` — per-stage MINUTE totals.
 * The on-device stager calls awake "wake"; the importer "awake" — both map to `awake`.
 *
 * The edit/recompute path only ever feeds the COMPUTED (`-noop`) source's `[{start,end,stage}]` stages
 * here (the daily override is computed-source-only, mirroring iOS scope), but [minutes] handles both
 * shapes so the helper is a complete twin of the Swift one and is robust to either input.
 */
object SleepStageTotals {

    /** Stage minute totals for one session. `asleep` = light+deep+rem; `inBed` = asleep+awake. */
    data class Minutes(
        var awake: Double = 0.0,
        var light: Double = 0.0,
        var deep: Double = 0.0,
        var rem: Double = 0.0,
    ) {
        val asleep: Double get() = light + deep + rem
        val inBed: Double get() = asleep + awake
    }

    /**
     * The sleep-derived daily fields for a night, or null if nothing decodes. `efficiency` is
     * asleep / in-bed (TST / Σ stage minutes) in [0,1]. For the segment stages noop stores (which TILE
     * the window), Σ stage minutes equals the clock span, so this coincides with the SleepStager's
     * TST/(end−start). Mirrors Swift `SleepStageTotals.DailySleep`.
     */
    data class DailySleep(
        val totalSleepMin: Double,
        val efficiency: Double,
        val deepMin: Double,
        val remMin: Double,
        val lightMin: Double,
    )

    /**
     * Stage minutes for one session's `stagesJSON`, or null if it decodes to nothing usable.
     * Handles both Android shapes — `[{start,end,stage}]` (seconds spans) and `[{stage,min}]`
     * (minute totals). Mirrors Swift `minutes(fromStagesJSON:)`.
     */
    fun minutes(stagesJSON: String?): Minutes? {
        val json = stagesJSON ?: return null
        val arr = try {
            JSONArray(json)
        } catch (_: Throwable) {
            // Object/dict shape {"awake":N,"light":N,"deep":N,"rem":N} of minute totals (imported
            // sessions). Mirrors Swift minutes(fromStagesJSON:)'s dict branch so imported sleep decodes
            // on Android too, not just the segment-array shapes.
            val dict = try { JSONObject(json) } catch (_: Throwable) { return null }
            val md = Minutes()
            md.awake = dict.optDouble("awake", 0.0)
            md.light = dict.optDouble("light", 0.0)
            md.deep = dict.optDouble("deep", 0.0)
            md.rem = dict.optDouble("rem", 0.0)
            return if (md.inBed > 0.0) md else null
        }
        val m = Minutes()
        for (i in 0 until arr.length()) {
            val seg = arr.optJSONObject(i) ?: continue
            val name = seg.optString("stage", "")
            // Per-segment SECONDS span (computed/edited) → minutes; else a direct minute total (imported).
            val mins = when {
                seg.has("start") && seg.has("end") -> {
                    val s = seg.optLong("start")
                    val e = seg.optLong("end")
                    if (e > s) (e - s) / 60.0 else continue
                }
                seg.has("min") -> seg.optDouble("min", 0.0)
                else -> continue
            }
            if (mins <= 0.0) continue
            when (name) {
                "wake", "awake" -> m.awake += mins
                "light" -> m.light += mins
                "deep" -> m.deep += mins
                "rem" -> m.rem += mins
                else -> continue
            }
        }
        return if (m.inBed > 0.0) m else null
    }

    // ── Canonical main-night selection (#525) ─────────────────────────────────

    /** Local hour (inclusive) at/after which a sleep onset counts as the start of a real OVERNIGHT
     *  (>= 20:00). Below [OVERNIGHT_END_HOUR] (< 10:00) also counts. The exact window the Sleep tab's
     *  `isOvernightOnset` uses, kept here as the single shared definition so the daily aggregate and the
     *  on-screen "your night" figure pick the SAME block. Mirrors Swift. (#525) */
    const val OVERNIGHT_START_HOUR = 20

    /** Local hour (exclusive) before which a sleep onset still counts as overnight (an early-morning
     *  wake-and-bed). A block onset in [OVERNIGHT_END_HOUR, OVERNIGHT_START_HOUR) is daytime — a nap. */
    const val OVERNIGHT_END_HOUR = 10

    /** One candidate block for main-night selection: its effective onset and end (unix seconds). A user
     *  wake/bed edit moves [end], never the detected onset key. */
    data class NightBlock(val start: Long, val end: Long) {
        val durationS: Long get() = end - start
    }

    /** True when a block's onset falls in the overnight window (>= [OVERNIGHT_START_HOUR] or
     *  < [OVERNIGHT_END_HOUR], local). Mirrors the Sleep tab `isOvernightOnset` so the analytics rollup
     *  and the Sleep tab agree on which block is the night. [offsetSec] is seconds EAST of UTC. (#525) */
    fun isOvernightOnset(ts: Long, offsetSec: Long): Boolean {
        val local = ts + offsetSec
        val secOfDay = ((local % 86_400L) + 86_400L) % 86_400L
        val hour = (secOfDay / 3_600L).toInt()
        return hour >= OVERNIGHT_START_HOUR || hour < OVERNIGHT_END_HOUR
    }

    /** Index of the day's MAIN night among [blocks]: the LONGEST block, preferring an OVERNIGHT-anchored
     *  onset so a long lazy afternoon nap can't out-rank a slightly shorter real night. The SAME rule the
     *  Sleep tab's hero / main-block selection use, so the daily total and the on-screen "your night"
     *  figure resolve to the identical block. Null only for an empty list. Ties break toward the EARLIER
     *  block (stable, deterministic) so two equal-length blocks always pick the same winner across
     *  platforms. Mirrors Swift `SleepStageTotals.mainNightIndex`. (#525) */
    fun mainNightIndex(blocks: List<NightBlock>, offsetSec: Long): Int? {
        if (blocks.isEmpty()) return null
        var bestIdx = 0
        for (i in 1 until blocks.size) {
            val cand = blocks[i]
            val best = blocks[bestIdx]
            val candON = isOvernightOnset(cand.start, offsetSec)
            val bestON = isOvernightOnset(best.start, offsetSec)
            val candWins = when {
                candON != bestON -> candON                       // an overnight block always beats a daytime one
                cand.durationS != best.durationS -> cand.durationS > best.durationS // same kind → the longer wins
                else -> cand.start < best.start                  // exact tie → earlier onset (stable)
            }
            if (candWins) bestIdx = i
        }
        return bestIdx
    }

    /** The night's daily sleep aggregate over these blocks' `stagesJSON`, or null if none decode.
     *  Mirrors Swift `dailyAggregate`. */
    fun dailyAggregate(stagesJSONs: List<String?>): DailySleep? {
        val total = Minutes()
        var any = false
        for (j in stagesJSONs) {
            val mm = minutes(j) ?: continue
            total.awake += mm.awake
            total.light += mm.light
            total.deep += mm.deep
            total.rem += mm.rem
            any = true
        }
        if (!any || total.inBed <= 0.0) return null
        return DailySleep(
            totalSleepMin = total.asleep,
            efficiency = total.asleep / total.inBed,
            deepMin = total.deep,
            remMin = total.rem,
            lightMin = total.light,
        )
    }

    /** Result of [dailyAggregateHonoringEdits]: the aggregate plus whether an edit actually applied. */
    data class HonoredAggregate(val sleep: DailySleep, val editApplied: Boolean)

    /**
     * The night's daily sleep aggregate, substituting any USER-EDITED block for its detected twin before
     * summing, then UNIONING in any user-added block that has no detected twin. [detected] is the
     * auto-detected blocks (their stable startTs + stages); [edited] maps a block's startTs → its
     * hand-corrected (reshaped) stages — a bed/wake-time edit never moves startTs, so the edited block
     * lands exactly on its detected twin. [manual] is user-added blocks (e.g. a hand-logged nap) the
     * detector never found; each is keyed by its own stable startTs and FOLDED IN so its minutes count
     * toward the day's totals (a detector-found nap already folds via [detected]). De-duped by startTs
     * so a block already in [detected] (or substituted via [edited]) is never double-counted. Returns the
     * aggregate plus whether an edit OR a manual block actually contributed (so the caller only overrides
     * the day when it did), or null when nothing decodes.
     *
     * Faithful twin of Swift `dailyAggregateHonoringEdits` (#518 / #508): substitute an edited block's
     * stages ONLY when the edit has usable (non-null) stages — an edit that reshaped to null must fall
     * back to the detected stages, never DROP the block (which would collapse the night's sleep total).
     * `editApplied` likewise reflects a real substitution or a folded manual block. Pure: unit-tested
     * with synthetic data, no store/stager.
     */
    fun dailyAggregateHonoringEdits(
        detected: List<Pair<Long, String?>>,
        edited: Map<Long, String?>,
        manual: List<Pair<Long, String?>> = emptyList(),
        // The block's effective onset (a wake/bed edit moves end, not the detected start key) keyed by
        // startTs, plus the device's UTC offset, so the MAIN-NIGHT pick reads the user's local clock.
        // When a caller can't supply onsets, leave null and the legacy SUM-of-all-blocks behaviour is
        // preserved (no regression for older callers); the day rollup passes them so the daily total
        // matches the Sleep tab. Mirrors Swift `onsetByStart` / `offsetSec`. (#525)
        onsetByStart: Map<Long, Long>? = null,
        offsetSec: Long = 0L,
    ): HonoredAggregate? {
        var applied = false
        // (startTs, effective stages) for every block on the day — detected (edit-substituted) then any
        // twinless manual block UNIONED in. Identity is preserved for the main-night selection.
        val blocks = detected.map { (startTs, detectedStages) ->
            // `edited[startTs]` is null both when the key is ABSENT and when it maps to NULL stages
            // (an edit that reshaped to nothing) — in both cases we fall back to the detected stages
            // and do NOT mark `applied`. Only a present, non-null edit substitutes, mirroring Swift's
            // `edited[d.startTs] ?? nil` requiring a non-nil value.
            val editStages = edited[startTs]
            if (editStages != null) {
                applied = true
                startTs to editStages
            } else {
                startTs to detectedStages
            }
        }.toMutableList()
        // Union: a user-added block the detector never found (no detected twin) must still be on the day
        // so the main-night pick (or the legacy sum) sees it — otherwise a manually-logged nap is dropped.
        // Match on the stable startTs and add ONLY rows absent from [detected], with usable stages.
        val detectedStarts = detected.map { it.first }.toHashSet()
        for ((startTs, manualStages) in manual) {
            if (startTs in detectedStarts) continue
            if (manualStages != null) {
                blocks.add(startTs to manualStages)
                applied = true
            }
        }
        // Canonical per-day total (#525): with block onsets supplied, the daily figure is the MAIN NIGHT
        // only (the longest, overnight-preferring block — the SAME block the Sleep tab shows), so
        // Intelligence / Sleep Need / the debt ledger / the card all read the same number as the Sleep
        // tab. Nap blocks stay their own session rows elsewhere; they are NOT summed into this figure.
        // No onsets supplied → the legacy sum-of-all-blocks total (older callers unchanged).
        if (onsetByStart != null) {
            val idx = mainNightIndexByStages(blocks, onsetByStart, offsetSec) ?: return null
            val agg = dailyAggregate(listOf(blocks[idx].second)) ?: return null
            return HonoredAggregate(agg, applied)
        }
        val agg = dailyAggregate(blocks.map { it.second }) ?: return null
        return HonoredAggregate(agg, applied)
    }

    /** Index into [blocks] of the day's MAIN night, ranked by the SAME rule the Sleep tab uses
     *  (overnight-preferring, then longest), measuring "longest" by each block's decoded asleep+awake
     *  minutes (its real in-bed span) rather than a synthetic end. [onsetByStart] gives each block's
     *  effective onset for the overnight test. Blocks whose stages don't decode are still candidates with
     *  a 0-minute span, so a day of only-undecodable blocks still resolves deterministically. Mirrors
     *  Swift `mainNightIndexByStages`. (#525) */
    internal fun mainNightIndexByStages(
        blocks: List<Pair<Long, String?>>,
        onsetByStart: Map<Long, Long>,
        offsetSec: Long,
    ): Int? {
        if (blocks.isEmpty()) return null
        fun span(b: Pair<Long, String?>): Double = minutes(b.second)?.inBed ?: 0.0
        fun onset(b: Pair<Long, String?>): Long = onsetByStart[b.first] ?: b.first
        var bestIdx = 0
        for (i in 1 until blocks.size) {
            val cand = blocks[i]
            val best = blocks[bestIdx]
            val candON = isOvernightOnset(onset(cand), offsetSec)
            val bestON = isOvernightOnset(onset(best), offsetSec)
            val candSpan = span(cand)
            val bestSpan = span(best)
            val candWins = when {
                candON != bestON -> candON
                candSpan != bestSpan -> candSpan > bestSpan
                else -> onset(cand) < onset(best)
            }
            if (candWins) bestIdx = i
        }
        return bestIdx
    }
}
