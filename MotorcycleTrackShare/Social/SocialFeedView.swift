import SwiftUI

/// In-memory cache shared across the Social hub so switching segments
/// (feed → groups → feed) doesn't wipe out fetched data and force a
/// visible reload. Each `Tab` view reads from and writes to this cache
/// via `@EnvironmentObject`, so their `@State` no longer resets when
/// SwiftUI recreates them on segment switch.
@MainActor
final class SocialHubCache: ObservableObject {
    @Published var feedEvents: [ActivityEvent] = []
    @Published var feedProfilesByID: [UUID: SocialProfile] = [:]
    @Published var feedLastLoaded: Date?

    @Published var mutuals: [SocialProfile] = []
    @Published var followingIDs: Set<UUID> = []
    @Published var mutualsLastLoaded: Date?

    @Published var groups: [GroupSummary] = []
    @Published var groupsLastLoaded: Date?

    @Published var challenges: [Challenge] = []
    @Published var challengeProgress: [UUID: ChallengeProgress] = [:]
    @Published var challengesLastLoaded: Date?
}

/// Top-level Social tab. Segmented hub for the four Phase 3 surfaces:
/// activity feed, groups, challenges, and riders (public profiles).
/// Uses the shared design system tokens so it feels native to RaceLine.
struct SocialHubView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var cache = SocialHubCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selection: SocialSegment = .feed
    /// -1 / 0 / +1 depending on whether the newly-selected segment is
    /// to the left, same as, or to the right of the previous one. Feeds
    /// into `NavTransition.segmentSwap(direction:)`.
    @State private var swipeDirection: Int = 0

    enum SocialSegment: String, CaseIterable, Identifiable {
        case feed, groups, challenges, riders
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .feed:       return "Feed"
            case .groups:     return "Groups"
            case .challenges: return "Challenges"
            case .riders:     return "Riders"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentBar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                ZStack {
                    Group {
                        switch selection {
                        case .feed:       ActivityFeedTab()
                        case .groups:     GroupsTab()
                        case .challenges: ChallengesTab()
                        case .riders:     RidersTab()
                        }
                    }
                    .id(selection)
                    // Directional slide reinforces the spatial layout
                    // of the segment bar — moving right in the bar
                    // slides content in from the right. Cross-fade
                    // fallback for Reduce Motion.
                    .transition(NavTransition.segmentSwap(
                        direction: swipeDirection,
                        reduceMotion: reduceMotion
                    ))
                }
                .environmentObject(cache)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(reduceMotion ? nil : NavTransition.animation, value: selection)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .background(Color.appBg)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Social")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.appBg)
    }

    // MARK: - Segment bar

    private var segmentBar: some View {
        HStack(spacing: 6) {
            ForEach(SocialSegment.allCases) { seg in
                let isSelected = selection == seg
                Button {
                    // Compute direction BEFORE mutating selection so
                    // the transition (which reads swipeDirection) sees
                    // the correct sign in the same animation frame.
                    let fromIdx = SocialSegment.allCases.firstIndex(of: selection) ?? 0
                    let toIdx   = SocialSegment.allCases.firstIndex(of: seg) ?? 0
                    swipeDirection = toIdx > fromIdx ? 1 : (toIdx < fromIdx ? -1 : 0)
                    selection = seg
                } label: {
                    Text(seg.displayName)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : Color.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(minHeight: 36)
                        .background(isSelected ? Color.appAccent : Color.appSurface2)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        // The pill background swap animates independently so the
        // selection indicator glides even while content is sliding.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
    }
}

// MARK: - Activity feed tab

struct ActivityFeedTab: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var cache: SocialHubCache

    @State private var state: LoadState = .idle
    @State private var errorMessage: String?

    private let feedService = ActivityFeedService()
    private let profileService = SocialProfileService()

    private enum LoadState: Equatable { case idle, loading, refreshing, loaded, empty, error }

    /// Skip re-fetch if we just pulled the feed. Prevents the top of
    /// the feed from stuttering as the user hops between segments.
    private var cacheIsFresh: Bool {
        guard let last = cache.feedLastLoaded else { return false }
        return Date().timeIntervalSince(last) < 30
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if cache.feedEvents.isEmpty {
                    switch state {
                    case .loading, .idle, .refreshing:
                        LoadingBlock(message: "Loading feed…")
                            .padding(.top, 40)
                    case .empty:
                        EmptyStateView(
                            icon: "sparkles",
                            title: "Your feed is quiet",
                            message: "Follow other riders or join a group to start seeing activity here."
                        )
                        .padding(.top, 40)
                    case .error:
                        ErrorBlock(message: errorMessage ?? "Couldn't load feed.") {
                            Task { await reload(force: true) }
                        }
                        .padding(.top, 40)
                    case .loaded:
                        // Shouldn't happen (loaded implies non-empty), but keep exhaustive.
                        EmptyView()
                    }
                } else {
                    // Cached events stay visible even while refreshing so
                    // the feed never blanks on tab switches or pull-to-
                    // refresh.
                    ForEach(cache.feedEvents) { event in
                        feedRow(for: event)
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

    // Wrap in a NavigationLink when the event kind has a tappable target.
    @ViewBuilder
    private func feedRow(for event: ActivityEvent) -> some View {
        let actor = cache.feedProfilesByID[event.actorID]
        switch event.kind {
        case .sharedRoutePosted:
            if let subjectID = event.subjectID {
                NavigationLink {
                    SharedRouteDetailView(routeID: subjectID)
                } label: {
                    FeedRow(event: event, actor: actor)
                }
                .buttonStyle(.plain)
            } else {
                FeedRow(event: event, actor: actor)
            }
        case .groupRideCreated:
            if let subjectID = event.subjectID {
                NavigationLink {
                    GroupRideDetailView(rideID: subjectID)
                } label: {
                    FeedRow(event: event, actor: actor)
                }
                .buttonStyle(.plain)
            } else {
                FeedRow(event: event, actor: actor)
            }
        default:
            FeedRow(event: event, actor: actor)
        }
    }

    /// `force = true` skips the freshness gate — used by pull-to-refresh
    /// and the Try Again button. Normal `.task` fires pass `force = false`
    /// so tab switches inside the 30-second window are basically free.
    private func reload(force: Bool) async {
        guard authService.isLoggedIn else {
            state = .error
            errorMessage = "Sign in to see your feed."
            return
        }
        if !force && cacheIsFresh { return }
        state = cache.feedEvents.isEmpty ? .loading : .refreshing
        do {
            // Circuit-wrapped: fast-fails without hitting the network
            // if the feed endpoint has been broken. Also enforces a
            // 10s per-request timeout so users never sit on a 60s
            // URLSession default.
            let list = try await SupabaseCircuit.shared.run(.feed) {
                try await ActivityFeedService().feed(limit: 40)
            }
            cache.feedEvents = list
            cache.feedLastLoaded = Date()
            state = list.isEmpty ? .empty : .loaded
            // Profile fetch already runs as fire-and-forget so a slow
            // avatars query can't stall the feed content that's
            // already visible above.
            Task { await loadActorProfiles(for: list) }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingSupabaseError(error, feature: "feed")
            if cache.feedEvents.isEmpty {
                state = .error
            } else {
                state = .loaded
            }
        }
    }

    private func loadActorProfiles(for events: [ActivityEvent]) async {
        let ids = Set(events.map(\.actorID))
        let missing = ids.subtracting(cache.feedProfilesByID.keys)
        guard !missing.isEmpty else { return }
        if let fetched = try? await profileService.fetchProfiles(userIDs: Array(missing)) {
            for p in fetched { cache.feedProfilesByID[p.id] = p }
        }
    }
}

/// True when the error came from a cancelled Task rather than an actual
/// failure. Reloads triggered by rapid tab switches routinely throw these
/// mid-flight; surfacing them as "couldn't load" would be misleading. The
/// URLError side covers Supabase's underlying URLSession request being
/// cancelled when the surrounding Task tears down.
func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
    if ns.domain == "NSURLErrorDomain", ns.code == -999 { return true }
    return false
}

/// Turns raw Supabase / Postgrest errors into a message that helps diagnose
/// the common Phase 3 setup issue — migrations 006 + 007 not applied — while
/// still preserving the underlying error text so real issues aren't hidden.
func userFacingSupabaseError(_ error: Error, feature: String) -> String {
    let text = "\(error)"
    let lower = text.lowercased()
    if lower.contains("relation") && (lower.contains("does not exist") || lower.contains("not exist")) {
        return "The \(feature) tables aren't set up yet. Run supabase/migrations/006_social.sql and 007_social_rls.sql in the Supabase Dashboard, then pull to refresh."
    }
    if lower.contains("row level security") || lower.contains("permission denied") {
        return "Row-level security blocked that query. Confirm 007_social_rls.sql ran successfully."
    }
    if lower.contains("network") || lower.contains("offline") {
        return "You're offline. Reconnect and pull to refresh."
    }
    return "Couldn't load \(feature).\n\n\(text)"
}

private struct FeedRow: View {
    let event: ActivityEvent
    let actor: SocialProfile?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: event.kind.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Reserve a fixed line height so late-arriving actor
                    // profiles ("A rider" → "Manan Gandhi") don't jump
                    // the row's vertical rhythm. The .redacted placeholder
                    // fills the same 13pt line so the row height stays
                    // constant across the profile fetch.
                    Text(actorLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .redacted(reason: actor == nil ? .placeholder : [])
                        .frame(minHeight: 16, alignment: .leading)
                    if event.kind == .sharedRoutePosted || event.kind == .groupRideCreated {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                if let title = displayTitle {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textPrimary)
                }
                if let summary = event.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(event.createdAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textGhost)
            }
            Spacer(minLength: 0)
        }
        .minimalCard()
    }

    private var actorLine: String {
        if let actor {
            if let name = actor.displayName, !name.isEmpty { return name }
            if let u = actor.username, !u.isEmpty          { return "@\(u)" }
        }
        return "A rider"
    }

    /// Rewrite user-facing titles at display time so legacy rows in the
    /// activity_feed table say "Shared a ride" instead of the old
    /// "Shared a route" copy without needing to rewrite the table.
    private var displayTitle: String? {
        guard let raw = event.title, !raw.isEmpty else { return nil }
        if event.kind == .sharedRoutePosted, raw == "Shared a route" {
            return "Shared a ride"
        }
        return raw
    }
}

// MARK: - Groups tab (thin wrapper around GroupsView)

struct GroupsTab: View {
    var body: some View { GroupsView() }
}

// MARK: - Challenges tab

struct ChallengesTab: View {
    var body: some View { ChallengesView() }
}

// MARK: - Riders tab (mutual followers list + add sheet)

/// Main Riders page shows the current user's actual friends — riders they
/// mutually follow. The plus button in the top-right opens a search sheet
/// where the user can search + follow more people. Discovery lives inside
/// that sheet, not on the main page (per product spec).
struct RidersTab: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var cache: SocialHubCache

    @State private var state: LoadState = .idle
    @State private var errorMessage: String?
    @State private var showAddSheet = false

    private let profileService = SocialProfileService()
    private let followService  = FollowService()

    private enum LoadState: Equatable { case idle, loading, loaded, empty, error }

    private var cacheIsFresh: Bool {
        guard let last = cache.mutualsLastLoaded else { return false }
        return Date().timeIntervalSince(last) < 30
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
                .padding(.horizontal, 12)
                .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if cache.mutuals.isEmpty {
                        switch state {
                        case .idle, .loading:
                            LoadingBlock(message: "Loading friends…")
                                .padding(.top, 40)
                        case .empty:
                            EmptyStateView(
                                icon: "person.2",
                                title: "No riding buddies yet",
                                message: "Tap + to search for riders. When two of you follow each other, you'll show up here."
                            )
                            .padding(.top, 40)
                        case .error:
                            ErrorBlock(message: errorMessage ?? "Couldn't load friends.") {
                                Task { await reload(force: true) }
                            }
                            .padding(.top, 20)
                        case .loaded:
                            EmptyView()
                        }
                    } else {
                        ForEach(cache.mutuals) { profile in
                            friendRow(profile)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 100)
            }
            .refreshable { await reload(force: true) }
        }
        .task { await reload(force: false) }
        .sheet(isPresented: $showAddSheet) {
            AddRidersSheet(followingIDs: Binding(
                get: { cache.followingIDs },
                set: { cache.followingIDs = $0 }
            ), onDone: {
                showAddSheet = false
                Task { await reload(force: true) }
            })
            .presentationDetents([.large])
        }
    }

    private var actionBar: some View {
        HStack {
            Text("Riding Buddies")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.appAccent)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add rider")
        }
    }

    private func friendRow(_ profile: SocialProfile) -> some View {
        NavigationLink {
            PublicProfileView(userID: profile.id)
        } label: {
            HStack(spacing: 12) {
                ProfileAvatarBubble(profile: profile, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName ?? profile.username ?? "Rider")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if let username = profile.username {
                        Text("@\(username)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer()
                Text("Mutual")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appAccent.opacity(0.15))
                    .clipShape(Capsule())
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .minimalCard()
        }
        .buttonStyle(.plain)
    }

    private func reload(force: Bool) async {
        guard let me = authService.userID else {
            state = .error
            errorMessage = "Sign in to see your riding buddies."
            return
        }
        if !force && cacheIsFresh { return }
        if cache.mutuals.isEmpty { state = .loading }
        do {
            let (mutualIDs, followingIDs) = try await SupabaseCircuit.shared.run(.mutuals) {
                let svc = FollowService()
                async let mIDs = svc.mutuals(userID: me)
                async let fIDs = svc.following(userID: me)
                return try await (mIDs, fIDs)
            }
            cache.followingIDs = Set(followingIDs)
            if mutualIDs.isEmpty {
                cache.mutuals = []
                cache.mutualsLastLoaded = Date()
                state = .empty
                return
            }
            let profiles = try await profileService.fetchProfiles(userIDs: mutualIDs)
            let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
            cache.mutuals = mutualIDs.compactMap { byID[$0] }.sorted {
                ($0.displayName ?? $0.username ?? "") < ($1.displayName ?? $1.username ?? "")
            }
            cache.mutualsLastLoaded = Date()
            state = cache.mutuals.isEmpty ? .empty : .loaded
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingSupabaseError(error, feature: "friends")
            state = cache.mutuals.isEmpty ? .error : .loaded
        }
    }
}

// MARK: - Recent searches store

/// Persists the last-N rider search queries in UserDefaults so the sheet
/// can show them as taps when nothing is currently typed. Scoped by
/// signed-in user so switching accounts doesn't spill history.
enum RecentRiderSearches {
    private static let key = "recentRiderSearches"
    private static let maxItems = 8

    private static func map() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    static func list(for userID: UUID) -> [String] {
        map()[userID.uuidString] ?? []
    }

    static func record(_ term: String, for userID: UUID) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        var current = map()
        var forUser = current[userID.uuidString] ?? []
        forUser.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        forUser.insert(trimmed, at: 0)
        if forUser.count > maxItems { forUser = Array(forUser.prefix(maxItems)) }
        current[userID.uuidString] = forUser
        UserDefaults.standard.set(current, forKey: key)
    }

    static func clear(for userID: UUID) {
        var current = map()
        current.removeValue(forKey: userID.uuidString)
        UserDefaults.standard.set(current, forKey: key)
    }
}

