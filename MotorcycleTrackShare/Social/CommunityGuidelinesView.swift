import SwiftUI

/// RaceLine community guidelines / user agreement for social features.
///
/// Two modes:
///   - **Gate** (`onAgree` set): shown the first time a rider opens the social
///     area. They must tap "I Agree" before any user-generated content loads.
///     Satisfies the "agree to terms with no tolerance for objectionable
///     content" prong of App Store Guideline 1.2.
///   - **Reference** (`onAgree` nil): read-only, linked from Settings.
struct CommunityGuidelinesView: View {
    /// When set, renders the acceptance gate with an "I Agree" button.
    var onAgree: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isAccepting = false

    private var isGate: Bool { onAgree != nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Community Guidelines")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                // Read-only mode (from Settings) gets a Done button; the gate
                // deliberately has no escape — the rider must tap "I Agree".
                if !isGate {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Text("Done")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    intro
                    rulesCard
                    toolsCard
                    footer
                }
                .padding(20)
            }

            if isGate {
                VStack(spacing: 10) {
                    PrimaryButton(title: isAccepting ? "One sec…" : "I Agree") {
                        guard !isAccepting else { return }
                        isAccepting = true
                        onAgree?()
                    }
                    Text("By tapping \u{201C}I Agree\u{201D} you accept these guidelines. Riders who violate them are removed.")
                        .font(.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .padding(.top, 8)
            }
        }
        .background(Color.appBg.ignoresSafeArea())
        .interactiveDismissDisabled(isGate)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.appAccent)
            Text("Ride respectfully")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text("RaceLine is a community for riders. To keep it that way, there is zero tolerance for objectionable content or abusive behavior.")
                .font(.system(size: 15))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Not allowed")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.textGhost)
            rule("Harassment, bullying, or threats toward other riders")
            rule("Hate speech or slurs of any kind")
            rule("Nudity, sexual content, or graphic violence")
            rule("Spam, scams, or impersonating others")
            rule("Anything illegal or that endangers others")
        }
        .minimalCard()
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're in control")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.textGhost)
            tool(icon: "flag", text: "Report any content or rider that breaks these rules. Reports are reviewed within 24 hours.")
            tool(icon: "hand.raised", text: "Block a rider to immediately hide all of their content from you.")
        }
        .minimalCard()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Need help? Contact us at racelineapp.com — we act on every report and remove violators.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rule(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red.opacity(0.85))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func tool(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
