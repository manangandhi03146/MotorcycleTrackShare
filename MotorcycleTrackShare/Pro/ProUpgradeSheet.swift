import SwiftUI

/// Sheet shown when the user hits a Pro-gated moment (e.g. adding a 3rd bike).
/// Intentionally non-transactional: no CTA that charges the user, no StoreKit,
/// no "start free trial" button. Reads as an honest heads-up that this becomes
/// a Pro feature later.
struct ProUpgradeSheet: View {
    let feature: ProFeature
    let contextTitle: String?
    let contextBody: String?
    var onDismiss: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(
                title: "RaceLine Pro",
                onCancel: { dismiss(); onDismiss() },
                onSave: nil
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    header

                    if let contextTitle, let contextBody {
                        contextCard(title: contextTitle, body: contextBody)
                    }

                    featureCard

                    otherFeaturesCard

                    footerNote
                }
                .padding(20)
            }
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.appAccent)
                Text("Coming with RaceLine Pro")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.appAccent)
            }
            Text(feature.displayName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(feature.teaser)
                .font(.system(size: 16))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contextCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .minimalCard()
    }

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Pro will unlock here")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.textGhost)
            proBenefitRow(icon: iconName(for: feature), text: benefitDetail(for: feature))
        }
        .minimalCard()
    }

    private var otherFeaturesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Also part of Pro")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.textGhost)

            ForEach(ProFeature.allCases.filter { $0 != feature }, id: \.self) { other in
                proBenefitRow(icon: iconName(for: other), text: other.displayName)
            }
        }
        .minimalCard()
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing to buy yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("RaceLine Pro is still in development. Everything you can currently do in the app stays free — this screen is a heads-up so you know what's on the way.")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func proBenefitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 22, height: 22, alignment: .center)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func iconName(for feature: ProFeature) -> String {
        switch feature {
        case .unlimitedBikes:    return "infinity"
        case .unlimitedGroups:   return "person.3"
        case .advancedAnalytics: return "chart.bar.xaxis"
        case .aiRideSummary:     return "text.bubble"
        case .cloudBackup:       return "icloud.and.arrow.up"
        case .customShareCards:  return "square.stack.3d.up"
        case .exportData:        return "square.and.arrow.up.on.square"
        }
    }

    private func benefitDetail(for feature: ProFeature) -> String {
        switch feature {
        case .unlimitedBikes:
            return "Add every bike you own or ride — there's no cap on how many you keep in your garage."
        case .unlimitedGroups:
            return "Free accounts can create up to \(ProFeatureManager.freeGroupLimit) groups. You can join as many groups as you want — the cap is only on groups you OWN."
        case .advancedAnalytics:
            return "Smoothness scoring, hard-event breakdowns, route character detection, and deeper stat surfaces on every ride."
        case .aiRideSummary:
            return "A rider-friendly written recap of every ride, generated automatically from your telemetry."
        case .cloudBackup:
            return "Cloud sync already works today — free accounts are capped at 10 rides in the cloud. Pro lifts that cap so every ride you record stays backed up and available on any device you sign in on."
        case .customShareCards:
            return "Additional layouts, custom colors, and the option to remove the RaceLine watermark."
        case .exportData:
            return "One-tap export of any ride to CSV, GPX, or JSON — perfect for external analysis tools."
        }
    }
}
