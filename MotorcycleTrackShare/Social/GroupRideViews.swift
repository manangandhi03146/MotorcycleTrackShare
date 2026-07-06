import SwiftUI

/// Broadcast so `ContentView` can flip to the Rides tab and start
/// recording the moment a joined participant taps "Start Ride" on
/// the group ride detail. Using NotificationCenter (rather than the
/// old `@AppStorage` signal) sidesteps the SwiftUI edge case where a
/// cross-view UserDefaults write inside a dismissed sheet wasn't
/// consistently waking the observer on the main tab.
extension Notification.Name {
    static let raceLineStartGroupRideRecording =
        Notification.Name("raceLineStartGroupRideRecording")
}

// MARK: - Row (list inside GroupDetailView)

/// Compact card used inside the group detail "Planned Rides" section.
struct GroupRideRow: View {
    let ride: GroupRide

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appAccent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: statusIcon)
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let dest = ride.destinationName ?? ride.destinationAddress {
                    Text(dest)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                if let scheduled = ride.scheduledAt {
                    Text(scheduled, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textGhost)
                }
            }
            Spacer()
            Text(ride.status.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.appSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusIcon: String {
        switch ride.status {
        case .planned:   return "calendar"
        case .active:    return "location.north.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle"
        }
    }
    private var statusColor: Color {
        switch ride.status {
        case .planned:   return Color.appAccent
        case .active:    return .green
        case .completed: return Color.textSecondary
        case .cancelled: return .red
        }
    }
}

// MARK: - Create sheet

struct CreateGroupRideSheet: View {
    let groupID: UUID
    var onDone: (GroupRide?) -> Void

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var notes = ""
    @State private var destinationName = ""
    @State private var destinationAddress = ""
    @State private var destinationLatText = ""
    @State private var destinationLonText = ""
    @State private var waypoints: [GroupRideWaypoint] = []
    @State private var scheduledDate: Date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @State private var visibility: GroupRideVisibility = .groupOnly
    @State private var liveLocationEnabled = false
    @State private var saving = false
    @State private var errorMessage: String?

    private let service = GroupRideService()

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "New Group Ride",
                    onCancel: { onDone(nil) },
                    saveLabel: "Create",
                    isSaveDisabled: title.trimmingCharacters(in: .whitespaces).count < 2 || saving,
                    onSave: { Task { await save() } }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AppFieldGroup(label: "TITLE") {
                            TextField("", text: $title, prompt: .appPrompt("Sunday canyon ride"))
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "DESTINATION NAME") {
                            TextField("", text: $destinationName, prompt: .appPrompt("The Rock Store"))
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "DESTINATION ADDRESS (OPTIONAL)") {
                            TextField("", text: $destinationAddress, prompt: .appPrompt("30354 Mulholland Hwy"))
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        HStack(spacing: 10) {
                            AppFieldGroup(label: "LATITUDE") {
                                TextField("", text: $destinationLatText, prompt: .appPrompt("34.09"))
                                    .keyboardType(.decimalPad)
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            }
                            AppFieldGroup(label: "LONGITUDE") {
                                TextField("", text: $destinationLonText, prompt: .appPrompt("-118.65"))
                                    .keyboardType(.decimalPad)
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            }
                        }
                        Text("If you don't know coordinates, leave them blank — Google Maps will look up the name/address.")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)

