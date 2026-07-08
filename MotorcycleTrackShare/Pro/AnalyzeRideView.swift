import SwiftUI

/// Premium ride-analysis surface. Combines advanced analytics with an AI-style
/// summary and an export sheet, all following the RaceLine dark design system.
///
/// Data is loaded lazily on appear:
///   - Samples are read from disk via `RideSampleLoader` (may be large).
///   - Analytics are computed once and cached in-view.
///   - The AI summary is fetched via the configured `AIRideSummaryService`.
struct AnalyzeRideView: View {

    let ride: SavedRide
    let telemetryURL: URL?
    var onRequestExport: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var proFeatures: ProFeatureManager

    @State private var samples: [RideSample] = []
    @State private var analytics: RideAnalytics = .empty
    @State private var summaryState: AIRideSummaryState = .idle
    @State private var didLoad = false

    private let summaryService: AIRideSummaryService = AIRideSummaryFactory.makeService()

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(
                title: "Analyze Ride",
                onCancel: { dismiss() },
                onSave: nil
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    hero

                    summarySection
                    performanceSection
                    brakingSection
                    accelerationSection
                    routeInsightsSection
                    safetyNotesSection

                    if onRequestExport != nil {
                        exportRow
                    }

                    disclaimer
                }
                .padding(20)
            }
        }
        .background(Color.appBg.ignoresSafeArea())
        .task {
            guard !didLoad else { return }
            didLoad = true
            loadAnalytics()
            await requestSummary()
        }
    }

    // MARK: - Loading

    private func loadAnalytics() {
        if let url = telemetryURL {
            samples = RideSampleLoader.load(from: url)
        }
        analytics = RideAnalyticsCalculator.analyze(samples: samples, summary: ride.summary)
    }

    private func requestSummary() async {
        guard proFeatures.hasAccess(to: .aiRideSummary) else {
            summaryState = .unavailable(reason: "AI ride summaries will be part of RaceLine Pro.")
            return
        }
        summaryState = .loading
        let input = AIRideSummaryInput.from(ride: ride, analytics: analytics)
        summaryState = await summaryService.summarize(input)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                Text("RIDE ANALYSIS")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1.2)
            }
            .foregroundStyle(Color.appAccent)

            Text(ride.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.textPrimary)

            Text(rideDateText)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
        }
    }

    // AI Summary

    private var summarySection: some View {
        SectionCard(icon: "text.bubble", title: "AI Ride Summary") {
            switch summaryState {
            case .idle, .loading:
                summaryLoadingRow
            case let .success(text):
                Text(text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            case let .unavailable(reason):
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case let .failure(reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(reason)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textSecondary)
                    Button("Try again") {
                        Task { await requestSummary() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                }
            }
        }
    }

    private var summaryLoadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Color.appAccent)
            Text("Generating summary…")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
        }
    }

    // Performance overview

    private var performanceSection: some View {
        SectionCard(icon: "gauge.with.dots.needle.67percent", title: "Performance Overview") {
            VStack(spacing: 10) {
                statRow("Distance", value: formatDistance(ride.summary.distanceM))
                statRow("Duration", value: ride.summary.durationText)
                statRow("Average Speed", value: formatSpeed(avgSpeedMph))
                statRow("Max Speed", value: formatSpeed(ride.summary.maxSpeedMph))
                statRow("Max Lean", value: String(format: "%.0f°", ride.summary.maxAbsLeanDeg))
                if let gain = analytics.elevationGainM ?? ride.summary.elevationGainM {
                    statRow("Elevation Gain", value: String(format: "%.0f ft", gain * 3.28084))
                }
                if let smoothness = analytics.smoothnessScore {
                    statRow("Smoothness", value: "\(smoothness)/100")
                }
                statRow("Hard Braking Events", value: "\(analytics.hardBrakingCount)")
                statRow("Aggressive Accelerations", value: "\(analytics.aggressiveAccelCount)")
            }
        }
    }

    // Braking

    private var brakingSection: some View {
        SectionCard(icon: "hand.raised.brakesignal", title: "Braking Analysis") {
            VStack(alignment: .leading, spacing: 12) {
                statRow("Hard-braking events", value: "\(analytics.hardBrakingCount)")
                if let peak = analytics.strongestBrakingMps2 {
                    statRow("Strongest event", value: String(format: "%.1f m/s²", peak))
                }
                if let consistency = analytics.brakingConsistency {
                    statRow("Consistency", value: consistency.displayName)
                }
                Text(brakingCommentary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var brakingCommentary: String {
        if !analytics.hasTelemetry {
            return "Detailed braking telemetry wasn't recorded for this ride, so only summary-level counts are shown."
        }
        switch analytics.hardBrakingCount {
        case 0:
            return "No hard-braking events were flagged — a great sign that you were reading the road ahead."
        case 1...2:
            return "A couple of firmer stops. That's normal for street riding; try to notice what triggered them so future rides can be smoother."
        default:
            return "Several hard-braking moments were detected. If the road allowed it, giving yourself more following distance can turn many of these into gentler brake applications."
        }
    }

    // Acceleration

    private var accelerationSection: some View {
        SectionCard(icon: "bolt.fill", title: "Acceleration Analysis") {
            VStack(alignment: .leading, spacing: 12) {
                statRow("Aggressive events", value: "\(analytics.aggressiveAccelCount)")
                if let peak = analytics.strongestAccelMps2 {
                    statRow("Strongest event", value: String(format: "%.1f m/s²", peak))
                }
                if let consistency = analytics.accelConsistency {
                    statRow("Consistency", value: consistency.displayName)
                }
                Text(accelCommentary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var accelCommentary: String {
        if !analytics.hasTelemetry {
            return "Detailed acceleration telemetry wasn't recorded for this ride, so only summary-level counts are shown."
        }
        switch analytics.aggressiveAccelCount {
        case 0:
            return "No aggressive throttle inputs were flagged — smooth, deliberate acceleration."
        case 1...2:
            return "A few firmer roll-ons — well within normal for spirited street riding."
        default:
            return "Several aggressive accelerations were flagged. Rolling on more progressively can help traction and predictability, especially in cold or damp conditions."
        }
    }

    // Route insights

    private var routeInsightsSection: some View {
        SectionCard(icon: "map", title: "Route Insights") {
            VStack(alignment: .leading, spacing: 10) {
                if analytics.dominantCharacters.isEmpty || analytics.dominantCharacters == [.mixed] {
                    Text("Not enough telemetry to characterize the route in detail — but the summary above still reflects everything RaceLine measured.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(analytics.dominantCharacters, id: \.self) { character in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: character))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(character.displayName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                Text(detail(for: character))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func icon(for character: RouteCharacter) -> String {
        switch character {
        case .stopAndGo: return "car.2.fill"
        case .highway:   return "road.lanes"
        case .twisty:    return "arrow.triangle.turn.up.right.diamond"
        case .elevated:  return "mountain.2"
        case .mixed:     return "circle.dashed"
        }
    }

    private func detail(for character: RouteCharacter) -> String {
        switch character {
        case .stopAndGo: return "A meaningful share of the ride was spent below 10 mph."
        case .highway:   return "Sustained cruising at 50 mph or higher for most of the ride."
        case .twisty:    return "Notable heading changes — corner-rich sections."
        case .elevated:  return "Significant elevation gain over the course of the ride."
        case .mixed:     return "A blend of characteristics without one dominant pattern."
        }
    }

    // Safety notes

    private var safetyNotesSection: some View {
        SectionCard(icon: "shield.lefthalf.filled", title: "Improvement Notes") {
            VStack(alignment: .leading, spacing: 8) {
                Text(safetyNote)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if ride.effectiveRideType == .street {
                    Text("These insights focus on smoothness, consistency, and awareness. They aren't a replacement for professional coaching or track-day instruction.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
        }
    }

    private var safetyNote: String {
        if !analytics.hasTelemetry {
            return "This ride didn't include full telemetry, so the analysis is limited to summary-level data. Future rides recorded with RaceLine will unlock deeper breakdowns."
        }
        var notes: [String] = []
        if analytics.hardBrakingCount == 0 && analytics.aggressiveAccelCount == 0 {
            notes.append("Consistent, composed inputs — this is what safer riding looks like on paper.")
        } else if analytics.hardBrakingCount > analytics.aggressiveAccelCount {
            notes.append("Braking was the busier input on this ride. Look for opportunities to lift earlier and coast into corners rather than braking hard.")
        } else if analytics.aggressiveAccelCount > analytics.hardBrakingCount {
            notes.append("Acceleration was the busier input on this ride. Progressive throttle application, especially exiting corners, keeps the bike more predictable.")
        } else {
            notes.append("Braking and acceleration events roughly balance out. Keep an eye on the smoothness score over time as a personal benchmark.")
        }
        if analytics.smoothnessScore ?? 100 < 60 {
            notes.append("A lower smoothness score often correlates with fatigue or busy roads. If the score dips again, consider a break or a route change.")
        }
        return notes.joined(separator: "\n\n")
    }

    // Export row

    private var exportRow: some View {
        Button {
            onRequestExport?()
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 15, weight: .semibold))
                Text("Export ride data")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var disclaimer: some View {
        Text("RaceLine analysis is for informational purposes only and is not professional coaching or a safety guarantee.")
            .font(.system(size: 11))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // MARK: - Helpers

    private var avgSpeedMph: Double {
        ride.summary.avgSpeedMph ?? ride.summary.computedAvgSpeedMph
    }

    private var rideDateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: ride.createdAt)
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        String(format: "%.2f mi", meters / 1609.344)
    }

    private func formatSpeed(_ mph: Double) -> String {
        String(format: "%.0f mph", mph)
    }
}

// MARK: - Section card

private struct SectionCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Color.appAccent)
            }
            content
        }
        .minimalCard()
    }
}
