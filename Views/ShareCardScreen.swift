import SwiftUI
import PhotosUI
import UIKit

struct ShareCardScreen: View {
    private enum ShareMetricField {
        case duration, maxSpeed, averageSpeed, maxLean, distance
    }

    @EnvironmentObject var rideStore: RideStore
    @EnvironmentObject var garageStore: GarageStore

    let currentSummary: RideSummary?
    let currentRoute: [RidePoint]
    let currentLogURL: URL?
    @Binding var initiallySelectedRideID: UUID?

    @State private var pickedItem: PhotosPickerItem?
    @State private var backgroundUIImage: UIImage?
    @State private var exportedURL: URL?
    @State private var exportTask: Task<Void, Never>?
    @State private var title: String = "Ride"
    @State private var mode: ShareBackgroundMode = .fill
    @State private var textColor: Color = .white
    @State private var routeColor: Color = .white
    @State private var showDuplicateAlert = false
    @State private var showNameSheet = false
    @State private var reopenNameSheetAfterDuplicate = false
    @State private var pendingName: String = ""
    @State private var pendingRidePhoto: UIImage?
    @State private var pendingRideBikeID: UUID?
    @State private var pendingRideType: RideType = .street
    @State private var pendingNotes: String = ""
    @State private var pendingTags: [String] = []
    @AppStorage("defaultStorageMode") private var defaultStorageModeRaw: String = StorageMode.localOnly.rawValue
    @State private var pendingStorageMode: StorageMode = .localOnly
    @State private var selectedKey: String = "current"

    // Public web-link sharing
    @State private var shareLinkURL: URL?
    @State private var isPreparingLink = false
    @State private var showMakePublicConfirm = false
    @State private var linkErrorMessage: String?

    private var hasCurrentRide: Bool {
        currentSummary != nil && currentRoute.count >= 2
    }

    private var isCurrentRideSaved: Bool {
        guard let s = currentSummary, currentRoute.count >= 2 else { return false }
        return rideStore.rides.contains { $0.summary == s && $0.route == currentRoute }
    }

    private var rideOptions: [(key: String, label: String)] {
        var out: [(String, String)] = []
        if hasCurrentRide {
            let label = isCurrentRideSaved ? "Current Ride (saved)" : "Current Ride (unsaved)"
            out.append(("current", label))
        } else {
            out.append(("current", "Current Ride (none)"))
        }
        for r in rideStore.rides {
            out.append((r.id.uuidString, "\(r.name) • \(String(format: "%.2f mi", r.summary.distanceMi))"))
        }
        return out
    }

    private var selectedSummaryAndRoute: (RideSummary, [RidePoint])? {
        if selectedKey == "current" {
            guard let s = currentSummary, currentRoute.count >= 2 else { return nil }
            return (s, currentRoute)
        }
        guard let id = UUID(uuidString: selectedKey),
              let ride = rideStore.rides.first(where: { $0.id == id }) else { return nil }
        return (ride.summary, ride.route)
    }

    private var selectedSavedRide: SavedRide? {
        guard selectedKey != "current", let id = UUID(uuidString: selectedKey) else { return nil }
        return rideStore.rides.first(where: { $0.id == id })
    }

    private var selectedLabel: String {
        rideOptions.first(where: { $0.key == selectedKey })?.label ?? "Select ride"
    }

