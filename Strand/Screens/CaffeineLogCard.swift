import SwiftUI
import StrandDesign

/// Caffeine window (#526) — log a caffeine intake (time + OPTIONAL mg) and see a plain on-device
/// "still active" hint. OPT-IN, manual-first: nothing shows until the user logs an intake, and the
/// estimate is clearly framed as a rough guide from a ~5–6 h half-life decay, never a measurement or a
/// health claim. Reuses the journal logging patterns (UserDefaults-backed store, pill controls, NoopCard).
///
/// Honesty is enforced in the model (`CaffeineDecay` / `CaffeineLogStore`): an unknown amount stays
/// unknown (we never invent mg), the active hint covers the dose-unknown case in words, and the copy
/// states it's an estimate from what was logged.
struct CaffeineLogCard: View {
    /// Single-user state owned here (UserDefaults-backed), so hosting needs no app-level injection.
    @StateObject private var store = CaffeineLogStore()

    /// Drives a live recompute of the estimate while the card is on screen (the decay is time-based).
    @State private var tick = Date()
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    @State private var mgDraft = ""
    /// "How long ago" quick options for logging — hours back from now.
    private let quickHoursAgo: [Int] = [0, 1, 2, 3]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Caffeine", overline: "Log")
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Log a coffee, tea, or energy drink and NOOP shows a rough estimate of how much may still be active. It's a guide based on a typical 5 to 6 hour half-life, not a measurement.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    activeHint

                    Divider().overlay(StrandPalette.hairline)

                    // Optional amount — leave blank if you don't know it. We never invent a number.
                    HStack {
                        TextField("Amount in mg (optional)", text: $mgDraft)
                            .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                        Text("mg")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }

                    // Log "now" or a quick number of hours ago — mirrors the journal's day-pill row.
                    HStack {
                        Text("Had it")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        ForEach(quickHoursAgo, id: \.self) { h in
                            logPill(h == 0 ? "Now" : "\(h)h ago", hoursAgo: h)
                        }
                    }

                    if !store.intakes.isEmpty {
                        Divider().overlay(StrandPalette.hairline)
                        loggedList
                    }
                }
            }
        }
        .onReceive(ticker) { tick = $0 }
    }

    // MARK: - Active hint

    /// The "caffeine still active" readout. Computed from the logged intakes via the decay model. Shows
    /// an mg estimate only when at least one active intake had a known amount; otherwise it's worded
    /// without a number (honest: we don't fabricate a dose). Renders a calm "all clear" line when nothing
    /// is active so the card always reads as live, never blank.
    @ViewBuilder private var activeHint: some View {
        let est = store.estimate()
        if est.hasActive {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeTitle(est))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(activeDetail(est))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(store.intakes.isEmpty
                 ? "No caffeine logged. Log an intake to see an estimate."
                 : "Estimated mostly cleared. Nothing logged is likely still active.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func activeTitle(_ est: CaffeineActiveEstimate) -> String {
        if let mg = est.totalRemainingMg {
            return "About \(Int(mg.rounded())) mg may still be active"
        }
        return "Caffeine may still be active"
    }

    private func activeDetail(_ est: CaffeineActiveEstimate) -> String {
        var parts: [String] = []
        if let hrs = est.hoursSinceMostRecentActive {
            parts.append("most recent intake about \(hoursLabel(hrs)) ago")
        }
        if est.activeIntakeCount > 1 {
            parts.append("\(est.activeIntakeCount) intakes still in the estimate")
        }
        let lead = parts.isEmpty ? "" : parts.joined(separator: " · ") + ". "
        return lead + "Rough guide only, based on what you logged."
    }

    private func hoursLabel(_ hrs: Double) -> String {
        if hrs < 1 { return "under an hour" }
        let rounded = Int(hrs.rounded())
        return rounded == 1 ? "1 hour" : "\(rounded) hours"
    }

    // MARK: - Logged list

    @ViewBuilder private var loggedList: some View {
        Text("Logged today")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        ForEach(store.intakes) { intake in
            HStack {
                Text(intakeLabel(intake))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button {
                    store.remove(intake.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove caffeine intake at \(Self.timeFormatter.string(from: intake.at))")
            }
        }
    }

    private func intakeLabel(_ intake: CaffeineIntake) -> String {
        let time = Self.timeFormatter.string(from: intake.at)
        if let mg = intake.mg {
            return "\(time) · \(Int(mg.rounded())) mg"
        }
        return "\(time) · amount not logged"
    }

    // MARK: - Controls

    private func logPill(_ label: LocalizedStringKey, hoursAgo: Int) -> some View {
        pillButton(label, selected: false) {
            let mg = Double(mgDraft.trimmingCharacters(in: .whitespaces))   // nil if blank/invalid
            let at = Calendar.current.date(byAdding: .hour, value: -hoursAgo, to: tick) ?? tick
            store.log(at: at, mg: mg)
            mgDraft = ""
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.accent : StrandPalette.hairline,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
