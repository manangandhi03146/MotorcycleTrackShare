import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var rideStore: RideStore
    @EnvironmentObject private var syncService: SyncService

    @AppStorage("defaultStorageMode")        private var defaultStorageModeRaw: String = StorageMode.localOnly.rawValue
    @AppStorage("samplingRateHz")            private var samplingRateHz: Double = 10
    @AppStorage("preferredUnits")            private var preferredUnits: String = "imperial"
    @AppStorage("hideRouteByDefault")        private var hideRouteByDefault: Bool = true
    @AppStorage("routeHideDistanceMiles")    private var routeHideDistanceMiles: Double = 0.25
    @AppStorage("cloudSyncPaused")           private var cloudSyncPaused: Bool = false

    @AppStorage("hasSeenIntroTutorial") private var hasSeenIntroTutorial: Bool = true

    @State private var showFullRouteWarning = false
    @State private var pendingStorageMode: StorageMode?
    @State private var showForceResyncConfirm = false

    // MARK: - Profile identity / visibility state
    //
    // Moved here from ProfileView so all the "settings" (username,
    // display name, public toggles, social-privacy sheet) live in one
    // place — the Profile tab now only shows identity, personal bests,
    // and bio.
    @State private var socialProfile: SocialProfile?
    @State private var socialUsername      = ""
    @State private var socialDisplayName   = ""
    @State private var socialIsPublic      = false
    @State private var socialShowBikes     = false
    @State private var socialShowRideStats = true
    @State private var socialProfileLoaded = false
    @State private var socialSaving        = false
    @State private var socialError: String?
    @State private var showSocialPrivacy   = false

    private let socialProfileService = SocialProfileService()

    private var defaultStorageMode: StorageMode {
        StorageMode(rawValue: defaultStorageModeRaw)?.canonical ?? .localOnly
    }

    var body: some View {
        List {
            // Profile (username, display name, visibility)
            if authService.isLoggedIn {
                profileIdentitySection
                profileVisibilitySection
                profilePrivacyLinkSection
            }

            // Cloud sync
            if authService.isLoggedIn {
                Section {
                    // Sync status
                    HStack {
                        Label("Sync Status", systemImage: syncStatusIcon)
                        Spacer()
                        Text(syncStatusText)
                            .font(.subheadline)
                            .foregroundStyle(syncStatusColor)
                    }

                    if let lastSync = syncService.lastSyncDate {
                        HStack {
                            Label("Last Synced", systemImage: "clock")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $cloudSyncPaused) {
                        Label("Pause Cloud Sync", systemImage: "pause.circle")
                    }
                    .tint(Color.appAccent)

                    if !cloudSyncPaused && !syncService.isSyncing {
                        Button {
                            Task { await syncService.syncNow() }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(Color.appAccent)
                        }

                        Button {
                            showForceResyncConfirm = true
                        } label: {
                            Label("Re-sync All Data", systemImage: "arrow.clockwise.icloud")
                                .foregroundStyle(Color.appAccent)
                        }
                        .confirmationDialog(
                            "Re-sync All Data?",
                            isPresented: $showForceResyncConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Re-sync All") {
                                Task { await syncService.forceResyncAll() }
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This will re-upload all rides and bikes to the cloud. Use this if your data is missing from the web dashboard.")
                        }
                    }

                    if syncService.isSyncing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Syncing…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cloud Sync")
                } footer: {
                    if let error = syncService.lastSyncError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Default storage mode
            Section {
                Picker("Default Storage", selection: Binding(
                    get: { defaultStorageMode },
                    set: { newMode in
                        if newMode.uploadsFullTelemetry {
                            pendingStorageMode = newMode
                            showFullRouteWarning = true
                        } else {
                            defaultStorageModeRaw = newMode.rawValue
                        }
                    }
                )) {
                    ForEach([StorageMode.localOnly, .cloudSummaryOnly, .cloudFull, .localAndCloudFull], id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!authService.isLoggedIn)
            } header: {
                Text("Default Storage Mode")
            } footer: {
                Text(storageModeFooter)
                    .font(.caption)
            }

            // Recording
            Section {
                Picker("Sampling Rate", selection: $samplingRateHz) {
                    Text("Low Battery (1 Hz)").tag(1.0)
                    Text("Standard (10 Hz)").tag(10.0)
                    Text("High Detail (25 Hz)").tag(25.0)
                    Text("Track / Max (50 Hz)").tag(50.0)
                }

                Picker("Units", selection: $preferredUnits) {
                    Text("Imperial (mph, mi)").tag("imperial")
                    Text("Metric (km/h, km)").tag("metric")
                }
            } header: {
                Text("Recording")
            } footer: {
                if samplingRateHz >= 25 {
                    Text("High sampling rates use more battery and storage.")
                        .font(.caption)
                }
            }

            // Route privacy
            Section {
                Toggle("Hide Route Start/End by Default", isOn: $hideRouteByDefault)
                    .tint(Color.appAccent)

                if hideRouteByDefault {
                    Picker("Hide Distance", selection: $routeHideDistanceMiles) {
                        Text("0.1 mile").tag(0.1)
                        Text("0.25 mile").tag(0.25)
                        Text("0.5 mile").tag(0.5)
                        Text("1.0 mile").tag(1.0)
                    }
                }
            } header: {
                Text("Route Privacy")
            } footer: {
                Text("Hides the start and end of your route on share cards and web maps to protect your home, school, and frequent locations.")
                    .font(.caption)
            }

            // Help
            Section {
                Button {
                    hasSeenIntroTutorial = false
                } label: {
                    Label("Show Intro Tutorial", systemImage: "play.circle")
                        .foregroundStyle(Color.appAccent)
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Replay the welcome walkthrough that appears on first launch.")
                    .font(.caption)
            }

            // RaceLine Pro roadmap — foundation is in place; features remain free
            // during Phase 2 while StoreKit and pricing land later.
            Section {
                proRoadmapRow(icon: "chart.bar.xaxis",
                              title: "Advanced analytics",
                              detail: "Available today via Analyze Ride")
                proRoadmapRow(icon: "text.bubble",
                              title: "AI ride summaries",
                              detail: "Available today via Analyze Ride")
                proRoadmapRow(icon: "square.and.arrow.up.on.square",
                              title: "Export ride data",
                              detail: "CSV, GPX, JSON from Analyze Ride")
                proRoadmapRow(icon: "icloud.and.arrow.up",
                              title: "Unlimited cloud rides",
                              detail: "Cloud sync active — free cap is \(CloudBackupService.freeRideCap) rides")
                proRoadmapRow(icon: "square.stack.3d.up",
                              title: "Custom share cards",
                              detail: "Foundation ready — new layouts coming")
                proRoadmapRow(icon: "infinity",
                              title: "Unlimited bikes",
                              detail: "Free garage capped at \(ProFeatureManager.freeBikeLimit) bikes")
            } header: {
                Text("RaceLine Pro")
            } footer: {
                Text("Pro isn't ready for purchase yet. Everything you can do in the app today stays free — these rows preview what Pro will bring.")
                    .font(.caption)
            }

            // App info
            Section {
                HStack {
                    Text("App")
                    Spacer()
                    Text("RaceLine")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersionString)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .contentMargins(.bottom, 80, for: .scrollContent)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog("Full Route Upload",
                            isPresented: $showFullRouteWarning,
                            titleVisibility: .visible) {
            Button("Enable Full Route Sync", role: .destructive) {
                if let mode = pendingStorageMode {
                    defaultStorageModeRaw = mode.rawValue
                }
                pendingStorageMode = nil
            }
            Button("Cancel", role: .cancel) {
                pendingStorageMode = nil
            }
        } message: {
            Text("Full route data includes exact GPS coordinates that can reveal your home, workplace, and frequently visited locations. Are you sure?")
        }
        .sheet(isPresented: $showSocialPrivacy) {
            SocialPrivacyView()
                .presentationDetents([.large])
        }
        .task { await loadSocialProfile() }
    }

    // MARK: - Profile identity (moved off Profile tab)

    private var profileIdentitySection: some View {
        Section {
            TextField("Display name", text: $socialDisplayName)
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()
            TextField("Username", text: $socialUsername)
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if socialProfileLoaded && isSocialIdentityDirty {
                Button {
                    Task { await saveSocialProfile() }
                } label: {
                    HStack {
                        Text(socialSaving ? "Saving…" : "Save")
                            .foregroundStyle(Color.appAccent)
                        Spacer()
                        if socialSaving { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(socialSaving)
            }
            if let socialError {
                Text(socialError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Username has to be unique. Display name is what other riders see on your profile and in the feed.")
                .font(.caption)
        }
    }

    private var profileVisibilitySection: some View {
        Section {
            Toggle("Public profile", isOn: $socialIsPublic)
                .tint(Color.appAccent)
                .onChange(of: socialIsPublic) { _, _ in
                    scheduleVisibilitySave()
                }
            Toggle("Show my bikes", isOn: $socialShowBikes)
                .tint(Color.appAccent)
                .disabled(!socialIsPublic)
                .onChange(of: socialShowBikes) { _, _ in
                    scheduleVisibilitySave()
                }
            Toggle("Show my ride stats", isOn: $socialShowRideStats)
                .tint(Color.appAccent)
                .disabled(!socialIsPublic)
                .onChange(of: socialShowRideStats) { _, _ in
                    scheduleVisibilitySave()
                }
        } header: {
            Text("Profile Visibility")
        } footer: {
            Text("Only fields you turn on here are visible to other riders. Email, sign-in provider, and exact ride routes are never shared.")
                .font(.caption)
        }
    }

    private var profilePrivacyLinkSection: some View {
        Section {
            Button {
                showSocialPrivacy = true
            } label: {
                HStack {
                    Label("Social Privacy", systemImage: "lock.shield")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color.appAccent)
            }
        } header: {
            Text("Privacy Defaults")
        } footer: {
            Text("Activity visibility and default route-sharing behavior.")
                .font(.caption)
        }
    }

    private var isSocialIdentityDirty: Bool {
        guard let baseline = socialProfile else { return false }
        let username    = socialUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayName = socialDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return username    != (baseline.username ?? "")
            || displayName != (baseline.displayName ?? "")
    }

    private func loadSocialProfile() async {
        guard !socialProfileLoaded, let uid = authService.userID else { return }
        do {
            let existing = try await socialProfileService.fetchProfile(userID: uid)
            socialProfile       = existing
            socialUsername      = existing?.username ?? ""
            socialDisplayName   = existing?.displayName ?? ""
            socialIsPublic      = existing?.isPublic ?? false
            socialShowBikes     = existing?.showBikes ?? false
            socialShowRideStats = existing?.showRideStats ?? true
            socialProfileLoaded = true
        } catch {
            guard !isCancellationError(error) else { return }
            socialError = "Couldn't load your profile."
        }
    }

    /// Toggling a visibility switch autosaves — the toggles double as
    /// their own commits so there's no "Save" button hunt in Settings.
    private func scheduleVisibilitySave() {
        guard socialProfileLoaded else { return }
        Task { await saveVisibility() }
    }

    private func saveVisibility() async {
        guard let uid = authService.userID else { return }
        do {
            let updated = try await socialProfileService.updateProfile(
                userID: uid,
                SocialProfileUpdate(
                    isPublic: socialIsPublic,
                    showBikes: socialShowBikes,
                    showRideStats: socialShowRideStats
                )
            )
            socialProfile = updated
            socialError   = nil
        } catch let e as SocialError {
            socialError = e.errorDescription
        } catch {
            socialError = "Couldn't save. Try again."
        }
    }

    private func saveSocialProfile() async {
        guard let uid = authService.userID else { return }
        socialSaving = true
        socialError  = nil
        defer { socialSaving = false }
        let username    = socialUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayName = socialDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await socialProfileService.updateProfile(
                userID: uid,
                SocialProfileUpdate(
                    username: username.isEmpty ? nil : username,
                    displayName: displayName.isEmpty ? nil : displayName
                )
            )
            socialProfile = updated
        } catch let e as SocialError {
            socialError = e.errorDescription
        } catch {
            socialError = "Couldn't save. Try again."
        }
    }

    private func proRoadmapRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var syncStatusIcon: String {
        let failed  = rideStore.failedSyncRides.count
        let pending = rideStore.pendingUploadRides.count
        if failed > 0  { return "exclamationmark.icloud" }
        if pending > 0 { return "icloud.and.arrow.up" }
        return "checkmark.icloud"
    }

    private var syncStatusText: String {
        let failed  = rideStore.failedSyncRides.count
        let pending = rideStore.pendingUploadRides.count
        if failed > 0  { return "\(failed) failed" }
        if pending > 0 { return "\(pending) pending" }
        return "Up to date"
    }

    private var syncStatusColor: Color {
        let failed  = rideStore.failedSyncRides.count
        if failed > 0 { return .red }
        if rideStore.pendingUploadRides.count > 0 { return .orange }
        return .green
    }

    private var storageModeFooter: String {
        if !authService.isLoggedIn {
            return "Sign in to enable cloud storage modes."
        }
        switch defaultStorageMode {
        case .localOnly:
            return "Rides are saved only on this device."
        case .localAndCloudFull, .cloudFull:
            return "Warning: full GPS route data is uploaded, including exact coordinates."
        default:
            return "Ride stats sync to the cloud. GPS routes stay on your device."
        }
    }
}
