import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import StrandImport
import WhoopStore

struct DataSourcesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop
    // Nutrition CSV import state — local to this screen (the import is a quick, self-contained
    // metric-series write; it doesn't need AppModel's heavyweight import pipeline).
    @State private var nutritionImporting = false
    @State private var nutritionSummary: String?
    @State private var nutritionFailed = false
    // Lifting (Hevy / Liftosaur) import state — same lightweight, self-contained pattern: parse the
    // file, upsert workout rows under the "lifting" source, refresh. No HR Effort is touched.
    @State private var liftingImporting = false
    @State private var liftingSummary: String?
    @State private var liftingFailed = false
    // Activity-file (GPX / TCX / FIT) import state — same lightweight, self-contained pattern: parse the
    // file, upsert one workout row under the "activity-file" source, refresh. No HR Effort is touched.
    @State private var activityFileImporting = false
    @State private var activityFileSummary: String?
    @State private var activityFileFailed = false
    // Wearable export (Oura / Fitbit / Garmin own-data export) import state — same lightweight,
    // self-contained pattern: parse the file, upsert daily metrics + sleep sessions under the brand's
    // own source, refresh. The brand's own scores are stored as reference only, never NOOP scores.
    @State private var wearableImporting = false
    @State private var wearableSummary: String?
    @State private var wearableFailed = false

    // "Broadcast heart rate" (opt-in, OFF by default): make NOOP a standard BLE Heart Rate peripheral
    // (0x180D / 0x2A37) so a gym treadmill / Zwift / Peloton can read the live strap HR NOOP receives.
    // LOCAL Bluetooth only — nothing leaves the device. The toggle is persisted; the broadcaster is owned
    // here (a pure consumer of LiveState, isolated from the WHOOP/central path).
    @AppStorage(HrBroadcaster.defaultsKey) private var broadcastHrEnabled = false

    // The broadcaster's diagnostic sink forwards to THIS box, which `onAppear` points at the screen's
    // `live`. A reference box lets the `@StateObject` capture a stable target at init even though the
    // `@EnvironmentObject` `live` isn't available until the view runs — so the broadcast-out lifecycle
    // lines (advertised / who subscribed / why the radio refused) reach the SAME exported strap log the
    // WHOOP path writes, mirroring Android's `HrBroadcaster(log = { ble.externalLog(it) })`. Every line is
    // already prefixed "HR-out: " inside HrBroadcaster; privacy-safe (statuses + a subscriber COUNT only).
    private final class LogSink { weak var live: LiveState? }
    private let broadcastLogSink: LogSink
    @StateObject private var hrBroadcaster: HrBroadcaster

    init() {
        let sink = LogSink()
        self.broadcastLogSink = sink
        _hrBroadcaster = StateObject(wrappedValue: HrBroadcaster(log: { [weak sink] line in
            // HrBroadcaster is @MainActor, so it only ever calls this closure from the main actor — assume
            // that isolation to forward straight into LiveState (also @MainActor) without an extra runloop
            // hop, matching Android's synchronous `ble.externalLog(it)`.
            MainActor.assumeIsolated { sink?.live?.append(log: line) }
        }))
    }

    var body: some View {
        ScreenScaffold(title: "Data Sources",
                       subtitle: "Everything stays on \(Platform.deviceNounPhrase). Bring your history in once, then it's yours.",
                       onRefresh: { await repo.refresh() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                whoopCard
                appleHealthCard
                xiaomiCard
                nutritionCard
                liftingCard
                activityFileCard
                wearableCard
                broadcastHrCard
                liveCard
            }
        }
        .onAppear {
            // Point the broadcaster's diagnostic sink at this screen's `live` so its broadcast-out
            // lifecycle lines land in the same exported strap log the WHOOP path uses (issue #421 parity).
            broadcastLogSink.live = live
            // Bind the broadcaster to the live HR once, and resume broadcasting if the user left it on.
            hrBroadcaster.bind(to: live)
            if broadcastHrEnabled { hrBroadcaster.start() }
        }
        .onDisappear {
            // The broadcast is a foreground convenience tied to this screen's owned object — release the
            // radio when the screen goes away; toggling it back on (or revisiting) re-starts it.
            hrBroadcaster.stop()
        }
        // A single target-aware importer avoids SwiftUI collapsing competing importers on the same screen.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importTarget.allowedContentTypes,
                      allowsMultipleSelection: false) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    private var whoopCard: some View {
        let hasWhoop = !repo.days.isEmpty
        return card(title: "WHOOP Export", icon: "square.and.arrow.down.fill",
             tint: StrandPalette.accent,
             status: StatePill(hasWhoop ? "Imported" : "Nothing imported",
                               tone: hasWhoop ? .accent : .neutral),
             subtitle: "Import your full WHOOP history — recovery, strain, sleep, workouts — from a data export (.zip). Works for WHOOP 4.0, 5.0 and MG. Get one at app.whoop.com → Data Management.") {
            let importingWhoop = model.isImporting(.whoop)
            HStack(spacing: 12) {
                Button {
                    presentImporter(.whoop)
                } label: {
                    Label(importingWhoop ? "Importing…" : "Choose export…",
                          systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if importingWhoop { ProgressView().controlSize(.small) }
            }
            if let s = model.whoopImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.whoopImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
            Text("\(repo.days.count) days · \(repo.sleeps.count) sleeps stored")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var appleHealthCard: some View {
        card(title: "Apple Health", icon: "heart.fill",
             tint: StrandPalette.metricCyan,
             subtitle: "Import an Apple Health export (Health app → profile → Export All Health Data → export.zip). 7 years of HR, HRV, sleep, SpO₂, steps and more — streamed locally. Large exports take a minute or two.") {
            let importingAppleHealth = model.isImporting(.appleHealth)
            HStack(spacing: 12) {
                Button { presentImporter(.appleHealth) } label: {
                    Label(importingAppleHealth ? "Working…" : "Choose export.zip…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.metricCyan)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if importingAppleHealth { ProgressView().controlSize(.small) }
            }
            if let s = model.appleHealthImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.appleHealthImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var xiaomiCard: some View {
        card(title: "Xiaomi Smart Band (Mi Band)", icon: "figure.walk.motion",
             tint: StrandPalette.metricAmber,
             subtitle: "Import your Mi Band history — steps, heart rate, resting HR, sleep stages, SpO₂, stress and sleep score — straight from the Mi Fitness app. On your iPhone: Files → On My iPhone → Mi Fitness, long-press the folder → Compress, then choose the .zip here. Fully offline; no Xiaomi account or Bluetooth needed. Smart Band 8/9/10.") {
            let importingXiaomi = model.isImporting(.xiaomi)
            HStack(spacing: 12) {
                Button { presentImporter(.xiaomi) } label: {
                    Label(importingXiaomi ? "Importing…" : "Choose Mi Fitness export…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.metricAmber)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if importingXiaomi { ProgressView().controlSize(.small) }
            }
            if let s = model.xiaomiImportSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(model.xiaomiImportFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var nutritionCard: some View {
        card(title: "Nutrition (.csv)", icon: "fork.knife",
             tint: StrandPalette.metricAmber,
             subtitle: "Import daily nutrition totals — calories in, protein, carbs, fat (and weight if present) — from a Cronometer or MacroFactor CSV export. Other trackers work too if the file has a date column and daily totals.") {
            HStack(spacing: 12) {
                Button { presentImporter(.nutrition) } label: {
                    Label(nutritionImporting ? "Importing…" : "Choose .csv…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if nutritionImporting { ProgressView().controlSize(.small) }
            }
            if let s = nutritionSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(nutritionFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var liftingCard: some View {
        card(title: "Lifting log (Hevy / Liftosaur)", icon: "dumbbell.fill",
             tint: DomainTheme.effort.color,
             subtitle: "Import your strength-training history from a Hevy CSV export or a Liftosaur JSON export. Each workout becomes a Strength session with a training-volume estimate (weight × reps). It's a volume figure, not a measured strain — it never changes your Effort.") {
            HStack(spacing: 12) {
                Button { presentImporter(.lifting) } label: {
                    Label(liftingImporting ? "Importing…" : "Choose export…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if liftingImporting { ProgressView().controlSize(.small) }
            }
            if let s = liftingSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(liftingFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var activityFileCard: some View {
        card(title: "Workout file (GPX / TCX / FIT)", icon: "point.topleft.down.curvedto.point.bottomright.up",
             tint: StrandPalette.metricAmber,
             subtitle: "Import a single exported workout file from any brand — Garmin, Coros, Suunto, Wahoo, Polar, Strava, Apple — straight off your device. GPS route, distance, heart rate and calories come in where the file has them. Fully offline; nothing leaves \(Platform.deviceNounPhrase).") {
            HStack(spacing: 12) {
                Button { presentImporter(.activityFile) } label: {
                    Label(activityFileImporting ? "Importing…" : "Choose .gpx / .tcx / .fit…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.metricAmber)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting)
                if activityFileImporting { ProgressView().controlSize(.small) }
            }
            if let s = activityFileSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(activityFileFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private var wearableCard: some View {
        card(title: "Oura / Fitbit / Garmin export", icon: "figure.mind.and.body",
             tint: StrandPalette.metricPurple,
             subtitle: "Import your own data export from Oura, Fitbit or Garmin — sleep, resting heart rate, HRV, steps and more, where the export has them. Download it from the brand's app (Oura: Account → Export Data; Fitbit: Google Takeout; Garmin: Export Your Data), then choose the file here. Fully offline; nothing leaves \(Platform.deviceNounPhrase). Each brand's own readiness or sleep score is kept for reference only — your scores stay yours.") {
            HStack(spacing: 12) {
                Button { presentImporter(.wearable) } label: {
                    Label(wearableImporting ? "Importing…" : "Choose export…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.metricPurple)
                .disabled(model.hasActiveImport || nutritionImporting || liftingImporting || activityFileImporting || wearableImporting)
                if wearableImporting { ProgressView().controlSize(.small) }
            }
            if let s = wearableSummary {
                Text(s).font(StrandFont.subhead)
                    .foregroundStyle(wearableFailed ? StrandPalette.statusWarning : StrandPalette.statusPositive)
            }
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        #if os(iOS)
        // iOS: go through UIDocumentPickerViewController with asCopy:true (DocumentPicker) rather than
        // SwiftUI's `.fileImporter` (#179). asCopy makes iOS DOWNLOAD an iCloud-Drive placeholder and
        // hand us a readable local copy — `.fileImporter` instead returns a security-scoped URL that,
        // for an undownloaded iCloud file, can't be read, and the whole import silently did nothing.
        Task {
            guard let url = await DocumentPicker.importFile(target.allowedContentTypes) else { return } // cancelled
            handlePickedURL(url, for: target)
        }
        #else
        showingImporter = true
        #endif
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            handlePickedURL(url, for: target)
        case .failure(let error):
            // Surface the failure instead of swallowing it (#179) — a silent return read as
            // "import does nothing", with no clue why.
            NSLog("Import: file picker failed for \(target) — \(error.localizedDescription)")
        }
    }

    private func handlePickedURL(_ url: URL, for target: ImportTarget) {
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        case .xiaomi:
            model.importXiaomi(url: url)
        case .nutrition:
            importNutrition(url: url)
        case .lifting:
            importLifting(url: url)
        case .activityFile:
            importActivityFile(url: url)
        case .wearable:
            importWearable(url: url)
        }
    }

    /// Write one privacy-safe line into the SAME exported strap log the WHOOP path uses, so a tester's
    /// file import is no longer invisible in a shared debug bundle (issue #421 parity). Brand label +
    /// COUNTS only, never a file name, a path, or any health value. Prefixed "Import " so it's
    /// distinguishable from the WHOOP / HR-strap / HR-out lines. Timestamp matches the rest of the log.
    /// The Android twin logs the same shape from DataSourcesScreen.runImport via ble.externalLog.
    private func logImport(_ line: String) {
        live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] Import \(line)")
    }

    /// Parse a daily-nutrition CSV and upsert it into the metric-series store under the
    /// dedicated "nutrition-csv" source, then refresh so Explore/Insights see the new keys.
    private func importNutrition(url: URL) {
        nutritionImporting = true
        nutritionSummary = nil
        nutritionFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = NutritionCsvImporter.parse(data: data)
                guard result.importedDays > 0 else {
                    nutritionSummary = "No usable rows found — check the file has a date column (yyyy-MM-dd) and daily totals."
                    nutritionFailed = true
                    logImport("Nutrition CSV: no usable rows (\(result.skippedRows) skipped)")
                    nutritionImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    nutritionSummary = "Couldn't open the local store."
                    nutritionFailed = true
                    nutritionImporting = false
                    return
                }
                let points = result.metricPoints.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
                try await store.upsertMetricSeries(points, deviceId: NutritionCsvImporter.sourceId)
                await repo.refresh()
                var msg = "Imported \(result.importedDays) days (\(points.count) values)"
                if let a = result.earliestDay, let b = result.latestDay, a != b { msg += " · \(a) – \(b)" }
                if result.skippedRows > 0 { msg += " · \(result.skippedRows) rows skipped" }
                nutritionSummary = msg
                nutritionFailed = false
                logImport("Nutrition CSV: \(result.importedDays) days, \(points.count) values, \(result.skippedRows) rejected")
            } catch {
                nutritionSummary = "Import failed: \(error.localizedDescription)"
                nutritionFailed = true
                logImport("Nutrition CSV failed: \(error.localizedDescription)")
            }
            nutritionImporting = false
        }
    }

    /// Parse a Hevy CSV / Liftosaur JSON lifting export and upsert each workout as a Strength session
    /// (source "lifting") with a transparent volume-load note. No `strain` is stored, so these never
    /// feed the HR-based Effort — lifting volume is reported alongside it, never folded into it.
    private func importLifting(url: URL) {
        liftingImporting = true
        liftingSummary = nil
        liftingFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let result = LiftingImporter.parse(data: data)
                guard result.sessionCount > 0 else {
                    liftingSummary = "No workouts found — point at a Hevy CSV export or a Liftosaur JSON export."
                    liftingFailed = true
                    logImport("Lifting log: no workouts found (\(result.skipped) skipped)")
                    liftingImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    liftingSummary = "Couldn't open the local store."
                    liftingFailed = true
                    liftingImporting = false
                    return
                }
                let rows = result.sessions.map { s in
                    WorkoutRow(
                        startTs: Int(s.start.timeIntervalSince1970),
                        endTs: Int(s.end.timeIntervalSince1970),
                        sport: LiftingImporter.sport,
                        source: LiftingImporter.sourceId,
                        durationS: s.durationS,
                        energyKcal: nil,
                        avgHr: nil,
                        maxHr: nil,
                        strain: nil,                 // never a fabricated cardiovascular strain
                        distanceM: nil,
                        zonesJSON: nil,
                        notes: s.volumeLoadNote()
                    )
                }
                try await store.upsertWorkouts(rows, deviceId: LiftingImporter.sourceId)
                await repo.refresh()
                let totalVolume = result.sessions.reduce(0.0) { $0 + $1.volumeLoadKg }
                var msg = "Imported \(result.sessionCount) workout\(result.sessionCount == 1 ? "" : "s")"
                if totalVolume > 0 { msg += " · \(LiftingImporter.groupedKg(totalVolume)) kg total volume" }
                if let a = result.earliest, let b = result.latest {
                    let span = liftingDayFormatter
                    let lo = span.string(from: a), hi = span.string(from: b)
                    if lo != hi { msg += " · \(lo) – \(hi)" }
                }
                if result.skipped > 0 { msg += " · \(result.skipped) skipped" }
                liftingSummary = msg
                liftingFailed = false
                logImport("Lifting log: \(result.sessionCount) workouts, \(result.skipped) rejected")
            } catch {
                liftingSummary = "Import failed: \(error.localizedDescription)"
                liftingFailed = true
                logImport("Lifting log failed: \(error.localizedDescription)")
            }
            liftingImporting = false
        }
    }

    /// Parse a single GPX / TCX / FIT activity file and upsert it as one workout (source
    /// "activity-file"). The route polyline isn't persisted on macOS (the shared WorkoutRow has no route
    /// column), but distance / HR / energy / ascent and an honest "N GPS points · M HR samples" note are.
    /// No `strain` is stored unless the file carried one — imported files never feed the HR-based Effort.
    private func importActivityFile(url: URL) {
        activityFileImporting = true
        activityFileSummary = nil
        activityFileFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Cap the read so a hostile huge file can't OOM us before the parser's own guards.
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                if data.count > ActivityFileImporter.maxBytes {
                    activityFileSummary = "That file is too large to import."
                    activityFileFailed = true
                    logImport("Workout file failed: file too large")
                    activityFileImporting = false
                    return
                }
                let result = ActivityFileImporter.parse(data: data, filename: url.lastPathComponent)
                guard let activity = result.activity, let s = activity.durationS, s > 0 else {
                    activityFileSummary = "No usable activity found — point at a .gpx, .tcx or .fit workout file."
                    activityFileFailed = true
                    logImport("Workout file: no usable activity found")
                    activityFileImporting = false
                    return
                }
                guard let store = await repo.storeHandle() else {
                    activityFileSummary = "Couldn't open the local store."
                    activityFileFailed = true
                    activityFileImporting = false
                    return
                }
                let sport = ActivityFileImporter.workoutSport(from: activity.sport)
                let row = WorkoutRow(
                    startTs: Int(activity.start.timeIntervalSince1970),
                    endTs: Int(activity.end.timeIntervalSince1970),
                    sport: sport,
                    source: ActivityFileImporter.sourceId,
                    durationS: activity.durationS,
                    energyKcal: activity.energyKcal,
                    avgHr: activity.avgHr,
                    maxHr: activity.maxHr,
                    strain: nil,                         // never a fabricated cardiovascular strain
                    distanceM: activity.distanceM,
                    zonesJSON: nil,
                    notes: activity.importNote()
                )
                try await store.upsertWorkouts([row], deviceId: ActivityFileImporter.sourceId)
                await repo.refresh()
                activityFileSummary = ActivityFileImporter.summaryText(activity)
                activityFileFailed = false
                logImport("Workout file (\(sport)): 1 workout imported")
            } catch {
                activityFileSummary = "Import failed: \(error.localizedDescription)"
                activityFileFailed = true
                logImport("Workout file failed: \(error.localizedDescription)")
            }
            activityFileImporting = false
        }
    }

    /// Parse a user's own Oura / Fitbit / Garmin data export and upsert it under the brand's own source
    /// (daily metrics + sleep sessions + reference-only metric series). The brand's own readiness/sleep
    /// score is NEVER mapped to a NOOP Charge/Effort/Rest — NOOP recomputes its own from the raw inputs.
    private func importWearable(url: URL) {
        wearableImporting = true
        wearableSummary = nil
        wearableFailed = false
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    wearableSummary = "Couldn't open the local store."
                    wearableFailed = true
                    wearableImporting = false
                    return
                }
                let result = try await WearableImporter.importExport(url: url, into: store)
                await repo.refresh()
                wearableSummary = WearableExportImporter.summaryText(result)
                wearableFailed = false
                logImport("\(result.brand.displayName) export: \(result.days.count) days, \(result.sleeps.count) sleeps, \(result.summary.skippedSpans) rejected")
            } catch {
                wearableSummary = "Import failed: \(error.localizedDescription)"
                wearableFailed = true
                logImport("Wearable export failed: \(error.localizedDescription)")
            }
            wearableImporting = false
        }
    }

    private var liftingDayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")   // sessions are stored at UTC; label the same span
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private enum ImportTarget {
        case whoop
        case appleHealth
        case xiaomi
        case nutrition
        case lifting
        case activityFile
        case wearable

        var allowedContentTypes: [UTType] {
            // `.folder` lets macOS users point at an *unzipped* export directory. On iOS the Files
            // picker can't meaningfully pick a folder here, and including `UTType.folder` in the type
            // list greys out the .zip itself — so the picker opens but nothing is selectable
            // (issue #179). iOS therefore offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            case .xiaomi:
                // The Mi Fitness sandbox is shared as a .zip (or, on macOS, an unzipped
                // folder); the bare `<user_id>.db` is also accepted directly.
                let db = UTType(filenameExtension: "db") ?? .data
                #if os(macOS)
                return [.zip, .folder, db]
                #else
                return [.zip, db]
                #endif
            case .nutrition:
                return [.commaSeparatedText, .plainText]
            case .lifting:
                // Hevy exports .csv, Liftosaur exports .json — accept both (plus plain text, since some
                // share sheets type a .csv as text/plain). The importer sniffs the actual format.
                return [.commaSeparatedText, .json, .plainText]
            case .activityFile:
                // GPX/TCX are XML; FIT is binary. None have a system UTType, so build them by extension
                // (falling back to .xml/.data) and add .data so an untyped share-sheet file is selectable.
                // The importer routes by extension/magic-bytes regardless.
                let gpx = UTType(filenameExtension: "gpx") ?? .xml
                let tcx = UTType(filenameExtension: "tcx") ?? .xml
                let fit = UTType(filenameExtension: "fit") ?? .data
                return [gpx, tcx, fit, .xml, .data]
            case .wearable:
                // Oura is a single .json; Fitbit (Google Takeout) and Garmin (GDPR) are .zip bundles.
                // On macOS an unzipped folder is also accepted. The importer sniffs the brand by content.
                #if os(macOS)
                return [.json, .zip, .folder, .data]
                #else
                return [.json, .zip, .data]
                #endif
            }
        }
    }
    private var broadcastHrCard: some View {
        // Status pill reflects the real broadcast state once it's on: advertising vs starting up.
        let status: StatePill? = broadcastHrEnabled
            ? StatePill(hrBroadcaster.advertising ? "Broadcasting" : "Starting…",
                        tone: hrBroadcaster.advertising ? .positive : .warning,
                        pulsing: !hrBroadcaster.advertising)
            : nil
        return card(title: "Broadcast heart rate", icon: "dot.radiowaves.up.forward",
             tint: DomainTheme.effort.color,
             status: status ?? StatePill("Off", tone: .neutral, showsDot: false),
             subtitle: "Re-share your live strap heart rate over Bluetooth as a standard heart-rate sensor, so a gym treadmill, bike, Zwift, Peloton or any fitness app nearby can read it. Local Bluetooth only. Nothing leaves \(Platform.deviceNounPhrase). Off by default.") {
            Toggle(isOn: $broadcastHrEnabled) {
                Text("Broadcast heart rate")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(DomainTheme.effort.color)
            .accessibilityLabel("Broadcast heart rate as a Bluetooth sensor")
            .onChangeCompat(of: broadcastHrEnabled) { on in
                if on { hrBroadcaster.start() } else { hrBroadcaster.stop() }
            }
            Text("Acts as a standard Bluetooth heart-rate strap. Pair NOOP from your treadmill, bike or app to see your strap's heart rate there.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Honest live status only while it's on: a warning note if the radio can't run, else either
            // who's reading it or that we're waiting (never a fabricated "connected").
            if broadcastHrEnabled {
                if let note = hrBroadcaster.statusNote {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if hrBroadcaster.subscriberCount > 0 {
                    let n = hrBroadcaster.subscriberCount
                    Text("\(n) \(n == 1 ? "device" : "devices") reading your heart rate")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else if let hr = live.heartRate {
                    Text("Sharing \(hr) bpm. Waiting for a device to pair.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("No live heart rate yet. Open Live to pair your strap.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var liveCard: some View {
        // Three-state, consistent with the Live screen's connection pill — a connected-but-
        // not-yet-streaming strap (e.g. an experimental WHOOP 5/MG link) no longer reads as
        // "Not connected" on one screen and "Connected" on another (issue #8).
        let (tone, label): (StrandTone, LocalizedStringKey) =
            live.bonded ? (.positive, "Bonded — streaming.")
            : live.connected ? (.warning, "Connected.")
            : (.critical, "Not connected — open Live to pair.")
        return card(title: "WHOOP Strap (Live BLE)", icon: "antenna.radiowaves.left.and.right",
             tint: StrandPalette.accent,
             status: StatePill(label, tone: tone, pulsing: live.connected && !live.bonded),
             subtitle: "Pairs directly with your strap over Bluetooth — no WHOOP app, no cloud.") {
            EmptyView()
        }
    }

    /// One source as a frosted, domain-tinted NoopCard: a tinted source glyph + title, an optional
    /// status pill on the trailing edge, the explainer line, then the connect/import action(s). The
    /// glyph + accents take the card's `tint` (its colour world); the status pill carries connection
    /// state. Replaces the old flat surfaceRaised rectangle with the shared Bevel card surface.
    @ViewBuilder
    private func card<C: View, S: View>(title: String, icon: String,
                              tint: Color = StrandPalette.accent,
                              status: S = EmptyView(),
                              subtitle: String,
                              @ViewBuilder content: @escaping () -> C) -> some View {
        NoopCard(padding: 18, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    status
                }
                Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}
