import SwiftUI

/// Report objectionable content or a user. Writes a row to `content_reports`
/// (migration 025) via `ModerationService`. Part of the App Store Guideline
/// 1.2 UGC safety requirements.
struct ReportSheet: View {
    let contentType: ReportedContentType
    let contentID: UUID?
    let reportedUserID: UUID?
    /// Optionally offer to block the author right after reporting.
    var showBlockOption: Bool = true

    @EnvironmentObject private var moderation: ModerationService
    @Environment(\.dismiss) private var dismiss

    @State private var reason: ReportReason = .spam
    @State private var details: String = ""
    @State private var alsoBlock = false
    @State private var isSubmitting = false
    @State private var didSubmit = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(title: "Report", onCancel: { dismiss() }, onSave: nil)
            if didSubmit {
                confirmation
            } else {
                form
            }
        }
        .background(Color.appBg.ignoresSafeArea())
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Why are you reporting this?")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                VStack(spacing: 0) {
                    ForEach(Array(ReportReason.allCases.enumerated()), id: \.element.id) { index, r in
                        Button {
                            reason = r
                        } label: {
                            HStack {
                                Text(r.title)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                if reason == r {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Color.appAccent)
                                }
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < ReportReason.allCases.count - 1 {
                            Divider().overlay(Color.textGhost.opacity(0.3))
                        }
                    }
                }
                .minimalCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add details (optional)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textGhost)
                    TextField("What's going on?", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textPrimary)
                        .padding(12)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if showBlockOption, reportedUserID != nil {
                    Toggle(isOn: $alsoBlock) {
                        Text("Also block this rider")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.textPrimary)
                    }
                    .tint(Color.appAccent)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                PrimaryButton(title: isSubmitting ? "Submitting…" : "Submit report") {
                    submit()
                }
                .disabled(isSubmitting)

                Text("Reports are reviewed within 24 hours. Content or accounts that violate the community guidelines are removed and repeat offenders are banned.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(20)
        }
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.appAccent)
            Text("Thanks for reporting")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text("Our team reviews every report within 24 hours and takes action on anything that breaks the community guidelines.")
                .font(.system(size: 15))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            PrimaryButton(title: "Done") { dismiss() }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
    }

    // MARK: - Actions

    private func submit() {
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                try await moderation.report(
                    contentType: contentType,
                    contentID: contentID,
                    reportedUserID: reportedUserID,
                    reason: reason,
                    details: details
                )
                if alsoBlock, let uid = reportedUserID {
                    try? await moderation.block(uid)
                }
                didSubmit = true
            } catch {
                errorMessage = "Couldn't submit the report. Please try again."
            }
            isSubmitting = false
        }
    }
}
