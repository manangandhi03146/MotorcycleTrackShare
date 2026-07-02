import SwiftUI

/// Track which local rides the current user has already shared to the
/// feed. Backed by UserDefaults so the check survives app restarts, but
/// doesn't require a DB round-trip on every share attempt. Keys stay
/// scoped to the local `SavedRide.id` so re-sharing after cloud-sync
/// doesn't create phantom dupes.
enum SharedRideRegistry {
    private static let key = "sharedRideIDsByUser"

    private static func map() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    static func hasShared(rideID: UUID, userID: UUID) -> Bool {
        map()[userID.uuidString]?.contains(rideID.uuidString) ?? false
    }

    static func markShared(rideID: UUID, userID: UUID) {
        var current = map()
        var forUser = current[userID.uuidString] ?? []
        if !forUser.contains(rideID.uuidString) {
            forUser.append(rideID.uuidString)
            current[userID.uuidString] = forUser
            UserDefaults.standard.set(current, forKey: key)
        }
    }
}

/// Sheet that lets a rider publish a saved ride's route to a chosen audience.
/// Route sanitizer (hide start/end + trim N points) runs in-app before insert
/// so the sensitive tail points never touch Supabase for private variants.
struct ShareRouteSheet: View {
    let ride: SavedRide

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authService: AuthService

    @State private var title: String
    @State private var description: String = ""
    @State private var visibility: SharedRouteVisibility = .privateOnly
    @State private var hideStart: Bool = true
    @State private var hideEnd: Bool = true
    @State private var trimPoints: Int = 5
    @State private var groups: [GroupSummary] = []
    @State private var selectedGroupID: UUID?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var showVisibilityDialog = false
    @State private var showGroupDialog = false

    private let routeService = SharedRouteService()
    private let groupService = GroupService()
    private let activityService = ActivityFeedService()

    init(ride: SavedRide) {
        self.ride = ride
        _title = State(initialValue: ride.name)
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Share Ride",
                    onCancel: { dismiss() },
                    saveLabel: "Share",
                    isSaveDisabled: saving || title.trimmingCharacters(in: .whitespaces).isEmpty,
                    onSave: { Task { await save() } }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AppFieldGroup(label: "TITLE") {
                            TextField("", text: $title, prompt: .appPrompt("Route name"))
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }
                        AppFieldGroup(label: "DESCRIPTION (OPTIONAL)") {
                            TextField("", text: $description,
                                      prompt: .appPrompt("Cornering-heavy, backroads, mild elevation…"),
                                      axis: .vertical)
                                .lineLimit(3, reservesSpace: true)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }
                        AppFieldGroup(label: "VISIBILITY") {
                            DropdownFieldButton(
                                selectionText: visibility.displayName
                            ) { showVisibilityDialog = true }
                        }
                        Text(visibility.explainer)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)

                        if visibility == .groups {
                            AppFieldGroup(label: "GROUP") {
                                DropdownFieldButton(
                                    selectionText: selectedGroupName
                                ) { showGroupDialog = true }
                            }
                        }

                        privacyToggles

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task { await loadGroups() }
        .confirmationDialog("Visibility",
                            isPresented: $showVisibilityDialog,
                            titleVisibility: .visible) {
            ForEach(SharedRouteVisibility.allCases) { v in
                Button(v.displayName) { visibility = v }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Share with which group?",
                            isPresented: $showGroupDialog,
                            titleVisibility: .visible) {
            ForEach(groups) { g in
                Button(g.name) { selectedGroupID = g.id }
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Sections

    private var privacyToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SAFETY")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textGhost)

            Toggle("Hide the ride's start point", isOn: $hideStart)
                .tint(Color.appAccent)
                .foregroundStyle(Color.textPrimary)
                .appFieldChrome()
            Toggle("Hide the ride's end point", isOn: $hideEnd)
                .tint(Color.appAccent)
                .foregroundStyle(Color.textPrimary)
                .appFieldChrome()

            HStack {
                Text("Trim points from each end")
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(trimPoints)")
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                Stepper("", value: $trimPoints, in: 0...50)
                    .labelsHidden()
                    .tint(Color.appAccent)
            }
            .appFieldChrome()

            Text("Trimming keeps residences and workplaces off the shared route.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedGroupName: String {
        groups.first(where: { $0.id == selectedGroupID })?.name ?? "Select a group"
    }

    // MARK: - Actions

    private func loadGroups() async {
        guard let uid = authService.userID else { return }
        groups = (try? await groupService.groups(forUser: uid)) ?? []
    }

    private func save() async {
        guard let uid = authService.userID else { errorMessage = "Sign in first."; return }
        if visibility == .groups, selectedGroupID == nil {
            errorMessage = "Pick a group to share with."
            return
        }
        // Block double-shares: if this rider already published this
        // ride's route, tell them instead of silently duplicating the
        // feed entry.
        if SharedRideRegistry.hasShared(rideID: ride.id, userID: uid) {
            errorMessage = "You've already shared this ride. Delete the existing share first if you want to re-share."
            return
        }
        saving = true
        defer { saving = false }
        let points = SharedRouteService.sanitize(
            points: ride.route,
            hideStart: hideStart,
            hideEnd: hideEnd,
            trim: trimPoints
        )
        // NOTE: We intentionally do NOT pass the local ride UUID as
        // `rideID` here — `shared_routes.ride_id` FK's to `rides.id`, which
        // is the server-generated cloud UUID (not the on-device UUID stored
        // in `SavedRide.id`). Passing the local UUID triggers a 23503
        // foreign-key violation for anyone who hasn't cloud-synced this
        // specific ride. If we later want to link back, do a lookup by
        // (user_id, local_id) against the cloud `rides` table first.
        let insert = SharedRouteInsert(
            authorID: uid,
            rideID: nil,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
            distanceMeters: ride.summary.distanceM,
            visibility: visibility,
            groupID: visibility == .groups ? selectedGroupID : nil,
            hideStart: hideStart,
            hideEnd: hideEnd,
            trimPoints: trimPoints,
            routePoints: points
        )
        do {
            let saved = try await routeService.post(insert)
            SharedRideRegistry.markShared(rideID: ride.id, userID: uid)
            // Skip the activity emit entirely for private routes — they
            // shouldn't appear in any follower / group / public feed.
            if visibility != .privateOnly {
                let feedVisibility: ActivityVisibility = {
                    switch visibility {
                    case .privateOnly:   return .followers // unreachable, guarded above
                    case .followers:     return .followers
                    case .groups:        return .groups
                    case .publicVisible: return .publicVisible
                    }
                }()
                _ = try? await activityService.emit(ActivityEventInsert(
                    actorID: uid,
                    kind: .sharedRoutePosted,
                    subjectID: saved.id,
                    subjectKind: "shared_route",
                    title: "Shared a ride",
                    summary: saved.title,
                    visibility: feedVisibility,
                    groupID: saved.groupID
                ))
            }
            dismiss()
        } catch {
            errorMessage = userFacingSupabaseError(error, feature: "route sharing")
        }
    }
}
