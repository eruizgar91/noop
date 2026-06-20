package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HrZones
import com.noop.ble.PuffinExperiment
import kotlin.math.roundToInt

/**
 * Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live
 * biometrics into on-device actions and haptic coaching. HR-zone coaching, the smart alarm
 * and the illness watch are real + persisted (ViewModel-backed); the remaining toggles
 * (stress nudge, auto-lock) are still local UI placeholders mirroring AutomationsView.swift.
 */
@Composable
fun AutomationsScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()

    // Double-tap action (parity since 4.2.8) — real + persisted via the ViewModel (NoopPrefs). The
    // dispatch runs in the ViewModel on a fresh strap DOUBLE_TAP event; this card just edits the choice.
    val doubleTapAction by viewModel.doubleTapAction.collectAsStateWithLifecycle()

    var stressNudge by remember { mutableStateOf(false) }
    var autoLockOnWristOff by remember { mutableStateOf(false) }
    // Smart alarm is real + persisted (issue #51): backed by the ViewModel, which arms the strap's
    // firmware alarm. (The toggles above are still preview-only — separate follow-up.)
    val smartAlarm by viewModel.smartAlarmEnabled.collectAsStateWithLifecycle()
    val alarmMinutes by viewModel.smartAlarmMinutes.collectAsStateWithLifecycle()
    val alarmWeekdays by viewModel.smartAlarmWeekdays.collectAsStateWithLifecycle()
    // Illness watch is real + persisted (opt-OUT — the watch has always run on Android).
    val illnessWatch by viewModel.illnessWatchEnabled.collectAsStateWithLifecycle()
    // Battery alerts are real + persisted (opt-OUT, default ON; #368, thanks @ujix).
    val batteryAlerts by viewModel.batteryAlertsEnabled.collectAsStateWithLifecycle()
    // The firmware alarm is EXPERIMENTAL: on a WHOOP 5/MG it is ONLY armed when the Experimental
    // probes toggle is on — otherwise enabling the alarm silently arms nothing (#111). Read the flag
    // so the UI can say so instead of promising a wake that never fires.
    val ctx = LocalContext.current
    val experimentalOn = PuffinExperiment.from(ctx).isEnabled

    // HR-zone coaching is real + persisted (zone-based, mirrors macOS): the ViewModel owns the toggle +
    // recovery option and buzzes the strap on entering the top zone (and Zone 1 if recovery is on).
    val profile = remember { ProfileStore.from(ctx.applicationContext) }
    val zoneCoaching by viewModel.zoneCoaching.collectAsStateWithLifecycle()
    val zoneCoachRecovery by viewModel.zoneCoachRecovery.collectAsStateWithLifecycle()
    // The Zone 5 entry threshold (≥ 90% of HR-max), from the same HrZones model used everywhere.
    val zone5Bpm = remember(profile.hrMax) {
        HrZones.zones(maxHR = profile.hrMax.toDouble()).zones.firstOrNull { it.number == 5 }?.lower?.roundToInt() ?: 0
    }

    // Inactivity reminder (#419) — real + persisted via InactivityPrefs (opt-in, default OFF). Seeded
    // once, written through on change (SharedPreferences isn't reactive). The buzz itself fires from the
    // BLE offload path (WhoopBleClient.maybeBuzzInactivity → the shipped SedentaryDetector engine); this
    // screen only edits the prefs the engine reads.
    var inactivityEnabled by remember { mutableStateOf(InactivityPrefs.enabled(ctx)) }
    var inactivityThreshold by remember { mutableStateOf(InactivityPrefs.thresholdMinutes(ctx)) }
    var inactivityReNudge by remember { mutableStateOf(InactivityPrefs.reNudgeMinutes(ctx)) }
    var inactivityBuzzLoops by remember { mutableStateOf(InactivityPrefs.buzzLoops(ctx)) }
    var inactivityActiveHours by remember { mutableStateOf(InactivityPrefs.activeHoursEnabled(ctx)) }
    var inactivityActiveStart by remember { mutableStateOf(InactivityPrefs.activeStartMinutes(ctx)) }
    var inactivityActiveEnd by remember { mutableStateOf(InactivityPrefs.activeEndMinutes(ctx)) }
    var inactivityOnlyWorn by remember { mutableStateOf(NotifPrefs.getBool(ctx, NotifPrefs.WORN, true)) }
    // The engine also requires the global notification master (default OFF); surface that dependency so
    // enabling the reminder while master is off isn't silently inert.
    val notifMasterOn = NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false)

    ScreenScaffold(
        title = "Automations",
        subtitle = "Make the strap do things — tap to act, walk away to lock, train by feel.",
    ) {
        // Double-tap (parity since 4.2.8): a real, persisted action picker bound to the ViewModel, with a
        // Test action button. Mirrors AutomationsView.swift's Picker (Apple-applicable subset only; no
        // lockScreen / runShortcut on Android).
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Double-tap",
            blurb = "Double-tap the strap to trigger an action on this device. (The strap exposes a single double-tap gesture.)",
            active = doubleTapAction != DoubleTapAction.NONE,
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("When I double-tap", style = NoopType.body, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                DoubleTapActionPicker(
                    selected = doubleTapAction,
                    onSelect = { viewModel.setDoubleTapAction(it) },
                )
            }
            RowDivider()
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(
                    onClick = { viewModel.testDoubleTapAction() },
                    enabled = doubleTapAction != DoubleTapAction.NONE,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Test action", style = NoopType.body)
                }
                Spacer(Modifier.weight(1f))
                StatePill(
                    if (live.bonded) "Strap bonded" else "Not connected",
                    tone = if (live.bonded) StrandTone.Positive else StrandTone.Warning,
                )
            }
        }

        // Haptic coaching.
        SettingsSection(
            icon = Icons.Filled.Bolt,
            title = "Haptic coaching",
            blurb = "Train by feel — the strap buzzes so you don't have to watch a screen.",
            active = zoneCoaching || stressNudge,
        ) {
            ToggleRow(
                label = "HR-zone coaching",
                help = "A triple-buzz when you climb into your top zone (Zone 5, ≥ $zone5Bpm bpm) — a cue to ease off. Max HR comes from Settings.",
                checked = zoneCoaching,
                onChange = { viewModel.setZoneCoaching(it) },
            )
            if (zoneCoaching) {
                RowDivider()
                ToggleRow(
                    label = "Recovery buzz",
                    help = "Also buzz once when your heart rate drops back to Zone 1 — a cue that you've recovered.",
                    checked = zoneCoachRecovery,
                    onChange = { viewModel.setZoneCoachRecovery(it) },
                )
            }
            RowDivider()
            ToggleRow(
                label = "Resting stress nudge (experimental)",
                help = "A gentle buzz when your HRV drops while your heart rate is calm — a cue to take a paced breath. Rate-limited to once every 15 minutes; off by default.",
                checked = stressNudge,
                onChange = { stressNudge = it },
            )
        }

        // Wear & presence.
        SettingsSection(
            icon = Icons.Filled.TouchApp,
            title = "Wear & presence",
            blurb = "React when the strap comes off or goes on.",
            active = autoLockOnWristOff,
        ) {
            ToggleRow(
                label = "Lock the device when I take the strap off",
                help = "Fires the moment the strap leaves your wrist.",
                checked = autoLockOnWristOff,
                onChange = { autoLockOnWristOff = it },
            )
        }

        // Smart alarm.
        SettingsSection(
            icon = Icons.Filled.Alarm,
            title = "Smart alarm",
            blurb = "Wake to a buzz from the strap's own firmware alarm, even if NOOP is closed. Still experimental on WHOOP 4.0, so keep a backup alarm until you've confirmed it wakes you.",
            active = smartAlarm,
        ) {
            ToggleRow(
                label = "Enable smart alarm",
                help = "Arms the strap to buzz at your wake time.",
                checked = smartAlarm,
                onChange = { viewModel.setSmartAlarmEnabled(it) },
            )
            if (smartAlarm) {
                RowDivider()
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Wake at", style = NoopType.body, color = Palette.textPrimary)
                    Spacer(Modifier.weight(1f))
                    TimeChip(
                        minutes = alarmMinutes,
                        accessibilityLabel = "Smart alarm wake time",
                        onPicked = { viewModel.setSmartAlarmMinutes(it) },
                    )
                }
                RowDivider()
                AlarmWeekdayPicker(
                    selected = alarmWeekdays,
                    onToggle = { dow -> viewModel.setSmartAlarmWeekdays(toggledSmartAlarmWeekday(dow, alarmWeekdays)) },
                )
                RowDivider()
                // A WHOOP 5/MG only arms when Experimental probes are on; without it the time is saved
                // but the strap is NEVER armed, so call that out in amber rather than promise a wake (#111).
                if (live.whoop5Detected && !experimentalOn) {
                    Text(
                        "Your WHOOP 5/MG won't arm this until Experimental mode is on (Settings → " +
                            "Experimental). Right now your wake time is saved but the strap is NOT armed.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                } else {
                    Text(
                        if (live.bonded)
                            "Armed on the strap itself, so it can buzz at your wake time even if your phone is asleep or NOOP is closed. Still experimental — we can't yet guarantee it fires, so keep a backup alarm."
                        else
                            "Connect your strap to arm this — it's set on the strap's own firmware alarm. Still experimental, so keep a backup alarm until you've confirmed it wakes you.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }

        // Inactivity reminder (#419) — real + persisted via InactivityPrefs; opt-in, default OFF.
        SettingsSection(
            icon = Icons.Filled.Timer,
            title = "Inactivity reminder",
            blurb = "A gentle wrist buzz when you've been sitting too long — a nudge to get up and move. Inferred from the strap's motion on each history sync, so it lags real time by a sync or two.",
            active = inactivityEnabled,
        ) {
            ToggleRow(
                label = "Enable inactivity reminder",
                help = "Buzzes after you've been sitting past your threshold.",
                checked = inactivityEnabled,
                onChange = {
                    inactivityEnabled = it
                    InactivityPrefs.setBool(ctx, InactivityPrefs.ENABLED, it)
                },
            )
            if (inactivityEnabled) {
                if (!notifMasterOn) {
                    RowDivider()
                    Text(
                        "Notifications are off, so this can't buzz yet — turn on the master switch in " +
                            "Settings → Notifications to let it through.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                    )
                }
                RowDivider()
                StepperRow(
                    label = "Sitting for",
                    help = "Minutes seated before the first nudge.",
                    value = inactivityThreshold, suffix = "min", range = 15..120, step = 15,
                    onChange = {
                        inactivityThreshold = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.THRESHOLD_MIN, it)
                    },
                )
                RowDivider()
                StepperRow(
                    label = "Re-nudge every",
                    help = "If you're still seated, buzz again this often.",
                    value = inactivityReNudge, suffix = "min", range = 15..120, step = 15,
                    onChange = {
                        inactivityReNudge = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.RENUDGE_MIN, it)
                    },
                )
                RowDivider()
                StepperRow(
                    label = "Buzz strength",
                    help = "How strong the buzz is.",
                    value = inactivityBuzzLoops, suffix = "×", range = 1..4, step = 1,
                    onChange = {
                        inactivityBuzzLoops = it
                        InactivityPrefs.setInt(ctx, InactivityPrefs.BUZZ_LOOPS, it)
                    },
                )
                RowDivider()
                ToggleRow(
                    label = "Only when worn",
                    help = "Don't buzz when the strap is off your wrist.",
                    checked = inactivityOnlyWorn,
                    onChange = {
                        inactivityOnlyWorn = it
                        // Reuses the shared notification only-when-worn gate (NotifPrefs.WORN).
                        NotifPrefs.setBool(ctx, NotifPrefs.WORN, it)
                    },
                )
                RowDivider()
                ToggleRow(
                    label = "Only during active hours",
                    help = "Only nudge during your active hours.",
                    checked = inactivityActiveHours,
                    onChange = {
                        inactivityActiveHours = it
                        InactivityPrefs.setBool(ctx, InactivityPrefs.ACTIVE_HOURS_ENABLED, it)
                    },
                )
                if (inactivityActiveHours) {
                    RowDivider()
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("From", style = NoopType.body, color = Palette.textPrimary)
                        Spacer(Modifier.weight(1f))
                        TimeChip(
                            minutes = inactivityActiveStart,
                            accessibilityLabel = "Active hours start",
                            onPicked = {
                                inactivityActiveStart = it
                                InactivityPrefs.setInt(ctx, InactivityPrefs.ACTIVE_START_MIN, it)
                            },
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("to", style = NoopType.body, color = Palette.textSecondary)
                        Spacer(Modifier.width(8.dp))
                        TimeChip(
                            minutes = inactivityActiveEnd,
                            accessibilityLabel = "Active hours end",
                            onPicked = {
                                inactivityActiveEnd = it
                                InactivityPrefs.setInt(ctx, InactivityPrefs.ACTIVE_END_MIN, it)
                            },
                        )
                    }
                }
            }
        }

        // Illness early-warning (real + persisted; opt-OUT — the watch has always run on Android).
        SettingsSection(
            icon = Icons.Filled.MonitorHeart,
            title = "Illness early-warning",
            blurb = "Watches your resting HR, HRV, skin temperature and respiration against your own 28-day baseline. On-device and approximate — informational only, not a diagnosis.",
            active = illnessWatch,
        ) {
            ToggleRow(
                label = "Watch for early-illness signs",
                help = "Needs at least 14 days of history. When two or more signals drift together you get a banner on Today and a notification — at most once a day.",
                checked = illnessWatch,
                onChange = { viewModel.setIllnessWatchEnabled(it) },
            )
        }

        // Battery alerts (real + persisted; opt-OUT, default ON — #368, thanks @ujix).
        SettingsSection(
            icon = Icons.Filled.BatteryStd,
            title = "Battery alerts",
            blurb = "A heads-up when the strap battery gets low so you can recharge before bed, and a note when it's finished charging.",
            active = batteryAlerts,
        ) {
            ToggleRow(
                label = "Notify on low and full battery",
                help = "Sends a notification when the strap drops to 15% or reaches a full charge — at most once per charge cycle.",
                checked = batteryAlerts,
                onChange = { viewModel.setBatteryAlertsEnabled(it) },
            )
        }
    }
}

// MARK: - Section + rows (mirror the settings idiom from AutomationsView.swift)

@Composable
private fun SettingsSection(
    icon: ImageVector,
    title: String,
    blurb: String,
    active: Boolean = false,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline("Automation")
                    if (active) Overline("ON", color = Palette.accent)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = if (active) Palette.accent else Palette.textSecondary,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

/** A compact dropdown that mirrors the iOS double-tap Picker: a tappable label + chevron that opens a
 *  menu of [DoubleTapAction]s. Labels come from [DoubleTapAction.label] so both clients read the same. */
@Composable
private fun DoubleTapActionPicker(
    selected: DoubleTapAction,
    onSelect: (DoubleTapAction) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .clickable { expanded = true }
                .background(Palette.surfaceInset)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(selected.label, style = NoopType.body, color = Palette.textPrimary)
            Spacer(Modifier.width(4.dp))
            Icon(
                Icons.Filled.ArrowDropDown,
                contentDescription = "Choose double-tap action",
                tint = Palette.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for (action in DoubleTapAction.entries) {
                DropdownMenuItem(
                    text = {
                        Text(
                            action.label,
                            style = NoopType.body,
                            color = if (action == selected) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = { onSelect(action); expanded = false },
                )
            }
        }
    }
}

@Composable
private fun ToggleRow(
    label: String,
    help: String,
    checked: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(16.dp))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.surfaceBase,
                checkedTrackColor = Palette.accent,
                uncheckedThumbColor = Palette.textSecondary,
                uncheckedTrackColor = Palette.surfaceInset,
                uncheckedBorderColor = Palette.hairline,
            ),
        )
    }
}

