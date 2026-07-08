import SwiftUI

/// Wraps the social hub with the App Store Guideline 1.2 acceptance gate: a
/// rider must agree to the community guidelines before any user-generated
/// content loads. Also refreshes the blocked-user set on entry so client-side
/// filtering is current.
struct SocialGateView: View {
    @EnvironmentObject private var moderation: ModerationService

    /// Cached so returning riders don't see the gate flash or a network wait.
    /// The server (`profiles.accepted_terms_at`) remains the source of truth
    /// and is checked whenever the local cache is unset.
    @AppStorage("acceptedCommunityGuidelines") private var acceptedLocal = false

    @State private var checkedServer = false

    var body: some View {
        Group {
            if acceptedLocal {
                SocialHubView()
            } else if checkedServer {
                CommunityGuidelinesView(onAgree: accept)
            } else {
                LoadingView(message: "Loading…")
            }
        }
        .task {
            await moderation.refreshBlocked()
            if !acceptedLocal {
                if await moderation.hasAcceptedTerms() {
                    acceptedLocal = true
                }
                checkedServer = true
            }
        }
    }

    private func accept() {
        Task {
            try? await moderation.acceptTerms()
            acceptedLocal = true
        }
    }
}
