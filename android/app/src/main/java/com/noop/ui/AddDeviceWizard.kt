package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.StandardHrSource
import com.noop.ble.WhoopBleClient
import com.noop.ble.WhoopModel
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.launch

// MARK: - Add a device — guided, branching wizard (MW-4)
//
// Different bands pair COMPLETELY differently, so this wizard asks the device TYPE first, then gives
// type-specific prep guidance and runs the RIGHT scan/connect for that type:
//
//   • WHOOP 4.0 / WHOOP 5.0 (MG)  → the WHOOP present-scan ([AppViewModel.presentWhoopScan]) targeted at
//     the chosen family. Lists nearby straps from [AppViewModel.discoveredWhoops] (a present-only mode
//     that never auto-connects).
//   • Heart-rate strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) → its OWN isolated
//     [StandardHrSource] scanning the standard 0x180D HR service. Lists from its `discovered` flow.
//
// Registration goes through [AppViewModel.registerDevice] → DeviceRegistry; the SourceCoordinator reacts
// to the active-device change and connects (pinning the WHOOP / starting the strap source). The wizard
// never touches the BLE client directly — only the AppViewModel pass-throughs. WHOOP-FIRST: WHOOP is the
// primary band; the type list shows it first and a footer reiterates it. Renders cleanly with nothing
// nearby (the type picker, every prep step, and the searching/empty pick state all need no hardware).
// Faithful Kotlin twin of Strand/Screens/AddDeviceWizard.swift. US English throughout.

/** What the user is adding. Drives the prep copy AND which scan/register path runs. */
private enum class DeviceType {
    Whoop5MG, Whoop4, HrStrap, GymEquipment,
    // EXPERIMENTAL tier — best-effort, clean-room, can't be hardware-verified here. Each fails to an
    // honest message and never fabricates data.
    Amazfit, MiBand, Garmin, Oura;

    val isWhoop: Boolean get() = this == Whoop4 || this == Whoop5MG
    val whoopModel: WhoopModel?
        get() = when (this) {
            Whoop4 -> WhoopModel.WHOOP4
            Whoop5MG -> WhoopModel.WHOOP5_MG
            else -> null
        }

    /** True for the EXPERIMENTAL tier (shown under a clearly-labelled "Experimental" heading). */
    val isExperimental: Boolean get() = this == Amazfit || this == MiBand || this == Garmin || this == Oura

    val title: String
        get() = when (this) {
            Whoop5MG -> "WHOOP 5.0 / MG"
            Whoop4 -> "WHOOP 4.0"
            HrStrap -> "Heart-rate strap"
            GymEquipment -> "Gym equipment"
            Amazfit -> "Amazfit / Zepp"
            MiBand -> "Xiaomi Mi Band"
            Garmin -> "Garmin watch"
            Oura -> "Oura ring"
        }
}

private enum class WizardStep { Type, Prep, Pick, Confirm }

