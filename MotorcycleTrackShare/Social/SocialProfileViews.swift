import SwiftUI

// MARK: - Public profile

/// A rider's public-facing profile. Respects the target user's privacy switches:
/// non-public profiles show a "This profile is private" state.
struct PublicProfileView: View {
    let userID: UUID

    @EnvironmentObject private var authService: AuthService
    @State private var profile: SocialProfile?
    @State private var loading = true
    @State private var isFollowing = false
    @State private var errorMessage: String?

    private let profileService = SocialProfileService()
    private let followService = FollowService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading {
                    // Skeleton mirrors the hero card so the follow row
                    // doesn't slide down into place when the profile
                    // fetch resolves.
                    profileHeroSkeleton
                } else if let profile {
                    if profile.isPublic {
                        heroCard(profile)
                        followRow(profile)
                        if profile.showBikes {
                            infoCard(icon: "sportbike-placeholder", title: "Bikes",
                                     detail: "The garage will list bikes here when this rider's data is ready.")
                        }
                        if profile.showRideStats {
                            infoCard(icon: "chart.bar.xaxis", title: "Ride stats",
                                     detail: "Public ride totals will appear here as data flows in from Supabase.")
                        }
                    } else {
                        EmptyStateView(
                            icon: "lock.fill",
                            title: "This profile is private",
                            message: "Only riders who have made their profile public appear in RaceLine's community search."
                        )
                        .padding(.top, 40)
                    }
                } else if let errorMessage {
                    ErrorBlock(message: errorMessage)
                } else {
                    EmptyStateView(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "Rider not found",
                        message: "This profile may have been deleted or made private."
                    )
                }
            }
            .padding(20)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle("Rider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await reload() }
    }

    private var profileHeroSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Circle()
                .fill(Color.appSurface2)
                .frame(width: 60, height: 60)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.appSurface2)
                .frame(width: 180, height: 26)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.appSurface2)
                .frame(width: 90, height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.appSurface2)
                .frame(width: 220, height: 12)
        }
        .minimalCard()
        .redacted(reason: .placeholder)
    }

    private func heroCard(_ profile: SocialProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProfileAvatarBubble(profile: profile, size: 60)
            Text(profile.displayName ?? profile.username ?? "Rider")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            if let u = profile.username {
                Text("@\(u)")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
            }
            if let bio = profile.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .minimalCard()
    }

@ViewBuilder
    private func followRow(_ profile: SocialProfile) -> some View {
        if profile.id != authService.userID {
            Button {
                Task { await toggleFollow(profile.id) }
            } label: {
                Text(isFollowing ? "Following" : "Follow")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isFollowing ? Color.appAccent : .white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isFollowing ? Color.appAccent.opacity(0.15) : Color.appAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func infoCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color.appAccent)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .minimalCard()
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            profile = try await profileService.fetchProfile(userID: userID)
            if let me = authService.userID {
                isFollowing = (try? await followService.isFollowing(follower: me, followee: userID)) ?? false
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = "Couldn't load this profile."
        }
    }

    /// Optimistic follow toggle. Flips the pill label instantly on
    /// tap; on server rejection we roll `isFollowing` back to its
    /// prior state and surface a message so the label reverting isn't
    /// mysterious.
    private func toggleFollow(_ targetID: UUID) async {
        guard let me = authService.userID else { return }
        let previous = isFollowing

        isFollowing.toggle()
        errorMessage = nil

        do {
            if previous {
                try await followService.unfollow(followerID: me, followeeID: targetID)
            } else {
                try await followService.follow(followerID: me, followeeID: targetID)
            }
        } catch {
            isFollowing = previous
            errorMessage = "Couldn't \(previous ? "unfollow" : "follow"). Check your connection and try again."
        }
    }
}

// MARK: - Social privacy