@Composable
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .padding(vertical = 4.dp)
            .background(Palette.hairline),
    )
}

/**
 * Weekday selector for the smart alarm (#539). One tappable circle per weekday, Monday-first. An empty
 * [selected] set means "every day" (all circles read as on). Mirrors the macOS AutomationsView picker.
 */
@Composable
private fun AlarmWeekdayPicker(selected: Set<Int>, onToggle: (Int) -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (dow in SMART_ALARM_WEEKDAY_ORDER) {
                val on = smartAlarmWeekdayIsSelected(dow, selected)
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(if (on) Palette.accent else Palette.surfaceInset)
                        .clickable { onToggle(dow) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        smartAlarmWeekdayInitial(dow),
                        style = NoopType.caption,
                        color = if (on) Palette.surfaceBase else Palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
        Text(smartAlarmWeekdaySummary(selected), style = NoopType.caption, color = Palette.textTertiary)
    }
}

/** Calendar.DAY_OF_WEEK numbers laid out Monday-first (Mon…Sun → 2,3,4,5,6,7,1). */
private val SMART_ALARM_WEEKDAY_ORDER = intArrayOf(2, 3, 4, 5, 6, 7, 1)

/** A day reads as "on" when the set is empty (= every day) or explicitly contains it. Pure for tests. */
internal fun smartAlarmWeekdayIsSelected(dow: Int, days: Set<Int>): Boolean =
    days.isEmpty() || days.contains(dow)

/**
 * Toggle one weekday, normalising "every day" at both ends so the empty set always means every day.
 * Pure + side-effect-free for unit tests. Pulling a day out of the implicit "every day" expands to the
 * explicit other six; selecting the seventh collapses back to the empty "every day" set. Mirrors macOS
 * `AutomationsView.toggledWeekday`.
 */
internal fun toggledSmartAlarmWeekday(dow: Int, days: Set<Int>): Set<Int> {
    val next: MutableSet<Int> = when {
        days.isEmpty() -> (1..7).toMutableSet().also { it.remove(dow) }
        days.contains(dow) -> days.toMutableSet().also { it.remove(dow) }
        else -> days.toMutableSet().also { it.add(dow) }
    }
    return if (next.size == 7) emptySet() else next
}

/** Human-readable summary of the selection. Pure for tests. Mirrors macOS `weekdaySummary`. */
internal fun smartAlarmWeekdaySummary(days: Set<Int>): String = when {
    days.isEmpty() || days.size == 7 -> "Every day"
    days == setOf(2, 3, 4, 5, 6) -> "Weekdays"
    days == setOf(1, 7) -> "Weekends"
    else -> SMART_ALARM_WEEKDAY_ORDER.filter { days.contains(it) }
        .joinToString(", ") { smartAlarmWeekdayName(it) }
}

private fun smartAlarmWeekdayInitial(dow: Int): String = when (dow) {
    1 -> "S"; 2 -> "M"; 3 -> "T"; 4 -> "W"; 5 -> "T"; 6 -> "F"; 7 -> "S"; else -> "?"
}

private fun smartAlarmWeekdayName(dow: Int): String = when (dow) {
    1 -> "Sun"; 2 -> "Mon"; 3 -> "Tue"; 4 -> "Wed"; 5 -> "Thu"; 6 -> "Fri"; 7 -> "Sat"; else -> "?"
}

/** A label/help row with a −[value]+ stepper, clamped to [range] and moved by [step]. */
@Composable
private fun StepperRow(
    label: String,
    help: String,
    value: Int,
    suffix: String,
    range: IntRange,
    step: Int,
    onChange: (Int) -> Unit,
) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = NoopType.body, color = Palette.textPrimary)
            Text(help, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Spacer(Modifier.width(12.dp))
        StepButton(Icons.Filled.Remove, "Decrease $label", enabled = value > range.first) {
            onChange((value - step).coerceAtLeast(range.first))
        }
        Text(
            "$value $suffix",
            style = NoopType.body,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 8.dp).widthIn(min = 56.dp),
        )
        StepButton(Icons.Filled.Add, "Increase $label", enabled = value < range.last) {
            onChange((value + step).coerceAtMost(range.last))
        }
    }
}

@Composable
private fun StepButton(icon: ImageVector, contentDescription: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = if (enabled) Palette.accent else Palette.textTertiary,
        )
    }
}