// MARK: - Add Riders sheet (search + follow)

/// Presented from the Riders tab plus-button. Lets the user search public
/// profiles and toggle follow. Any changes to `followingIDs` flow back to
/// the parent binding so the Riders list refreshes on dismiss.
struct AddRidersSheet: View {
    @Binding var followingIDs: Set<UUID>
    let onDone: () -> Void

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var committedTerm: String = ""
    @State private var results: [SocialProfile] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var recents: [String] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchGeneration: Int = 0
    @State private var showClearRecentsConfirm = false
    @FocusState private var searchFocused: Bool

    private let profileService = SocialProfileService()
    private let followService  = FollowService()

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Add Riders",
                    onCancel: { onDone() },
                    saveLabel: "Done",
                    isSaveDisabled: false,
                    onSave: { onDone() }
                )

                searchField
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.textSecondary)
                                .padding()
                        }

                        contentSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            recents = authService.userID.map { RecentRiderSearches.list(for: $0) } ?? []
            // Auto-focus keeps the keyboard up so the user can start
            // typing without an extra tap. Feels like the search sheet
            // "means it" — the input is the primary action.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                searchFocused = true
            }
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if searching && results.isEmpty {
            // Only show the loading pill when we're searching from a
            // cold state. If the user is refining an existing query
            // the previous rows stay on screen for continuity.
            LoadingBlock(message: "Searching…")
                .padding(.top, 20)
        } else if trimmed.isEmpty {
            // Empty query → surface recent searches (if any) and the
            // "start typing" hint. Recents double as suggestions and
            // give the user something to tap.
            if !recents.isEmpty {
                recentsSection
            } else {
                EmptyStateView(
                    icon: "person.crop.circle.badge.plus",
                    title: "Search for riders",
                    message: "Start typing a username or name to find riders to follow."
                )
                .padding(.top, 20)
            }
        } else if results.isEmpty && !searching {
            noResultsSection(for: trimmed)
        } else {
            ForEach(results) { profile in
                riderRow(profile, matchTerm: trimmed)
            }
            if searching {
                // Small trailing spinner while a refined query flies —
                // keeps existing results scannable, signals "still
                // working".
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Refining…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT SEARCHES")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.textGhost)
                Spacer()
                Button("Clear") {
                    showClearRecentsConfirm = true
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .confirmationDialog("Clear recent searches?",
                                    isPresented: $showClearRecentsConfirm,
                                    titleVisibility: .visible) {
                    Button("Clear \(recents.count) recent search\(recents.count == 1 ? "" : "es")",
                           role: .destructive) {
                        if let uid = authService.userID {
                            RecentRiderSearches.clear(for: uid)
                            recents = []
                        }
                    }
                    Button("Keep", role: .cancel) { }
                } message: {
                    Text("Your recent searches only live on this device. They aren't shared with anyone.")
                }
            }
            ForEach(recents, id: \.self) { term in
                Button {
                    query = term
                    triggerSearch(for: term, debounce: false)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Color.textSecondary)
                        Text(term)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.appSurface2)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
    }

    private func noResultsSection(for term: String) -> some View {
        VStack(spacing: 14) {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No riders found for \"\(term)\"",
                message: "Try just the first few letters, or check the spelling. Only riders with a public profile show up here."
            )
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TRY A RECENT SEARCH")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(Color.textGhost)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(recents.prefix(3), id: \.self) { r in
                        Button {
                            query = r
                            triggerSearch(for: r, debounce: false)
                        } label: {
                            Text(r)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.appAccent.opacity(0.12))
                                .clipShape(Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 20)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
                .font(.system(size: 16, weight: .semibold))
            TextField("Search by username or name", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(Color.textPrimary)
                .font(.system(size: 17))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit {
                    // Commit and record the search immediately on
                    // Return so the query lands in recents even if the
                    // debounce hadn't fired yet.
                    triggerSearch(for: query, debounce: false)
                }
                .onChange(of: query) { _, newValue in
                    triggerSearch(for: newValue, debounce: true)
                }
            if searching {
                ProgressView().scaleEffect(0.8)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textGhost)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func riderRow(_ profile: SocialProfile, matchTerm: String) -> some View {
        HStack(spacing: 12) {
            ProfileAvatarBubble(profile: profile, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                highlighted(
                    profile.displayName ?? profile.username ?? "Rider",
                    term: matchTerm,
                    baseFont: .system(size: 15, weight: .semibold),
                    baseColor: Color.textPrimary
                )
                if let username = profile.username {
                    highlighted(
                        "@\(username)",
                        term: matchTerm,
                        baseFont: .system(size: 12),
                        baseColor: Color.textSecondary
                    )
                }
            }
            Spacer()
            followButton(profile)
        }
        .minimalCard()
    }

    /// Renders `text` with occurrences of `term` bolded + accent-colored.
    /// Case-insensitive; falls back to plain text when `term` is short or
    /// not found. Uses AttributedString so we get one Text view instead
    /// of a fragile HStack of substrings.
    private func highlighted(_ text: String, term: String,
                             baseFont: Font, baseColor: Color) -> some View {
        Text(Self.highlightAttributed(text: text, term: term))
            .font(baseFont)
            .foregroundStyle(baseColor)
            .lineLimit(1)
    }

    private static func highlightAttributed(text: String, term: String) -> AttributedString {
        var attributed = AttributedString(text)
        let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
        guard trimmedTerm.count >= 2 else { return attributed }
        // Highlight each whitespace-separated token independently so
        // "manan gandhi" bolds both words in the result.
        for token in trimmedTerm.split(whereSeparator: { $0.isWhitespace }) {
            let needle = String(token).lowercased()
            guard needle.count >= 2 else { continue }
            let lowerText = text.lowercased()
            var searchStart = lowerText.startIndex
            while let range = lowerText.range(of: needle, range: searchStart..<lowerText.endIndex) {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].foregroundColor = Color.appAccent
                    attributed[attrRange].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    @ViewBuilder
    private func followButton(_ profile: SocialProfile) -> some View {
        if profile.id == authService.userID {
            Text("You")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textGhost)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appSurface2)
                .clipShape(Capsule())
        } else {
            let following = followingIDs.contains(profile.id)
            Button {
                Task { await toggleFollow(profile) }
            } label: {
                Text(following ? "Following" : "Follow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(following ? Color.appAccent : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(following ? Color.appAccent.opacity(0.15) : Color.appAccent)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Schedules a search for `term`. `debounce = true` (the typing path)
    /// waits ~280ms before hitting the server so a fast typist doesn't
    /// fire off a dozen queries. `debounce = false` (Return key or a
    /// tapped recent) skips the wait and runs immediately. Any pending
    /// or in-flight prior request is cancelled so results always match
    /// the latest committed query — no out-of-order overwrite.
    private func triggerSearch(for term: String, debounce: Bool) {
        debounceTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        errorMessage = nil

        if trimmed.count < 2 {
            results = []
            searching = false
            committedTerm = ""
            return
        }

        searchGeneration += 1
        let myGen = searchGeneration
        committedTerm = trimmed

        debounceTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: 280_000_000)
                if Task.isCancelled { return }
            }
            await performSearch(term: trimmed, generation: myGen)
        }
    }

    /// Actual network hit. `generation` guards against races: if the
    /// user typed further while this request was in flight, `myGen`
    /// won't match the current `searchGeneration` and we drop the
    /// stale response on the floor.
    private func performSearch(term: String, generation: Int) async {
        searching = true
        defer {
            if generation == searchGeneration { searching = false }
        }
        do {
            let fetched = try await SupabaseCircuit.shared.run(.search) {
                try await SocialProfileService().searchPublic(query: term)
            }
            guard generation == searchGeneration else { return }
            // Rank exact-prefix hits above substring hits so what the
            // user is literally typing shows first. Case-insensitive.
            let lower = term.lowercased()
            results = fetched.sorted { a, b in
                score(profile: a, prefix: lower) > score(profile: b, prefix: lower)
            }
            // Record the term as "recent" only after we know it produced
            // results — no point suggesting a search that goes nowhere.
            if !fetched.isEmpty, let uid = authService.userID {
                RecentRiderSearches.record(term, for: uid)
                recents = RecentRiderSearches.list(for: uid)
            }
        } catch {
            guard generation == searchGeneration else { return }
            if isCancellationError(error) { return }
            errorMessage = userFacingSupabaseError(error, feature: "search")
            results = []
        }
    }

    /// Higher score = should appear higher. Simple relevance ordering:
    /// username prefix > display-name prefix > any-substring.
    private func score(profile: SocialProfile, prefix: String) -> Int {
        let username = profile.username?.lowercased() ?? ""
        let display  = profile.displayName?.lowercased() ?? ""
        if username == prefix { return 100 }
        if username.hasPrefix(prefix) { return 60 }
        if display.hasPrefix(prefix)  { return 40 }
        if username.contains(prefix)  { return 20 }
        if display.contains(prefix)   { return 10 }
        return 0
    }

    /// Optimistic follow toggle: flips the local set immediately so the
    /// pill visibly updates on tap, then fires the request in the
    /// background. If the server rejects, we roll the local set back
    /// and surface a message so the user knows why the pill flipped
    /// back — silent rollback would be worse than the original delay.
    private func toggleFollow(_ profile: SocialProfile) async {
        guard let me = authService.userID else { return }
        let wasFollowing = followingIDs.contains(profile.id)

        // 1. Optimistic UI flip.
        if wasFollowing {
            followingIDs.remove(profile.id)
        } else {
            followingIDs.insert(profile.id)
        }
        errorMessage = nil

        // 2. Server reconcile — rollback on failure with a visible
        //    message so the pill flipping back isn't mysterious.
        do {
            if wasFollowing {
                try await followService.unfollow(followerID: me, followeeID: profile.id)
            } else {
                try await followService.follow(followerID: me, followeeID: profile.id)
            }
        } catch {
            if wasFollowing {
                followingIDs.insert(profile.id)
            } else {
                followingIDs.remove(profile.id)
            }
            errorMessage = "Couldn't \(wasFollowing ? "unfollow" : "follow") \(profile.displayName ?? profile.username ?? "that rider"). Try again."
        }
    }
}

// MARK: - Shared avatar bubble

/// Circular avatar view for a `SocialProfile`. Renders the uploaded
/// avatar via the public URL if `avatarPath` is set; otherwise falls
/// back to a person glyph so rows always keep their shape.
struct ProfileAvatarBubble: View {
    let profile: SocialProfile?
    var size: CGFloat = 44

    private let service = SocialProfileService()

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.appAccent.opacity(0.15))
                .frame(width: size, height: size)
            if let path = profile?.avatarPath,
               !path.isEmpty,
               let url = service.avatarPublicURL(path: path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
        }
    }
}

// MARK: - Shared UI

struct LoadingBlock: View {
    var message: String = "Loading…"
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.appAccent)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBlock: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(Color.appAccent)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