struct SocialPrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService

    @State private var settings: SocialPrivacySettings?
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?

    private let service = SocialPrivacyService()

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Social Privacy",
                    onCancel: { dismiss() },
                    isSaveDisabled: saving || settings == nil,
                    onSave: { Task { await save() } }
                )

                if loading {
                    LoadingBlock(message: "Loading privacy…")
                    Spacer()
                } else if let bound = binding {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Sensible defaults keep your data private. Turn things on only for what you want to share.")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)

                            groupHeader("Sharing defaults")
                            toggleRow("Share rides by default", value: bound.shareRidesByDefault)
                            toggleRow("Hide ride start point by default", value: bound.hideRideStartByDefault)
                            toggleRow("Hide ride end point by default", value: bound.hideRideEndByDefault)

                            groupHeader("Activity visibility")
                            toggleRow("Show my ride activities", value: bound.showRideActivities)
                            toggleRow("Show my challenge activities", value: bound.showChallengeActivities)
                            toggleRow("Show my group activities", value: bound.showGroupActivities)

                            groupHeader("Route sharing")
                            DropdownFieldButton(
                                selectionText: bound.shareDefaultRouteVisibility.wrappedValue.displayName
                            ) {
                                showVisibilityDialog = true
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(20)
                    }
                    .confirmationDialog("Default route visibility",
                                        isPresented: $showVisibilityDialog,
                                        titleVisibility: .visible) {
                        ForEach(SharedRouteVisibility.allCases) { v in
                            Button(v.displayName) { settings?.shareDefaultRouteVisibility = v }
                        }
                        Button("Cancel", role: .cancel) { }
                    }
                }
            }
        }
        .task { await load() }
    }

    @State private var showVisibilityDialog = false

    private var binding: SocialPrivacyBindings? {
        guard settings != nil else { return nil }
        return SocialPrivacyBindings(
            shareRidesByDefault:         nonNilBinding(\.shareRidesByDefault),
            hideRideStartByDefault:      nonNilBinding(\.hideRideStartByDefault),
            hideRideEndByDefault:        nonNilBinding(\.hideRideEndByDefault),
            showRideActivities:          nonNilBinding(\.showRideActivities),
            showChallengeActivities:     nonNilBinding(\.showChallengeActivities),
            showMaintenanceActivities:   nonNilBinding(\.showMaintenanceActivities),
            showGroupActivities:         nonNilBinding(\.showGroupActivities),
            shareDefaultRouteVisibility: nonNilBinding(\.shareDefaultRouteVisibility)
        )
    }

    private func nonNilBinding<T>(_ keyPath: WritableKeyPath<SocialPrivacySettings, T>) -> Binding<T> {
        Binding(
            get: { settings![keyPath: keyPath] },
            set: { newValue in
                guard settings != nil else { return }
                settings![keyPath: keyPath] = newValue
            }
        )
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Color.textGhost)
            .padding(.top, 6)
    }

    private func toggleRow(_ label: String, value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value)
            .tint(Color.appAccent)
            .foregroundStyle(Color.textPrimary)
            .appFieldChrome()
    }

    private func load() async {
        guard let uid = authService.userID else {
            loading = false
            errorMessage = "Sign in first."
            return
        }
        defer { loading = false }
        do {
            settings = try await service.fetch(userID: uid)
        } catch {
            errorMessage = "Couldn't load privacy settings."
        }
    }

    private func save() async {
        guard let uid = authService.userID, let s = settings else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await service.update(userID: uid, SocialPrivacySettingsUpdate(
                shareRidesByDefault:         s.shareRidesByDefault,
                hideRideStartByDefault:      s.hideRideStartByDefault,
                hideRideEndByDefault:        s.hideRideEndByDefault,
                showRideActivities:          s.showRideActivities,
                showChallengeActivities:     s.showChallengeActivities,
                showMaintenanceActivities:   s.showMaintenanceActivities,
                showGroupActivities:         s.showGroupActivities,
                shareDefaultRouteVisibility: s.shareDefaultRouteVisibility
            ))
            dismiss()
        } catch {
            errorMessage = "Couldn't save privacy settings."
        }
    }
}

// MARK: - Binding helper container

private struct SocialPrivacyBindings {
    let shareRidesByDefault: Binding<Bool>
    let hideRideStartByDefault: Binding<Bool>
    let hideRideEndByDefault: Binding<Bool>
    let showRideActivities: Binding<Bool>
    let showChallengeActivities: Binding<Bool>
    let showMaintenanceActivities: Binding<Bool>
    let showGroupActivities: Binding<Bool>
    let shareDefaultRouteVisibility: Binding<SharedRouteVisibility>
}
