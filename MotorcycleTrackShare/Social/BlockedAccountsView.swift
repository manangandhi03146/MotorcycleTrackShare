import SwiftUI

/// Lists the riders the current account has blocked, with an unblock action.
/// Reached from Settings → Safety. Part of the Guideline 1.2 block-management
/// requirement.
struct BlockedAccountsView: View {
    @EnvironmentObject private var moderation: ModerationService

    @State private var riders: [BlockedRider] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView()
                        .tint(Color.appAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if riders.isEmpty {
                    EmptyStateView(
                        icon: "hand.raised.slash",
                        title: "No blocked riders",
                        message: "Riders you block appear here. You won't see their content and they won't see yours."
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(riders) { rider in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Color.textGhost)
                            Text(rider.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Button {
                                unblock(rider)
                            } label: {
                                Text("Unblock")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.appAccent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.appAccent.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .minimalCard()
                    }
                }
            }
            .padding(20)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle("Blocked Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        await moderation.refreshBlocked()
        riders = (try? await moderation.blockedRiders()) ?? []
        loading = false
    }

    private func unblock(_ rider: BlockedRider) {
        Task {
            try? await moderation.unblock(rider.id)
            riders.removeAll { $0.id == rider.id }
        }
    }
}
