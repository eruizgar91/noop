import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Control Center (the home dashboard) — HomeDensity rewrite
//
// The owner's complaint was "cards then random space". This rebuild is a tight,
// GAPLESS dashboard grid: one column of uniform sections, every gap == NoopMetrics.gap,
// every section break == NoopMetrics.sectionGap, equal margins from ScreenScaffold.
//
// Composition (top → bottom):
//   (a) HERO  — full-width HStack that fills the width EQUALLY: RecoveryRing (left card)
//               + InsightCard "Today's Synthesis" (right card). No lone card, no gap.
//   (b) METRICS — one adaptive LazyVGrid of fixed-104pt StatTiles (Recovery, Strain,
//               Sleep, HRV, RHR, SpO2, Respiratory, Steps, Weight, Calories) each with
//               a 14-day sparkline so the grid tiles perfectly with no empty cells.
//   (c) LAST WORKOUTS — the SAME adaptive grid of fixed-104pt workout StatTiles.
//   (d) DATA SOURCES — one full-width NoopCard footer of SourceBadges + counts.
//
// Sparse series (weight) fall back to ALL history so a tile never shows an empty
// state when data exists. Only locked StrandDesign components are used.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var router: NavRouter
    /// The "update ringer" — the bell in the top bar opens this inbox; dismissed Today cards post into it.
    @EnvironmentObject var updateStore: UpdateStore

    // Imperial/Metric display preference (D#103). Only the Weight tile carries a convertible unit here.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    // Effort display scale (#268) — drives the Effort tile's value + caption. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // Editable Key-Metrics layout (#251) — an ordered list of the enabled tiles, persisted display-only.
    // Empty/unset shows the full default order. The "Edit" affordance on the section opens a local sheet.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @State private var showingMetricsEditor = false
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State private var sparks: [String: [Double]] = [:]
    @State private var workouts: [WorkoutRow] = []
    @State private var appleDays: [AppleDaily] = []
    /// Distinct days + sleep sessions imported from a Mi Band (Mi Fitness), for the Data Sources row.
    @State private var xiaomiDays = 0
    @State private var xiaomiSleeps = 0

    // The Rest SCORE (0–100) for the logical day — IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series (imported export wins, computed strap fills). The Key-Metrics
    // "Rest" tile shows THIS, formatted like Charge/Effort, with hours-in-bed kept as the caption — the
    // tile previously showed hours where the score belonged (#248). nil until loaded / no night yet.
    @State private var restScore: Double?

    // On-device steps ESTIMATE per day (key "steps_est", computed "-noop" source). The Steps tile
    // prefers a REAL step count (strap @57 counter / Apple Health); only when a day has neither does it
    // fall back to this estimate, shown with an "est." caption so it's never read as a measured count.
    // Loaded once via exploreSeries (same merged read fitness_age/vitality use), keyed by day. (#150)
    @State private var stepsEstByDay: [String: Int] = [:]

    // Today's heart rate as 5-minute bucket means (midnight → now), for the 24h trend chart.
    @State private var hrPoints: [TrendPoint] = []

    // The night's sleep session overlapping the HR window — shaded as a band on the HR chart and
    // used to anchor the recovery marker at wake time (WHOOP-style Overview HR annotations).
    @State private var sleepToday: CachedSleepSession?

    // TODAY's in-progress Effort (NOOP 0–100 axis), recomputed over the day's HR (local-midnight→now)
    // each load so the gauge tracks today as it accumulates rather than waiting on the heavy daily pass
    // to persist — which early in the day would otherwise surface yesterday's completed Effort or a stale
    // 0.0 (#402). nil below StrainScorer.minReadings (we then fall back to the stored daily row) and on
    // any navigated past day (those use the stored value).
    @State private var liveTodayStrain: Double?

    // The HR chart's x-axis window. Today → midnight…now; a navigated PAST day → the full calendar
    // day (midnight…next midnight) so a morning with no banked data reads as empty space rather than
    // the axis silently starting at the first sample (#overview-hr gap clarity).
    @State private var hrAxis: ClosedRange<Date>?

    // Day navigation — 0 = today (the logical day), 1 = yesterday, … The DayNavBar chevrons and date
    // jump drive this, and every day-scoped read-out (hero synthesis, the Key-Metrics tiles, the HR
    // trend and Rest score) resolves to the selected day instead of always showing today. Mirrors the
    // Android TodayScreen.selectedDayOffset. Loads re-run when this changes (see .task(id:)).
    @State private var selectedDayOffset = 0
    // iOS top-bar state: the date-jump popover and the profile/settings sheet.
    @State private var showDayPicker = false
    @State private var showSettings = false
    /// The Updates inbox sheet (opened by the header bell). Shared across both platforms.
    @State private var showUpdatesInbox = false

    /// The NEWEST day-key (max yyyy-MM-dd in `repo.days`) announced to the inbox. Persisted (not @State)
    /// so a relaunch over the same history never re-announces (#521). We trigger on a strictly-newer KEY,
    /// not a count: a recompute that deletes-then-reinserts the window dips/recovers the count but keeps
    /// the same max key, so churn can't masquerade as new history. Empty = no baseline yet (first load
    /// just records the key silently — we only announce genuine forward growth).
    @AppStorage("today.lastAnnouncedDayKey") private var lastAnnouncedDayKey = ""

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // (via the shared `TodayCardDismissal.flagKey`). @AppStorage matches the file's existing prefs style.
    @AppStorage(TodayCardDismissal.flagKey("scoresBuilding")) private var scoresBuildingDismissed = false
    @AppStorage(TodayCardDismissal.flagKey("newHere")) private var newHereDismissed = false

    // Memoized repo-derived values that are expensive (a full-history sort + per-call
    // `repo.days.map`) yet INDEPENDENT of the ~1 Hz live-HR ticks that re-evaluate `body`
    // while a strap streams. `LiveState` publishes R-R every second, so `body` (and every
    // section it renders) re-runs ~1 Hz; recomputing Readiness and the recovery calibration
    // over the whole history on each of those passes is pure waste. Cache them keyed on a
    // cheap repo fingerprint and rebuild only when that changes — the same memoization
    // SleepView and StressView already use to absorb the live-HR re-render flood.
    @State private var derived: TodayDerived?
    @State private var derivedKey: TodayInputKey?

    // Support sheet (donate + contact) — opened from the home toolbar on macOS, and from an
    // in-content control on iOS (a primary tab has no NavigationStack, so a `.toolbar` item never
    // renders on iPhone — the affordance was dead there before this in-flow button + sheet, #185-class).
    @State private var showingSupport = false

    // "How your scores work" guide — presented at a specific score's section when the ⓘ on that
    // score (or the first-run card) is tapped. nil = not shown. ScoreSection is Identifiable, so
    // .sheet(item:) drives both presentation and the deep-link target in one binding.
    @State private var guideSection: ScoreSection?
    /// `nil` means the user tapped the generic first-run card / a non-section entry: open at the top.
    @State private var showGuideTop = false

    // One-time, dismissible first-run card pointing at the guide. Set true by either the primary tap
    // or the ✕, so it never shows again. @AppStorage matches the file's existing prefs style (#103).
    @AppStorage(Self.guideCardSeenKey) private var scoringGuideCardSeen = false
    static let guideCardSeenKey = "scoringGuideCardSeen"

    // THE single grid definition — every tile group reuses it so margins line up. minimum 150 (not
    // 168) so two tiles reliably fit a phone's ~345pt content width; at 168 the grid sat on the
    // single-vs-two-column boundary and could collapse to one full-width column on a narrow phone.
    private let grid = [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)]

    /// The logical day the selector resolves to: offset 0 is today's logical day (rolls at 04:00 like
    /// `repo.today`), past offsets count back from it. Presentation-only — used to pick which stored row
    /// is on screen and to anchor the HR-trend window. Mirrors Android TodayScreen.selectedDay.
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    /// follows `repo.today?.day` so it tracks the row the resolver actually surfaces — including the
    /// non-UTC pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one.
    /// Falls back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }

    /// The DailyMetric shown for the selected day. Offset 0 prefers the live `repo.today` (so the small
    /// hours after midnight still show the logical day's banked row), past offsets look the stored row up
    /// by key. nil when no row exists for that day — every read-out then renders its honest empty state.
    private var displayDay: DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Recovery cold-start: recovery is nil until the HRV baseline crosses the seed gate
    /// (Baselines.minNightsSeed valid nights). While calibrating, this is the count of nights
    /// banked so far — it drives an honest "Calibrating — N of 4 nights" on the recovery ring,
    /// the synthesis card and the Key Metrics tile instead of a bare empty state. It self-clears
    /// the moment recovery populates, and never claims "calibrating" at/above the seed gate.
    /// Mirrors Android TodayScreen.recoveryCalibrationNights (7b5f212). Only meaningful for today —
    /// a past day with no recovery is missing data, not mid-calibration, so navigated days return nil.
    private var recoveryCalibration: Int? {
        guard selectedDayOffset == 0 else { return nil }
        if derivedKey == todayInputKey, let d = derived { return d.calibration }
        return computeCalibration()
    }

    /// On-device training-readiness synthesis (HRV / resting-HR / load). Read through the
    /// memoized cache so the full-history sort inside `evaluate` runs once per data change,
    /// not once per ~1 Hz `body` pass while HR streams.
    private var readiness: ReadinessEngine.Readiness {
        if derivedKey == todayInputKey, let d = derived { return d.readiness }
        return computeReadiness()
    }

    // MARK: Memoization plumbing (absorbs the 1 Hz live-HR body flood)

    /// Cached expensive derivations and the inputs they were built from.
    private struct TodayDerived { let readiness: ReadinessEngine.Readiness; let calibration: Int? }

    /// A cheap, O(1) fingerprint of the inputs `derived` depends on. Recomputed every render
    /// (and per accessor call), but it only holds counts + the identity of the first/last and
    /// today rows + the selected offset, so equality is fast and never walks the history.
    private struct TodayInputKey: Equatable {
        let loaded: Bool
        let daysCount: Int
        let firstDay: String?
        let lastDay: DailyMetric?
        let today: DailyMetric?   // covers repo.today?.recovery (calibration) and day rollover
        let offset: Int
        let refreshSeq: Int
    }

    private var todayInputKey: TodayInputKey {
        TodayInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last,
            today: repo.today,
            offset: selectedDayOffset,
            refreshSeq: repo.refreshSeq)
    }

    private func computeReadiness() -> ReadinessEngine.Readiness {
        ReadinessEngine.evaluate(days: repo.days, today: Repository.logicalDayKey(Date()))
    }

    private func computeCalibration() -> Int? {
        guard selectedDayOffset == 0 else { return nil }
        return RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                                hasRecovery: repo.today?.recovery != nil)
    }

    private func buildDerived() -> TodayDerived {
        TodayDerived(readiness: computeReadiness(), calibration: computeCalibration())
    }

    /// Synthesis-card copy while the recovery baseline calibrates; nil otherwise. Built as
    /// LocalizedStringKey literals so the String Catalog picks up the %lld patterns.
    private var calibrationStatus: LocalizedStringKey? {
        recoveryCalibration == nil ? nil : "Calibrating"
    }
    private var calibrationDetail: LocalizedStringKey? {
        guard let n = recoveryCalibration else { return nil }
        return "Learning your baseline — \(n) of \(Baselines.minNightsSeed) nights."
    }

    /// The iOS tab is already labelled "Today", and "Control Center" collides with the OS feature of
    /// that name (on both platforms). Match the tab on iOS; keep the established name on macOS.
    private var screenTitle: LocalizedStringKey {
        #if os(iOS)
        "Today"
        #else
        "Control Center"
        #endif
    }

    /// The big scaffold title — suppressed on iOS, where `todayTopBar` replaces it; macOS keeps its
    /// "Control Center" header.
    private var scaffoldTitle: LocalizedStringKey? {
        #if os(iOS)
        nil
        #else
        screenTitle
        #endif
    }

    #if os(iOS)
    /// The day-nav label: relative for today/yesterday, else a short date.
    private var dayNavLabel: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let d = Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: Date()) ?? Date()
            return Self.navDayFmt.string(from: d)
        }
    }

    private static let navDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Picker binding that converts a chosen date back to a whole-day offset (capped at today).
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: Date()) ?? Date() },
            set: { newValue in
                let cal = Calendar.current
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: newValue),
                                              to: cal.startOfDay(for: Date())).day ?? 0
                selectedDayOffset = max(0, days)
                showDayPicker = false
            }
        )
    }

    /// Compact WHOOP-style top bar: a profile/settings button (left), the centred ‹ Today › day-nav
    /// (bold, tappable to jump to a date), and the strap-battery badge (right).
    @ViewBuilder private var todayTopBar: some View {
        ZStack {
            // Centre — the day navigator.
            HStack(spacing: 8) {
                topNavChevron("chevron.left", enabled: true) { selectedDayOffset += 1 }
                Button { showDayPicker = true } label: {
                    Text(dayNavLabel)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayNavLabel). Pick a date")
                .popover(isPresented: $showDayPicker) {
                    DatePicker("", selection: dayPickerBinding, in: ...Date(), displayedComponents: [.date])
                        .datePickerStyle(.graphical).labelsHidden().padding(12)
                }
                topNavChevron("chevron.right", enabled: selectedDayOffset > 0) {
                    if selectedDayOffset > 0 { selectedDayOffset -= 1 }
                }
            }
            // Sides — profile/settings (leading) + updates/quick-action (trailing). The strap-battery
            // reading lives on the dashboard metrics row (#57 removed the duplicate header badge that
            // overlapped the day-nav label).
            HStack {
                Button { showSettings = true } label: {
                    // Shows the user's chosen profile photo (Circle-cropped) if set, else the
                    // default person.crop.circle icon. Still opens Settings on tap.
                    ProfileAvatarView(imageData: profile.avatarImageData, size: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile and settings")
                Spacer()
                // Updates "ringer" — before the +. Bell with a gold unread badge.
                updateBell
                // Quick-action "+" — moved here from the tab bar to balance the avatar on the left and
                // free the bottom bar to four clean tabs. Routes to the shell's quick-action sheet.
                Button { router.requestQuickActions() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(StrandPalette.goldDeepText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(LinearGradient(gradient: StrandPalette.goldGradient,
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .accessibilityLabel("Quick actions")
                .accessibilityHint("Start a workout, log your journal, or breathe")
            }
        }
        .frame(height: 36)
    }

    private func topNavChevron(_ name: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Settings presented as a sheet from the top-bar profile button (sheets inherit the app
    /// environment on iOS, so SettingsView gets the same objects it has under the More tab).
    private var settingsSheet: some View {
        NavigationStack {
            SettingsView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }
    #endif

    /// The Updates "ringer": a bell button (~30pt) with a small gold unread-count badge. Tapping opens
    /// the Updates inbox sheet. Shared by the iOS top bar and the macOS toolbar.
    private var updateBell: some View {
        Button { showUpdatesInbox = true } label: {
            Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if updateStore.unreadCount > 0 {
                        Text("\(min(updateStore.unreadCount, 99))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.goldDeepText)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .frame(minWidth: 15)
                            .background(Capsule().fill(StrandPalette.gold))
                            .offset(x: 6, y: -4)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(updateStore.unreadCount > 0
                            ? "Updates, \(updateStore.unreadCount) unread"
                            : "Updates")
    }

    var body: some View {
        ScreenScaffold(title: scaffoldTitle, onRefresh: { await repo.refresh() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                #if os(iOS)
                // Compact top bar: profile/settings (left) · ‹ Today › day-nav (centre, bold) · strap
                // battery (right). Replaces the big title + the full-width day-nav pill (WHOOP-style).
                todayTopBar
                HealthAlertBanner()
                #else
                HealthAlertBanner()
                // Browse past days — chevrons + a date jump capped at today (no future days).
                DayNavBar(selectedOffset: selectedDayOffset) { selectedDayOffset = $0 }
                #endif
                // The "still building" and "new here?" prompts are about getting today's scores going,
                // so they stay anchored to today rather than reappearing on every navigated past day.
                if selectedDayOffset == 0 && repo.today?.recovery == nil {
                    // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
                    if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
                    if !scoresBuildingDismissed {
                        DataPendingNote(
                            title: "Live now. Your scores are building.",
                            message: "Your live heart rate is working from the strap, and charge, effort and rest build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                        )
                        // A small × dismisses the card INTO the Updates inbox (restorable from there).
                        .overlay(alignment: .topTrailing) {
                            todayCardDismissButton {
                                dismissTodayCard(
                                    id: "scoresBuilding",
                                    title: "Live now. Your scores are building.",
                                    message: "Charge, Effort and Rest build over your next few nights of wear."
                                )
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                // One-time pointer to the scoring guide, shown once scores exist.
                if selectedDayOffset == 0 && repo.today?.recovery != nil && !scoringGuideCardSeen && !newHereDismissed {
                    scoringGuideFirstRunCard
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                #if os(iOS)
                // Pull the rings up under the compact top bar — the full section gap left too much air
                // above them now the big "Today's Synthesis" header is gone.
                heroSection.padding(.top, -16)
                #else
                heroSection
                #endif
                heartRateTrendSection
                readinessSection
                metricsSection
                workoutsSection
                // Honest, dismissible 12-hourly donation ask — a card in the flow, never a modal.
                DonationNudgeCard()
                #if os(iOS)
                // iOS entry point to Support (donate + contact). macOS opens the same sheet from the
                // toolbar heart, but a primary tab on iPhone has no nav bar to host a `.toolbar` item,
                // so the affordance lives in-content here and presents SupportView as an auto-sized sheet.
                supportRow
                #endif
                sourcesSection
            }
        }
        // Reload when the data refreshes OR the selected day changes — the HR trend and Rest score are
        // day-scoped, so navigating must re-fetch them for the newly selected window.
        .task(id: TodayLoadKey(seq: repo.refreshSeq, offset: selectedDayOffset)) { await loadAll() }
        // Persist the freshly-built derivations so subsequent (1 Hz) renders with the same
        // inputs hit the cache instead of recomputing. Writing @State during `body` is not
        // allowed, so commit it after layout — the memoized accessors already return the
        // correct value for the change frame, so there is no flash and no missed update.
        // macOS-13-safe single-param onChange.
        .onChangeCompat(of: todayInputKey) { newKey in
            derived = buildDerived()
            derivedKey = newKey
        }
        .onAppear {
            if derivedKey != todayInputKey {
                derived = buildDerived()
                derivedKey = todayInputKey
            }
        }
        #if os(macOS)
        // macOS hosts the Support affordance in the window toolbar (RootView's NavigationSplitView
        // supplies the toolbar) and presents it as the fixed-width SupportModalOverlay panel. On iOS
        // this path is unavailable (no nav bar on a primary tab) and the 560pt panel would overflow
        // iPhone, so the in-content `supportRow` + auto-sized `.sheet` below take over instead.
        .toolbar {
            // Support heart on the LEADING (left) edge of the window toolbar.
            ToolbarItem(placement: .navigation) {
                Button { showingSupport = true } label: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(StrandPalette.metricRose)
                        .attentionWiggle(period: 4)
                }
                .help("Support NOOP — donate or get in touch")
                .accessibilityLabel("Support NOOP — donate or get in touch")
            }
            // The Updates "ringer" on the TRAILING (top-right) edge, separated from the heart (iOS hosts
            // it in the compact top bar instead).
            ToolbarItem(placement: .primaryAction) {
                updateBell.help("Updates")
            }
        }
        .overlay {
            if showingSupport {
                SupportModalOverlay(isPresented: $showingSupport)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSupport)
        #else
        // iOS: present Support as an auto-sized sheet (sizes to the device, unlike the 560pt overlay).
        .sheet(isPresented: $showingSupport) { SupportView() }
        // Profile/settings from the top-bar button.
        .sheet(isPresented: $showSettings) { settingsSheet }
        #endif
        // The scoring guide, opened at a specific score from its ⓘ.
        .sheet(item: $guideSection) { section in
            ScoringGuideView(initialSection: section, onClose: { guideSection = nil })
        }
        // The scoring guide opened at the top (the first-run card's primary action).
        .sheet(isPresented: $showGuideTop) {
            ScoringGuideView(onClose: { showGuideTop = false })
        }
        // The Updates inbox (the header bell). Both platforms.
        .sheet(isPresented: $showUpdatesInbox) {
            UpdatesInboxView(onClose: { showUpdatesInbox = false })
        }
        // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the
        // card reappears (the inbox also clears the @AppStorage key directly, but this covers an
        // already-mounted Today). Cleared once handled.
        .onChangeCompat(of: updateStore.restoreRequest) { payload in
            guard let payload else { return }
            withAnimation(StrandMotion.interactive) { restoreTodayCard(payload) }
            updateStore.restoreRequest = nil
        }
    }

    /// Flip a Today info-card's dismissed flag back to false so it reappears (driven by the inbox's
    /// "Restore to Today"). Keyed on the card id stored in the update's `restorePayload`.
    private func restoreTodayCard(_ cardID: String) {
        switch cardID {
        case "scoresBuilding": scoresBuildingDismissed = false
        case "newHere":        newHereDismissed = false
        default:               break
        }
    }

    /// Dismiss a Today info-card INTO the inbox: set its @AppStorage flag (so it stays gone) and post a
    /// `.dismissedCard` update carrying the card id so it can be restored.
    private func dismissTodayCard(id: String, title: String, message: String) {
        StrandHaptic.selection.play()
        switch id {
        case "scoresBuilding": scoresBuildingDismissed = true
        case "newHere":        newHereDismissed = true
        default:               break
        }
        updateStore.post(UpdateItem(
            kind: .dismissedCard,
            title: title,
            message: message,
            restorePayload: id
        ))
    }

    /// A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
    /// `DataPendingNote`). Matches the "New here?" card's × styling.
    private func todayCardDismissButton(_ action: @escaping () -> Void) -> some View {
        Button { withAnimation(StrandMotion.interactive) { action() } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss to Updates")
    }

    // MARK: First-run scoring-guide card (one-time, dismissible)

    /// "New here?" — a single, dismissible card that points first-time users at the guide. Tapping the
    /// card opens the guide; the ✕ closes it. Either action sets `scoringGuideCardSeen`, so it shows
    /// once and never again. Mirrors the DonationNudgeCard's in-flow, never-modal pattern.
    private var scoringGuideFirstRunCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New here?")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("See how Charge, Effort and Rest are calculated — and how they differ from WHOOP.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        scoringGuideCardSeen = true
                        showGuideTop = true
                    } label: {
                        Label("How your scores work", systemImage: "arrow.right")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button {
                    // Dismiss INTO the Updates inbox (restorable), rather than permanently hiding.
                    withAnimation(StrandMotion.interactive) {
                        dismissTodayCard(
                            id: "newHere",
                            title: "New here?",
                            message: "How Charge, Effort and Rest are calculated — and how they differ from WHOOP."
                        )
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            // The whole card is tappable as the primary action; the ✕ stops the tap from also firing.
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(iOS)
                StrandHaptic.selection.play()
                #endif
                scoringGuideCardSeen = true
                showGuideTop = true
            }
        }
        // Press-down feedback for the tappable card surface.
        .strandPressable()
    }

    #if os(iOS)
    // MARK: Support entry point (iOS) — the in-content stand-in for the macOS toolbar heart.

    /// An in-flow card that opens the Support sheet (donate + contact). The whole card is the tap
    /// target; reuses the heart.fill + metricRose styling and the accessibility copy of the macOS
    /// toolbar button so both platforms read identically. iOS-only — macOS keeps the toolbar item.
    private var supportRow: some View {
        Button {
            StrandHaptic.selection.play()
            showingSupport = true
        } label: {
            NoopCard {
                HStack(spacing: 14) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.metricRose)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Support NOOP")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Donate or get in touch — totally optional.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        // Press-down feedback for the full-card button surface.
        .buttonStyle(StrandPressableButtonStyle())
        .accessibilityLabel("Support NOOP — donate or get in touch")
    }
    #endif

    // MARK: Readiness — on-device training-readiness synthesis (HRV / resting-HR / load).

    @ViewBuilder
    private var readinessSection: some View {
        let r = readiness
        if r.level != .insufficient {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Readiness", overline: "Should you push today?")
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle().fill(readinessColor(r.level)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(r.headline).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel("Readiness: \(levelWord(r.level)). \(r.headline)")
                            Spacer()
                            if let acwr = r.acwr {
                                Text("load \(String(format: "%.2f", acwr))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .help("Acute (7-day) vs chronic (28-day) training load. 0.8–1.3 is the sweet spot.")
                            }
                        }
                        Text(r.summary).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !r.signals.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(r.signals, id: \.key) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    // Glyph + colour (not colour alone) so the flag reads
                                    // for colour-blind users; hidden from VoiceOver since the
                                    // flag word is folded into the row's combined label below.
                                    Image(systemName: flagSymbol(s.flag))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(flagColor(s.flag))
                                        .padding(.top, 4)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.label).font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                        if let evidence = s.evidence {
                                            Text(evidence).font(StrandFont.captionNumber)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                    }
                                        .frame(width: 104, alignment: .leading)
                                    Text(s.detail).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(s.label), \(flagWord(s.flag)): \(s.detail)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Word + glyph equivalents so the colour-coded severity isn't carried by hue
    // alone — read by VoiceOver and visible to colour-blind users.
    private func levelWord(_ l: ReadinessEngine.Level) -> String {
        switch l {
        case .primed:       return "Primed"
        case .balanced:     return "Balanced"
        case .strained:     return "Strained"
        case .rundown:      return "Run down"
        case .insufficient: return "Not enough data"
        }
    }

    private func flagWord(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "Good"
        case .neutral: return "Neutral"
        case .watch:   return "Watch"
        case .bad:     return "Alert"
        }
    }

    /// Colour-independent glyph so severity isn't conveyed by hue alone.
    private func flagSymbol(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "checkmark.circle.fill"
        case .neutral: return "minus.circle.fill"
        case .watch:   return "exclamationmark.circle.fill"
        case .bad:     return "exclamationmark.triangle.fill"
        }
    }

    private func readinessColor(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    private func flagColor(_ f: ReadinessEngine.Flag) -> Color {
        switch f {
        case .good:    return StrandPalette.accent
        case .neutral: return StrandPalette.textTertiary
        case .watch:   return StrandPalette.statusWarning
        case .bad:     return StrandPalette.metricRose
        }
    }

    // MARK: (a) HERO — three ring scores (Charge / Effort / Rest) over a scenic backdrop,
    // then the green-tinted Synthesis coaching card. Bevel layout.

    @ViewBuilder
    private var heroSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // The WHOOP-style three-ring hero leads the screen directly — the "AT A GLANCE / Today's
            // Synthesis" header was redundant with the rings, so it's gone. Charge centred + enlarged,
            // flanked by smaller Rest and Effort rings over the scenic backdrop.
            scoreHeroRow(d: d, score: score)

            // The greeting + SOLID/CALIBRATING data-confidence pill ride in their OWN header row
            // ABOVE the card, not as a top-trailing overlay over it (#527). The old overlay reserved
            // a fixed 188pt inset on the card's overline + status rows so the cluster wouldn't collide
            // with them on a narrow iPhone — but that squeezed the big status word below its natural
            // width, so a single word ("Calibrating") was force-broken mid-word ("Calibrati/ng").
            // A separate row CAN'T overlap the "SYNTHESIS" overline or the status word, and lets the
            // card keep its FULL width (titleTrailingInset: 0) so the status stays one line.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(greetingWord)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                recoveryStatePill(score: score)
                    .layoutPriority(1)   // the pill keeps its width; the greeting yields/scales first
            }
            .accessibilityElement(children: .combine)

            // The plain-English read-out — the gold Synthesis card. Full width now the greeting/pill
            // moved to their own row, so the status word never gets squeezed into a mid-word break.
            InsightCard(
                category: "Synthesis",
                status: calibrationStatus ?? "\(hrvInsightStatus(d, score: score))",
                detail: calibrationDetail ?? "\(hrvInsightDetail(d, score: score))",
                statusColor: score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary,
                tint: StrandPalette.chargeColor
            )

            // Honest "why is Effort 0?" caption (#482/#480) — only when today's Effort is a real
            // near-zero, so a calm day reads as explained rather than broken.
            if let note = effortZeroNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }

            // HRV / Resting HR / Respiratory — the vitals that drive recovery, below the guidance.
            recoveryVitalsCard(d)
        }
    }

    // MARK: Screen-4 — data-confidence pill, vitals metric card, HRV-baseline insight

    /// The SOLID / CALIBRATING data-confidence chip beside the hero title (README screen 4).
    /// SOLID (gold) once today carries a settled recovery score; CALIBRATING (slate) while the
    /// HRV baseline is still forming (it shows the running "N of 4" count); for a navigated past
    /// day with no score it falls back to CALIBRATING without a count. Drives off the SAME
    /// recovery / calibration bindings the rings use — presentation only.
    @ViewBuilder
    private func recoveryStatePill(score: Double?) -> some View {
        if score != nil {
            ScoreStatePill(.solid)
        } else if let n = recoveryCalibration {
            ScoreStatePill(.calibrating, text: "Calibrating — \(n) of \(Baselines.minNightsSeed)")
        } else {
            ScoreStatePill(.calibrating)
        }
    }

    /// Screen-4 "metric card": HRV / Resting HR / Respiratory as a stack of labelled metric rows
    /// inside one frosted card — the three vitals that feed recovery. HRV reads teal (its biometric
    /// hue), Resting HR burnt-orange, Respiratory gold. Values come straight from the selected day's
    /// `DailyMetric` (respiratory falls back to the loaded sparkline tail, as the tile does), so this
    /// changes no data — it only re-presents existing bindings as the README's metric-row component.
    @ViewBuilder
    private func recoveryVitalsCard(_ d: DailyMetric?) -> some View {
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(spacing: 0) {
                metricRow(icon: "waveform.path.ecg", label: "HRV",
                          value: d?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—", unit: "ms",
                          tint: StrandPalette.metricCyan)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "heart.fill", label: "Resting HR",
                          value: d?.restingHr.map { "\($0)" } ?? "—", unit: "bpm",
                          tint: StrandPalette.metricRose)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "lungs.fill", label: "Respiratory",
                          value: d?.respRateBpm.map { String(format: "%.1f", $0) }
                              ?? latestString("resp_rate", decimals: 1),
                          unit: "rpm",
                          tint: StrandPalette.accent)
            }
        }
    }

    /// One README "metric row": a metric-hue line icon, a secondary label, and a right-aligned bold
    /// value with a small unit. Rows are divided by a hairline. Shared by the Today vitals card.
    @ViewBuilder
    private func metricRow(icon: String, label: String, value: String, unit: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }

    /// Screen-4 insight headline — when the HRV baseline is established, the gold "primed" read
    /// keyed on how far today's HRV sits above/below the learned baseline ("HRV 12% over baseline");
    /// otherwise the recovery-state word. Purely a re-presentation of the existing recovery + HRV
    /// bindings (no new computation beyond the baseline mean already available on `repo.days`).
    private func hrvInsightStatus(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisWord(score) }
        let sign = pct >= 0 ? "over" : "under"
        return "HRV \(abs(pct))% \(sign) baseline"
    }

    /// The supporting line for the screen-4 insight: the primed/steady read tied to the HRV delta,
    /// folding in the recovery-state synthesis so the card still reads as a coaching summary.
    private func hrvInsightDetail(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisDetail(d) }
        let lead: String
        if pct >= 8 { lead = "Your nervous system is well-recovered — you're primed to push" }
        else if pct >= -8 { lead = "You're in balance with your baseline — moderate strain is well-judged" }
        else { lead = "HRV is below your baseline — ease into the day" }
        return lead + ". " + synthesisDetail(d)
    }

    /// Today's HRV as a percentage above/below the learned baseline (mean of prior nights' avgHrv),
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate) — the insight then falls back to the state word.
    private func hrvBaselineDeltaPct(_ d: DailyMetric?) -> Int? {
        guard let today = d?.avgHrv, today > 0 else { return nil }
        // Baseline = mean of the prior nights' HRV, excluding the selected day so "vs baseline"
        // compares today against history. Needs the same seed depth recovery uses to be honest.
        let prior = repo.days
            .filter { $0.day != selectedDayKey }
            .compactMap(\.avgHrv)
            .filter { $0 > 0 }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        let baseline = prior.reduce(0, +) / Double(prior.count)
        guard baseline > 0 else { return nil }
        return Int(((today - baseline) / baseline * 100).rounded())
    }

    /// The three score rings over a scenic hero background — WHOOP-style, with the Charge (recovery)
    /// ring centred and enlarged as the hero and smaller Rest / Effort rings flanking it. Each ring
    /// floats cleanly on the scenic field (no per-ring card); a tappable label + chevron sits beneath
    /// each and opens that score's section in the scoring guide. Rings are sized off the available
    /// width so the trio never crushes on a narrow phone nor bloats on iPad.
    @ViewBuilder
    private func scoreHeroRow(d: DailyMetric?, score: Double?) -> some View {
        GeometryReader { geo in
            // Centre (hero) ring sized off width; the flanking rings are ~66% of it. Grouped tightly and
            // centred so the trio reads as one cluster, bottom-aligned so all three share a baseline and
            // the larger Charge ring rises above its neighbours. The rings float on the page (no boxed
            // card) like WHOOP.
            let center = min(150, max(110, (geo.size.width - 12) / 2.3))
            let side = (center * 0.66).rounded()
            HStack(alignment: .bottom, spacing: 18) {
                heroRingColumn(section: .rest, domain: .rest) { restRing(diameter: side) }
                heroRingColumn(section: .charge, domain: .charge) { chargeRing(score: score, d: d, diameter: center) }
                heroRingColumn(section: .effort, domain: .effort) { effortRing(d: d, diameter: side) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(height: 214)
    }

    /// One hero ring column: the ring centred, with a tappable UPPERCASE domain label + chevron
    /// beneath it (the WHOOP affordance) that opens the matching scoring-guide section. The ring is
    /// intrinsically diameter×diameter, so the column just centres it and stretches to an equal share
    /// of the row width.
    @ViewBuilder
    private func heroRingColumn<RingBody: View>(
        section: ScoreSection, domain: DomainTheme, @ViewBuilder ring: () -> RingBody
    ) -> some View {
        VStack(spacing: 10) {
            ring()
            Button { guideSection = section } label: {
                HStack(spacing: 3) {
                    Text(domain.rawValue.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How \(domain.rawValue.capitalized) is calculated")
        }
    }

    /// Charge (recovery 0–100) hero ring — the premium animated GlowRing, with a calibrating / no-data
    /// track when nil.
    @ViewBuilder
    private func chargeRing(score: Double?, d: DailyMetric?, diameter: CGFloat) -> some View {
        if let s = score {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.chargeColor, diameter: diameter, lineWidth: diameter * 0.085)
        } else {
            emptyHeroRing(diameter: diameter) { ringEmptyOverlay(d: d) }
        }
    }

    /// Effort (strain) hero ring, honouring the 0–100 / WHOOP-0–21 toggle (#313). Integer on the 0–100
    /// axis so it matches Charge/Rest; one decimal on the WHOOP 0–21 axis where the tenth matters.
    @ViewBuilder
    private func effortRing(d: DailyMetric?, diameter: CGFloat) -> some View {
        if effortStrain(d) != nil, let gv = effortGaugeValue(d) {
            GlowRing(fraction: gv / effortGaugeMax, value: gv,
                     format: { effortScale == .whoop ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" },
                     color: StrandPalette.effortColor, diameter: diameter, lineWidth: diameter * 0.085)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData() }
        }
    }

    /// Rest (sleep composite 0–100) hero ring.
    @ViewBuilder
    private func restRing(diameter: CGFloat) -> some View {
        if let s = restScore {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.restColor, diameter: diameter, lineWidth: diameter * 0.085)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData() }
        }
    }

    /// The faint full-circle track with a centred overlay, shown when a score is still calibrating/absent.
    @ViewBuilder
    private func emptyHeroRing<Overlay: View>(diameter: CGFloat, @ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            Circle().stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: diameter * 0.085, lineCap: .round))
            overlay()
        }
        .frame(width: diameter, height: diameter)
    }

    /// The effective Effort strain (NOOP 0–100 axis) the gauge shows. For TODAY this prefers the live
    /// in-progress value computed over the day's HR (midnight→now) in `loadAll`, so the gauge reflects
    /// the accumulating day rather than the last persisted daily row — which only refreshes when the
    /// heavy daily pass runs, so early in the day the stored row is yesterday's Effort or a stale 0.0
    /// (#402). Falls back to the stored `strain` when there isn't yet enough of today's HR to score
    /// (StrainScorer.minReadings). Navigated past days always use the stored row.
    private func effortStrain(_ d: DailyMetric?) -> Double? {
        if selectedDayOffset == 0, let live = liveTodayStrain {
            // Effort accrues over a day and must never visibly DROP. The in-progress recompute (raw day
            // HR, midnight→now) can UNDER-read when today's HR is sparse or a logged workout's load isn't
            // in the raw stream — e.g. a 5/MG user who trained this morning saw today's real 38.3 get
            // replaced by a live 0 (#489/#506). Floor at the day's already-earned Effort. `d` (displayDay)
            // for today is ALWAYS today's row or nil — never a prior day — so this can't resurrect a stale
            // day; it only stops the gauge dropping below what's already been counted today.
            if let stored = d?.strain { return Swift.max(live, stored) }
            return live
        }
        return d?.strain
    }

    /// When TODAY's Effort scores a genuine near-zero — there's enough HR to score, but it never
    /// crossed the cardiovascular "effort zone" (~50% of heart-rate reserve) — explain the 0 instead
    /// of leaving a bare number that reads as a fault (#482/#480). A low-HR day honestly earns ~0, the
    /// same as a WHOOP low-strain day; the 5/MG just hits it more often (sparser HR, lower daytime
    /// peaks). Only for today, only when the score is ~0 and a score exists (a no-data ring shows its
    /// own overlay, a past day isn't annotated).
    private var effortZeroNote: String? {
        guard selectedDayOffset == 0, let s = effortStrain(displayDay), s < 1.0 else { return nil }
        return "No cardio load yet — Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero."
    }

    /// Strain value to feed the Effort gauge, on the SELECTED display scale (#313). The effective
    /// `strain` is on NOOP's 0–100 Effort axis; `UnitFormatter.effortValue` converts it to the
    /// user's chosen scale (0–100 native, or ×21/100 down to WHOOP's 0–21) so the arc + number
    /// match the rest of the app's Effort read-outs. Pairs with `effortGaugeMax` for the "of N".
    private func effortGaugeValue(_ d: DailyMetric?) -> Double? {
        effortStrain(d).map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    /// The Effort gauge's scale maximum — 100 on NOOP's native axis, 21 on the WHOOP axis. Drives
    /// the arc fraction and the gauge's "of N" caption so both follow the toggle (#313).
    private var effortGaugeMax: Double { effortScale == .whoop ? 21 : 100 }

    /// Honest overlay shown over the Charge ring when recovery is nil: calibrating count or No data.
    @ViewBuilder
    private func ringEmptyOverlay(d: DailyMetric?) -> some View {
        VStack(spacing: 3) {
            if let n = recoveryCalibration {
                Text("Calibrating").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("\(n) of \(Baselines.minNightsSeed)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else {
                ringNoData()
            }
        }
    }

    @ViewBuilder
    private func ringNoData() -> some View {
        Text("No data").font(StrandFont.headline).foregroundStyle(StrandPalette.textSecondary)
    }

    // MARK: HEART RATE — today's continuous HR, off the strap's own ~1Hz history.

    /// A full-width 24-hour heart-rate trend, plotted from 5-minute bucket means of the strap's
    /// `hrSample` history (offloaded even while the app was closed, so the day reads continuously).
    /// Hidden until there are at least two buckets — a strap-only user with no wear today sees nothing
    /// rather than an empty axis. Mirrored on Android (TodayScreen.kt HeartRateTrendCard).
    @ViewBuilder
    private var heartRateTrendSection: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "\(selectedDayOverline)")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: selectedDayOffset == 0 ? "5-minute average · since midnight" : "5-minute average · selected day",
                    trailing: v.last.map { "\(Int($0.rounded())) bpm" },
                    tint: StrandPalette.metricRose
                ) {
                    OverviewHRChart(
                        points: hrPoints,
                        sleep: sleepSpan,
                        workouts: workoutSpans,
                        recovery: recoveryMarker,
                        effort: effortMarker,
                        gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                        valueRange: hrRange(v),
                        xRange: hrAxis,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { "\(Int($0.rounded())) bpm" },
                        dateFormat: { Self.hrTimeFmt.string(from: $0) }
                    )
                } footer: {
                    ChartFooter([
                        ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                        ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                        ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                    ])
                }
            }
        }
    }

    /// Padded HR axis range so the line never sits flush against an edge (mirrors MetricExplorer.valueRange).
    private func hrRange(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 40...120 }
        if hi <= lo { return (lo - 5)...(hi + 5) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: Overview HR markers (sleep band · workout glyphs · Charge / Effort)

    /// The HR chart's x-window, derived from the loaded points (used to scope workout glyphs).
    private var hrWindow: ClosedRange<Date>? {
        guard let lo = hrPoints.first?.date, let hi = hrPoints.last?.date, lo < hi else { return nil }
        return lo...hi
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06").
    private func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    /// Last night's sleep as a shaded band, labelled with its duration.
    private var sleepSpan: OverviewHRChart.SleepSpan? {
        guard let s = sleepToday else { return nil }
        // Use the EFFECTIVE onset so a hand-corrected bedtime shows the same band/duration here as on
        // the Sleep tab (not the detected onset). (#318)
        return .init(
            start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
            end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
            label: hoursMinutes(s.endTs - s.effectiveStartTs)
        )
    }

    /// Each workout overlapping the HR window, as a sport glyph anchored at its HR peak.
    private var workoutSpans: [OverviewHRChart.WorkoutSpan] {
        guard let win = hrWindow else { return [] }
        return workouts.compactMap { w in
            let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
            guard end >= win.lowerBound, start <= win.upperBound else { return nil }
            return .init(start: start, end: end, symbol: sportSymbol(w.sport))
        }
    }

    /// "Charge" marker (NOOP's name for recovery) at wake time (sleep end), else at the window start.
    /// Hidden while calibrating.
    private var recoveryMarker: OverviewHRChart.EdgeMarker? {
        guard let rec = displayDay?.recovery else { return nil }
        let at = sleepToday.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
            ?? hrPoints.first?.date
        guard let date = at else { return nil }
        return .init(date: date, label: "\(Int(rec.rounded()))% Charge",
                     color: StrandPalette.recoveryColor(rec), alignment: .leading)
    }

    /// "Effort" marker pinned to the right edge (latest HR sample). Routed through the SAME formatter
    /// as the Effort tile (`UnitFormatter.effortDisplay`) so it honours the 0–100 / WHOOP-0–21 scale
    /// preference (#268) and reads identically — the stored strain is on the 0–100 axis, so a morning
    /// "21.2" is 21.2-of-100, not WHOOP's near-max 21-of-21.
    private var effortMarker: OverviewHRChart.EdgeMarker? {
        guard let strain = displayDay?.strain, let date = hrPoints.last?.date else { return nil }
        return .init(date: date,
                     label: "\(UnitFormatter.effortDisplay(strain, scale: effortScale)) Effort",
                     color: StrandPalette.effortTint(fraction: strain / StrainScorer.maxStrain), alignment: .trailing)
    }

    // MARK: (b) METRICS — one uniform grid of 104pt StatTiles, every cell filled.

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // The section header keeps its "14-day trend" trailing label; an Edit control sits beside it
            // to open the local layout editor (#251). No new nav destination — a sheet over Today.
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Key Metrics", overline: "\(selectedDayOverline)", trailing: "14-day trend")
                Button {
                    showingMetricsEditor = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(StrandFont.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Edit Key Metrics")
                .help("Choose which Key Metrics show and reorder them")
            }
            // Render the enabled tiles in the saved order; an empty layout still shows the default set.
            LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(enabledKeyMetrics) { metric in
                    keyMetricTile(metric)
                }
            }
        }
        .sheet(isPresented: $showingMetricsEditor) {
            KeyMetricsEditorSheet(layoutRaw: $keyMetricsRaw)
        }
    }

    /// One Key-Metric tile, keyed so the grid can be filtered + reordered per the saved layout (#251).
    /// Each case is byte-for-byte the tile that used to be hard-coded in the grid — the refactor only
    /// changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    @ViewBuilder
    private func keyMetricTile(_ metric: KeyMetric) -> some View {
        let d = displayDay
        let aLatest = appleDays.last
        switch metric {
        case .charge:
            StatTile(
                label: "Charge",
                value: d?.recovery.map { "\(Int($0.rounded()))%" }
                    ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" } ?? "—",
                caption: d?.recovery.map { StrandPalette.recoveryState($0).capitalized }
                    ?? recoveryCalibration.map { _ in "Calibrating" },
                accent: d?.recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                sparkline: sparks["recovery"],
                sparkColor: StrandPalette.accent
            )
        case .effort:
            // Unscored TODAY → a short "building" hint instead of the "of N" axis caption, so a
            // fresh user reads "coming" not "broken" (#527); a scored day keeps "of N".
            StatTile(
                label: "Effort",
                value: d?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                caption: d?.strain != nil ? "of \(UnitFormatter.effortScaleMax(effortScale))"
                                          : (buildingHint(.effort) ?? "of \(UnitFormatter.effortScaleMax(effortScale))"),
                accent: d?.strain.map { StrandPalette.effortTint(fraction: $0 / StrainScorer.maxStrain) } ?? StrandPalette.textPrimary,
                sparkline: sparks["strain"],
                sparkColor: StrandPalette.strain066
            )
            .overlay(alignment: .topTrailing) { scoreInfoButton(.effort) }
        case .rest:
            // Unscored TODAY → "building, wear it tonight" instead of a lone "—" caption (#527);
            // a scored day keeps its sleep-duration / efficiency caption.
            StatTile(
                label: "Rest",
                value: restScore.map { "\(Int($0.rounded()))%" } ?? "—",
                caption: restScore != nil ? restCaption(d) : (buildingHint(.rest) ?? restCaption(d)),
                accent: restScore.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                sparkline: sparks["sleep_total_min"],
                sparkColor: StrandPalette.metricPurple
            )
            .overlay(alignment: .topTrailing) { scoreInfoButton(.rest) }
        case .hrv:
            StatTile(
                label: "HRV",
                value: d?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—",
                caption: "ms",
                accent: StrandPalette.metricPurple,
                sparkline: sparks["hrv"],
                sparkColor: StrandPalette.metricPurple
            )
        case .restingHr:
            StatTile(
                label: "Resting HR",
                value: d?.restingHr.map { "\($0)" } ?? "—",
                caption: "bpm",
                accent: StrandPalette.metricRose,
                sparkline: sparks["rhr"],
                sparkColor: StrandPalette.metricRose
            )
        case .bloodOxygen:
            StatTile(
                label: "Blood Oxygen",
                value: d?.spo2Pct.map { String(format: "%.0f%%", $0) } ?? "—",
                caption: "SpO₂",
                accent: StrandPalette.metricCyan,
                sparkline: sparks["spo2"],
                sparkColor: StrandPalette.metricCyan
            )
        case .respiratory:
            StatTile(
                label: "Respiratory",
                value: d?.respRateBpm.map { String(format: "%.1f", $0) } ?? latestString("resp_rate", decimals: 1),
                caption: "rpm",
                accent: StrandPalette.accent,
                sparkline: sparks["resp_rate"],
                sparkColor: StrandPalette.accent
            )
        case .steps:
            // Prefer a REAL step count: the strap's own @57 counter (DailyMetric.steps, WHOOP 5/MG),
            // then Apple Health for the day, then the loaded Apple-Health steps sparkline tail. Only when
            // a day has NONE of those real sources do we fall back to the on-device ESTIMATE (steps_est)
            // a WHOOP 4.0 user gets — flagged "est." so it's never mistaken for a measured count. A day
            // with neither real nor estimated steps shows "—". Mirrors Android (#276/#150).
            let realSteps: String? = (d?.steps).map { intString(Double($0)) }
                ?? aLatest?.steps.map { intString(Double($0)) }
                ?? (sparks["steps"]?.last).map { intString($0) }
            let estSteps = stepsEstByDay[selectedDayKey]
            StatTile(
                label: "Steps",
                value: realSteps ?? estSteps.map { intString(Double($0)) } ?? "—",
                // An estimated day reads "est." so the number is never taken as a measured count.
                caption: realSteps != nil ? "today" : (estSteps != nil ? "est." : "today"),
                accent: (realSteps != nil || estSteps != nil) ? StrandPalette.metricCyan : StrandPalette.textPrimary,
                sparkline: sparks["steps"],
                sparkColor: StrandPalette.metricCyan
            )
        case .weight:
            StatTile(
                label: "Weight",
                value: weightTile(aLatest?.weightKg).value,
                caption: weightTile(aLatest?.weightKg).caption,
                accent: StrandPalette.accent,
                sparkline: sparks["weight"],
                sparkColor: StrandPalette.accent
            )
        case .calories:
            StatTile(
                label: "Calories",
                value: caloriesValue(aLatest),
                caption: "active",
                accent: StrandPalette.metricAmber,
                sparkline: sparks["active_kcal"],
                sparkColor: StrandPalette.metricAmber
            )
        }
    }

    // MARK: (c) LAST WORKOUTS — SAME grid, uniform 104pt workout tiles.

    @ViewBuilder
    private var workoutsSection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last Workouts", overline: "Activity",
                              trailing: "\(workouts.count) total")
                LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StatTile(
                            label: "\(WorkoutSource.displaySport(w.sport))",
                            value: workoutDuration(w),
                            caption: workoutCaption(w),
                            accent: StrandPalette.effortTint(fraction: (w.strain ?? 0) / StrainScorer.maxStrain),
                            delta: w.energyKcal.map { "\(Int($0.rounded())) kcal" },
                            deltaColor: StrandPalette.metricAmber
                        )
                    }
                }
            }
        }
    }

    // MARK: (d) DATA SOURCES — one full-width footer card.

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data Sources", overline: "Provenance")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(
                        badge: "Whoop",
                        tint: StrandPalette.accent,
                        present: !repo.days.isEmpty,
                        detail: "\(repo.days.count) days · \(repo.sleeps.count) sleeps"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    sourceRow(
                        badge: "Apple Health",
                        tint: StrandPalette.metricCyan,
                        present: !appleDays.isEmpty,
                        detail: "\(appleDays.count) days · \(workouts.filter { WorkoutSource.isAppleHealth($0.source) }.count) workouts"
                    )
                    if xiaomiDays > 0 {
                        Divider().overlay(StrandPalette.hairline)
                        sourceRow(
                            badge: "Mi Band",
                            tint: StrandPalette.metricAmber,
                            present: true,
                            detail: "\(xiaomiDays) days · \(xiaomiSleeps) sleeps"
                        )
                    }
                    strapBatteryRow
                    Divider().overlay(StrandPalette.hairline)
                    strapSyncRow
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(badge: String, tint: Color, present: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            SourceBadge("\(badge)", tint: present ? tint : StrandPalette.textTertiary)
            Spacer()
            Text(present ? detail : "Not connected")
                .font(StrandFont.captionNumber)
                .foregroundStyle(present ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        }
    }

    /// Honest strap-sync outcome for a cloud-free app (ports the Android Live line, ed6a31d): the
    /// stalled-offload error when the last one died, else "History synced N ago". Hidden while an
    /// offload runs — SyncingHistoryNote already says so. TimelineView re-renders the relative label
    /// each minute so "5 min ago" can't go stale while the window sits open with no strap connected
    /// (LiveState publishes nothing then).
    @ViewBuilder
    private var strapSyncRow: some View {
        if !live.backfilling {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: 10) {
                    SourceBadge("Strap sync",
                                tint: live.lastSyncError != nil ? StrandPalette.statusWarning
                                    : live.lastSyncedAt != nil ? StrandPalette.accent
                                    : StrandPalette.textTertiary)
                    Spacer()
                    if let error = live.lastSyncError {
                        Text(error)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let at = live.lastSyncedAt {
                        Text("History synced \(relativeAgo(at, now: context.date.timeIntervalSince1970))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Not synced yet")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// Strap battery on the dashboard (#159) — the live reading the keep-alive refreshes, so a glance
    /// covers charge without opening Live. Rendered ONLY while a strap is connected AND a reading
    /// exists; otherwise the row (and its divider) isn't there at all — no empty state.
    @ViewBuilder
    private var strapBatteryRow: some View {
        if live.connected, let pct = live.batteryPct {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 10) {
                SourceBadge("Strap battery", tint: batteryTint(pct))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol(pct))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(batteryTint(pct))
                    Text("\(Int(pct.rounded()))%")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(Int(pct.rounded())) percent\(live.charging == true ? ", charging" : "")")
            }
        }
    }

    /// Battery tint — same thresholds as the menu-bar stat (MenuBarContent.batteryTone).
    private func batteryTint(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return StrandPalette.statusCritical
        case ..<35: return StrandPalette.statusWarning
        default:    return StrandPalette.statusPositive
        }
    }

    /// Level-banded battery glyph; the bolt variant when the strap reports charging.
    private func batterySymbol(_ pct: Double) -> String {
        if live.charging == true { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    // MARK: - Scoring-guide info affordance

    /// A small ⓘ that opens the scoring guide at the given score's section. Sized + tinted as
    /// unobtrusive chrome so it sits in a tile/card corner without competing with the value.
    private func scoreInfoButton(_ section: ScoreSection) -> some View {
        Button {
            guideSection = section
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How \(section.rawValue.capitalized) is calculated")
        .help("How this score is calculated")
    }

    // MARK: - Loading

    private func loadAll() async {
        // 14-day sparklines — Whoop.
        sparks["recovery"]        = await sparkValues("recovery", source: "my-whoop", window: 14)
        sparks["strain"]          = await sparkValues("strain", source: "my-whoop", window: 14)
        sparks["sleep_total_min"] = await sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        sparks["hrv"]             = await sparkValues("hrv", source: "my-whoop", window: 14)
        sparks["rhr"]             = await sparkValues("rhr", source: "my-whoop", window: 14)
        sparks["spo2"]            = await sparkValues("spo2", source: "my-whoop", window: 14)

        // 14-day sparklines — Apple Health.
        sparks["resp_rate"]   = await sparkValues("resp_rate", source: "apple-health", window: 14)
        sparks["steps"]       = await sparkValues("steps", source: "apple-health", window: 14)
        // Steps prefer the strap's own @57 daily total (no metricSeries — it lives on the daily row),
        // so a strap-only WHOOP 5/MG user gets a steps trend without Apple Health. Falls back to the
        // Apple Health series above when the strap supplied no steps (#276).
        let strapSteps = repo.days.suffix(14).compactMap { $0.steps.map(Double.init) }
        if !strapSteps.isEmpty { sparks["steps"] = strapSteps }
        sparks["weight"]      = await sparkValues("weight", source: "apple-health", window: 90)
        sparks["active_kcal"] = await sparkValues("active_kcal", source: "apple-health", window: 14)

        // Rest SCORE for the logical day. `exploreSeries` already merges imported + computed
        // `sleep_performance` (imported-wins), so a Bluetooth-only user sees the on-device Rest
        // composite and an importer sees the export's figure — exactly like the Rest detail screen.
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })

        // Steps ESTIMATE per day (WHOOP 4.0 motion → calibrated steps). exploreSeries reads the computed
        // "-noop" metricSeries the IntelligenceEngine writes, exactly like the Explore "steps_est" metric.
        // Only consulted when a day has no REAL step count (see the .steps tile), so it never overrides a
        // measured value — it just fills the gap a 4.0 user would otherwise see as "—".
        let stepsEstSeries = await repo.exploreSeries(key: "steps_est", source: "my-whoop")
        stepsEstByDay = Dictionary(stepsEstSeries.map { ($0.day, Int($0.value.rounded())) },
                                   uniquingKeysWith: { _, last in last })
        // The selected day's Rest, falling back to the series tail only when today itself is selected —
        // a navigated past day with no Rest row shows "—" rather than borrowing the newest value.
        restScore = restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)

        workouts = await repo.workoutRows()
        appleDays = await repo.appleDailyRows()
        // Mi Band (Mi Fitness import) — distinct days across its representative metric keys.
        let xSteps = await repo.series(key: "steps", source: "xiaomi-band")
        let xSleep = await repo.series(key: "sleep_total_min", source: "xiaomi-band")
        xiaomiDays = Set(xSteps.map(\.day) + xSleep.map(\.day)).count
        if let store = await repo.storeHandle() {
            let farFuture = Int(Date.distantFuture.timeIntervalSince1970)
            xiaomiSleeps = ((try? await store.sleepSessions(deviceId: "xiaomi-band", from: 0, to: farFuture, limit: 4000))?.count) ?? 0
        }

        // HR trend for the SELECTED day — 5-minute bucket means from that logical day's local midnight.
        // For today the window runs to now (an in-progress curve); for a navigated past day it runs the
        // full 24h to the next midnight. The logical day rolls at 04:00 (Repository.logicalDayStart), so
        // in the small hours after midnight today still starts at yesterday's midnight rather than
        // blanking to an empty new-calendar-day axis (#144).
        let dayStart = Calendar.current.startOfDay(for: selectedLogicalDay)
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let windowEnd: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: windowStart, to: windowEnd, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // In-progress Effort for TODAY (#402): score today's strain over the SAME window the HR curve
        // above shows (logical-day midnight → now) so the gauge tracks the day live instead of lagging
        // on the last persisted daily row. Uses the identical params the daily pass uses — Tanaka HRmax
        // from age, today's resting HR (else the default), sex — so the live number matches what the
        // engine will eventually persist. Below StrainScorer.minReadings the scorer returns nil and the
        // gauge falls back to the stored row (never a fabricated value); a navigated past day clears it.
        if selectedDayOffset == 0 {
            let todayHr = await repo.hrSamples(from: windowStart, to: windowEnd)
            let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
            let restHR = displayDay?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveTodayStrain = StrainScorer.strain(todayHr, maxHR: maxHR, restingHR: restHR, sex: profile.sex)
        } else {
            liveTodayStrain = nil
        }
        // Pin the chart axis to the loaded window — today midnight→now, a past day the full 24h — so
        // a gap (e.g. a morning the strap wasn't banking) shows as empty space, not a late start.
        hrAxis = Date(timeIntervalSince1970: TimeInterval(windowStart))
            ... Date(timeIntervalSince1970: TimeInterval(windowEnd))

        // Sleep session overlapping the window. Uses `allSleepSessions` (BOTH the imported and the
        // on-device COMPUTED source) — a Bluetooth-only user's sleep lives under the computed source,
        // so the imported-only `sleepSessions` returns nothing. Keep blocks that actually overlap the
        // displayed window, then pick the LONGEST — the main night, not an afternoon nap. Drives the
        // HR sleep band + the recovery marker's wake anchor.
        sleepToday = await repo.allSleepSessions(days: selectedDayOffset + 2)
            .filter { $0.endTs > windowStart && $0.startTs < windowEnd }
            .max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) })

        announceNewDaysIfNeeded()
    }

    /// Post a single honest `.reading` update to the inbox when a refresh brought in genuinely NEWER
    /// history (a WHOOP import or an overnight backfill that pushed the newest day forward). We compare
    /// the MAX day-key in `repo.days`, not the count (#521): a background recompute rebuilds the window
    /// via delete-then-reinsert, so the count momentarily dips and recovers, but the newest key is
    /// unchanged — so churn never fires this. The very first load (empty baseline) records the key
    /// silently; a navigated past day is ignored; the persisted key means a relaunch over the same
    /// history never re-announces. The count of newly-forward days is real (keys strictly above the
    /// previous max), never fabricated. Links to Trends.
    private func announceNewDaysIfNeeded() {
        guard selectedDayOffset == 0 else { return }
        guard let newestKey = repo.days.map(\.day).max() else { return }   // no history yet
        let previousKey = lastAnnouncedDayKey
        defer { lastAnnouncedDayKey = newestKey }
        // No baseline yet → record silently, never announce historical data on first sight.
        guard !previousKey.isEmpty else { return }
        // Only a STRICTLY newer day-key counts as new history (yyyy-MM-dd sorts chronologically).
        guard newestKey > previousKey else { return }
        // Honest count of how many distinct days arrived ABOVE the old watermark.
        let added = Set(repo.days.map(\.day)).filter { $0 > previousKey }.count
        guard added > 0 else { return }
        updateStore.post(UpdateItem(
            kind: .reading,
            title: "New data added",
            message: added == 1 ? "1 new day of history landed. Open Trends to see it."
                                : "\(added) new days of history landed. Open Trends to see them.",
            deepLink: NavRouter.Destination.trends.rawValue
        ))
    }

    /// Trailing-window values for a metric — NO fall back to all history. The section is labelled a
    /// current trend ("14-day trend"), so a stale import must not render months-old points as if they
    /// were recent (same spirit as the #23 trailing-window fix). The window is generous enough that a
    /// genuinely sparse-but-recent series still renders — weight uses 90 days — and the Sparkline view
    /// already handles 0/1 points (empty / a single head dot), so no fallback is needed for layout.
    /// `latestString` reads `.last` of this windowed series, so a value older than the window shows
    /// "—" rather than a stale number under a Today tile (#49).
    private func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        let all = await repo.series(key: key, source: source)   // full history, asc
        guard !all.isEmpty else { return [] }
        return trailingWindow(all, days: window).map { $0.value }
    }

    /// Keep only points within the trailing `days` CALENDAR days ending TODAY (the phone's local date).
    /// Was anchored to the most-recent point, which on a stale import pinned the window to months-old
    /// data shown as a current trend (issue #23). ISO yyyy-MM-dd compares chronologically.
    private func trailingWindow(_ points: [(day: String, value: Double)], days: Int) -> [(day: String, value: Double)] {
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return points.filter { $0.day >= cutoffKey }
    }

    /// Latest value of a loaded sparkline series, formatted — for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    private func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// The Weight tile's display string + an honest caption ("from profile" only on the fallback).
    /// Prefers a real Apple-Health reading (today's daily, else the "weight" series' newest point so a
    /// sparse-but-recent value still renders); when neither carries a weight, falls back to the user's
    /// self-reported profile weight instead of "—" (#204). Always formatted through the shared
    /// `UnitFormatter` so the Imperial/Metric toggle reaches this tile. Mirrors Android's `weightTile`.
    private func weightTile(_ appleWeightKg: Double?) -> (value: String, caption: String) {
        if let kg = appleWeightKg ?? sparks["weight"]?.last {
            return (UnitFormatter.massFromKilograms(kg, system: unitSystem), "latest")
        }
        return (UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem), "from profile")
    }

    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    private var greetingWord: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        // The selected day's date when navigated; today's banked-row date (or today) at offset 0.
        if selectedDayOffset == 0, let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return f.string(from: date)
        }
        return f.string(from: selectedLogicalDay)
    }

    /// Hero title that names the selected day — "Today's"/"Yesterday's"/"Day's" Synthesis.
    private var synthesisTitle: LocalizedStringKey {
        switch selectedDayOffset {
        case 0:  return "Today’s Synthesis"
        case 1:  return "Yesterday’s Synthesis"
        default: return "Synthesis"
        }
    }

    /// Section overline naming the selected day — "Today"/"Yesterday"/"EEE d MMM".
    private var selectedDayOverline: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE d MMM"
            return f.string(from: selectedLogicalDay)
        }
    }

    /// A short recovery state word for the synthesis hero.
    private func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return "No Data" }
        switch s {
        case ..<25:  return "Depleted"
        case ..<50:  return "Low"
        case ..<70:  return "Steady"
        case ..<88:  return "Primed"
        default:     return "Peak"
        }
    }

    /// Plain-English synthesis of recovery + sleep.
    private func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return "No metrics yet. Import your Whoop export or wear the strap to begin."
        }
        let recPart: String
        switch rec {
        case ..<50:  recPart = "Charge is low"
        case ..<70:  recPart = "Charge is steady"
        default:     recPart = "Charge is strong"
        }
        let sleepPart: String
        if let mins = d.totalSleepMin {
            let h = mins / 60.0
            sleepPart = h >= 7 ? " and sleep was consistent" : " but sleep ran short"
        } else {
            sleepPart = ""
        }
        return recPart + sleepPart + "."
    }

    private func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "— ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return "HRV \(hrv) · RHR \(rhr)"
    }

    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }

    /// The Rest tile's caption — hours-in-bed for the day, the figure that used to be the tile's
    /// VALUE before #248 moved the Rest score there. Falls back to the efficiency read-out when no
    /// duration is banked, and to nil so the tile shows no caption line at all when neither exists.
    private func restCaption(_ d: DailyMetric?) -> String? {
        if d?.totalSleepMin != nil { return sleepValue(d) }
        return d?.efficiency.map { String(format: "%.0f%% eff", $0) }
    }

    /// Short "it's coming, not broken" caption for an unscored Effort/Rest tile on TODAY only. The
    /// call sites only reach here when the score is genuinely absent; this adds the today-only gate so
    /// a navigated PAST day with no score honestly stays a bare "—" (missing data, not mid-calibration).
    /// Mirrors the recoveryCalibration today-only rule the Charge tile uses for its "N of 4" treatment.
    private func buildingHint(_ metric: KeyMetric) -> String? {
        Self.buildingHintCopy(metric, isToday: selectedDayOffset == 0)
    }

    /// Pure copy/gate behind `buildingHint` — extracted so it can be unit-tested without a live view.
    /// Rest fills in after a night's sleep; Effort fills in once cardio load is logged. Em-dash-free
    /// house style. Returns nil off-today and for any metric other than Effort/Rest (#527).
    static func buildingHintCopy(_ metric: KeyMetric, isToday: Bool) -> String? {
        guard isToday else { return nil }
        switch metric {
        case .rest:   return "Building, wear it tonight"
        case .effort: return "Building, moves as you do"
        default:      return nil
        }
    }

    /// Active calories (Apple) for the latest day, falling back to the sparkline tail.
    private func caloriesValue(_ a: AppleDaily?) -> String {
        if let kcal = a?.activeKcal { return intString(kcal) }
        return latestString("active_kcal", decimals: 0)
    }

    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    /// "d MMM · HH:mm–HH:mm", start-only when the row has no real end (#157). The "· N bpm"
    /// segment was dropped: the StatTile caption is lineLimit(1) and date + range + bpm clips —
    /// avg HR remains on the Workouts screen.
    private func workoutCaption(_ w: WorkoutRow) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let date = f.string(from: start)
        guard w.endTs > w.startTs else { return "\(date) · \(Self.hrTimeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
        return "\(date) · \(Self.hrTimeFmt.string(from: start))–\(Self.hrTimeFmt.string(from: end))"
    }

    /// Thousands-grouped integer string (steps / calories).
    private func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }

    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, LOCAL zone)
    //
    // Parses a `DailyMetric.day` key, which is written in the device's LOCAL zone
    // (Repository.dayKeyFormatter sets no zone — the post-#277 local-day bucketing).
    // It MUST parse in that same local zone: parsing a local-day key like "2026-06-14"
    // as UTC yields 00:00Z, which is still June 13 in any negative-UTC zone, so the
    // header subtitle then printed the previous day for everyone west of UTC (#319/#320).
    // Matching dayKeyFormatter (no explicit zone) makes the parse→format round-trip an identity.

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local wall-clock time for the HR trend's x-axis / tooltip — the chart spans one day, so it must
    /// show times, not the day-granularity default ("EEE d MMM"). Also formats the workout-tile caption's
    /// time range (#157). The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "7:10 AM"
    /// where 12-hour is preferred, "19:10" where 24-hour is — instead of forcing one on everyone.
    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}

