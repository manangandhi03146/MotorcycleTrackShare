import SwiftUI
import MapKit
import UIKit

struct ContentView: View {
    private enum Tab: Hashable {
        case calendar, ride, garage, social, profile
    }

    @EnvironmentObject private var authService: AuthService
    @AppStorage("samplingRateHz")     private var samplingRateHz: Double  = 10
    @AppStorage("defaultStorageMode") private var defaultStorageModeRaw: String = StorageMode.localOnly.rawValue

    @StateObject private var motion           = MotionService()
    @StateObject private var location         = LocationService()
    @StateObject private var recorder         = RideRecorder()
    @StateObject private var rideStore        = RideStore()
    @StateObject private var garageStore      = GarageStore()
    @StateObject private var maintenanceStore = MaintenanceStore()
    @StateObject private var syncService      = SyncService()
    @StateObject private var motorcycleCatalog = MotorcycleCatalogService()
    @StateObject private var proFeatures      = ProFeatureManager()
    @StateObject private var cloudBackup      = CloudBackupService()
    @StateObject private var customShareCards = CustomShareCardService()
    @State private var selectedTab: Tab = .ride

    // Phase 4 — one-shot signal set by GroupRideDetailView when the user
    // taps "Start RaceLine Recording". `.onChange` below picks it up,
    // switches to the Rides tab, and kicks off the normal ride flow.
    @AppStorage("startGroupRideRecordingRequest") private var groupRideRecordingRequest: String = ""
    @State private var groupRideBanner: String? = nil

