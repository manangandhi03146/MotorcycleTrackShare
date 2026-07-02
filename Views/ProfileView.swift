import SwiftUI
import PhotosUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var rideStore: RideStore
    @EnvironmentObject private var syncService: SyncService

    @State private var isLoggingOut = false
    @State private var showDeleteAccountConfirm = false
    @State private var isDeleting = false
    @State private var showDeleteError = false
    @State private var showPrivacyPolicy = false

    // Inline profile-edit state — only the bio + avatar live on this
    // tab now. Username, display name, visibility toggles, and the
    // social-privacy sheet all moved into Settings so the Profile tab
    // stays focused on the rider's headline identity.
    @State private var socialProfile: SocialProfile?
    @State private var loadingProfile = true
    @State private var savingProfile  = false
    @State private var profileError: String?

    @State private var bio = ""

    @State private var avatarPickerItem: PhotosPickerItem?
    @State private var localAvatarImage: UIImage?
    @State private var avatarPath: String?
    @State private var avatarUploading = false

    private let socialProfileService = SocialProfileService()

    private var profile: UserProfile? { authService.state.profile }

    private var identityHeadline: String {
        if let name = socialProfile?.displayName, !name.isEmpty { return name }
        if let name = profile?.displayName, !name.isEmpty { return name }
        if let email = profile?.email, !email.isEmpty     { return email }
        return "Signed in"
    }

    // MARK: - All-time stats

    private var allTimeMaxSpeedMph: Double {
        rideStore.rides.map { $0.summary.maxSpeedMph }.max() ?? 0
    }
    private var allTimeMaxLeanRight: Double {
        rideStore.rides.map { $0.summary.maxLeanRightDeg }.max() ?? 0
    }
    private var allTimeMaxLeanLeft: Double {
        rideStore.rides.map { $0.summary.maxLeanLeftDeg }.max() ?? 0
    }
    private var totalDistanceMi: Double {
        rideStore.rides.reduce(0) { $0 + $1.summary.distanceMi }
    }
    private var totalRides: Int { rideStore.rides.count }

    private var syncBadge: String? {
        let failed  = rideStore.failedSyncRides.count
        let pending = rideStore.pendingUploadRides.count
        if failed > 0  { return "\(failed) sync failed" }
        if pending > 0 { return "\(pending) pending" }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {

                // Identity: avatar + name at the top.
                identityBlock
                    .padding(.top, 24)

                // Personal bests promoted just under the avatar so it's
                // the first substantive content the rider sees.
                personalBestsBlock

                // Bio stays inline — it's a lightweight, expressive field
                // that reads better here than buried in Settings.
                bioBlock

                if isProfileDirty {
                    saveProfileRow
                }

                if let profileError {
                    Text(profileError)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }

                // Account actions
                VStack(spacing: 10) {
                    PrimaryButton(
                        title: "Sign Out",
                        isLoading: isLoggingOut,
                        isDestructive: true
                    ) {
                        Task { await logOut() }
                    }

                    Button {
                        showDeleteAccountConfirm = true
                    } label: {
                        Text("Delete Account")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)

                // Privacy policy link
                Button {
                    showPrivacyPolicy = true
                } label: {
                    Text("Privacy Policy")
                        .font(.caption)
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 80)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { profileHeader }
        .background(Color.appBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await loadSocialProfile() }
        .onChange(of: avatarPickerItem) { _, newItem in
            Task { await handleAvatarPick(newItem) }
        }
        .confirmationDialog("Delete Account?",
                            isPresented: $showDeleteAccountConfirm,
                            titleVisibility: .visible) {
            Button("Delete My Account and Data", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all your rides, bikes, and account data. This cannot be undone.")
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Could not delete your account. Please try again or contact support.")
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicySheet()
        }
    }

    // MARK: - Identity block

    private var identityBlock: some View {
        VStack(spacing: 16) {
            avatarPicker
            HStack(spacing: 6) {
                Image(systemName: "icloud.fill").font(.system(size: 12))
                Text(identityHeadline)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let badge = syncBadge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 20)
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $avatarPickerItem, matching: .images, photoLibrary: .shared()) {
            ZStack(alignment: .bottomTrailing) {
                avatarCircle
                if avatarUploading {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.35))
                        ProgressView()
                            .tint(.white)
                    }
                    .frame(width: 96, height: 96)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.appAccent)
                            .frame(width: 30, height: 30)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 2, y: 2)
                }
            }
            .accessibilityLabel("Change profile picture")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatarCircle: some View {
        let ring = Circle().stroke(Color.appAccent.opacity(0.35), lineWidth: 2)
        ZStack {
            Circle()
                .fill(Color.appSurface2)
                .frame(width: 96, height: 96)
            if let localAvatarImage {
                Image(uiImage: localAvatarImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
            } else if let path = avatarPath,
                      let url  = socialProfileService.avatarPublicURL(path: path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.fill")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.appAccent)
            }
        }
        .overlay(ring)
        .frame(width: 96, height: 96)
    }

    private var bioBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("BIO")
            TextField("", text: $bio,
                      prompt: .appPrompt("Sport-touring in the PNW"),
                      axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .foregroundStyle(Color.textPrimary)
                .appFieldChrome()
        }
        .padding(.horizontal, 20)
    }

    private var saveProfileRow: some View {
        PrimaryButton(
            title: savingProfile ? "Saving…" : "Save Bio",
            isLoading: savingProfile,
            isDestructive: false
        ) {
            Task { await saveSocialProfile() }
        }
        .padding(.horizontal, 24)
    }

    private var personalBestsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("PERSONAL BESTS")
                .padding(.horizontal, 24)

            if rideStore.rides.isEmpty {
                Text("Record your first ride to see your stats here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    personalBestCard(label: "Max Lean Right", value: allTimeMaxLeanRight > 0 ? String(format: "%.1f°", allTimeMaxLeanRight) : "—", icon: "rotate.right.fill")
                    personalBestCard(label: "Max Lean Left",  value: allTimeMaxLeanLeft  > 0 ? String(format: "%.1f°", allTimeMaxLeanLeft)  : "—", icon: "rotate.left.fill")
                    personalBestCard(label: "Max Speed",      value: allTimeMaxSpeedMph  > 0 ? String(format: "%.1f mph", allTimeMaxSpeedMph) : "—", icon: "speedometer")
                    personalBestCard(label: "Total Distance", value: String(format: "%.1f mi", totalDistanceMi), icon: "road.lanes")
                }
                .padding(.horizontal, 16)

                HStack {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 12))
                    Text("\(totalRides) ride\(totalRides == 1 ? "" : "s") total")
                        .font(.subheadline)
                }
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Color.textGhost)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileHeader: some View {
        HStack {
            Text("Profile")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            NavigationLink {
                SettingsView()
                    .environmentObject(rideStore)
                    .environmentObject(syncService)
                    .environmentObject(authService)
            } label: {
                Image(systemName: "gear")
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

    private func logOut() async {
        isLoggingOut = true
        await authService.signOut()
        isLoggingOut = false
    }

    // MARK: - Social profile loading / saving

    private var isProfileDirty: Bool {
        guard let baseline = socialProfile else { return false }
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBio != (baseline.bio ?? "")
    }

    private func loadSocialProfile() async {
        guard let uid = authService.userID else {
            loadingProfile = false
            return
        }
        loadingProfile = true
        defer { loadingProfile = false }
        do {
            let existing = try await socialProfileService.fetchProfile(userID: uid)
            socialProfile = existing
            bio        = existing?.bio ?? ""
            avatarPath = existing?.avatarPath
        } catch {
            guard !isCancellationError(error) else { return }
            profileError = "Couldn't load your profile."
        }
    }

    private func saveSocialProfile() async {
        guard let uid = authService.userID else { return }
        savingProfile = true
        profileError  = nil
        defer { savingProfile = false }

        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let updated = try await socialProfileService.updateProfile(
                userID: uid,
                SocialProfileUpdate(
                    bio: trimmedBio.isEmpty ? nil : trimmedBio,
                    avatarPath: avatarPath
                )
            )
            socialProfile = updated
        } catch let e as SocialError {
            profileError = e.errorDescription
        } catch {
            profileError = "Couldn't save profile. Try again."
        }
    }

    // MARK: - Avatar pick / upload

    private func handleAvatarPick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let uid = authService.userID else {
            profileError = "Sign in first before changing your avatar."
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                profileError = "Couldn't read that image. Pick a different photo."
                return
            }
            guard let image = UIImage(data: data) else {
                profileError = "Couldn't decode that image. Try a JPEG or PNG."
                return
            }
            let resized = image.resized(toMaxDimension: 512) ?? image
            localAvatarImage = resized
            avatarUploading = true
            defer { avatarUploading = false }
            let path = try await socialProfileService.uploadAvatar(resized, userID: uid)
            avatarPath = path
            let updated = try await socialProfileService.updateProfile(
                userID: uid,
                SocialProfileUpdate(avatarPath: path)
            )
            socialProfile = updated
            profileError = nil
        } catch let e as SocialError {
            profileError = e.errorDescription
        } catch {
            profileError = "Couldn't upload avatar: \(error.localizedDescription)"
            print("Avatar upload error:", error)
        }
    }

    private func personalBestCard(label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(Color.textGhost)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.appAccent)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func deleteAccount() async {
        isDeleting = true
        do {
            try await authService.deleteAccount()
        } catch {
            showDeleteError = true
        }
        isDeleting = false
    }
}

// MARK: - Image helpers

private extension UIImage {
    /// Aspect-fit downscale that keeps the larger dimension at `maxDim`
    /// and preserves aspect ratio. Returns nil if the render fails.
    func resized(toMaxDimension maxDim: CGFloat) -> UIImage? {
        let width  = size.width
        let height = size.height
        let larger = max(width, height)
        guard larger > maxDim else { return self }
        let scale = maxDim / larger
        let newSize = CGSize(width: width * scale, height: height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale  = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Privacy Policy Sheet

struct PrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        Text("RaceLine Privacy Policy")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.textPrimary)

                        Text("Last updated: June 2026")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)

                        privacySection("What we collect", """
RaceLine collects only the data you choose to provide: your email address (for account creation), ride stats, and optionally GPS route data if you enable full cloud sync.

By default, GPS routes are stored locally on your device only. Cloud sync uploads summary statistics (speed, distance, lean angles) without your exact GPS route unless you explicitly enable full route sync.
""")

                        privacySection("Your account", """
RaceLine requires an account so your rides sync across the iOS app and the web dashboard. We only store what you explicitly opt to upload — ride summaries by default, full GPS routes only if you turn them on.
""")

                        privacySection("Cloud sync", """
If you enable cloud sync, ride summaries are stored in a private Supabase database. Only you can access your data. Full GPS route data is only uploaded if you choose "Cloud Full Data" storage mode with an explicit privacy warning.
""")

                        privacySection("Data deletion", """
You can delete your account and all associated data at any time from Profile → Delete Account. This permanently removes all rides, bikes, and media from our servers.
""")

                        privacySection("Third parties", """
RaceLine does not sell or share your data with third parties. We use Supabase for database and authentication services, and Apple/Google for sign-in.
""")

                        privacySection("Contact", """
For privacy questions, contact us at: privacy@raceline.app
""")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .background(Color.appBg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.appAccent)
                }
            }
        }
    }

    private func privacySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