                        AppFieldGroup(label: "PLANNED START") {
                            DatePicker("", selection: $scheduledDate,
                                       displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .colorScheme(.dark)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "RIDE NOTES (OPTIONAL)") {
                            TextField("", text: $notes,
                                      prompt: .appPrompt("Meet at the shop, 8am roll-off"),
                                      axis: .vertical)
                                .lineLimit(3, reservesSpace: true)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        waypointsSection

                        Toggle("Only group members can see this ride", isOn: visibilityBinding)
                            .tint(Color.appAccent)
                            .foregroundStyle(Color.textPrimary)
                            .appFieldChrome()

                        Toggle("Allow live location sharing during ride", isOn: $liveLocationEnabled)
                            .tint(Color.appAccent)
                            .foregroundStyle(Color.textPrimary)
                            .appFieldChrome()
                        Text("Riders can still choose whether to share their own location. This just permits it.")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }

                        Text("Google Maps handles the actual turn-by-turn navigation. Everyone gets the same shared destination, route link, and stops loaded instantly.")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                            .padding(.top, 8)
                    }
                    .padding(20)
                }
            }
        }
    }

    // Visibility toggle is stored as an enum; expose as a Bool binding
    // where `true` means "group only".
    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { visibility == .groupOnly },
            set: { visibility = $0 ? .groupOnly : .publicVisible }
        )
    }

    // MARK: - Waypoints

    private var waypointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STOPS / WAYPOINTS (OPTIONAL)")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Color.textGhost)
                Spacer()
                Button {
                    waypoints.append(GroupRideWaypoint(name: ""))
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.appAccent)
                }
            }
            if waypoints.isEmpty {
                Text("Add stops to share them with the group route.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            } else {
                ForEach($waypoints) { $wp in
                    HStack(spacing: 8) {
                        TextField("", text: $wp.name, prompt: .appPrompt("Stop name"))
                            .foregroundStyle(Color.textPrimary)
                            .appFieldChrome()
                        Button {
                            waypoints.removeAll { $0.id == wp.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(Color.textGhost)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Save

    private func save() async {
        guard let uid = authService.userID else {
            errorMessage = "Sign in first."
            return
        }
        saving = true
        defer { saving = false }
        errorMessage = nil

        let lat = Double(destinationLatText.trimmingCharacters(in: .whitespaces))
        let lon = Double(destinationLonText.trimmingCharacters(in: .whitespaces))
        let cleanedWaypoints = waypoints.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let mapsURL = GoogleMapsRouteService.directionsURL(
            destinationName: destinationName.nilIfBlank,
            destinationAddress: destinationAddress.nilIfBlank,
            destinationLatitude: lat,
            destinationLongitude: lon,
            waypoints: cleanedWaypoints
        )

        let insert = GroupRideInsert(
            groupID: groupID,
            authorID: uid,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: notes.nilIfBlank,
            destinationName: destinationName.nilIfBlank,
            destinationAddress: destinationAddress.nilIfBlank,
            destinationLatitude: lat,
            destinationLongitude: lon,
            waypoints: cleanedWaypoints,
            googleMapsURL: mapsURL?.absoluteString,
            visibility: visibility,
            liveLocationEnabled: liveLocationEnabled,
            scheduledAt: scheduledDate
        )

        do {
            let ride = try await service.create(insert)
            _ = try? await ActivityFeedService().emit(ActivityEventInsert(
                actorID: uid,
                kind: .groupRideCreated,
                subjectID: ride.id,
                subjectKind: "group_ride",
                title: "Planned a group ride",
                summary: ride.title,
                visibility: .groups,
                groupID: ride.groupID
            ))
            onDone(ride)
        } catch let e as SocialError {
            errorMessage = e.errorDescription
        } catch {
            errorMessage = userFacingSupabaseError(error, feature: "group ride")
        }
    }
}

// MARK: - Detail view

struct GroupRideDetailView: View {
    let rideID: UUID

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("activeGroupRideID") private var activeGroupRideIDString: String = ""

    @State private var ride: GroupRide?
    @State private var participants: [GroupRideParticipant] = []
    @State private var participantProfiles: [UUID: SocialProfile] = [:]
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var actionInFlight = false

    @State private var showLiveShareWarning = false
    @State private var showDeleteConfirm = false
    @State private var showEndRideConfirm = false
    @State private var showCancelRideConfirm = false
    @State private var showLeaveRideConfirm = false
    @StateObject private var liveLocation = LiveLocationSharingService()

    private let rideService = GroupRideService()
    private let profileService = SocialProfileService()

    private var isAuthor: Bool {
        ride?.authorID == authService.userID
    }
    private var isJoined: Bool {
        guard let uid = authService.userID else { return false }
        return participants.contains { $0.userID == uid && $0.status != .cancelled }
    }
    private var isActive: Bool { ride?.status == .active }

    /// Ride title used in destructive dialogs so the user always knows
    /// which specific ride they're about to end/cancel/delete/leave.
    private var rideTitleForDialog: String {
        let raw = ride?.title.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? "this ride" : raw
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if loading {
                    // Skeleton mirrors the loaded layout: header pill +
                    // title, detail rows, primary action, participant
                    // list. Prevents the full page from popping in below
                    // a tiny loading spinner.
                    rideDetailSkeleton
                } else if let ride {
                    headerCard(ride)
                    detailsCard(ride)
                    if !ride.waypoints.isEmpty { waypointsCard(ride) }
                    actionButtons(ride)
                    participantsSection(ride)
                    liveLocationSection(ride)
                    creatorControls(ride)
                    safetyNote
                } else if let errorMessage {
                    ErrorBlock(message: errorMessage) { Task { await reload() } }
                }
            }
            .padding(20)
            .padding(.bottom, 60)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle("Group Ride")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await reload() }
        .refreshable { await reload() }
        .alert("Delete \(rideTitleForDialog)?", isPresented: $showDeleteConfirm) {
            Button("Delete Ride", role: .destructive) { Task { await deleteRide() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes \"\(rideTitleForDialog)\" from the group for everyone. This can't be undone.")
        }
        .alert("End \(rideTitleForDialog)?", isPresented: $showEndRideConfirm) {
            Button("End Ride", role: .destructive) {
                Task { await setStatus(.completed) }
            }
            Button("Keep Ride Active", role: .cancel) { }
        } message: {
            Text("Everyone joined to \"\(rideTitleForDialog)\" will see the ride as completed. You can't reopen a completed ride.")
        }
        .alert("Cancel \(rideTitleForDialog)?", isPresented: $showCancelRideConfirm) {
            Button("Cancel Ride", role: .destructive) {
                Task { await setStatus(.cancelled) }
            }
            Button("Keep Ride", role: .cancel) { }
        } message: {
            Text("\"\(rideTitleForDialog)\" will be cancelled for everyone who joined. The ride stays visible until you delete it.")
        }
        .alert("Leave \(rideTitleForDialog)?", isPresented: $showLeaveRideConfirm) {
            Button("Leave Ride", role: .destructive) {
                Task { await toggleJoin() }
            }
            Button("Stay", role: .cancel) { }
        } message: {
            Text("You'll be removed from the participant list for \"\(rideTitleForDialog)\". You can rejoin as long as the ride is still active.")
        }
        .alert("Share your live location?", isPresented: $showLiveShareWarning) {
            Button("Share", role: .none) {
                if let uid = authService.userID, let ride {
                    liveLocation.start(rideID: ride.id, userID: uid)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your location will be visible to this group only while this ride is active. You can turn it off any time.")
        }
        .onDisappear { liveLocation.stop() }
    }

    // MARK: - Cards

    private func headerCard(_ ride: GroupRide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusPill(ride.status)
                if ride.visibility == .groupOnly {
                    Label("Group only", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Label("Public", systemImage: "globe")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
            }
            Text(ride.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            if let notes = ride.description, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .minimalCard()
    }

    private func detailsCard(_ ride: GroupRide) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let scheduled = ride.scheduledAt {
                detailRow(icon: "clock.fill", label: scheduled.formatted(date: .abbreviated, time: .shortened))
            }
            if let dest = ride.destinationName {
                detailRow(icon: "mappin.and.ellipse", label: dest)
            }
            if let address = ride.destinationAddress {
                detailRow(icon: "signpost.right.fill", label: address)
            }
        }
        .minimalCard()
    }

    private func waypointsCard(_ ride: GroupRide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STOPS")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textGhost)
            ForEach(Array(ride.waypoints.enumerated()), id: \.element.id) { pair in
                HStack(spacing: 10) {
                    Text("\(pair.offset + 1)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 22)
                    Text(pair.element.name)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                }
            }
        }
        .minimalCard()
    }

    private func actionButtons(_ ride: GroupRide) -> some View {
        VStack(spacing: 10) {
            Button {
                if let url = GoogleMapsRouteService.directionsURL(for: ride) {
                    GoogleMapsRouteService.open(url: url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                    Text("Open in Google Maps")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.appAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(GoogleMapsRouteService.directionsURL(for: ride) == nil)

            Button {
                if isJoined {
                    // Leaving affects the participant list everyone can
                    // see — worth a confirmation prompt naming the ride.
                    showLeaveRideConfirm = true
                } else {
                    Task { await toggleJoin() }
                }
            } label: {
                Text(isJoined ? "Leave Ride" : "Join Ride")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isJoined ? .red : .white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(isJoined ? Color.red.opacity(0.15) : Color.appAccent.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(actionInFlight)

            // A participant "Start Ride" only appears once the ride is
            // active (creator has kicked it off), matching what the
            // creator sees below. Tapping it jumps to the Rides tab
            // and immediately begins recording, linked to this ride.
            if isJoined && !isAuthor && ride.status == .active {
                Button {
                    startRideRecording(for: ride)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Start Ride")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.appAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func participantsSection(_ ride: GroupRide) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RIDERS JOINING (\(participants.count))")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textGhost)
            if participants.isEmpty {
                Text("Nobody has joined yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
            } else {
                ForEach(participants) { p in
                    HStack(spacing: 12) {
                        ProfileAvatarBubble(profile: participantProfiles[p.userID], size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(participantName(for: p))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text(p.status.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                        if p.userID == ride.authorID {
                            Text("Leader")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.appAccent.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .minimalCard()
    }

    private func liveLocationSection(_ ride: GroupRide) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIVE LOCATION")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Color.textGhost)
            if !ride.liveLocationEnabled {
                Text("The organizer has turned off live location sharing for this ride.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
            } else if !isJoined {
                Text("Join the ride to share your location with the group.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
            } else {
                Toggle("Share my location with this group", isOn: Binding(
                    get: { liveLocation.isSharing },
                    set: { newValue in
                        if newValue { showLiveShareWarning = true }
                        else        { liveLocation.stop() }
                    }
                ))
                .tint(Color.appAccent)
                .foregroundStyle(Color.textPrimary)
                if let msg = liveLocation.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Sharing stops automatically when you leave the ride, the ride ends, or you close this screen.")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .minimalCard()
    }

    @ViewBuilder
    private func creatorControls(_ ride: GroupRide) -> some View {
        if isAuthor {
            VStack(spacing: 10) {
                if ride.status == .planned {
                    Button {
                        Task {
                            await setStatus(.active)
                            // Immediately kick off the local recording
                            // so the creator's Start Ride is a single
                            // tap: flips the ride to active AND jumps
                            // to the Rides tab with recording running.
                            if let updated = ride as GroupRide? {
                                startRideRecording(for: updated)
                            }
                        }
                    } label: {
                        actionLabel("Start Ride", icon: "play.fill")
                            .foregroundStyle(.white)
                            .background(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if ride.status == .active {
                    Button {
                        // End Ride marks the group ride done for every
                        // participant — confirm before firing so an
                        // accidental tap on a tight button stack doesn't
                        // close the ride mid-run.
                        showEndRideConfirm = true
                    } label: {
                        actionLabel("End Ride", icon: "stop.fill")
                            .foregroundStyle(.white)
                            .background(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if ride.status == .planned || ride.status == .active {
                    Button {
                        // Cancelling propagates to every joined rider's
                        // ride list — a bare tap here would be the most
                        // destructive miss in the whole detail view.
                        showCancelRideConfirm = true
                    } label: {
                        actionLabel("Cancel Ride", icon: "xmark")
                            .foregroundStyle(.red)
                            .background(Color.red.opacity(0.15))
                    }
                    .buttonStyle(.plain)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                // Delete is always available to the author regardless of
                // status — riders need a way to clear out cancelled or
                // completed rides that are cluttering the group page.
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    actionLabel("Delete Ride", icon: "trash")
                        .foregroundStyle(.white)
                        .background(Color.red)
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func actionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    // MARK: - Skeleton (loading placeholder)

    private var rideDetailSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.appSurface2)
                        .frame(width: 60, height: 18)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.appSurface2)
                        .frame(width: 80, height: 12)
                    Spacer()
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.appSurface2)
                    .frame(height: 26)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.appSurface2)
                    .frame(width: 220, height: 14)
            }
            .minimalCard()

            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.appSurface2)
                            .frame(width: 20, height: 20)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.appSurface2)
                            .frame(width: 180, height: 14)
                        Spacer()
                    }
                }
            }
            .minimalCard()

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appSurface2)
                .frame(height: 50)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.appSurface2)
                .frame(height: 46)

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.appSurface2)
                    .frame(width: 140, height: 12)
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.appSurface2)
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.appSurface2)
                                .frame(width: 120, height: 12)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.appSurface2)
                                .frame(width: 80, height: 10)
                        }
                        Spacer()
                    }
                }
            }
            .minimalCard()
        }
        .redacted(reason: .placeholder)
    }

    private var safetyNote: some View {
        Text("RaceLine hands navigation off to Google Maps. Ride within your limits and obey local traffic laws — RaceLine is not responsible for route accuracy.")
            .font(.caption)
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private func statusPill(_ status: GroupRideStatus) -> some View {
        Text(status.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(pillColor(status))
            .clipShape(Capsule())
    }

    private func pillColor(_ status: GroupRideStatus) -> Color {
        switch status {
        case .planned:   return Color.appAccent
        case .active:    return .green
        case .completed: return Color.textSecondary
        case .cancelled: return .red
        }
    }

    private func detailRow(icon: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.appAccent)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func participantName(for p: GroupRideParticipant) -> String {
        if p.userID == authService.userID { return "You" }
        if let profile = participantProfiles[p.userID] {
            if let name = profile.displayName, !name.isEmpty { return name }
            if let u = profile.username, !u.isEmpty          { return "@\(u)" }
        }
        return "Rider"
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            async let fetchedRide         = rideService.ride(id: rideID)
            async let fetchedParticipants = rideService.participants(rideID: rideID)
            let (r, p) = try await (fetchedRide, fetchedParticipants)
            ride = r
            participants = p
            await loadParticipantProfiles(p)
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingSupabaseError(error, feature: "group ride")
        }
    }

    private func loadParticipantProfiles(_ list: [GroupRideParticipant]) async {
        let missing = Set(list.map(\.userID)).subtracting(participantProfiles.keys)
        guard !missing.isEmpty else { return }
        if let fetched = try? await profileService.fetchProfiles(userIDs: Array(missing)) {
            for p in fetched { participantProfiles[p.id] = p }
        }
    }

    /// Optimistic RSVP toggle. Instead of waiting for the server and
    /// then re-fetching the whole participant list, we mutate the
    /// local `participants` array immediately so the button label,
    /// participant count, and "You" row all update on tap. The server
    /// call then reconciles in the background. On failure we restore
    /// the previous snapshot and show an error.
    private func toggleJoin() async {
        guard let uid = authService.userID else { return }
        let previous = participants
        let wasJoined = isJoined
        actionInFlight = true
        defer { actionInFlight = false }

        // 1. Optimistic local mutation.
        if wasJoined {
            participants.removeAll { $0.userID == uid }
            liveLocation.stop()
        } else {
            let now = Date()
            participants.append(GroupRideParticipant(
                groupRideID: rideID,
                userID: uid,
                status: .joined,
                joinedAt: now,
                updatedAt: now
            ))
        }
        errorMessage = nil

        // 2. Server reconcile.
        do {
            if wasJoined {
                try await rideService.leave(rideID: rideID, userID: uid)
            } else {
                try await rideService.join(rideID: rideID, userID: uid)
            }
            // On success, quietly refetch participants so any
            // concurrent joins/leaves from other riders show up.
            // Silent — no loading state — so the reconcile is
            // invisible on the happy path.
            if let latest = try? await rideService.participants(rideID: rideID) {
                participants = latest
                await loadParticipantProfiles(latest)
            }
        } catch {
            // 3. Rollback + visible message so the button snapping
            //    back isn't mysterious.
            participants = previous
            errorMessage = wasJoined
                ? "Couldn't leave this ride. Check your connection."
                : "Couldn't join this ride. Check your connection."
        }
    }

    /// Optimistic status change. The pill/buttons/creator-controls
    /// all render off `ride.status`, so we mutate the local `ride`
    /// with the new status immediately and let the network catch up.
    /// This is what makes "Start Ride" feel instant — the pill flips
    /// to Active and Start becomes End without a spinner. On failure
    /// we restore the previous ride and surface a message.
    private func setStatus(_ status: GroupRideStatus) async {
        guard let current = ride else { return }
        let previous = current

        // 1. Optimistic local mutation. We can't build a full new
        //    GroupRide (immutable, all `let` fields), so mirror the
        //    status change by rehydrating with the same fields and
        //    the new status/timestamps.
        let now = Date()
        ride = GroupRide(
            id: current.id,
            groupID: current.groupID,
            authorID: current.authorID,
            rideID: current.rideID,
            title: current.title,
            description: current.description,
            destinationName: current.destinationName,
            destinationAddress: current.destinationAddress,
            destinationLatitude: current.destinationLatitude,
            destinationLongitude: current.destinationLongitude,
            waypoints: current.waypoints,
            googleMapsURL: current.googleMapsURL,
            status: status,
            visibility: current.visibility,
            liveLocationEnabled: current.liveLocationEnabled,
            scheduledAt: current.scheduledAt,
            startedAt: status == .active ? now : current.startedAt,
            completedAt: status == .completed ? now : current.completedAt,
            createdAt: current.createdAt
        )
        if status == .completed || status == .cancelled {
            liveLocation.stop()
        }
        errorMessage = nil

        // 2. Server reconcile.
        do {
            let updated = try await rideService.setStatus(rideID: rideID, status: status)
            // Server timestamps supersede ours — swap in the
            // canonical row silently.
            ride = updated
        } catch {
            // 3. Rollback + visible message.
            ride = previous
            errorMessage = statusRollbackMessage(for: status)
        }
    }

    private func statusRollbackMessage(for status: GroupRideStatus) -> String {
        switch status {
        case .active:    return "Couldn't start the ride. Try again."
        case .completed: return "Couldn't end the ride. Try again."
        case .cancelled: return "Couldn't cancel the ride. Try again."
        case .planned:   return "Couldn't update ride status."
        }
    }

    /// Author-initiated hard delete. Works regardless of status so the
    /// group page can be cleaned of stale planned / cancelled / completed
    /// rides.
    private func deleteRide() async {
        do {
            liveLocation.stop()
            try await rideService.delete(rideID: rideID)
            dismiss()
        } catch {
            errorMessage = "Couldn't delete this ride."
        }
    }

    /// Kick off the normal ride recording from inside the group ride
    /// detail. Sets `activeGroupRideID` so the saved ride gets linked
    /// on cloud sync, dismisses this view, and posts a notification
    /// that ContentView listens to. ContentView flips the tab to
    /// Rides and calls the same `beginRide(.street)` path the manual
    /// Start Ride button uses — so the timer, distance, lean angle,
    /// and Stop button all behave the same as a solo ride.
    private func startRideRecording(for ride: GroupRide) {
        activeGroupRideIDString = ride.id.uuidString
        NotificationCenter.default.post(
            name: .raceLineStartGroupRideRecording,
            object: nil,
            userInfo: ["rideID": ride.id, "title": ride.title]
        )
        dismiss()
    }
}

// MARK: - Small helpers

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