/// `.task(id:)` key combining the data refresh sequence with the selected day so a reload runs on
/// either a data change or a day-navigation change (the HR trend + Rest score are day-scoped).
private struct TodayLoadKey: Equatable {
    let seq: Int
    let offset: Int
}

// MARK: - Preview

#if DEBUG
#Preview("Control Center") {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    var sample: [DailyMetric] = []
    for i in stride(from: 39, through: 0, by: -1) {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        let day = Repository.dayString(date)
        let phase = Double(i)
        let rec = 48 + 34 * sin(phase / 5.0) + Double((i * 7) % 11)
        let strain = 8 + 7 * abs(sin(phase / 4.0))
        let total = 380 + 70 * sin(phase / 6.0)
        sample.append(DailyMetric(
            day: day, totalSleepMin: total, efficiency: 88 + 6 * sin(phase / 3.0),
            deepMin: 95, remMin: 110, lightMin: total - 200, disturbances: 4,
            restingHr: 50 + (i % 6), avgHrv: 58 + 16 * sin(phase / 4.0),
            recovery: min(max(rec, 8), 99), strain: strain, exerciseCount: i % 3,
            spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6
        ))
    }
    repo.days = sample
    repo.loaded = true

    return TodayView()
        .environmentObject(repo)
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif
