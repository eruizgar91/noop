package com.noop.ui

import com.noop.data.AppleDaily
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Unit tests for the Today Weight + Steps tile fallback logic (issues #107, #150). The Calories tile
 * reads straight off DailyMetric, so the pure logic worth pinning is the two tiles with an imported
 * fallback source:
 *   - [latestWeightKg] picks the most-recent non-null body weight across the two Apple-side sources.
 *   - [weightTile] prefers that weight, else falls back to the SI profile weight with an honest
 *     "from profile" caption, always formatted through the unit toggle.
 *   - [stepsForDay] resolves the selected day's imported Apple Health / Health Connect step total —
 *     the Steps tile's fallback when the strap (e.g. a WHOOP 4.0) didn't bank an on-device count.
 */
class TodayMetricTilesTest {

    private fun appleDay(day: String, weightKg: Double?) =
        AppleDaily(deviceId = "apple-health", day = day, weightKg = weightKg)

    private fun stepsDay(deviceId: String, day: String, steps: Int?) =
        AppleDaily(deviceId = deviceId, day = day, steps = steps)

    // MARK: latestWeightKg

    @Test
    fun latestWeight_nullWhenNoSourceHasWeight() {
        val apple = listOf(appleDay("2026-01-01", null), appleDay("2026-01-02", null))
        assertNull(latestWeightKg(apple, emptyList()))
    }

    @Test
    fun latestWeight_picksTheMostRecentDay() {
        val apple = listOf(
            appleDay("2026-01-01", 80.0),
            appleDay("2026-01-05", 78.5),
            appleDay("2026-01-03", 79.0),
        )
        assertEquals(78.5, latestWeightKg(apple, emptyList())!!, 1e-9)
    }

    @Test
    fun latestWeight_skipsNullWeightDaysEvenWhenNewer() {
        // A newer day with no weight must not blank out an older real reading.
        val apple = listOf(appleDay("2026-01-02", 81.0), appleDay("2026-01-09", null))
        assertEquals(81.0, latestWeightKg(apple, emptyList())!!, 1e-9)
    }

    @Test
    fun latestWeight_unionsBothSources_mostRecentWins() {
        val apple = listOf(appleDay("2026-01-04", 80.0))
        val healthConnect = listOf(
            AppleDaily(deviceId = "health-connect", day = "2026-01-06", weightKg = 77.0),
        )
        assertEquals(77.0, latestWeightKg(apple, healthConnect)!!, 1e-9)
    }

    // MARK: weightTile

    @Test
    fun weightTile_usesLatestReading_metric() {
        val t = weightTile(latestWeightKg = 74.5, profileWeightKg = 90.0, system = UnitSystem.METRIC)
        assertEquals("74.5 kg", t.value)
        assertEquals("latest", t.caption)
    }

    @Test
    fun weightTile_usesLatestReading_imperial() {
        val t = weightTile(latestWeightKg = 100.0, profileWeightKg = 90.0, system = UnitSystem.IMPERIAL)
        // 100 kg * 2.20462 = 220.462 lb
        assertEquals("220.5 lb", t.value)
        assertEquals("latest", t.caption)
    }

    @Test
    fun weightTile_fallsBackToProfile_withHonestCaption() {
        val t = weightTile(latestWeightKg = null, profileWeightKg = 75.0, system = UnitSystem.METRIC)
        assertEquals("75.0 kg", t.value)
        assertEquals("from profile", t.caption)
    }

    @Test
    fun weightTile_profileFallbackRespectsImperial() {
        val t = weightTile(latestWeightKg = null, profileWeightKg = 75.0, system = UnitSystem.IMPERIAL)
        // 75 kg * 2.20462 = 165.3465 lb
        assertEquals("165.3 lb", t.value)
        assertEquals("from profile", t.caption)
    }

    // MARK: stepsForDay — Today Steps-tile fallback to imported Apple Health / Health Connect (#150)

    @Test
    fun stepsForDay_nullWhenNeitherSourceCoversTheDay() {
        val apple = listOf(stepsDay("apple-health", "2026-01-01", 8000))
        assertNull(stepsForDay(apple, emptyList(), "2026-01-02"))
    }

    @Test
    fun stepsForDay_returnsImportedStepsForTheSelectedDay() {
        val apple = listOf(
            stepsDay("apple-health", "2026-01-01", 8000),
            stepsDay("apple-health", "2026-01-02", 11200),
        )
        assertEquals(11200, stepsForDay(apple, emptyList(), "2026-01-02"))
    }

    @Test
    fun stepsForDay_ignoresNullStepRowsForTheDay() {
        // A row exists for the day but carries no step count → treated as absent, not zero.
        val apple = listOf(stepsDay("apple-health", "2026-01-03", null))
        assertNull(stepsForDay(apple, emptyList(), "2026-01-03"))
    }

    @Test
    fun stepsForDay_unionsBothSources_takesTheLargerForTheDay() {
        // Both Apple Health and Health Connect can report the same day; take the larger (most complete)
        // rather than summing, so we never double-count overlapping sources.
        val apple = listOf(stepsDay("apple-health", "2026-01-04", 6000))
        val hc = listOf(stepsDay("health-connect", "2026-01-04", 9500))
        assertEquals(9500, stepsForDay(apple, hc, "2026-01-04"))
    }

    // MARK: buildingHint — the unscored Effort/Rest "it's coming" caption, today-only (#527)

    @Test
    fun buildingHint_rest_today_isTheWearItTonightCopy() {
        assertEquals("Building, wear it tonight", buildingHint(KeyMetric.REST, isToday = true))
    }

    @Test
    fun buildingHint_effort_today_isTheMovesAsYouDoCopy() {
        assertEquals("Building, moves as you do", buildingHint(KeyMetric.EFFORT, isToday = true))
    }

    @Test
    fun buildingHint_pastDay_isNull_soAnUnscoredOldDayStaysABareDash() {
        // Honesty: a navigated past day with no score is missing data, not mid-calibration.
        assertNull(buildingHint(KeyMetric.REST, isToday = false))
        assertNull(buildingHint(KeyMetric.EFFORT, isToday = false))
    }

    @Test
    fun buildingHint_otherMetrics_null_onlyEffortAndRestGetTheHint() {
        // Charge owns its own "Calibrating N of 4" treatment; other tiles never show this hint.
        assertNull(buildingHint(KeyMetric.CHARGE, isToday = true))
        assertNull(buildingHint(KeyMetric.HRV, isToday = true))
    }

    @Test
    fun buildingHint_copy_hasNoEmDash() {
        // House style: user-facing strings carry no em-dashes.
        for (m in listOf(KeyMetric.REST, KeyMetric.EFFORT)) {
            val hint = buildingHint(m, isToday = true)!!
            assert(!hint.contains('—')) { "buildingHint($m) must not contain an em-dash: $hint" }
        }
    }
}