    private var cardIsReady: Bool {
        backgroundUIImage != nil && selectedSummaryAndRoute != nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            cardPreviewSection

            VStack(alignment: .leading, spacing: 20) {
                backgroundPhotoSection
                customizeSection
                shareLinkSection
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle("Share")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                exportToolbarButton
            }
        }
        .sheet(isPresented: $showNameSheet) { saveRideSheet }
        .alert("Ride name already exists", isPresented: $showDuplicateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please choose a different name.")
        }
        .confirmationDialog(
            "Create a public link?",
            isPresented: $showMakePublicConfirm,
            titleVisibility: .visible
        ) {
            Button("Create Public Link") {
                if let ride = selectedSavedRide {
                    Task { await createPublicLink(ride: ride) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Anyone with the link will be able to view this ride's stats (distance, speed, lean, and your notes) on the web. You can stop sharing at any time.")
        }
        .onChange(of: showDuplicateAlert) { _, isShowing in
            guard !isShowing, reopenNameSheetAfterDuplicate else { return }
            reopenNameSheetAfterDuplicate = false
            showNameSheet = true
        }
        .onChange(of: initiallySelectedRideID) { _, newValue in
            if newValue != nil { applyInitialSelectionFromNavigation() }
        }
        .onChange(of: selectedKey)     { _, _ in
            shareLinkURL = nil
            linkErrorMessage = nil
            Task { await applyAssociatedRidePhotoIfAvailable() }
        }
        .onChange(of: title)           { _, _ in refreshExportedURLIfNeeded() }
        .onChange(of: mode)            { _, _ in refreshExportedURLIfNeeded() }
        .onChange(of: textColor)       { _, _ in refreshExportedURLIfNeeded() }
        .onChange(of: routeColor)      { _, _ in refreshExportedURLIfNeeded() }
        .onChange(of: backgroundUIImage) { _, _ in refreshExportedURLIfNeeded() }
        .onChange(of: pickedItem) { _, newItem in
            Task { await loadImage(from: newItem) }
        }
        .onAppear {
            if rideStore.rides.isEmpty { rideStore.load() }
            if initiallySelectedRideID != nil {
                applyInitialSelectionFromNavigation()
            } else {
                setDefaultSelection()
            }
            Task { await applyAssociatedRidePhotoIfAvailable() }
        }
    }

    // MARK: - Card Preview

    private var cardPreviewSection: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.appSurface

                if let bg = backgroundUIImage, let (s, route) = selectedSummaryAndRoute {
                    ShareCardView(
                        background: bg,
                        summary: s,
                        title: title.isEmpty ? "Ride" : title,
                        route: route,
                        mode: mode,
                        tightPadding: true,
                        textColor: textColor,
                        routeColor: routeColor
                    )
                    .frame(width: 185, height: 329)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(Color.textGhost)
                        Text("Choose a ride and photo")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.textGhost)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360)

            Rectangle()
                .fill(Color.appDivider)
                .frame(height: 1)
        }
    }

    // MARK: - Select Ride

    private var selectRideSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Select Ride")

            Menu {
                ForEach(rideOptions, id: \.key) { opt in
                    Button { selectedKey = opt.key } label: { Text(opt.label) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedLabel)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appSurface2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if selectedKey == "current", !isCurrentRideSaved {
                Button {
                    pendingName = defaultRideName()
                    pendingRideBikeID = nil
                    pendingRidePhoto = nil
                    showNameSheet = true
                } label: {
                    Text("Save Ride to Library")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.appAccent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(currentSummary == nil || currentLogURL == nil || currentRoute.count < 2)
            }
        }
    }

    // MARK: - Background Photo

    private var backgroundPhotoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Background Photo")

            PhotosPicker(selection: $pickedItem, matching: .images) {
                HStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.appAccent)
                    Text(backgroundUIImage == nil ? "Choose Photo" : "Change Photo")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    if backgroundUIImage != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.appAccent)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.textGhost)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appSurface2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Customize

    private var customizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Customize")

            VStack(spacing: 0) {
                // Title
                HStack(spacing: 12) {
                    Text("Title")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textSecondary)
                    TextField("Ride", text: $title)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                rowDivider

                // Text color
                HStack {
                    Text("Text color")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    ColorPicker("", selection: $textColor, supportsOpacity: true)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                rowDivider

                // Route color
                HStack {
                    Text("Route color")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    ColorPicker("", selection: $routeColor, supportsOpacity: true)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)

                rowDivider

                // Photo fit
                HStack {
                    Text("Photo fit")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Picker("", selection: $mode) {
                        ForEach(ShareBackgroundMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Share Web Link

    @ViewBuilder
    private var shareLinkSection: some View {
        if let ride = selectedSavedRide {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("Share Link")

                VStack(alignment: .leading, spacing: 12) {
                    if ride.remoteID == nil {
                        linkHint("Sync this ride to the cloud to create a shareable web link.")
                    } else if let url = shareLinkURL {
                        linkHint("Anyone with this link can view this ride's stats on the web.")
                        HStack(spacing: 10) {
                            ShareLink(item: url) {
                                Label("Share Link", systemImage: "link")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.appAccent)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.appAccent.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            Button {
                                Task { await revokePublicLink(ride: ride) }
                            } label: {
                                Text("Stop Sharing")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.red.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    } else {
                        linkHint("Create a public web link to this ride's stat card.")
                        Button {
                            showMakePublicConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                if isPreparingLink {
                                    ProgressView().tint(Color.appAccent).scaleEffect(0.85)
                                }
                                Text(isPreparingLink ? "Creating…" : "Create Public Link")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.appAccent)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.appAccent.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(isPreparingLink)
                    }

                    if let err = linkErrorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func linkHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.textSecondary)
    }

    // MARK: - Export Toolbar Button

    @ViewBuilder
    private var exportToolbarButton: some View {
        if let url = exportedURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        } else if backgroundUIImage != nil && selectedSummaryAndRoute != nil {
            ProgressView()
                .tint(Color.appAccent)
                .scaleEffect(0.85)
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textGhost)
                .frame(width: 44, height: 44)
        }
    }

    // MARK: - Save Ride Sheet

    private var saveRideSheet: some View {
        SaveRideSheet(
            name: $pendingName,
            selectedImage: $pendingRidePhoto,
            selectedBikeID: $pendingRideBikeID,
            selectedRideType: $pendingRideType,
            selectedStorageMode: $pendingStorageMode,
            notes: $pendingNotes,
            tags: $pendingTags,
            bikes: garageStore.bikes,
            onSave: {
                guard let s = currentSummary,
                      let logURL = currentLogURL,
                      currentRoute.count >= 2 else {
                    showNameSheet = false
                    return
                }
                let trimmed = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalName = trimmed.isEmpty ? defaultRideName() : trimmed

                if rideStore.hasRide(named: finalName) {
                    reopenNameSheetAfterDuplicate = true
                    showDuplicateAlert = true
                    return
                }

                let savedRide = rideStore.saveRide(
                    name: finalName,
                    summary: s,
                    route: currentRoute,
                    logTempURL: logURL,
                    rideBikeID: pendingRideBikeID,
                    ridePhoto: pendingRidePhoto,
                    rideType: pendingRideType,
                    notes: pendingNotes.isEmpty ? nil : pendingNotes,
                    tags: pendingTags,
                    storageMode: pendingStorageMode
                )
                guard savedRide != nil else {
                    reopenNameSheetAfterDuplicate = true
                    showDuplicateAlert = true
                    return
                }
                rideStore.load()
                if let latest = rideStore.latest {
                    selectedKey = latest.id.uuidString
                }
                pendingRideBikeID = nil
                pendingRidePhoto = nil
                pendingRideType = .street
                pendingNotes = ""
                pendingTags = []
                pendingStorageMode = StorageMode(rawValue: defaultStorageModeRaw) ?? .localOnly
                showNameSheet = false
            },
            onCancel: {
                pendingRideBikeID = nil
                pendingRidePhoto = nil
                pendingRideType = .street
                pendingNotes = ""
                pendingTags = []
                pendingStorageMode = StorageMode(rawValue: defaultStorageModeRaw) ?? .localOnly
                showNameSheet = false
            }
        )
        .presentationDetents([.height(520)])
        .presentationBackground(Color.appSurface)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Color.textGhost)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.appDivider)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func applyInitialSelectionFromNavigation() {
        guard let rideID = initiallySelectedRideID else { return }
        if rideStore.rides.contains(where: { $0.id == rideID }) {
            selectedKey = rideID.uuidString
        } else {
            setDefaultSelection()
        }
        initiallySelectedRideID = nil
    }

    private func setDefaultSelection() {
        if !hasCurrentRide, let latest = rideStore.latest {
            selectedKey = latest.id.uuidString
        } else {
            selectedKey = "current"
        }
    }

    private func loadImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        exportedURL = nil
        if let data = try? await item.loadTransferable(type: Data.self),
           let ui = UIImage(data: data) {
            backgroundUIImage = normalizedImage(ui)
            applyDefaultMode(for: ui)
        }
    }

    private func defaultRideName() -> String {
        "Ride \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))"
    }

    private func exportPNG(background: UIImage,
                           summary: RideSummary,
                           title: String,
                           route: [RidePoint],
                           mode: ShareBackgroundMode,
                           textColor: Color,
                           routeColor: Color) -> URL? {
        let size = CGSize(width: 1080, height: 1920)
        let view = ShareCardView(
            background: background,
            summary: summary,
            title: title,
            route: route,
            mode: mode,
            tightPadding: true,
            textColor: textColor,
            routeColor: routeColor
        )
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = UIScreen.main.scale

        guard let image = renderer.uiImage,
              let data = image.pngData() else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private func refreshExportedURLIfNeeded() {
        exportTask?.cancel()
        guard let bg = backgroundUIImage,
              let (s, route) = selectedSummaryAndRoute else {
            exportedURL = nil
            return
        }
        let (t, m, tc, rc) = (title.isEmpty ? "Ride" : title, mode, textColor, routeColor)
        exportTask = Task {
            let url = exportPNG(background: bg, summary: s, title: t, route: route,
                                mode: m, textColor: tc, routeColor: rc)
            if !Task.isCancelled { exportedURL = url }
        }
    }

    private func applyAssociatedRidePhotoIfAvailable() async {
        guard selectedKey != "current",
              let id = UUID(uuidString: selectedKey),
              let ride = rideStore.rides.first(where: { $0.id == id }),
              let url = rideStore.photoURL(for: ride) else { return }

        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value

        guard let image else {
            backgroundUIImage = nil
            return
        }
        backgroundUIImage = normalizedImage(image)
        applyDefaultMode(for: image)
    }

    // MARK: - Public link actions

    private func createPublicLink(ride: SavedRide) async {
        guard let remoteID = ride.remoteID else { return }
        isPreparingLink = true
        linkErrorMessage = nil
        let store = CloudRideStore()
        do {
            try await store.setRideVisibility(remoteID: remoteID, isPublic: true)
            shareLinkURL = store.publicShareURL(remoteID: remoteID)
        } catch {
            linkErrorMessage = "Couldn't create the link. Check your connection and try again."
        }
        isPreparingLink = false
    }

    private func revokePublicLink(ride: SavedRide) async {
        guard let remoteID = ride.remoteID else { return }
        linkErrorMessage = nil
        let store = CloudRideStore()
        do {
            try await store.setRideVisibility(remoteID: remoteID, isPublic: false)
            shareLinkURL = nil
        } catch {
            linkErrorMessage = "Couldn't stop sharing. Please try again."
        }
    }

    private func applyDefaultMode(for image: UIImage) {
        let ratio = image.size.height / max(image.size.width, 1)
        mode = (ratio > 1.9) ? .fit : .fill
    }

    private func normalizedImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? image
    }
}
