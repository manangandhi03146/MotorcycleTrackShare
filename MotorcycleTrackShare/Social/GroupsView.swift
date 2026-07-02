import SwiftUI

// MARK: - Groups list

/// List of the current user's groups. Presents create + join sheets, and
/// pushes into `GroupDetailView` on tap.
struct GroupsView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var proFeatures: ProFeatureManager

    @State private var groups: [GroupSummary] = []
    @State private var state: LoadState = .loading
    @State private var showCreateSheet = false
    @State private var showJoinSheet = false
    @State private var showGroupLimitSheet = false
    @State private var actionError: String?

    private let service = GroupService()

    /// Groups the current user OWNS. Free tier is capped at
    /// `ProFeatureManager.freeGroupLimit` — joining others is unlimited.
    private var ownedGroupCount: Int {
        guard let uid = authService.userID else { return 0 }
        return groups.filter { $0.ownerID == uid }.count
    }

    private enum LoadState: Equatable { case loading, loaded, empty, error(String) }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 10) {
                    switch state {
                    case .loading:
                        LoadingBlock(message: "Loading groups…")
                            .padding(.top, 40)
                    case .empty:
                        EmptyStateView(
                            icon: "person.3",
                            title: "No groups yet",
                            message: "Create a crew for your riding buddies or join one with a code."
                        )
                        .padding(.top, 40)
                    case .error(let m):
                        ErrorBlock(message: m) { Task { await reload() } }
                            .padding(.top, 20)
                    case .loaded:
                        ForEach(groups) { group in
                            NavigationLink {
                                GroupDetailView(group: group)
                            } label: {
                                groupRow(group)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let actionError {
                        Text(actionError)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textSecondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 100)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $showCreateSheet) {
            CreateGroupSheet { newGroup in
                showCreateSheet = false
                if let newGroup {
                    groups.insert(newGroup, at: 0)
                    state = .loaded
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinGroupSheet { joined in
                showJoinSheet = false
                if joined != nil { Task { await reload() } }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGroupLimitSheet) {
            ProUpgradeSheet(
                feature: .unlimitedGroups,
                contextTitle: "You've hit the free group-owner cap",
                contextBody: "Free accounts can create up to \(ProFeatureManager.freeGroupLimit) groups. You can still join as many groups as you want with an invite code — the limit is only on groups you OWN. Delete or leave an owned group to free up a slot."
            )
            .presentationDetents([.large])
        }
    }

    private func attemptCreate() {
        if proFeatures.canCreateGroup(currentOwnedCount: ownedGroupCount) {
            showCreateSheet = true
        } else {
            showGroupLimitSheet = true
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                attemptCreate()
            } label: {
                Label("Create", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appAccent)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button {
                showJoinSheet = true
            } label: {
                Label("Join", systemImage: "key")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appAccent.opacity(0.15))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func groupRow(_ group: GroupSummary) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.appAccent.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: group.isPublic ? "person.3.fill" : "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(group.isPublic ? "Public group" : "Private group")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
        }
        .minimalCard()
    }

    private func reload() async {
        guard let uid = authService.userID else {
            state = .error("Sign in to see your groups.")
            return
        }
        state = .loading
        do {
            let list = try await service.groups(forUser: uid)
            groups = list
            state = list.isEmpty ? .empty : .loaded
        } catch {
            state = .error(userFacingSupabaseError(error, feature: "groups"))
        }
    }
}

// MARK: - Create group

struct CreateGroupSheet: View {
    var onDone: (GroupSummary?) -> Void

    @EnvironmentObject private var authService: AuthService
    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = false
    @State private var saving = false
    @State private var errorMessage: String?

    private let service = GroupService()

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Create Group",
                    onCancel: { onDone(nil) },
                    saveLabel: "Create",
                    isSaveDisabled: name.trimmingCharacters(in: .whitespaces).count < 2 || saving,
                    onSave: { Task { await create() } }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AppFieldGroup(label: "GROUP NAME") {
                            TextField("", text: $name, prompt: .appPrompt("Sunday Sport Crew"))
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }
                        AppFieldGroup(label: "DESCRIPTION (OPTIONAL)") {
                            TextField("", text: $description, prompt: .appPrompt("What's this group about?"), axis: .vertical)
                                .lineLimit(3, reservesSpace: true)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }
                        Toggle("Public group", isOn: $isPublic)
                            .tint(Color.appAccent)
                            .foregroundStyle(Color.textPrimary)
                            .appFieldChrome()
                        Text(isPublic
                             ? "Anyone signed into RaceLine can find and join this group."
                             : "Only riders with the invite code can join.")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)

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
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            let group = try await service.createGroup(
                name: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
                isPublic: isPublic
            )
            onDone(group)
        } catch let e as SocialError {
            errorMessage = e.errorDescription
        } catch {
            let text = "\(error)"
            if text.contains("Free accounts can only create up to") {
                errorMessage = "You've hit the \(ProFeatureManager.freeGroupLimit)-group ownership limit. Delete or leave an existing owned group to free up a slot."
            } else if text.contains("Not authenticated") {
                errorMessage = "Your session is signed out. Sign back in and try again."
            } else {
                errorMessage = userFacingSupabaseError(error, feature: "group creation")
            }
        }
    }
}

// MARK: - Join group

struct JoinGroupSheet: View {
    var onDone: (GroupSummary?) -> Void

    @EnvironmentObject private var authService: AuthService
    @State private var code = ""
    @State private var joining = false
    @State private var errorMessage: String?

    private let service = GroupService()

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Join a Group",
                    onCancel: { onDone(nil) },
                    saveLabel: "Join",
                    isSaveDisabled: code.trimmingCharacters(in: .whitespaces).count < 4 || joining,
                    onSave: { Task { await join() } }
                )

                VStack(alignment: .leading, spacing: 14) {
                    AppFieldGroup(label: "INVITE CODE") {
                        TextField("", text: $code, prompt: .appPrompt("8-character code"))
                            .foregroundStyle(Color.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .appFieldChrome()
                    }
                    Text("Ask a group owner or admin for the invite code.")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
                Spacer()
            }
        }
    }

    private func join() async {
        guard let uid = authService.userID else { errorMessage = "Sign in first."; return }
        joining = true
        defer { joining = false }
        do {
            let group = try await service.joinByCode(userID: uid, code: code)
            onDone(group)
        } catch let e as SocialError {
            errorMessage = e.errorDescription
        } catch {
            errorMessage = "Couldn't join. Try again."
        }
    }
}

