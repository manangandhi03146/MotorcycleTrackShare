import SwiftUI

/// Active challenges list with per-user progress. Safe challenge types only —
/// no top-speed leaderboards or public-road speed contests.
struct ChallengesView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var cache: SocialHubCache

    @State private var state: LoadState = .idle
    @State private var errorMessage: String?

    private let service = ChallengeService()

    private enum LoadState: Equatable { case idle, loading, loaded, empty, error }

    private var cacheIsFresh: Bool {
        guard let last = cache.challengesLastLoaded else { return false }
        return Date().timeIntervalSince(last) < 30
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if cache.challenges.isEmpty {
                    switch state {
                    case .idle, .loading:
                        LoadingBlock(message: "Loading challenges…")
                            .padding(.top, 40)
                    case .empty:
                        EmptyStateView(
                            icon: "target",
                            title: "No active challenges",
                            message: "Check back soon — new challenges roll out with each season."
                        )
                        .padding(.top, 40)
                    case .error:
                        ErrorBlock(message: errorMessage ?? "Couldn't load challenges.") {
                            Task { await reload(force: true) }
                        }
                        .padding(.top, 20)
                    case .loaded:
                        EmptyView()
                    }
                } else {
                    ForEach(cache.challenges) { challenge in
                        NavigationLink {
                            ChallengeDetailView(challenge: challenge)
                        } label: {
                            ChallengeRow(
                                challenge: challenge,
                                progress: cache.challengeProgress[challenge.id]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .refreshable { await reload(force: true) }
        .task { await reload(force: false) }
    }

    private func reload(force: Bool) async {
        if !force && cacheIsFresh { return }
        if cache.challenges.isEmpty { state = .loading }
        do {
            async let listTask = service.activeChallenges()
            let list = try await listTask
            cache.challenges = list
            cache.challengesLastLoaded = Date()
            state = list.isEmpty ? .empty : .loaded
            // Progress request is decoupled from the challenge list so a
            // slow per-user query never blocks the challenge cards from
            // rendering.
            if let uid = authService.userID {
                Task {
                    if let progresses = try? await service.progress(userID: uid) {
                        cache.challengeProgress = Dictionary(
                            uniqueKeysWithValues: progresses.map { ($0.challengeID, $0) }
                        )
                    }
                }
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingSupabaseError(error, feature: "challenges")
            state = cache.challenges.isEmpty ? .error : .loaded
        }
    }
}

// MARK: - Row

private struct ChallengeRow: View {
    let challenge: Challenge
    let progress: ChallengeProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.appAccent.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: challenge.challengeType.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(challenge.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(challenge.challengeType.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                if progress?.completedAt != nil {
                    Text("Complete")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.9))
                        .clipShape(Capsule())
                } else if progress != nil {
                    Text("Joined")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.appAccent.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            ProgressBar(fraction: fraction)
            Text(progressCopy)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .minimalCard()
    }

    private var fraction: Double {
        guard let p = progress, challenge.goalValue > 0 else { return 0 }
        return min(1.0, p.currentValue / challenge.goalValue)
    }

    private var progressCopy: String {
        let current = progress?.currentValue ?? 0
        return String(format: "%.0f / %.0f %@",
                      current,
                      challenge.goalValue,
                      challenge.goalUnit)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appSurface2)
                Capsule()
                    .fill(Color.appAccent)
                    .frame(width: max(4, geo.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Detail

struct ChallengeDetailView: View {
    let challenge: Challenge

    @EnvironmentObject private var authService: AuthService

    @State private var progress: ChallengeProgress?
    @State private var errorMessage: String?
    @State private var joining = false

    @State private var leaderboard: [ChallengeProgress] = []
    @State private var leaderboardProfiles: [UUID: SocialProfile] = [:]
    @State private var leaderboardLoading = true

    private let service = ChallengeService()
    private let followService = FollowService()
    private let profileService = SocialProfileService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                if let progress {
                    progressCard(progress)
                }
                joinButton
                leaderboardSection
                safetyNote
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle(challenge.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadProgress() }
        .task { await loadLeaderboard() }
    }

    // MARK: - Leaderboard

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Color.appAccent)
                Text("FRIENDS LEADERBOARD")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.textGhost)
                Spacer()
            }

            if leaderboardLoading {
                LoadingBlock(message: "Loading leaderboard…")
            } else if leaderboard.isEmpty {
                EmptyStateView(
                    icon: "person.2.slash",
                    title: "No mutuals here yet",
                    message: "Only riders you and they both follow show up on this leaderboard. Add a few mutuals from the Riders tab."
                )
            } else {
                ForEach(Array(leaderboard.enumerated()), id: \.element.id) { pair in
                    leaderboardRow(rank: pair.offset + 1, entry: pair.element)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimalCard()
    }

    private func leaderboardRow(rank: Int, entry: ChallengeProgress) -> some View {
        let profile = leaderboardProfiles[entry.userID]
        let isSelf  = entry.userID == authService.userID
        let name: String = {
            if isSelf { return "You" }
            if let name = profile?.displayName, !name.isEmpty { return name }
            if let u = profile?.username, !u.isEmpty { return "@\(u)" }
            return "Rider"
        }()
        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(rank <= 3 ? Color.appAccent : Color.textSecondary)
                .frame(width: 22, alignment: .trailing)
            Text(name)
                .font(.system(size: 14, weight: isSelf ? .semibold : .regular))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.0f %@", entry.currentValue, challenge.goalUnit))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.textSecondary)
            if entry.completedAt != nil {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.green)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 6)
    }

    private func loadLeaderboard() async {
        guard let uid = authService.userID else {
            leaderboardLoading = false
            return
        }
        defer { leaderboardLoading = false }
        do {
            let mutuals = try await followService.mutuals(userID: uid)
            let rows = try await service.leaderboard(challengeID: challenge.id,
                                                     viewerID: uid,
                                                     mutuals: mutuals)
            let sorted = rows.sorted { $0.currentValue > $1.currentValue }
            leaderboard = sorted
            let ids = Array(Set(sorted.map(\.userID)))
            if !ids.isEmpty,
               let profiles = try? await profileService.fetchProfiles(userIDs: ids) {
                leaderboardProfiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            }
        } catch {
            leaderboard = []
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: challenge.challengeType.systemImage)
                    .foregroundStyle(Color.appAccent)
                Text(challenge.challengeType.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            Text(challenge.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            if let d = challenge.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Goal: \(Int(challenge.goalValue)) \(challenge.goalUnit)")
                .font(.caption)
                .foregroundStyle(Color.textGhost)
        }
        .minimalCard()
    }

    private func progressCard(_ p: ChallengeProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR PROGRESS")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textGhost)
            HStack {
                Text("\(Int(p.currentValue)) / \(Int(challenge.goalValue))")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if p.completedAt != nil {
                    Text("Completed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.9))
                        .clipShape(Capsule())
                }
            }
            ProgressBar(fraction: min(1.0, p.currentValue / max(challenge.goalValue, 1)))
        }
        .minimalCard()
    }

    private var joinButton: some View {
        Button {
            Task { await join() }
        } label: {
            Text(progress == nil ? "Join Challenge" : "Update Progress")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.appAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(joining)
    }

    private var safetyNote: some View {
        Text("Challenges track riding habits and consistency. They don't reward speeding or risk-taking — always ride within your limits and the law.")
            .font(.caption)
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadProgress() async {
        guard let uid = authService.userID else { return }
        progress = try? await service.progress(userID: uid, challengeID: challenge.id)
    }

    private func join() async {
        guard let uid = authService.userID else { errorMessage = "Sign in to join."; return }
        joining = true
        defer { joining = false }
        do {
            let updated = try await service.joinChallenge(userID: uid, challengeID: challenge.id)
            progress = updated
        } catch {
            errorMessage = "Couldn't join right now."
        }
    }
}
