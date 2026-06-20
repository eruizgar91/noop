package com.noop.analytics

import kotlin.math.ln
import kotlin.math.pow

/*
 * CaffeineDecay.kt — caffeine window (#526): a simple, honest on-device half-life decay estimate.
 *
 * Faithful Kotlin mirror of Strand/Data/CaffeineLog.swift (the CaffeineDecay enum + CaffeineActiveEstimate
 * struct). The user logs a caffeine intake (time + OPTIONAL mg); NOOP shows a rough "still active" hint.
 * This is a GUIDE from what the user logged using a ~5–6 h population-average half-life, NOT a measurement
 * and NOT a health claim. The honesty rules — unknown dose stays unknown, future-dated logs can't amplify
 * a dose — are enforced here and pinned by CaffeineDecayTest. Cross-platform parity is the contract.
 */
object CaffeineDecay {

    /** The half-life used for the estimate, in hours. A population-average adult figure (~5–6 h); the
     *  estimate is only a rough guide because real clearance varies widely. */
    const val DEFAULT_HALF_LIFE_HOURS = 5.5

    /** Fraction (0..1) of a single dose still present [hoursElapsed] after intake. A negative elapsed time
     *  (a future-dated log) clamps to 1.0 — nothing has decayed yet — rather than amplifying the dose. */
    fun fractionRemaining(hoursElapsed: Double, halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS): Double {
        if (halfLifeHours <= 0) return 0.0
        val t = maxOf(0.0, hoursElapsed)
        return 0.5.pow(t / halfLifeHours)
    }

    /** Estimated mg still active from one dose of [doseMg], [hoursElapsed] after intake. */
    fun remainingMg(doseMg: Double, hoursElapsed: Double, halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS): Double =
        maxOf(0.0, doseMg) * fractionRemaining(hoursElapsed, halfLifeHours)

    /** Total mg still active across several intakes (each mg + hoursElapsed), at one moment. Intakes with
     *  an unknown dose are excluded from the mg total — we won't invent an amount. */
    fun totalRemainingMg(
        intakes: List<Pair<Double, Double>>, // (doseMg, hoursElapsed)
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Double = intakes.sumOf { remainingMg(it.first, it.second, halfLifeHours) }

    /** Hours until a single dose decays to [fraction] of itself (default 25%, ~two half-lives). */
    fun hoursUntilFraction(fraction: Double, halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS): Double {
        if (fraction <= 0 || fraction >= 1 || halfLifeHours <= 0) return 0.0
        return halfLifeHours * (ln(fraction) / ln(0.5))
    }

    /** True when a dose is still meaningfully active [hoursElapsed] after intake — more than [threshold]
     *  (default 25%) remains. Covers the dose-UNKNOWN case (can't show mg, but can honestly flag active). */
    fun isStillActive(
        hoursElapsed: Double,
        threshold: Double = 0.25,
        halfLifeHours: Double = DEFAULT_HALF_LIFE_HOURS,
    ): Boolean = fractionRemaining(hoursElapsed, halfLifeHours) > threshold
}

/** One logged caffeine intake — an epoch-seconds timestamp and an OPTIONAL amount in mg. */
data class CaffeineIntake(
    val id: String,
    /** When the caffeine was consumed (unix seconds). */
    val atEpochSec: Long,
    /** Amount in mg, if the user gave one. null = logged it, didn't say how much — never invented. */
    val mg: Double? = null,
)

/** A computed, honest summary of the caffeine still active right now from the logged intakes. Mirror of
 *  Swift CaffeineActiveEstimate. */
data class CaffeineActiveEstimate(
    val activeIntakeCount: Int,
    /** Total mg still active across intakes that HAD a known dose; null when none did (so the UI shows the
     *  dose-unknown phrasing rather than a fabricated mg). */
    val totalRemainingMg: Double?,
    /** Hours since the MOST RECENT still-active intake, for the "had one ~Nh ago" phrasing. */
    val hoursSinceMostRecentActive: Double?,
) {
    val hasActive: Boolean get() = activeIntakeCount > 0

    companion object {
        /** Build the estimate for [nowEpochSec] from a set of intakes using the decay model. Pure. */
        fun compute(
            intakes: List<CaffeineIntake>,
            nowEpochSec: Long,
            halfLifeHours: Double = CaffeineDecay.DEFAULT_HALF_LIFE_HOURS,
            activeThreshold: Double = 0.25,
        ): CaffeineActiveEstimate {
            var activeCount = 0
            var mgSum = 0.0
            var anyMg = false
            var mostRecentActiveHours: Double? = null

            for (intake in intakes) {
                val hours = (nowEpochSec - intake.atEpochSec) / 3600.0
                // A future-dated intake (hours < 0) isn't active yet.
                if (hours < 0) continue
                if (!CaffeineDecay.isStillActive(hours, activeThreshold, halfLifeHours)) continue
                activeCount++
                intake.mg?.let {
                    mgSum += CaffeineDecay.remainingMg(it, hours, halfLifeHours)
                    anyMg = true
                }
                if (mostRecentActiveHours == null || hours < mostRecentActiveHours!!) {
                    mostRecentActiveHours = hours
                }
            }
            return CaffeineActiveEstimate(
                activeIntakeCount = activeCount,
                totalRemainingMg = if (anyMg) mgSum else null,
                hoursSinceMostRecentActive = mostRecentActiveHours,
            )
        }
    }
}
