package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #525 — sleep numbers must agree across screens. A day can hold an overnight AND a daytime nap; the
 * day's canonical sleep total must be the MAIN night (the same block the Sleep tab's hero shows),
 * never the night + nap SUM. Naps stay their own session rows, labelled separately.
 *
 * Faithful Kotlin mirror of the #525 cases in SleepStageTotalsTests.swift / AnalyticsEngineTests.swift:
 * same selection rule (overnight-preferring, then longest), same fixtures, same invariant.
 */
class MainNightConsistencyTest {

    /** 2026-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). tzOffset 0 → local==UTC. */
    private val refMidnight = 1_749_513_600L
    private fun atHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    // ── main-night selection (the single shared rule) ────────────────────────────────────────────

    @Test
    fun mainNightPrefersOvernightOverLongerDaytimeNap() {
        val nightStart = atHour(23) - 86_400L  // 2026-06-09 23:00 overnight onset
        val napStart = atHour(13)              // 13:00 daytime onset
        // The nap is LONGER in clock span, but the overnight block must still win.
        val blocks = listOf(
            SleepStageTotals.NightBlock(napStart, napStart + 5 * 3600),    // 5h daytime
            SleepStageTotals.NightBlock(nightStart, nightStart + 4 * 3600), // 4h overnight
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    @Test
    fun mainNightLongestAmongOvernightBlocks() {
        val a = atHour(22) - 86_400L
        val b = atHour(23) - 86_400L + 1_800L
        val blocks = listOf(
            SleepStageTotals.NightBlock(a, a + 3 * 3600),  // 3h
            SleepStageTotals.NightBlock(b, b + 6 * 3600),  // 6h longer overnight wins
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    @Test
    fun mainNightEmptyAndTieAreDeterministic() {
        assertNull(SleepStageTotals.mainNightIndex(emptyList(), 0L))
        // Two equal-length overnight blocks → the EARLIER onset wins (stable across platforms).
        val a = atHour(22) - 86_400L
        val b = atHour(23) - 86_400L
        val blocks = listOf(
            SleepStageTotals.NightBlock(b, b + 4 * 3600),
            SleepStageTotals.NightBlock(a, a + 4 * 3600),
        )
        assertEquals(1, SleepStageTotals.mainNightIndex(blocks, 0L))
    }

    // ── the #525 seam invariant: total == main night, not the sum ────────────────────────────────

    @Test
    fun overnightPlusNapReportsConsistentTotalsNotTheSum() {
        val nightStart = atHour(23) - 86_400L
        val napStart = atHour(14)
        val nightStages = """{"awake":24,"light":214,"deep":82,"rem":96}""" // 392 min asleep
        val napStages = """{"awake":2,"light":30,"deep":10,"rem":8}"""       // 48 min asleep

        val mainOnly = SleepStageTotals.dailyAggregate(listOf(nightStages))!!
        assertEquals(392.0, mainOnly.totalSleepMin, 1e-6)

        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(nightStart to nightStages, napStart to napStages),
            edited = emptyMap(),
            onsetByStart = mapOf(nightStart to nightStart, napStart to napStart),
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertEquals("day total = MAIN night, not night+nap sum", mainOnly.totalSleepMin, r!!.sleep.totalSleepMin, 1e-6)
        assertEquals(mainOnly.deepMin, r.sleep.deepMin, 1e-6)
        assertEquals(mainOnly.remMin, r.sleep.remMin, 1e-6)
        assertNotEquals("must NOT sum the nap in", 440.0, r.sleep.totalSleepMin, 1e-6)
    }

    @Test
    fun honoringEditsMainNightModeTracksEditedNightNotNapSum() {
        val nightStart = atHour(23) - 86_400L
        val napStart = atHour(14)
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(
                nightStart to """{"awake":24,"light":214,"deep":82,"rem":96}""",
                napStart to """{"awake":2,"light":30,"deep":10,"rem":8}""",
            ),
            edited = mapOf(nightStart to """{"awake":0,"light":118,"deep":82,"rem":96}"""), // trimmed to 296
            onsetByStart = mapOf(nightStart to nightStart, napStart to napStart),
            offsetSec = 0L,
        )
        assertNotNull(r)
        assertTrue(r!!.editApplied)
        assertEquals("tracks the EDITED main night, nap excluded", 296.0, r.sleep.totalSleepMin, 1e-6)
    }

    @Test
    fun honoringEditsLegacySumWhenNoOnsets() {
        // With NO onsets the seam keeps the legacy sum-of-all-blocks total (older callers unchanged).
        val r = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = listOf(
                100L to """{"awake":2,"light":30,"deep":10,"rem":8}""",
                1000L to """{"awake":24,"light":214,"deep":82,"rem":96}""",
            ),
            edited = emptyMap(),
        )
        assertNotNull(r)
        assertEquals(48.0 + 392.0, r!!.sleep.totalSleepMin, 1e-6)
    }

    // The end-to-end analyzeDay variant (overnight + synthetic daytime nap, asserting 2 detected) was
    // dropped on both platforms: it leaned on the SleepStager detecting a synthetic nap, which the
    // daytime-false-sleep guard rejects by design, so it tested detection (a #508 concern), not #525's
    // aggregation. The seam tests above cover the main-night-not-sum reconciliation deterministically.
}