// MARK: - Group detail

struct GroupDetailView: View {
    let group: GroupSummary

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var members: [GroupMember] = []
    @State private var rides: [GroupRide] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var showLeaveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showCreateGroupRide = false
    @State private var didLeave = false

    private let service = GroupService()
    private let groupRideService = GroupRideService()

    /// The current user owns the group when the local copy of the row has
    /// their id as `owner_id`. Migration 017 auto-transfers ownership on
    /// owner leave, so this stays truthful across reloads.
    private var isOwner: Bool {
        authService.userID == group.ownerID
    }

    /// Owner leaving with other members still present will hand ownership
    /// off to the longest-tenured remaining member via the DB trigger.
    private var willTransferOwnershipOnLeave: Bool {
        isOwner && members.count > 1
    }

    /// Last-member-leaving auto-deletes the group. Warn the user.
    private var willDeleteGroupOnLeave: Bool {
        members.count <= 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerCard
                inviteCard

                sectionHeader("Members")
                if members.isEmpty {
                    Text("Loading members…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(members) { m in
                        memberRow(m)
                    }
                }

                HStack {
                    sectionHeader("Planned Rides")
                    Spacer()
                    Button {
                        showCreateGroupRide = true
                    } label: {
                        Label("New", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.appAccent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if rides.isEmpty {
                    Text("No group rides planned yet. Tap New to share a destination with the group.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(rides) { ride in
                        NavigationLink {
                            GroupRideDetailView(rideID: ride.id)
                        } label: {
                            GroupRideRow(ride: ride)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !didLeave {
                    if isOwner {
                        Button("Delete Group") { showDeleteConfirm = true }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(Color.red.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.top, 10)
                    }
                    Button("Leave Group") { showLeaveConfirm = true }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(Color.red.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, isOwner ? 0 : 10)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            // Extra breathing room so the destructive Leave/Delete
            // buttons aren't clipped by the tab bar / home indicator.
            .padding(.bottom, 60)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await reload() }
        .alert("Leave this group?", isPresented: $showLeaveConfirm) {
            Button("Leave", role: .destructive) { Task { await leave() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(leaveWarningText)
        }
        .alert("Delete this group?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await deleteGroup() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the group and all its rides for every member. This can't be undone.")
        }
        .sheet(isPresented: $showCreateGroupRide) {
            CreateGroupRideSheet(groupID: group.id) { newRide in
                showCreateGroupRide = false
                if let newRide {
                    rides.insert(newRide, at: 0)
                }
            }
            .presentationDetents([.large])
        }
    }

    private var leaveWarningText: String {
        if willDeleteGroupOnLeave {
            return "You're the last member — leaving will delete this group and its rides."
        }
        if willTransferOwnershipOnLeave {
            return "You'll be leaving as the owner. Ownership will move to the longest-standing member."
        }
        return "You'll need the invite code to rejoin."
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: group.isPublic ? "person.3.fill" : "lock.fill")
                    .foregroundStyle(Color.appAccent)
                Text(group.isPublic ? "Public group" : "Private group")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            if let desc = group.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Created \(group.createdAt, style: .date)")
                .font(.caption)
                .foregroundStyle(Color.textGhost)
        }
        .minimalCard()
    }

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INVITE CODE")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textGhost)
            HStack {
                Text(group.joinCode)
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button {
                    UIPasteboard.general.string = group.joinCode
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.appAccent.opacity(0.15))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("Share this code with fellow riders to invite them.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .minimalCard()
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.textGhost)
    }

    private func memberRow(_ member: GroupMember) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .foregroundStyle(Color.appAccent)
                .frame(width: 26)
            Text(shortID(member.userID))
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(member.role.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(member.role == .owner ? Color.appAccent : Color.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((member.role == .owner ? Color.appAccent : Color.textSecondary).opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.appSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            async let m = service.members(groupID: group.id)
            async let r = groupRideService.rides(forGroup: group.id)
            let (mList, rList) = try await (m, r)
            members = mList
            rides = rList
        } catch {
            errorMessage = "Couldn't load group. Check your connection."
        }
    }

    private func leave() async {
        guard let uid = authService.userID else { return }
        do {
            try await service.leave(userID: uid, groupID: group.id)
            didLeave = true
            dismiss()
        } catch {
            errorMessage = "Couldn't leave the group."
        }
    }

    private func deleteGroup() async {
        guard isOwner else { return }
        do {
            try await service.deleteGroup(groupID: group.id)
            didLeave = true
            dismiss()
        } catch {
            errorMessage = "Couldn't delete the group. Only the owner can delete a group."
        }
    }
}