@Composable
fun AddDeviceWizard(viewModel: AppViewModel, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()

    var step by remember { mutableStateOf(WizardStep.Type) }
    var type by remember { mutableStateOf<DeviceType?>(null) }

    // The chosen strap, in whichever shape its path produces.
    var pickedWhoop by remember { mutableStateOf<WhoopBleClient.DiscoveredWhoop?>(null) }
    var pickedStrap by remember { mutableStateOf<StandardHrSource.DiscoveredStrap?>(null) }
    var pickedMachine by remember { mutableStateOf<com.noop.ble.FtmsSource.DiscoveredMachine?>(null) }
    var pickedHuami by remember { mutableStateOf<com.noop.ble.HuamiHrSource.DiscoveredDevice?>(null) }

    var nameDraft by remember { mutableStateOf("") }
    var askMakeActive by remember { mutableStateOf(false) }

    // Discovery-only HR source for the strap path (also Garmin Broadcast HR). Never persists, never
    // connects — we only read its `discovered` / `scanning` StateFlows while scanning. Created once.
    val hrScanner = remember { viewModel.makeStrapScanner() }
    // Discovery-only FTMS source for the gym-equipment path. Same throwaway contract.
    val ftmsScanner = remember { viewModel.makeFtmsScanner() }
    // Discovery-only EXPERIMENTAL Huami scanner (Amazfit / Zepp / Mi Band).
    val huamiScanner = remember { viewModel.makeHuamiScanner() }
    // Discovery-only EXPERIMENTAL Oura probe (detect → honest dead-end → file import).
    val ouraScanner = remember { viewModel.makeOuraScanner() }

    fun startScan(t: DeviceType) {
        when {
            t.isWhoop -> viewModel.presentWhoopScan(t.whoopModel ?: WhoopModel.WHOOP4)
            t == DeviceType.GymEquipment -> ftmsScanner.scan()
            t == DeviceType.Amazfit || t == DeviceType.MiBand -> huamiScanner.scan()
            t == DeviceType.Oura -> ouraScanner.scan()
            else -> hrScanner.scan()   // HrStrap AND Garmin (Broadcast HR is the standard 0x180D path)
        }
    }

    fun stopAllScans() {
        viewModel.stopWhoopScan()
        hrScanner.stopScan()
        ftmsScanner.stopScan()
        huamiScanner.stopScan()
        ouraScanner.stop()
    }

    // Belt-and-braces: stop whichever scan is live whenever the wizard leaves composition.
    DisposableEffect(Unit) { onDispose { stopAllScans() } }

    fun goBack() {
        when (step) {
            WizardStep.Type -> Unit
            WizardStep.Prep -> step = WizardStep.Type
            WizardStep.Pick -> { stopAllScans(); step = WizardStep.Prep }
            WizardStep.Confirm -> {
                // Re-enter the pick step and restart its scan so the user can choose a different device.
                type?.let { startScan(it) }
                pickedWhoop = null; pickedStrap = null; pickedMachine = null; pickedHuami = null
                step = WizardStep.Pick
            }
        }
    }

    val confirmAdvertisedName = run {
        pickedWhoop?.let { return@run it.name?.takeIf { n -> n.isNotBlank() } ?: (type?.title ?: "Device") }
        pickedStrap?.let { return@run it.name }
        pickedMachine?.let { return@run it.name }
        pickedHuami?.let { return@run it.name }
        type?.title ?: "Device"
    }
    val confirmName = nameDraft.trim().ifEmpty { confirmAdvertisedName }
    val confirmBrand = when {
        type?.isWhoop == true -> "WHOOP"
        type == DeviceType.GymEquipment -> "Gym equipment"
        type == DeviceType.Amazfit -> "Amazfit"
        type == DeviceType.MiBand -> "Mi Band"
        type == DeviceType.Garmin -> "Garmin"
        pickedStrap != null -> brandGuess(pickedStrap!!.name)
        else -> "Heart-rate strap"
    }
    val confirmRssi = pickedWhoop?.rssi ?: pickedStrap?.rssi ?: pickedMachine?.rssi ?: pickedHuami?.rssi ?: -70

    fun finishAdd(makeActive: Boolean) {
        stopAllScans()
        val now = System.currentTimeMillis() / 1000
        val pw = pickedWhoop
        val ps = pickedStrap
        val pm = pickedMachine
        val ph = pickedHuami
        val isGarmin = type == DeviceType.Garmin
        val device: PairedDeviceRow? = when {
            pw != null && type?.whoopModel != null -> {
                // WHOOP: full capability set; id namespaced by address; model "4.0" / "5.0 MG".
                val wm = type!!.whoopModel!!
                val modelLabel = if (wm == WhoopModel.WHOOP4) "4.0" else "5.0 MG"
                PairedDeviceRow(
                    id = "whoop-${pw.address}",
                    brand = "WHOOP",
                    model = modelLabel,
                    nickname = confirmName,
                    peripheralId = pw.address,
                    sourceKind = SourceKind.liveBLE.name,
                    capabilities = "hr,hrv,spo2,skinTemp,sleep,strainLoad",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            ps != null -> {
                // Generic HR strap OR a Garmin broadcasting standard HR. Garmin is registered as a
                // `liveBLE` device (its live HR IS the standard 0x180D path) but branded "Garmin"; both
                // are HR + HRV.
                PairedDeviceRow(
                    id = "${if (isGarmin) "garmin" else "strap"}-${ps.address}",
                    brand = if (isGarmin) "Garmin" else brandGuess(ps.name),
                    model = ps.name,
                    nickname = if (confirmName == ps.name) null else confirmName,
                    peripheralId = ps.address,
                    sourceKind = SourceKind.liveBLE.name,
                    capabilities = "hr,hrv",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            ph != null -> {
                // EXPERIMENTAL Amazfit / Zepp / Mi Band. sourceKind "huami" routes the SourceCoordinator
                // to the HuamiHrSource. HR only (the Huami custom characteristic carries no R-R).
                val brand = if (type == DeviceType.MiBand) "Mi Band" else "Amazfit"
                PairedDeviceRow(
                    id = "huami-${ph.address}",
                    brand = brand,
                    model = ph.name,
                    nickname = if (confirmName == ph.name) null else confirmName,
                    peripheralId = ph.address,
                    sourceKind = SourceKind.huami.name,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            pm != null -> {
                // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
                // live-workout path. sourceKind "ftms" routes the SourceCoordinator to the FtmsSource.
                PairedDeviceRow(
                    id = "ftms-${pm.address}",
                    brand = "Gym equipment",
                    model = pm.name,
                    nickname = if (confirmName == pm.name) null else confirmName,
                    peripheralId = pm.address,
                    sourceKind = SourceKind.ftms.name,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            else -> null
        }
        if (device == null) { onClose(); return }
        scope.launch { viewModel.registerDevice(device, makeActive = makeActive) }
        onClose()
    }

    AlertDialog(
        onDismissRequest = { stopAllScans(); onClose() },
        containerColor = Palette.surfaceOverlay,
        title = {
            Row(verticalAlignment = Alignment.Top) {
                if (step != WizardStep.Type) {
                    IconButton(onClick = { goBack() }, modifier = Modifier.size(28.dp)) {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                            contentDescription = "Back",
                            tint = Palette.textSecondary,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(headerTitle(step, type), style = NoopType.title2, color = Palette.textPrimary)
                    headerSubtitle(step)?.let {
                        Text(it, style = NoopType.caption, color = Palette.textTertiary)
                    }
                }
                IconButton(onClick = { stopAllScans(); onClose() }, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = "Close", tint = Palette.textTertiary, modifier = Modifier.size(20.dp))
                }
            }
        },
        text = {
            when (step) {
                WizardStep.Type -> TypeStep(onPick = { t -> type = t; nameDraft = ""; step = WizardStep.Prep })
                WizardStep.Prep -> type?.let { t ->
                    PrepStep(t, onScan = { startScan(t); step = WizardStep.Pick })
                }
                WizardStep.Pick -> type?.let { t ->
                    when {
                        t.isWhoop -> WhoopPickStep(
                            viewModel = viewModel,
                            onSelect = { strap ->
                                pickedWhoop = strap; pickedStrap = null; pickedMachine = null; pickedHuami = null
                                nameDraft = strap.name?.takeIf { it.isNotBlank() } ?: t.title
                                viewModel.stopWhoopScan()
                                step = WizardStep.Confirm
                            },
                            onRescan = { viewModel.presentWhoopScan(t.whoopModel ?: WhoopModel.WHOOP4) },
                        )
                        t == DeviceType.GymEquipment -> FtmsPickStep(
                            scanner = ftmsScanner,
                            onSelect = { machine ->
                                pickedMachine = machine
                                pickedWhoop = null; pickedStrap = null; pickedHuami = null
                                nameDraft = machine.name
                                ftmsScanner.stopScan()
                                step = WizardStep.Confirm
                            },
                            onRescan = { ftmsScanner.scan() },
                        )
                        t == DeviceType.Amazfit || t == DeviceType.MiBand -> HuamiPickStep(
                            scanner = huamiScanner,
                            onSelect = { dev ->
                                pickedHuami = dev
                                pickedWhoop = null; pickedStrap = null; pickedMachine = null
                                nameDraft = dev.name
                                huamiScanner.stopScan()
                                step = WizardStep.Confirm
                            },
                            onRescan = { huamiScanner.scan() },
                        )
                        t == DeviceType.Oura -> OuraPickStep(
                            scanner = ouraScanner,
                            onUseImport = { ouraScanner.stopScan(); onClose() },
                        )
                        else -> HrPickStep(
                            // Heart-rate strap AND Garmin (Broadcast HR is the standard 0x180D path).
                            scanner = hrScanner,
                            onSelect = { strap ->
                                pickedStrap = strap
                                pickedWhoop = null; pickedMachine = null; pickedHuami = null
                                nameDraft = strap.name
                                hrScanner.stopScan()
                                step = WizardStep.Confirm
                            },
                            onRescan = { hrScanner.scan() },
                        )
                    }
                }
                WizardStep.Confirm -> ConfirmStep(
                    advertisedName = confirmAdvertisedName,
                    brand = confirmBrand,
                    rssi = confirmRssi,
                    name = nameDraft,
                    onName = { nameDraft = it },
                    onAdd = { askMakeActive = true },
                )
            }
        },
        confirmButton = {},
        dismissButton = {},
    )

    // After adding, offer to make the new device active.
    if (askMakeActive) {
        AlertDialog(
            onDismissRequest = { askMakeActive = false; finishAdd(makeActive = false) },
            containerColor = Palette.surfaceOverlay,
            title = { Text("Make this your active device?", style = NoopType.title2, color = Palette.textPrimary) },
            text = {
                Text(
                    "Make $confirmName your active device now? It will provide your live data. You can change " +
                        "this any time.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = { askMakeActive = false; finishAdd(makeActive = true) }) {
                    Text("Make active", style = NoopType.body, color = Palette.accent)
                }
            },
            dismissButton = {
                TextButton(onClick = { askMakeActive = false; finishAdd(makeActive = false) }) {
                    Text("Not now", style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

private fun headerTitle(step: WizardStep, type: DeviceType?): String = when (step) {
    WizardStep.Type -> "Add a device"
    WizardStep.Prep -> type?.title ?: "Add a device"
    WizardStep.Pick -> "Pick your device"
    WizardStep.Confirm -> "Name & confirm"
}

private fun headerSubtitle(step: WizardStep): String? = when (step) {
    WizardStep.Type -> "What are you adding?"
    WizardStep.Prep -> "Get it ready, then scan."
    WizardStep.Pick -> "Tap the one that's yours."
    WizardStep.Confirm -> null
}

// MARK: - Step 1 — type picker

@Composable
private fun TypeStep(onPick: (DeviceType) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TypeRow(Icons.Filled.Watch, DeviceType.Whoop5MG.title, "Newer WHOOP band — experimental in NOOP") {
            onPick(DeviceType.Whoop5MG)
        }
        TypeRow(Icons.Filled.Watch, DeviceType.Whoop4.title, "NOOP's primary, fully-supported band") {
            onPick(DeviceType.Whoop4)
        }
        TypeRow(Icons.Filled.FavoriteBorder, DeviceType.HrStrap.title, "Polar, Wahoo, Coospo, Garmin HRM, Amazfit Helio broadcast") {
            onPick(DeviceType.HrStrap)
        }
        TypeRow(Icons.AutoMirrored.Filled.DirectionsRun, DeviceType.GymEquipment.title, "Treadmill, indoor bike, rower or cross-trainer (Bluetooth FTMS)") {
            onPick(DeviceType.GymEquipment)
        }

        // EXPERIMENTAL tier — clearly labelled, opt-in, best-effort. Each is honest about what it can
        // actually read; none fabricates data.
        Overline("Experimental", modifier = Modifier.padding(top = 8.dp))
        ExperimentalTierNote()
        TypeRow(Icons.Filled.GraphicEq, DeviceType.Amazfit.title, "Incl. Helio. Live heart rate where the band exposes it. Help us test.") {
            onPick(DeviceType.Amazfit)
        }
        TypeRow(Icons.Filled.GraphicEq, DeviceType.MiBand.title, "Live heart rate on bands that don't need pairing. Help us test.") {
            onPick(DeviceType.MiBand)
        }
        TypeRow(Icons.Filled.Watch, DeviceType.Garmin.title, "Uses the watch's Broadcast Heart Rate. We'll show you how.") {
            onPick(DeviceType.Garmin)
        }
        TypeRow(Icons.Filled.FileDownload, DeviceType.Oura.title, "Live isn't available. We'll check, then point you to file import.") {
            onPick(DeviceType.Oura)
        }

        WhoopFirstNote()
    }
}

/** A shared "this tier is experimental" note shown on the type-list heading and every experimental prep
 *  step. Honest, US-neutral, no em-dashes. */
@Composable
private fun ExperimentalTierNote() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Palette.statusWarning.copy(alpha = 0.10f))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Science, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(18.dp))
        Text(
            "Experimental, best-effort support. We're still testing these, so they might not connect on " +
                "every device. They never make up data, and they'll tell you honestly when live isn't possible.",
            style = NoopType.footnote,
            color = Palette.statusWarning,
        )
    }
}

@Composable
private fun TypeRow(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .frostedCardSurface(cornerRadius = 14.dp)
            .clickable(onClick = onClick)
            .semantics { contentDescription = "$title. $subtitle" }
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(28.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(subtitle, style = NoopType.caption, color = Palette.textTertiary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun WhoopFirstNote() {
    Row(
        modifier = Modifier.padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.FavoriteBorder, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(16.dp))
        Text(
            "WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps stream live heart rate " +
                "and HRV, but not WHOOP's deeper sleep and recovery data.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Step 2 — type-specific prep + guidance

@Composable
private fun PrepStep(type: DeviceType, onScan: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                when {
                    type.isWhoop || type == DeviceType.Garmin -> Icons.Filled.Watch
                    type == DeviceType.GymEquipment -> Icons.AutoMirrored.Filled.DirectionsRun
                    type == DeviceType.Amazfit || type == DeviceType.MiBand -> Icons.Filled.GraphicEq
                    type == DeviceType.Oura -> Icons.Filled.FileDownload
                    else -> Icons.Filled.FavoriteBorder
                },
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(28.dp),
            )
            Text(type.title, style = NoopType.title2, color = Palette.textPrimary)
        }

        if (type == DeviceType.Whoop5MG) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.statusWarning.copy(alpha = 0.10f))
                    .padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Science, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(18.dp))
                Text(
                    "WHOOP 5.0 / MG support is newer and still experimental in NOOP.",
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
        } else if (type.isExperimental) {
            ExperimentalTierNote()
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .frostedCardSurface(cornerRadius = 14.dp)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            prepInstructions(type).forEach { line ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                    Text("•", style = NoopType.body, color = Palette.accent)
                    Text(line, style = NoopType.body, color = Palette.textSecondary)
                }
            }
        }

        TextButton(
            onClick = onScan,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Palette.accent)
                .semantics { contentDescription = "Scan for ${type.title}" },
        ) {
            Text("Scan", style = NoopType.headline, color = Palette.goldDeepText)
        }
    }
}

/** Type-specific "get it ready" guidance — the point of the branching wizard. US English copy. */
private fun prepInstructions(type: DeviceType): List<String> = when (type) {
    DeviceType.Whoop4 -> listOf(
        "Put your WHOOP 4.0 on your wrist and make sure it's awake.",
        "Make sure it's NOT connected to the official WHOOP app right now.",
        "NOOP will look for it nearby.",
    )
    DeviceType.Whoop5MG -> listOf(
        "WHOOP 5.0 / MG bonds to one device at a time — unpair it from the official WHOOP app first.",
        "Put the band into pairing mode, on your wrist and awake.",
        "NOOP will look for it nearby.",
    )
    DeviceType.HrStrap -> listOf(
        "Wake your strap — put it on, or dampen the contacts.",
        "Make sure it isn't connected to another app (a bike computer, the brand's own app…).",
        "NOOP will look for it nearby.",
    )
    DeviceType.GymEquipment -> listOf(
        "Wake the machine — start pedalling, walking or rowing so it powers on its Bluetooth.",
        "Make sure it isn't already connected to another app (Zwift, the gym's app, a bike computer…).",
        "NOOP looks for machines that broadcast the standard Bluetooth Fitness Machine service.",
    )
    DeviceType.Amazfit -> listOf(
        "Wake your Amazfit / Zepp band and make sure it isn't connected to the Zepp app right now.",
        "NOOP reads live heart rate when the band exposes it. Some bands need a pairing we can't do yet — if so, we'll say so honestly.",
        "Experimental: this is best-effort. If live doesn't work, you can export from Zepp and import the file.",
    )
    DeviceType.MiBand -> listOf(
        "Wake your Mi Band and make sure it isn't connected to the Mi Fitness / Zepp Life app right now.",
        "NOOP reads live heart rate on bands that don't require pairing. Newer bands need an auth handshake we can't do yet.",
        "Experimental: if your band needs pairing, we'll tell you honestly rather than show a fake reading.",
    )
    DeviceType.Garmin -> com.noop.ble.GarminBroadcast.broadcastHint
    DeviceType.Oura -> listOf(
        "The Oura ring is proprietary and only syncs to the Oura app, so there's no open live stream NOOP can read.",
        "We'll scan for your ring and check its Bluetooth services so you can see we looked.",
        "Then we'll point you at file import, which is the honest way to get your Oura data into NOOP.",
    )
}

// MARK: - Step 3 — pick from the live scan

@Composable
private fun WhoopPickStep(
    viewModel: AppViewModel,
    onSelect: (WhoopBleClient.DiscoveredWhoop) -> Unit,
    onRescan: () -> Unit,
) {
    val found by viewModel.discoveredWhoops.collectAsStateWithLifecycle()
    PickList(searching = true, isEmpty = found.isEmpty(), onRescan = onRescan) {
        found.sortedByDescending { it.rssi }.forEach { strap ->
            DiscoveredRow(
                name = strap.name?.takeIf { it.isNotBlank() } ?: "WHOOP",
                subtitle = "WHOOP",
                rssi = strap.rssi,
                onTap = { onSelect(strap) },
            )
        }
    }
}

@Composable
private fun HrPickStep(
    scanner: StandardHrSource,
    onSelect: (StandardHrSource.DiscoveredStrap) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    PickList(searching = scanning, isEmpty = discovered.isEmpty(), onRescan = onRescan) {
        discovered.sortedByDescending { it.rssi }.forEach { strap ->
            DiscoveredRow(
                name = strap.name,
                subtitle = brandGuess(strap.name),
                rssi = strap.rssi,
                onTap = { onSelect(strap) },
            )
        }
    }
}

@Composable
private fun FtmsPickStep(
    scanner: com.noop.ble.FtmsSource,
    onSelect: (com.noop.ble.FtmsSource.DiscoveredMachine) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    PickList(searching = scanning, isEmpty = discovered.isEmpty(), onRescan = onRescan) {
        discovered.sortedByDescending { it.rssi }.forEach { machine ->
            DiscoveredRow(
                name = machine.name,
                subtitle = "Gym equipment",
                rssi = machine.rssi,
                onTap = { onSelect(machine) },
            )
        }
    }
}

@Composable
private fun HuamiPickStep(
    scanner: com.noop.ble.HuamiHrSource,
    onSelect: (com.noop.ble.HuamiHrSource.DiscoveredDevice) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    PickList(searching = scanning, isEmpty = discovered.isEmpty(), onRescan = onRescan) {
        discovered.sortedByDescending { it.rssi }.forEach { dev ->
            DiscoveredRow(
                name = dev.name,
                subtitle = "Experimental",
                rssi = dev.rssi,
                onTap = { onSelect(dev) },
            )
        }
    }
}

@Composable
private fun OuraPickStep(
    scanner: com.noop.ble.OuraProbeSource,
    onUseImport: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    val deadEnd by scanner.deadEndMessage.collectAsStateWithLifecycle()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatePill(
                if (scanning) "Searching…" else "Idle",
                tone = if (scanning) StrandTone.Accent else StrandTone.Neutral,
                pulsing = scanning,
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { scanner.scan() }) {
                Text("Rescan", style = NoopType.subhead, color = Palette.accent)
            }
        }
        val msg = deadEnd
        when {
            msg != null -> {
                // The honest dead-end: no open live stream → file import.
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .frostedCardSurface(cornerRadius = 14.dp)
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(msg, style = NoopType.body, color = Palette.textPrimary)
                    TextButton(
                        onClick = onUseImport,
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .background(Palette.accent)
                            .semantics { contentDescription = "Use file import for Oura" },
                    ) {
                        Text("Use file import", style = NoopType.headline, color = Palette.goldDeepText)
                    }
                }
            }
            discovered.isEmpty() -> {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .frostedCardSurface(cornerRadius = 14.dp)
                        .padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    CircularProgressIndicator(color = Palette.accent, modifier = Modifier.size(22.dp))
                    Text("Searching…", style = NoopType.body, color = Palette.textPrimary)
                    Text(
                        "Make sure it's awake and not connected elsewhere.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }
            else -> {
                // Found a ring (or rings): tap to probe so the user sees we genuinely looked.
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    discovered.sortedByDescending { it.rssi }.forEach { ring ->
                        DiscoveredRow(
                            name = ring.name,
                            subtitle = "Tap to check",
                            rssi = ring.rssi,
                            onTap = { scanner.probe(ring.address) },
                        )
                    }
                }
            }
        }
    }
}

/** Shared pick-step shell: a searching status bar + a Rescan button, then either the searching card
 *  (while [isEmpty]) or the caller's discovered [rows]. Mirrors the iOS pick step's ScanStatusBar +
 *  SearchingCard. */
@Composable
private fun PickList(
    searching: Boolean,
    isEmpty: Boolean,
    onRescan: () -> Unit,
    rows: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatePill(
                if (searching) "Searching…" else "Idle",
                tone = if (searching) StrandTone.Accent else StrandTone.Neutral,
                pulsing = searching,
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onRescan) {
                Text("Rescan", style = NoopType.subhead, color = Palette.accent)
            }
        }
        if (isEmpty) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .frostedCardSurface(cornerRadius = 14.dp)
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(color = Palette.accent, modifier = Modifier.size(22.dp))
                Text("Searching…", style = NoopType.body, color = Palette.textPrimary)
                Text(
                    "Make sure it's awake and not connected elsewhere.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) { rows() }
        }
    }
}

@Composable
private fun DiscoveredRow(name: String, subtitle: String, rssi: Int, onTap: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .frostedCardSurface(cornerRadius = 12.dp)
            .clickable(onClick = onTap)
            .semantics { contentDescription = "$name, signal ${SignalBars.level(rssi)} of 4" }
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SignalBars(rssi)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, style = NoopType.body, color = Palette.textPrimary)
            Text(subtitle, style = NoopType.caption, color = Palette.textTertiary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(18.dp),
        )
    }
}

// MARK: - Step 4 — name + confirm

@Composable
private fun ConfirmStep(
    advertisedName: String,
    brand: String,
    rssi: Int,
    name: String,
    onName: (String) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .frostedCardSurface(cornerRadius = 12.dp)
                .padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SignalBars(rssi)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(advertisedName, style = NoopType.headline, color = Palette.textPrimary)
                Text(brand, style = NoopType.caption, color = Palette.textTertiary)
            }
        }

        Overline("Name")
        OutlinedTextField(
            value = name,
            onValueChange = onName,
            singleLine = true,
            placeholder = { Text("Device name", style = NoopType.body, color = Palette.textTertiary) },
            colors = wizardFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = "Device name" },
        )

        TextButton(
            onClick = onAdd,
            enabled = name.trim().isNotEmpty(),
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(if (name.trim().isNotEmpty()) Palette.accent else Palette.surfaceInset),
        ) {
            Text(
                "Add",
                style = NoopType.headline,
                color = if (name.trim().isNotEmpty()) Palette.goldDeepText else Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun wizardFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)