    // Map state
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.0, longitude: -74.0),
                           span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
    )
    @State private var didInitialCenter = false

    // Save ride state
    @State private var awaitingSavePrompt       = false
    @State private var showSavePrompt           = false
    @State private var showNameSheet            = false
    @State private var pendingName: String      = ""
    @State private var pendingRidePhoto: UIImage?
    @State private var pendingRideBikeID: UUID?
    @State private var pendingRideType: RideType = .street
    @State private var pendingNotes: String      = ""
    @State private var pendingTags: [String]     = []
    @State private var pendingStorageMode: StorageMode = .localOnly
    @State private var showTooShortAlert        = false
    @State private var showDuplicateAlert       = false
    @State private var reopenNameSheetAfterDuplicate = false
    @State private var saveFinalizeRetryPending = false
    @State private var showStartRideTypePrompt  = false
    @State private var showTrackModeWarning     = false
    @State private var showLocationDeniedAlert  = false

    // Ride list state
    @State private var expandedRideID: UUID?
    @State private var showRideDayPicker        = false
    @State private var scrollTargetRideID: UUID?

    var body: some View {
        Group {
            if selectedTab == .ride {
                rideRecordingView
            } else if selectedTab == .garage {
                GarageView(garageStore: garageStore, catalogService: motorcycleCatalog)
                    .environmentObject(rideStore)
                    .environmentObject(maintenanceStore)
            } else if selectedTab == .social {
                SocialHubView()
            } else if selectedTab == .profile {
                NavigationStack {
                    ProfileView()
                        .environmentObject(rideStore)
                        .environmentObject(syncService)
                }
            } else {
                calendarView
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomNavigationBar
        }
        .fullScreenCover(isPresented: Binding(
            get: { expandedRideID != nil },
            set: { if !$0 { expandedRideID = nil } }
        )) {
            rideDetailCover
        }
        .onChange(of: showDuplicateAlert) { _, isShowing in
            guard !isShowing, reopenNameSheetAfterDuplicate else { return }
            reopenNameSheetAfterDuplicate = false
            showNameSheet = true
        }
        .onAppear {
            rideStore.load()
            garageStore.load()
            maintenanceStore.load()
            location.requestPermission()
            location.start()
            motion.start(hz: samplingRateHz)
            syncService.configure(rideStore: rideStore, garageStore: garageStore, authService: authService)
            syncService.startMonitoring()
        }
        .environmentObject(proFeatures)
        .environmentObject(cloudBackup)
        .environmentObject(customShareCards)
    }

    // MARK: - Ride Detail Cover

    @ViewBuilder
    private var rideDetailCover: some View {
        if let rideID = expandedRideID,
           let ride = rideStore.rides.first(where: { $0.id == rideID }) {
            RideDetailScreen(
                ride: ride,
                initialPhoto: ridePhotoImage(for: ride),
                bikes: garageStore.bikes,
                onExportJSONL: ride.logFilename.hasSuffix(".jsonl") ? { rideStore.jsonlExportURL(for: ride) } : nil,
                onClose: { expandedRideID = nil },
                onRename: { rideStore.renameRide(id: rideID, newName: $0) },
                onSetBike: { rideStore.setRideBike(id: rideID, bikeID: $0) },
                onUpdateNotes: { notes, tags in rideStore.updateNotesAndTags(id: rideID, notes: notes, tags: tags) },
                onSetPhoto: { rideStore.setRidePhoto(id: rideID, image: $0) },
                onDelete: {
                    let toDelete = rideStore.rides.first(where: { $0.id == rideID })
                    let result   = rideStore.deleteRide(id: rideID)
                    if case .success = result, let r = toDelete,
                       let remoteID = r.remoteID, let userID = authService.userID {
                        Task {
                            try? await CloudRideStore().deleteRide(
                                remoteID: remoteID, deletePhoto: r.cloudPhotoPath != nil,
                                userID: userID, rideID: r.id
                            )
                        }
                    }
                    return result
                }
            )
            .environmentObject(rideStore)
            .environmentObject(garageStore)
        } else {
            Color.appBg.ignoresSafeArea().onAppear { expandedRideID = nil }
        }
    }

    // MARK: - Ride Recording View

    private var rideRecordingView: some View {
        ZStack {
            Map(position: $position, interactionModes: .all) {
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }

            // Gradient overlay
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.appSurface.opacity(0.55), location: 0.35),
                        .init(color: Color.appSurface.opacity(0.92), location: 0.72),
                        .init(color: Color.appSurface, location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 560)
            }
            .allowsHitTesting(false)

            // Stats + controls
            VStack(spacing: 0) {
                // Top strip: time + distance, stacked on the left
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        rideTopStat("TIME", recordingTime)
                        rideTopStat("DIST", recordingDistance)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)

                Spacer()

                // Speed
                VStack(spacing: 4) {
                    Text(speedDisplayText)
                        .font(.statDisplay)
                        .foregroundStyle(Color.appAccent)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: speedDisplayText)
                    Text("MPH")
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(2.0)
                        .foregroundStyle(Color.textGhost)
                }

                // Lean angle
                VStack(spacing: 4) {
                    Text(liveLeanDisplayText)
                        .font(.statSecondary)
                        .foregroundStyle(Color.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: liveLeanDisplayText)
                    Text("LEAN")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(1.5)
                        .foregroundStyle(Color.textGhost)

                    if recorder.isRecording || recorder.summary != nil {
                        Text(maxLeanDisplayText)
                            .font(.system(size: 24, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.textSecondary)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.18), value: maxLeanDisplayText)
                            .padding(.top, 8)
                        Text("MAX LEAN")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(1.5)
                            .foregroundStyle(Color.textGhost)
                    }
                }
                .padding(.top, 18)

                Spacer()

                // Safety disclaimer during recording
                if recorder.isRecording {
                    if let banner = groupRideBanner {
                        Label(banner, systemImage: "person.3.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.appAccent.opacity(0.85))
                            .clipShape(Capsule())
                            .padding(.bottom, 4)
                    }
                    Text("Do not interact with the app while riding.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textGhost)
                        .padding(.bottom, 4)
                }

                // Controls
                VStack(spacing: 10) {
                    if !recorder.isRecording {
                        Button { motion.calibrateUpright() } label: {
                            Text("Calibrate Lean Sensor")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(Color.textSecondary)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        if recorder.isRecording {
                            awaitingSavePrompt = true
                            recorder.stop()
                            UIApplication.shared.isIdleTimerDisabled = false
                        } else if location.isPermissionBlocked {
                            showLocationDeniedAlert = true
                        } else {
                            showStartRideTypePrompt = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: recorder.isRecording ? "stop.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                            Text(recorder.isRecording ? "Stop Ride" : "Start Ride")
                                .font(.system(size: 20, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(recorder.isRecording ? Color.red : Color.appAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 12)
            }
        }
        .onChange(of: location.lat) { _, _ in centerOnUserIfNeeded() }
        .onChange(of: location.lon) { _, _ in centerOnUserIfNeeded() }
        .onChange(of: recorder.summary) { _, _ in maybePresentSavePrompt() }
        .onChange(of: recorder.fileURL) { _, _ in maybePresentSavePrompt() }
        .onChange(of: recorder.isRecording) { _, isRec in
            if !isRec {
                maybePresentSavePrompt()
                groupRideBanner = nil
            }
        }
        .onChange(of: groupRideRecordingRequest) { _, newValue in
            handleGroupRideRecordingRequest(newValue)
        }
        .onAppear {
            // Fire once if the request was set before this view was on screen.
            if !groupRideRecordingRequest.isEmpty {
                handleGroupRideRecordingRequest(groupRideRecordingRequest)
            }
        }
        .alert("Ride too short to save", isPresented: $showTooShortAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Record a little longer to capture enough data.")
        }
        .alert("Ride name already exists", isPresented: $showDuplicateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please choose a different name.")
        }
        .confirmationDialog("Save this ride?", isPresented: $showSavePrompt, titleVisibility: .visible) {
            Button("Save") { showNameSheet = true }
            Button("Don't Save", role: .destructive) { }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Choose Ride Type", isPresented: $showStartRideTypePrompt, titleVisibility: .visible) {
            Button("Street") { beginRide(rideType: .street) }
            Button("Track")  { showTrackModeWarning = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Pick how you'll be riding so we can label and surface this ride correctly.")
        }
        .alert("Track Mode", isPresented: $showTrackModeWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Start Track Ride") { beginRide(rideType: .track) }
        } message: {
            Text("Track mode is not a lap timer or official timing device. Use only on closed circuits.")
        }
        .alert("Location Access Needed", isPresented: $showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("RaceLine needs location access to record your ride. Enable it in Settings → Privacy → Location Services → RaceLine.")
        }
        .sheet(isPresented: $showNameSheet) {
            SaveRideSheet(
                name: $pendingName,
                selectedImage: $pendingRidePhoto,
                selectedBikeID: $pendingRideBikeID,
                selectedRideType: $pendingRideType,
                selectedStorageMode: $pendingStorageMode,
                notes: $pendingNotes,
                tags: $pendingTags,
                bikes: garageStore.bikes,
                onSave: saveRide,
                onCancel: resetPendingSave
            )
            .presentationDetents([.height(520)])
        }
    }

    private func beginRide(rideType: RideType) {
        pendingRideType = rideType
        recorder.start(motion: motion, location: location, sampleHz: samplingRateHz)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Reacts to a one-shot signal set by GroupRideDetailView's
    /// "Start RaceLine Recording" button. Switches to the Rides tab
    /// and begins recording (defaulting to street) so the user goes
    /// straight from the group ride sheet into the live recording UI.
    private func handleGroupRideRecordingRequest(_ raw: String) {
        guard !raw.isEmpty else { return }
        // Clear the request immediately so we never fire twice.
        groupRideRecordingRequest = ""

        if recorder.isRecording {
            // Already recording — just jump to the tab so the user can
            // see the live UI.
            selectedTab = .ride
            return
        }
        if location.isPermissionBlocked {
            selectedTab = .ride
            showLocationDeniedAlert = true
            return
        }
        selectedTab = .ride
        beginRide(rideType: .street)
        groupRideBanner = "Recording as part of a group ride"
    }

    private func saveRide() {
        guard let s = recorder.summary, let log = recorder.fileURL else {
            showNameSheet = false
            return
        }

        let trimmed   = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultRideName() : trimmed

        if rideStore.hasRide(named: finalName) {
            reopenNameSheetAfterDuplicate = true
            showDuplicateAlert = true
            return
        }

        let notes   = pendingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags    = pendingTags
        let rideType = pendingRideType
        let mode    = pendingStorageMode

        guard let savedRide = rideStore.saveRide(
            name:         finalName,
            summary:      s,
            route:        recorder.route,
            logTempURL:   log,
            rideBikeID:   pendingRideBikeID,
            ridePhoto:    pendingRidePhoto,
            rideType:     rideType,
            notes:        notes.isEmpty ? nil : notes,
            tags:         tags,
            storageMode:  mode
        ) else {
            reopenNameSheetAfterDuplicate = true
            showDuplicateAlert = true
            return
        }

        // Cloud sync if enabled
        if mode.isCloudEnabled, let userID = authService.userID {
            let photo = pendingRidePhoto
            let localRideID = savedRide.id
            let groupRideIDString = UserDefaults.standard.string(forKey: "activeGroupRideID") ?? ""
            Task {
                await syncService.syncNow()
                _ = savedRide
                _ = photo
                // Phase 4 — if the user tapped "Start RaceLine Recording"
                // from a group ride, attach the group_ride_id to the
                // uploaded ride row so we can show recap connections later.
                if !groupRideIDString.isEmpty,
                   let groupRideID = UUID(uuidString: groupRideIDString) {
                    await Self.attachGroupRide(groupRideID: groupRideID,
                                               localRideID: localRideID,
                                               userID: userID)
                    // The synchronous clear below (unconditional) already
                    // resets activeGroupRideID for the next ride.
                }
            }
        }

        // Phase 3 — no ride-completion feed emit. Per product spec, the
        // Social feed only surfaces route shares and new bike additions.
        // Users share a ride to the feed explicitly via the Share button.

        // Phase 4 — always clear the active group ride flag after save,
        // even for local-only rides that don't hit the cloud attach path.
        // Otherwise the next unrelated recording would inherit the id.
        UserDefaults.standard.removeObject(forKey: "activeGroupRideID")
        groupRideBanner = nil

        rideStore.load()
        resetPendingSave()
        showNameSheet = false
    }

    /// Once the cloud-synced ride row exists, tag it with the group ride
    /// id so recap views can link back. Best-effort — swallowed if the
    /// row hasn't uploaded yet or the auth session is stale.
    private static func attachGroupRide(groupRideID: UUID, localRideID: UUID, userID: UUID) async {
        struct Patch: Encodable { let group_ride_id: String }
        let client = SupabaseManager.shared.client
        _ = try? await client
            .from("rides")
            .update(Patch(group_ride_id: groupRideID.uuidString.lowercased()))
            .eq("local_id", value: localRideID.uuidString)
            .eq("user_id",  value: userID.uuidString)
            .execute()
    }

    private func resetPendingSave() {
        pendingRideBikeID  = nil
        pendingRidePhoto   = nil
        pendingRideType    = .street
        pendingNotes       = ""
        pendingTags        = []
        pendingStorageMode = StorageMode(rawValue: defaultStorageModeRaw) ?? .localOnly
        showNameSheet      = false
    }

    // MARK: - Recording Computed Properties

    private var speedDisplayText: String {
        guard let mps = location.speedMps, mps > 0.5 else { return "0" }
        return String(Int((mps * 2.23693629).rounded()))
    }

    private var liveLeanDisplayText: String {
        String(format: "%.0f°", abs(motion.leanDeg))
    }

    private var maxLeanDisplayText: String {
        String(format: "%.0f°", recorder.liveMaxAbsLeanDeg)
    }

    private var recordingTime: String {
        formatDuration(recorder.isRecording ? recorder.liveDurationSec : 0)
    }

    private var recordingDistance: String {
        let meters = recorder.isRecording ? recorder.liveDistanceM : 0
        return String(format: "%.2f mi", meters * 0.000621371)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    private func rideTopStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .kerning(1.0)
                .foregroundStyle(Color.textGhost)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .monospacedDigit()
        }
    }

    // MARK: - Calendar View

    private var calendarView: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if rideStore.rides.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                            Text("No rides yet")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text("Tap Start Ride to begin tracking.")
                                .font(.subheadline)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 80)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                            ForEach(ridesByMonth) { group in
                                Section {
                                    ForEach(group.rides) { ride in
                                        Button { expandedRideID = ride.id } label: {
                                            calendarRideCard(ride)
                                        }
                                        .buttonStyle(.plain)
                                        .id(ride.id)
                                    }
                                } header: {
                                    Text(group.month.uppercased())
                                        .font(.system(size: 11, weight: .semibold))
                                        .kerning(0.8)
                                        .foregroundStyle(Color.textGhost)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 16)
                                        .padding(.bottom, 2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.appBg)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 120)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) { calendarHeader }
                .onChange(of: scrollTargetRideID) { _, targetID in
                    guard let targetID else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(targetID, anchor: .top)
                    }
                    scrollTargetRideID = nil
                }
            }
            .background(Color.appBg)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showRideDayPicker) {
                RideDayPickerSheet(rideDays: Set(firstRideIDByDay.keys)) { day in
                    if let targetID = firstRideIDByDay[day] {
                        scrollTargetRideID = targetID
                    }
                    showRideDayPicker = false
                }
            }
        }
    }

    private var calendarHeader: some View {
        HStack {
            Text("Rides")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button { showRideDayPicker = true } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.appBg)
    }

    private func calendarRideCard(_ ride: SavedRide) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Mode badge
                HStack(spacing: 4) {
                    Image(systemName: ride.effectiveRideType.iconName)
                        .font(.system(size: 10, weight: .bold))
                    Text(ride.effectiveRideType.displayName.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.5)
                }
                .foregroundStyle(Color.white.opacity(0.75))

                Text(ride.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Sync status indicator
                if ride.effectiveSyncStatus == .pendingUpload {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.6))
                } else if ride.effectiveSyncStatus == .syncFailed {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.appAccent)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text(calendarDateShort(ride.createdAt))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textTertiary)
                    if let name = bikeName(for: ride) {
                        Text("·")
                            .foregroundStyle(Color.textGhost)
                        Text(name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appAccent.opacity(0.80))
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 0) {
                    rideCardStat("DIST",     rideMetricText(ride, field: .distance))
                    Spacer()
                    rideCardStat("TIME",     rideMetricText(ride, field: .duration))
                    Spacer()
                    rideCardStat("MAX LEAN", rideMetricText(ride, field: .maxLean))
                }

                if !ride.effectiveTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(ride.effectiveTags.prefix(5), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.appAccent.opacity(0.8))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.appAccent.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(Color.appSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rideCardStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.textGhost)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func calendarDateShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private struct MonthGroup: Identifiable {
        var id: String { month }
        let month: String
        var rides: [SavedRide]
    }

    private var ridesByMonth: [MonthGroup] {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        let sorted = rideStore.rides.sorted { $0.createdAt > $1.createdAt }
        var groups: [String: [SavedRide]] = [:]
        var order: [String] = []
        for ride in sorted {
            let month = formatter.string(from: ride.createdAt)
            if groups[month] == nil { groups[month] = []; order.append(month) }
            groups[month]!.append(ride)
        }
        return order.map { MonthGroup(month: $0, rides: groups[$0] ?? []) }
    }

    // MARK: - Bottom Navigation Bar

    private var bottomNavigationBar: some View {
        HStack(spacing: 0) {
            navBarButton(title: "Social", tab: .social) { isActive in
                Image(systemName: "person.2.fill")
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .frame(height: 22)
            }
            navBarButton(title: "Garage", tab: .garage) { _ in
                SportbikeIcon(height: 18).frame(height: 22)
            }
            navBarButton(title: "Ride", tab: .ride) { isActive in
                Image(systemName: "speedometer")
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .frame(height: 22)
            }
            navBarButton(title: "Rides", tab: .calendar) { isActive in
                Image(systemName: "calendar")
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .frame(height: 22)
            }
            navBarButton(title: "Profile", tab: .profile) { isActive in
                Image(systemName: "person.fill")
                    .font(.system(size: 20, weight: isActive ? .semibold : .regular))
                    .frame(height: 22)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .background(Color.appSurface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.appDivider).frame(height: 1)
        }
    }

    @ViewBuilder
    private func navBarButton<Icon: View>(title: String,
                                          tab: Tab,
                                          @ViewBuilder icon: @escaping (Bool) -> Icon) -> some View {
        let isActive = selectedTab == tab
        Button { selectedTab = tab } label: {
            VStack(spacing: 3) {
                icon(isActive)
                Text(title)
                    .font(.system(size: 9, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? Color.appAccent : Color.textGhost)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .animation(.easeOut(duration: 0.15), value: isActive)
    }

    // MARK: - Save Prompt Logic

    private func maybePresentSavePrompt() {
        guard awaitingSavePrompt else { return }

        if let summary = recorder.summary, recorder.fileURL != nil {
            awaitingSavePrompt = false
            saveFinalizeRetryPending = false
            if summary.durationSec < 5 {
                showTooShortAlert = true
                return
            }
            pendingName         = defaultRideName()
            pendingRideType     = .street
            pendingStorageMode  = StorageMode(rawValue: defaultStorageModeRaw) ?? .localOnly
            showSavePrompt = true
            return
        }

        if !recorder.isRecording, !saveFinalizeRetryPending {
            saveFinalizeRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.saveFinalizeRetryPending = false
                if self.awaitingSavePrompt { self.maybePresentSavePrompt() }
            }
            return
        }

        if !recorder.isRecording {
            awaitingSavePrompt = false
            saveFinalizeRetryPending = false
            showTooShortAlert = true
        }
    }

    // MARK: - Helpers

    private func centerOnUserIfNeeded() {
        guard !didInitialCenter, let lat = location.lat, let lon = location.lon else { return }
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
        didInitialCenter = true
    }

    private func defaultRideName() -> String {
        "Ride \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))"
    }

    private var firstRideIDByDay: [Date: UUID] {
        var out: [Date: UUID] = [:]
        let calendar = Calendar.current
        for ride in rideStore.rides {
            let day = calendar.startOfDay(for: ride.createdAt)
            if out[day] == nil { out[day] = ride.id }
        }
        return out
    }

    private func rideMetricText(_ ride: SavedRide, field: RideMetricField) -> String {
        let av = ride.metricAvailability ?? .allAvailable
        switch field {
        case .duration:     return av.hasDuration   ? ride.summary.durationText : "N/A"
        case .maxSpeed:     return av.hasMaxSpeed    ? String(format: "%.1f mph", ride.summary.maxSpeedMph) : "N/A"
        case .averageSpeed: return av.hasAverageSpeed ? String(format: "%.1f mph", ride.summary.computedAvgSpeedMph) : "N/A"
        case .maxLean:      return av.hasMaxLean     ? String(format: "%.0f°", ride.summary.maxAbsLeanDeg) : "N/A"
        case .distance:     return av.hasDistance    ? String(format: "%.2f mi", ride.summary.distanceMi) : "N/A"
        }
    }

    private func ridePhotoImage(for ride: SavedRide) -> UIImage? {
        guard let url = rideStore.photoURL(for: ride),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func bikeName(for ride: SavedRide) -> String? {
        guard let bikeID = ride.bikeID,
              let bike = garageStore.bikes.first(where: { $0.id == bikeID }) else { return nil }
        return bike.title
    }
}

// MARK: - Supporting Types

private enum RideMetricField {
    case duration, maxSpeed, averageSpeed, maxLean, distance
}

// MARK: - Ride Detail Screen

private struct RideDetailScreen: View {
    private enum PhotoPickerSource: String, Identifiable {
        case camera, library
        var id: String { rawValue }
        var uiKitSourceType: UIImagePickerController.SourceType {
            self == .camera ? .camera : .photoLibrary
        }
    }

    @EnvironmentObject private var rideStore: RideStore
    @EnvironmentObject private var garageStore: GarageStore

    let ride: SavedRide
    let initialPhoto: UIImage?
    let bikes: [GarageBike]
    let onExportJSONL: (() -> URL?)?
    let onClose: () -> Void
    let onRename: (String) -> RideStore.RenameRideResult
    let onSetBike: (UUID?) -> RideStore.SetRideBikeResult
    let onUpdateNotes: (String?, [String]) -> Bool
    let onSetPhoto: (UIImage) -> RideStore.SetRidePhotoResult
    let onDelete: () -> RideStore.DeleteRideResult

    @State private var draftName: String
    @State private var selectedBikeID: UUID?
    @State private var photoImage: UIImage?
    @State private var notesText: String
    @State private var tagsText: String
    @State private var nameSaveTask: Task<Void, Never>?
    @State private var showDuplicateAlert   = false
    @State private var showRenameFailedAlert = false
    @State private var showBikeSaveFailedAlert = false
    @State private var showDeleteConfirm    = false
    @State private var showDeleteFailedAlert = false
    @State private var showPhotoSourceDialog = false
    @State private var showPhotoSaveFailedAlert = false
    @State private var photoPickerSource: PhotoPickerSource?
    @State private var exportURL: URL?
    @State private var showExportSheet      = false
    @State private var showExportFailedAlert = false
    @State private var showingShareCover    = false
    @State private var shareInitialRideID: UUID?
    @State private var showAnalyzeSheet     = false
    @State private var showExportFormatDialog = false
    @State private var showShareOptionsDialog = false
    @State private var showShareRouteSheet    = false

    init(ride: SavedRide, initialPhoto: UIImage?, bikes: [GarageBike],
         onExportJSONL: (() -> URL?)?,
         onClose: @escaping () -> Void,
         onRename: @escaping (String) -> RideStore.RenameRideResult,
         onSetBike: @escaping (UUID?) -> RideStore.SetRideBikeResult,
         onUpdateNotes: @escaping (String?, [String]) -> Bool,
         onSetPhoto: @escaping (UIImage) -> RideStore.SetRidePhotoResult,
         onDelete: @escaping () -> RideStore.DeleteRideResult) {
        self.ride = ride
        self.initialPhoto = initialPhoto
        self.bikes = bikes
        self.onExportJSONL = onExportJSONL
        self.onClose = onClose
        self.onRename = onRename
        self.onSetBike = onSetBike
        self.onUpdateNotes = onUpdateNotes
        self.onSetPhoto = onSetPhoto
        self.onDelete = onDelete
        _draftName     = State(initialValue: ride.name)
        _selectedBikeID = State(initialValue: ride.bikeID)
        _photoImage    = State(initialValue: initialPhoto)
        _notesText     = State(initialValue: ride.notes ?? "")
        _tagsText      = State(initialValue: ride.effectiveTags.joined(separator: ", "))
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 12) {
                // Header
                HStack {
                    Button {
                        commitNameSave()
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.textGhost)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()

                    // Mode badge
                    HStack(spacing: 4) {
                        Image(systemName: ride.effectiveRideType.iconName)
                            .font(.system(size: 11, weight: .bold))
                        Text(ride.effectiveRideType.displayName)
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.appAccent.opacity(0.12))
                    .clipShape(Capsule())

                    Button {
                        showShareOptionsDialog = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(Color.appAccent.opacity(0.12))
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Name (auto-saves)
                        TextField("Ride name", text: $draftName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                            .appFieldChrome()
                            .onChange(of: draftName) { _, newValue in
                                scheduleNameSave(newValue)
                            }
                            .onSubmit { commitNameSave() }

                        // Bike picker
                        Menu {
                            Button("No bike") {
                                switch onSetBike(nil) {
                                case .success: selectedBikeID = nil
                                case .notFound, .writeFailed: showBikeSaveFailedAlert = true
                                }
                            }
                            ForEach(bikes) { bike in
                                Button(bike.title) {
                                    switch onSetBike(bike.id) {
                                    case .success: selectedBikeID = bike.id
                                    case .notFound, .writeFailed: showBikeSaveFailedAlert = true
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Bike Used")
                                        .font(.caption)
                                        .foregroundStyle(Color.textTertiary)
                                    Text(selectedBikeLabel)
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.textSecondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.appSurface2)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        // Notes
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes")
                                .font(.caption)
                                .foregroundStyle(Color.textTertiary)
                            TextField("Add notes…", text: $notesText, axis: .vertical)
                                .lineLimit(3, reservesSpace: true)
                                .textFieldStyle(.roundedBorder)
                            TextField("Tags (comma separated)", text: $tagsText)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button {
                                let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
                                let tags = tagsText
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                                    .filter { !$0.isEmpty }
                                _ = onUpdateNotes(notes.isEmpty ? nil : notes, tags)
                            } label: {
                                Text("Save Notes & Tags")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.appAccent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        // Photo
                        Button { showPhotoSourceDialog = true } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.appSurface2).frame(height: 160)
                                if let photoImage {
                                    Image(uiImage: photoImage)
                                        .resizable().scaledToFill()
                                        .frame(height: 160).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                } else {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo.on.rectangle")
                                            .font(.system(size: 24)).foregroundStyle(Color.textTertiary)
                                        Text("Add Ride Photo")
                                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.textSecondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        analyzeRideButton

                        Rectangle().fill(Color.appDivider).frame(height: 1)

                        Text(dateTimeText(ride.createdAt))
                            .font(.subheadline).foregroundStyle(Color.textTertiary)

                        // Stats
                        VStack(spacing: 10) {
                            detailRow("Total Time",  metricText(.duration))
                            detailRow("Max Speed",   metricText(.maxSpeed))
                            detailRow("Avg Speed",   metricText(.averageSpeed))
                            detailRow("Max Lean",    metricText(.maxLean))
                            detailRow("Distance",    metricText(.distance))
                            if let gain = ride.summary.elevationGainM {
                                detailRow("Elev. Gain", String(format: "%.0f ft", gain * 3.28084))
                            }
                            if let braking = ride.summary.hardBrakingCount, braking > 0 {
                                detailRow("Hard Braking", "\(braking) events")
                            }
                        }

                        // Sync status
                        HStack(spacing: 8) {
                            Image(systemName: syncIcon)
                                .font(.system(size: 12))
                                .foregroundStyle(syncColor)
                            Text(syncLabel)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }

                        if onExportJSONL != nil {
                            SecondaryButton(title: "Export JSONL") {
                                if let url = onExportJSONL?() {
                                    exportURL = url; showExportSheet = true
                                } else {
                                    showExportFailedAlert = true
                                }
                            }
                        }

                        Spacer(minLength: 20)
                        PrimaryButton(title: "Delete Ride", isDestructive: true) {
                            showDeleteConfirm = true
                        }
                    }
                    .padding(16)
                }
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(12)
        }
        .alert("Ride name already exists", isPresented: $showDuplicateAlert) { Button("OK", role: .cancel) { } }
            message: { Text("Please choose a different name.") }
        .alert("Could not save name", isPresented: $showRenameFailedAlert) { Button("OK", role: .cancel) { } }
            message: { Text("Please try again.") }
        .alert("Could not save bike", isPresented: $showBikeSaveFailedAlert) { Button("OK", role: .cancel) { } }
            message: { Text("Please try again.") }
        .confirmationDialog("Ride Photo", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { photoPickerSource = .camera }
            }
            Button("Choose Photo") { photoPickerSource = .library }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $photoPickerSource) { source in
            UIKitImagePicker(sourceType: source.uiKitSourceType) { image in
                switch onSetPhoto(image) {
                case .success: photoImage = image
                case .notFound, .writeFailed: showPhotoSaveFailedAlert = true
                }
            }
            .ignoresSafeArea()
        }
        .alert("Delete this ride?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                switch onDelete() {
                case .success: onClose()
                case .notFound, .deleteFailed: showDeleteFailedAlert = true
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This cannot be undone.") }
        .alert("Could not delete ride", isPresented: $showDeleteFailedAlert) { Button("OK", role: .cancel) { } }
            message: { Text("Please try again.") }
        .alert("Could not save photo", isPresented: $showPhotoSaveFailedAlert) { Button("OK", role: .cancel) { } }
            message: { Text("Please try again.") }
        .alert("Export Failed", isPresented: $showExportFailedAlert) { Button("OK", role: .cancel) { } }
            message: { Text("The ride file could not be exported.") }
        .sheet(isPresented: $showExportSheet) {
            if let url = exportURL { ActivityView(activityItems: [url]) }
        }
        .sheet(isPresented: $showAnalyzeSheet) {
            AnalyzeRideView(
                ride: ride,
                telemetryURL: rideStore.telemetryURL(for: ride),
                onRequestExport: { showExportFormatDialog = true }
            )
            .environmentObject(rideStore)
            .presentationDetents([.large])
        }
        .confirmationDialog("Export Ride Data",
                            isPresented: $showExportFormatDialog,
                            titleVisibility: .visible) {
            Button("CSV (samples)") { runExport(format: .csv) }
            Button("GPX (route)")   { runExport(format: .gpx) }
            Button("JSON (full ride)") { runExport(format: .json) }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Share Ride",
                            isPresented: $showShareOptionsDialog,
                            titleVisibility: .visible) {
            Button("Share Card") {
                shareInitialRideID = ride.id
                showingShareCover = true
            }
            Button("Share Route to Feed") {
                showShareRouteSheet = true
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showShareRouteSheet) {
            ShareRouteSheet(ride: ride)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(true)
        }
        .fullScreenCover(isPresented: $showingShareCover) {
            NavigationStack {
                ShareCardScreen(
                    currentSummary: nil,
                    currentRoute: [],
                    currentLogURL: nil,
                    initiallySelectedRideID: $shareInitialRideID
                )
                .environmentObject(rideStore)
                .environmentObject(garageStore)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showingShareCover = false
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                }
            }
        }
    }

    private var analyzeRideButton: some View {
        Button {
            showAnalyzeSheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.appAccent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.appAccent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Analyze Ride")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("AI summary, deeper stats, and safety notes")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.appSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.appAccent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Runs a multi-format export via `RideExportService` and presents the
    /// system share sheet on success. Falls back to the same failure alert
    /// the legacy JSONL export uses.
    private func runExport(format: RideExportFormat) {
        let service = RideExportService()
        let samplesProvider: () -> [RideSample] = {
            guard let url = rideStore.telemetryURL(for: ride) else { return [] }
            return RideSampleLoader.load(from: url)
        }
        do {
            let url = try service.export(
                ride: ride,
                route: ride.route,
                samples: samplesProvider(),
                format: format
            )
            exportURL = url
            showExportSheet = true
        } catch {
            showExportFailedAlert = true
        }
    }

    private var syncIcon: String {
        switch ride.effectiveSyncStatus {
        case .synced:        return "checkmark.icloud"
        case .pendingUpload: return "icloud.and.arrow.up"
        case .syncFailed:    return "exclamationmark.icloud"
        case .localOnly:     return "iphone"
        }
    }

    private var syncColor: Color {
        switch ride.effectiveSyncStatus {
        case .synced:        return .green
        case .pendingUpload: return .orange
        case .syncFailed:    return .red
        case .localOnly:     return Color.textGhost
        }
    }

    private var syncLabel: String {
        switch ride.effectiveSyncStatus {
        case .synced:        return "Synced to cloud"
        case .pendingUpload: return "Pending upload"
        case .syncFailed:    return "Sync failed — check Settings to retry"
        case .localOnly:     return "Saved locally only"
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Color.textPrimary)
        }
    }

    private func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func scheduleNameSave(_ candidate: String) {
        nameSaveTask?.cancel()
        nameSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitNameSave() }
        }
    }

    private func commitNameSave() {
        nameSaveTask?.cancel()
        nameSaveTask = nil
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ride.name else { return }
        switch onRename(trimmed) {
        case .success: break
        case .duplicateName: showDuplicateAlert = true
        case .notFound, .writeFailed: showRenameFailedAlert = true
        }
    }

    private func metricText(_ field: RideMetricField) -> String {
        let av = ride.metricAvailability ?? .allAvailable
        switch field {
        case .duration:     return av.hasDuration   ? ride.summary.durationText : "N/A"
        case .maxSpeed:     return av.hasMaxSpeed    ? String(format: "%.1f mph", ride.summary.maxSpeedMph) : "N/A"
        case .averageSpeed: return av.hasAverageSpeed ? String(format: "%.1f mph", ride.summary.computedAvgSpeedMph) : "N/A"
        case .maxLean:      return av.hasMaxLean     ? String(format: "%.0f°", ride.summary.maxAbsLeanDeg) : "N/A"
        case .distance:     return av.hasDistance    ? String(format: "%.2f mi", ride.summary.distanceMi) : "N/A"
        }
    }

    private var selectedBikeLabel: String {
        guard let selectedBikeID,
              let bike = bikes.first(where: { $0.id == selectedBikeID }) else { return "No bike" }
        return bike.title
    }
}

// MARK: - Ride Day Picker Sheet

private struct RideDayPickerSheet: View {
    let rideDays: Set<Date>
    let onSelectDay: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var monthAnchor: Date

    private let calendar = Calendar.current

    init(rideDays: Set<Date>, onSelectDay: @escaping (Date) -> Void) {
        let normalized = Set(rideDays.map { Calendar.current.startOfDay(for: $0) })
        self.rideDays = normalized
        self.onSelectDay = onSelectDay
        _monthAnchor = State(initialValue: normalized.max() ?? Date())
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { shiftMonth(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(monthTitle(monthAnchor)).font(.headline).foregroundStyle(Color.textPrimary)
                Spacer()
                Button { shiftMonth(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 0) {
                ForEach(weekdaySymbols(), id: \.self) { day in
                    Text(day).font(.caption.weight(.semibold)).foregroundStyle(Color.textTertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
                ForEach(Array(monthGridDays().enumerated()), id: \.offset) { _, maybeDate in
                    if let date = maybeDate {
                        let day    = calendar.component(.day, from: date)
                        let dayKey = calendar.startOfDay(for: date)
                        let hasRide = rideDays.contains(dayKey)
                        Button {
                            guard hasRide else { return }
                            onSelectDay(dayKey); dismiss()
                        } label: {
                            ZStack {
                                if hasRide { Circle().fill(Color.appAccent).frame(width: 34, height: 34) }
                                Text("\(day)").font(.body.weight(.semibold))
                                    .foregroundStyle(hasRide ? Color.white : Color.textTertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasRide)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
            }
            if rideDays.isEmpty {
                Text("No ride days yet.").font(.subheadline).foregroundStyle(Color.textSecondary).padding(.top, 8)
            }
        }
        .padding(16)
        .presentationDetents([.height(420)])
        .presentationBackground(Color.appSurface)
    }

    private func shiftMonth(by amount: Int) {
        if let next = calendar.date(byAdding: .month, value: amount, to: monthStart(monthAnchor)) { monthAnchor = next }
    }
    private func monthStart(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
    private func monthGridDays() -> [Date?] {
        let start = monthStart(monthAnchor)
        let daysInMonth = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let firstWeekday = calendar.component(.weekday, from: start)
        let lead = (firstWeekday - calendar.firstWeekday + 7) % 7
        var values = Array(repeating: Optional<Date>.none, count: lead)
        for offset in 0..<daysInMonth {
            if let day = calendar.date(byAdding: .day, value: offset, to: start) { values.append(day) }
        }
        // Pad to 42 cells (6 rows × 7 cols) so grid height is constant across months
        while values.count < 42 { values.append(nil) }
        return values
    }
    private func weekdaySymbols() -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[index...]) + Array(symbols[..<index])
    }
    private func monthTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f.string(from: date)
    }
}

// MARK: - Activity View

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
