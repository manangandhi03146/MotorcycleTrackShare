import SwiftUI
import UIKit

struct BikeStats {
    let rideCount: Int
    let totalMiles: Double
    let maxSpeedMph: Double
    let maxLeanDeg: Double
    let lastRideDate: Date?
}

struct GarageView: View {
    @ObservedObject var garageStore: GarageStore
    @ObservedObject var catalogService: MotorcycleCatalogService
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var rideStore: RideStore
    @EnvironmentObject private var maintenanceStore: MaintenanceStore
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled: Bool = false

    @State private var showAddBikeSheet = false
    @State private var addBikeErrorMessage: String?
    @State private var expandedBikeID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                if garageStore.bikes.isEmpty {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            SportbikeIcon(height: 48)
                                .foregroundStyle(Color.appAccent)
                            Text("No bikes yet")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text("Add your first bike to get started.")
                                .font(.subheadline)
                                .foregroundStyle(Color.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(32)
                        .frame(maxWidth: .infinity)

                        PrimaryButton(title: "Add First Bike") {
                            attemptAddBike()
                        }
                        .padding(.horizontal, 32)
                    }
                    .padding(.top, 40)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(garageStore.bikes) { bike in
                            Button {
                                expandedBikeID = bike.id
                            } label: {
                                garageBikeCard(bike)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                garageHeader
            }
            .background(Color.appBg)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddBikeSheet) {
                AddBikeSheet(
                    catalogService: catalogService,
                    onSave: { nickname, year, make, model, photo in
                        switch garageStore.addBike(
                            nickname: nickname,
                            year: year,
                            make: make,
                            model: model,
                            photo: photo
                        ) {
                        case .success(let bike):
                            showAddBikeSheet = false
                            if cloudSyncEnabled, let userID = authService.userID {
                                let photoToSync = photo
                                Task {
                                    if let remoteID = try? await CloudGarageStore().syncBike(bike, userID: userID, photo: photoToSync) {
                                        let path = photoToSync != nil ? CloudGarageStore().photoStoragePath(userID: userID, bikeID: bike.id) : nil
                                        _ = garageStore.updateCloudInfo(id: bike.id, remoteID: remoteID, cloudPhotoPath: path)
                                    }
                                }
                            }
                            if let userID = authService.userID {
                                let addedBike = bike
                                Task { await Self.emitBikeAddedActivity(userID: userID, bike: addedBike) }
                            }
                        case .writeFailed:
                            addBikeErrorMessage = "The bike could not be saved."
                        }
                    },
                    onCancel: {
                        showAddBikeSheet = false
                    }
                )
            }
            .alert("Could Not Save Bike", isPresented: Binding(
                get: { addBikeErrorMessage != nil },
                set: { if !$0 { addBikeErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { addBikeErrorMessage = nil }
            } message: {
                Text(addBikeErrorMessage ?? "The bike could not be saved.")
            }
            .task {
                garageStore.load()
                await catalogService.loadMakesIfNeeded()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { expandedBikeID != nil },
            set: { if !$0 { expandedBikeID = nil } }
        )) {
            if let bikeID = expandedBikeID,
               let bike = garageStore.bikes.first(where: { $0.id == bikeID }) {
                GarageBikeDetailScreen(
                    bike: bike,
                    stats: bikeStats(for: bikeID),
                    initialPhoto: bikeImage(for: bike),
                    catalogService: catalogService,
                    onClose: { expandedBikeID = nil },
                    onUpdate: { nickname, year, make, model in
                        garageStore.updateBike(
                            id: bikeID,
                            nickname: nickname,
                            year: year,
                            make: make,
                            model: model
                        )
                    },
                    onSetPhoto: { image in
                        garageStore.setBikePhoto(id: bikeID, image: image)
                    },
                    onDelete: {
                        let bikeToDelete = garageStore.bikes.first(where: { $0.id == bikeID })
                        let result = garageStore.deleteBike(id: bikeID)
                        if case .success = result,
                           let bike = bikeToDelete,
                           let remoteID = bike.remoteID,
                           let userID = authService.userID {
                            Task {
                                try? await CloudGarageStore().deleteBike(
                                    remoteID: remoteID,
                                    deletePhoto: bike.cloudPhotoPath != nil,
                                    userID: userID,
                                    bikeID: bike.id
                                )
                            }
                        }
                        return result
                    }
                )
                .environmentObject(maintenanceStore)
                .environmentObject(garageStore)
            } else {
                Color.appBg
                    .ignoresSafeArea()
                    .onAppear { expandedBikeID = nil }
            }
        }
    }

    private var garageHeader: some View {
        HStack {
            Text("Garage")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button {
                attemptAddBike()
            } label: {
                Image(systemName: "plus")
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

    private func attemptAddBike() {
        showAddBikeSheet = true
    }

    /// Best-effort emit of a `bikeAdded` activity so the user's followers
    /// see the new bike in their feed. Never blocks the save flow.
    static func emitBikeAddedActivity(userID: UUID, bike: GarageBike) async {
        let summary: String = {
            let year = bike.year.map { "\($0) " } ?? ""
            let spec = "\(year)\(bike.make) \(bike.model)".trimmingCharacters(in: .whitespaces)
            return spec.isEmpty ? bike.nickname : spec
        }()
        try? await ActivityFeedService().emit(ActivityEventInsert(
            actorID: userID,
            kind: .bikeAdded,
            subjectID: bike.id,
            subjectKind: "bike",
            title: "Added a new bike",
            summary: summary,
            visibility: .followers,
            groupID: nil
        ))
    }

    @ViewBuilder
    private func garageBikeCard(_ bike: GarageBike) -> some View {
        HStack(spacing: 14) {
            bikePhotoView(for: bike)

            VStack(alignment: .leading, spacing: 6) {
                Text(bike.title)
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                if !bike.specLine.isEmpty {
                    Text(bike.specLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.appAccent.opacity(0.85))
                }

                let stats = bikeStats(for: bike.id)
                if stats.rideCount > 0 {
                    HStack(spacing: 10) {
                        Label("\(stats.rideCount)", systemImage: "flag.checkered")
                        Text("·")
                        Text(String(format: "%.0f mi", stats.totalMiles))
                    }
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                } else {
                    Text("Added \(formattedDate(bike.createdAt))")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textGhost)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func bikeStats(for bikeID: UUID) -> BikeStats {
        let rides = rideStore.rides.filter { $0.bikeID == bikeID }
        return BikeStats(
            rideCount: rides.count,
            totalMiles: rides.reduce(0) { $0 + $1.summary.distanceMi },
            maxSpeedMph: rides.map { $0.summary.maxSpeedMph }.max() ?? 0,
            maxLeanDeg: rides.map { max($0.summary.maxLeanRightDeg, $0.summary.maxLeanLeftDeg) }.max() ?? 0,
            lastRideDate: rides.map(\.createdAt).max()
        )
    }

    @ViewBuilder
    private func bikePhotoView(for bike: GarageBike) -> some View {
        if let image = bikeImage(for: bike) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.appSurface2)
                .frame(width: 96, height: 96)
                .overlay {
                    SportbikeIcon(height: 32)
                        .foregroundStyle(Color.appAccent)
                }
        }
    }

    private func bikeImage(for bike: GarageBike) -> UIImage? {
        guard let url = garageStore.photoURL(for: bike),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

private struct AddBikeSheet: View {
    @ObservedObject var catalogService: MotorcycleCatalogService

    let onSave: (String, Int?, String, String, UIImage?) -> Void
    let onCancel: () -> Void

    @State private var yearText = ""
    @State private var selectedMake = ""
    @State private var selectedModel = ""
    @State private var manualMake = ""
    @State private var manualModel = ""
    @State private var selectedPhoto: UIImage?
    @State private var showPhotoSourceDialog = false
    @State private var photoPickerSource: PhotoPickerSource?
    @State private var showMakeSearch = false
    @State private var showModelSearch = false

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Add Bike",
                    onCancel: onCancel,
                    saveLabel: "Save Bike",
                    isSaveDisabled: parsedYear == nil || resolvedMake.isEmpty || resolvedModel.isEmpty,
                    onSave: {
                        onSave("", parsedYear, resolvedMake, resolvedModel, selectedPhoto)
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        AppFieldGroup(label: "YEAR") {
                            TextField("", text: $yearText, prompt: .appPrompt("e.g. 2023"))
                                .keyboardType(.numberPad)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "MAKE") {
                            if catalogService.isLoadingMakes && catalogService.makes.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView().tint(Color.appAccent).scaleEffect(0.85)
                                    Text("Loading motorcycle makes…")
                                        .foregroundStyle(Color.textSecondary)
                                }
                                .appFieldChrome()
                            } else if catalogService.makes.isEmpty {
                                TextField("", text: $manualMake, prompt: .appPrompt("Make"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                                if let message = catalogService.makesErrorMessage {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(Color.textTertiary)
                                }
                            } else {
                                CatalogPickerRow(
                                    selection: selectedMake.isEmpty ? "Select make" : selectedMake,
                                    hasValue: !selectedMake.isEmpty
                                ) { showMakeSearch = true }
                                .sheet(isPresented: $showMakeSearch) {
                                    CatalogSearchSheet(title: "Make", items: catalogService.makes.map(\.name)) { make in
                                        selectedMake = make
                                        selectedModel = ""
                                        manualModel = ""
                                        Task { await catalogService.loadModels(makeName: make, year: parsedYear) }
                                    }
                                }
                            }
                        }

                        AppFieldGroup(label: "MODEL") {
                            if selectedMake.isEmpty && !catalogService.makes.isEmpty {
                                TextField("", text: $manualModel, prompt: .appPrompt("Model"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            } else if catalogService.isLoadingModels {
                                HStack(spacing: 10) {
                                    ProgressView().tint(Color.appAccent).scaleEffect(0.85)
                                    Text("Loading motorcycle models…")
                                        .foregroundStyle(Color.textSecondary)
                                }
                                .appFieldChrome()
                            } else if catalogService.models.isEmpty && !selectedMake.isEmpty {
                                TextField("", text: $manualModel, prompt: .appPrompt("Model"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                                if let message = catalogService.modelsErrorMessage {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(Color.textTertiary)
                                }
                            } else if !catalogService.models.isEmpty {
                                CatalogPickerRow(
                                    selection: selectedModel.isEmpty ? "Select model" : selectedModel,
                                    hasValue: !selectedModel.isEmpty
                                ) { showModelSearch = true }
                                .sheet(isPresented: $showModelSearch) {
                                    CatalogSearchSheet(title: "Model", items: catalogService.models.map(\.name)) { model in
                                        selectedModel = model
                                    }
                                }
                            } else {
                                TextField("", text: $manualModel, prompt: .appPrompt("Model"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            }
                        }

                        AppFieldGroup(label: "BIKE PHOTO (OPTIONAL)") {
                            Button {
                                showPhotoSourceDialog = true
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.appSurface2)
                                        .frame(height: 160)

                                    if let selectedPhoto {
                                        Image(uiImage: selectedPhoto)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 160)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 24, weight: .semibold))
                                                .foregroundStyle(Color.appAccent)
                                            Text("Add Bike Photo")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Color.textPrimary)
                                            Text("Take or upload")
                                                .font(.caption)
                                                .foregroundStyle(Color.textTertiary)
                                        }
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .presentationDetents([.large])
        .confirmationDialog("Bike Photo", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") {
                    photoPickerSource = .camera
                }
            }
            Button("Choose Photo") {
                photoPickerSource = .library
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $photoPickerSource) { source in
            UIKitImagePicker(sourceType: source.uiKitSourceType) { image in
                selectedPhoto = image
            }
            .ignoresSafeArea()
        }
        .task {
            await catalogService.loadMakesIfNeeded()
            if !selectedMake.isEmpty {
                await catalogService.loadModels(makeName: selectedMake, year: parsedYear)
            }
        }
        .onChange(of: yearText) { _, _ in
            guard !selectedMake.isEmpty else { return }
            selectedModel = ""
            manualModel = ""
            Task {
                await catalogService.loadModels(makeName: selectedMake, year: parsedYear)
            }
        }
    }

    private var parsedYear: Int? {
        guard let year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1900...2100).contains(year) else {
            return nil
        }
        return year
    }

    private var resolvedMake: String {
        let selected = selectedMake.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return manualMake.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedModel: String {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum PhotoPickerSource: String, Identifiable {
        case camera
        case library

        var id: String { rawValue }

        var uiKitSourceType: UIImagePickerController.SourceType {
            switch self {
            case .camera:
                return .camera
            case .library:
                return .photoLibrary
            }
        }
    }
}

private struct GarageBikeDetailScreen: View {
    let bike: GarageBike
    let stats: BikeStats
    let initialPhoto: UIImage?
    @ObservedObject var catalogService: MotorcycleCatalogService
    let onClose: () -> Void
    let onUpdate: (String, Int?, String, String) -> GarageStore.UpdateBikeResult
    let onSetPhoto: (UIImage) -> GarageStore.SetBikePhotoResult
    let onDelete: () -> GarageStore.DeleteBikeResult

    @EnvironmentObject private var maintenanceStore: MaintenanceStore
    @EnvironmentObject private var garageStore: GarageStore

    @State private var photoImage: UIImage?
    @State private var showEditSheet = false

    init(bike: GarageBike,
         stats: BikeStats,
         initialPhoto: UIImage?,
         catalogService: MotorcycleCatalogService,
         onClose: @escaping () -> Void,
         onUpdate: @escaping (String, Int?, String, String) -> GarageStore.UpdateBikeResult,
         onSetPhoto: @escaping (UIImage) -> GarageStore.SetBikePhotoResult,
         onDelete: @escaping () -> GarageStore.DeleteBikeResult) {
        self.bike = bike
        self.stats = stats
        self.initialPhoto = initialPhoto
        self.catalogService = catalogService
        self.onClose = onClose
        self.onUpdate = onUpdate
        self.onSetPhoto = onSetPhoto
        self.onDelete = onDelete
        _photoImage = State(initialValue: initialPhoto)
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    header

                    VStack(alignment: .leading, spacing: 16) {
                        photoRow

                        VStack(alignment: .leading, spacing: 6) {
                            Text(bike.title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                            Text(bike.specLine)
                                .font(.subheadline)
                                .foregroundStyle(Color.textSecondary)
                            Text("Added \(formattedDate(bike.createdAt))")
                                .font(.caption)
                                .foregroundStyle(Color.textGhost)
                        }

                        if stats.rideCount > 0 {
                            statsCard
                        }

                        Divider().background(Color.appDivider)

                        BikeMaintenanceSection(bike: bike)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditBikeSheet(
                bike: bike,
                initialPhoto: photoImage,
                catalogService: catalogService,
                onUpdate: onUpdate,
                onSetPhoto: { image in
                    let result = onSetPhoto(image)
                    if case .success = result { photoImage = image }
                    return result
                },
                onDelete: {
                    let result = onDelete()
                    if case .success = result { onClose() }
                    return result
                },
                onCancel: { showEditSheet = false },
                onSaved: { showEditSheet = false }
            )
            .presentationDetents([.large])
        }
    }

    // MARK: - Header + rows

    private var header: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showEditSheet = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit bike")
        }
    }

    private var photoRow: some View {
        Button {
            showEditSheet = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.appSurface2)
                    .frame(height: 190)

                if let photoImage {
                    Image(uiImage: photoImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 190)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                        Text("Add Bike Photo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("Tap the gear to upload")
                            .font(.caption)
                            .foregroundStyle(Color.textGhost)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statsCard: some View {
        HStack(spacing: 0) {
            bikeStatCell(value: "\(stats.rideCount)", label: "RIDES")
            Divider().frame(height: 32)
            bikeStatCell(value: String(format: "%.0f", stats.totalMiles), label: "MILES")
            Divider().frame(height: 32)
            bikeStatCell(value: String(format: "%.0f", stats.maxSpeedMph), label: "TOP MPH")
            Divider().frame(height: 32)
            bikeStatCell(value: String(format: "%.0f°", stats.maxLeanDeg), label: "MAX LEAN")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.appSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func bikeStatCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.appAccent)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Color.textGhost)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - BikeMaintenanceSection

/// Per-bike maintenance surface. Lives on `GarageBikeDetailScreen` and reuses
/// the shared `MaintenanceRecordRow` / `AddMaintenanceSheet` / `EditMaintenanceSheet`
/// so behavior (reminders, receipt photos, sync status) matches what the old
/// standalone Maintenance tab did.
private struct BikeMaintenanceSection: View {
    let bike: GarageBike

    @EnvironmentObject private var maintenanceStore: MaintenanceStore
    @EnvironmentObject private var garageStore: GarageStore

    @State private var showAddSheet = false
    @State private var editingRecord: MaintenanceRecord?

    private var records: [MaintenanceRecord] {
        maintenanceStore.records(forBikeID: bike.id)
            .filter { !$0.effectiveIsArchived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if records.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(records) { record in
                        MaintenanceRecordRow(
                            record: record,
                            bikeName: nil,
                            receiptURL: maintenanceStore.receiptPhotoURL(for: record),
                            onEdit: { editingRecord = record },
                            onDelete: { _ = maintenanceStore.deleteRecord(id: record.id) }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMaintenanceSheet(
                garageStore: garageStore,
                presetBikeID: bike.id,
                onSave: { record, photo in
                    _ = maintenanceStore.addRecord(record, photo: photo)
                    showAddSheet = false
                },
                onCancel: { showAddSheet = false }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
        .sheet(item: $editingRecord) { record in
            EditMaintenanceSheet(
                record: record,
                receiptURL: maintenanceStore.receiptPhotoURL(for: record),
                garageStore: garageStore
            ) { updated, photo in
                var finalRecord = updated
                if let photo,
                   let data = photo.jpegData(compressionQuality: 0.8) {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let folder = docs.appendingPathComponent("maintenance/\(record.id.uuidString)")
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try? data.write(to: folder.appendingPathComponent("receipt.jpg"), options: [.atomic])
                    finalRecord = MaintenanceRecord(
                        id: updated.id, createdAt: updated.createdAt, bikeID: updated.bikeID,
                        type: updated.type, title: updated.title, date: updated.date,
                        odometerMiles: updated.odometerMiles, notes: updated.notes,
                        reminderIntervalDays: updated.reminderIntervalDays,
                        reminderIntervalMiles: updated.reminderIntervalMiles,
                        receiptPhotoFilename: "receipt.jpg", isArchived: updated.isArchived,
                        remoteID: updated.remoteID, syncStatus: updated.syncStatus
                    )
                }
                _ = maintenanceStore.updateRecord(finalRecord)
                editingRecord = nil
            } onCancel: {
                editingRecord = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(true)
        }
    }

    private var header: some View {
        HStack {
            Text("Maintenance")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Color.textGhost)
            Spacer()
            Button {
                showAddSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Add")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appAccent.opacity(0.12))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.textGhost)
            Text("No maintenance records yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            Text("Log an oil change, tire swap, or any service to keep tabs on this bike.")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color.appSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - EditBikeSheet

/// The bike editor, moved out of `GarageBikeDetailScreen` so the detail screen
/// can be a read-first experience. Presented from the gear icon in the detail
/// header. Retains full functionality: nickname, year, catalog-backed
/// make/model, photo, and delete.
private struct EditBikeSheet: View {
    private enum PhotoPickerSource: String, Identifiable {
        case camera, library
        var id: String { rawValue }
        var uiKitSourceType: UIImagePickerController.SourceType {
            self == .camera ? .camera : .photoLibrary
        }
    }

    let bike: GarageBike
    let initialPhoto: UIImage?
    @ObservedObject var catalogService: MotorcycleCatalogService
    let onUpdate: (String, Int?, String, String) -> GarageStore.UpdateBikeResult
    let onSetPhoto: (UIImage) -> GarageStore.SetBikePhotoResult
    let onDelete: () -> GarageStore.DeleteBikeResult
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var nickname: String
    @State private var yearText: String
    @State private var selectedMake: String
    @State private var selectedModel: String
    @State private var manualMake: String
    @State private var manualModel: String
    @State private var photoImage: UIImage?
    @State private var showPhotoSourceDialog = false
    @State private var photoPickerSource: PhotoPickerSource?
    @State private var showSaveFailedAlert = false
    @State private var showPhotoSaveFailedAlert = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteFailedAlert = false
    @State private var showMakeSearch = false
    @State private var showModelSearch = false

    init(bike: GarageBike,
         initialPhoto: UIImage?,
         catalogService: MotorcycleCatalogService,
         onUpdate: @escaping (String, Int?, String, String) -> GarageStore.UpdateBikeResult,
         onSetPhoto: @escaping (UIImage) -> GarageStore.SetBikePhotoResult,
         onDelete: @escaping () -> GarageStore.DeleteBikeResult,
         onCancel: @escaping () -> Void,
         onSaved: @escaping () -> Void) {
        self.bike = bike
        self.initialPhoto = initialPhoto
        self.catalogService = catalogService
        self.onUpdate = onUpdate
        self.onSetPhoto = onSetPhoto
        self.onDelete = onDelete
        self.onCancel = onCancel
        self.onSaved = onSaved
        _nickname = State(initialValue: bike.nickname)
        _yearText = State(initialValue: bike.year.map(String.init) ?? "")
        _selectedMake = State(initialValue: bike.make)
        _selectedModel = State(initialValue: bike.model)
        _manualMake = State(initialValue: bike.make)
        _manualModel = State(initialValue: bike.model)
        _photoImage = State(initialValue: initialPhoto)
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Edit Bike",
                    onCancel: onCancel,
                    isSaveDisabled: resolvedMake.isEmpty || resolvedModel.isEmpty,
                    onSave: {
                        switch onUpdate(nickname, parsedYear, resolvedMake, resolvedModel) {
                        case .success:
                            onSaved()
                        case .notFound, .writeFailed:
                            showSaveFailedAlert = true
                        }
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        AppFieldGroup(label: "NICKNAME (OPTIONAL)") {
                            TextField("", text: $nickname,
                                      prompt: .appPrompt("e.g. Weekend Bike"))
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "YEAR (OPTIONAL)") {
                            TextField("", text: $yearText,
                                      prompt: .appPrompt("e.g. 2024"))
                                .keyboardType(.numberPad)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "MAKE") {
                            if catalogService.isLoadingMakes && catalogService.makes.isEmpty {
                                ProgressView().tint(Color.appAccent).appFieldChrome()
                            } else if catalogService.makes.isEmpty {
                                TextField("", text: $manualMake,
                                          prompt: .appPrompt("Make"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            } else {
                                CatalogPickerButton(
                                    title: "Make",
                                    selection: selectedMake.isEmpty ? "Select make" : selectedMake,
                                    hasValue: !selectedMake.isEmpty
                                ) { showMakeSearch = true }
                                .sheet(isPresented: $showMakeSearch) {
                                    CatalogSearchSheet(title: "Make", items: catalogService.makes.map(\.name)) { make in
                                        selectedMake = make
                                        manualMake = make
                                        selectedModel = ""
                                        manualModel = ""
                                        Task { await catalogService.loadModels(makeName: make, year: parsedYear) }
                                    }
                                }
                            }
                        }

                        AppFieldGroup(label: "MODEL") {
                            if selectedMake.isEmpty && catalogService.makes.isEmpty == false {
                                TextField("", text: $manualModel,
                                          prompt: .appPrompt("Model"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            } else if catalogService.isLoadingModels {
                                ProgressView().tint(Color.appAccent).appFieldChrome()
                            } else if catalogService.models.isEmpty {
                                TextField("", text: $manualModel,
                                          prompt: .appPrompt("Model"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            } else {
                                CatalogPickerButton(
                                    title: "Model",
                                    selection: selectedModel.isEmpty ? "Select model" : selectedModel,
                                    hasValue: !selectedModel.isEmpty
                                ) { showModelSearch = true }
                                .sheet(isPresented: $showModelSearch) {
                                    CatalogSearchSheet(title: "Model", items: catalogService.models.map(\.name)) { model in
                                        selectedModel = model
                                        manualModel = model
                                    }
                                }
                            }
                        }

                        Button {
                            showPhotoSourceDialog = true
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.appSurface2)
                                    .frame(height: 190)

                                if let photoImage {
                                    Image(uiImage: photoImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 190)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                } else {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo.on.rectangle")
                                            .font(.system(size: 26, weight: .semibold))
                                            .foregroundStyle(Color.appAccent)
                                        Text("Add Bike Photo")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.textPrimary)
                                        Text("Tap to upload or take photo")
                                            .font(.caption)
                                            .foregroundStyle(Color.textGhost)
                                    }
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 4)

                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete Bike")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .background(Color.red)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                }
            }
        }
        .task {
            await catalogService.loadMakesIfNeeded()
            if !selectedMake.isEmpty {
                await catalogService.loadModels(makeName: selectedMake, year: parsedYear)
            }
        }
        .onChange(of: yearText) { _, _ in
            guard !selectedMake.isEmpty else { return }
            selectedModel = ""
            manualModel = ""
            Task {
                await catalogService.loadModels(makeName: selectedMake, year: parsedYear)
            }
        }
        .confirmationDialog("Bike Photo", isPresented: $showPhotoSourceDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { photoPickerSource = .camera }
            }
            Button("Choose Photo") { photoPickerSource = .library }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $photoPickerSource) { source in
            UIKitImagePicker(sourceType: source.uiKitSourceType) { image in
                switch onSetPhoto(image) {
                case .success:
                    photoImage = image
                case .notFound, .writeFailed:
                    showPhotoSaveFailedAlert = true
                }
            }
            .ignoresSafeArea()
        }
        .alert("Could not save bike", isPresented: $showSaveFailedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please try again.")
        }
        .alert("Could not save photo", isPresented: $showPhotoSaveFailedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please try again.")
        }
        .alert("Delete \(bike.title)?", isPresented: $showDeleteConfirm) {
            Button("Delete Bike", role: .destructive) {
                switch onDelete() {
                case .success: break // parent closes via onSaved chain
                case .notFound, .deleteFailed:
                    showDeleteFailedAlert = true
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes \"\(bike.title)\" and its maintenance history. This action cannot be undone.")
        }
        .alert("Could not delete bike", isPresented: $showDeleteFailedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please try again.")
        }
    }

    private var parsedYear: Int? {
        guard let year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1900...2100).contains(year) else {
            return nil
        }
        return year
    }

    private var resolvedMake: String {
        let selected = selectedMake.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return manualMake.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedModel: String {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CatalogPickerRow: View {
    let selection: String
    let hasValue: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(selection)
                    .foregroundStyle(hasValue ? Color.textPrimary : Color.textGhost)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .appFieldChrome()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CatalogPickerButton: View {
    let title: String
    let selection: String
    let hasValue: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Text(selection)
                        .foregroundStyle(hasValue ? Color.textPrimary : Color.textGhost)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.appSurface2)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CatalogSearchSheet: View {
    let title: String
    let items: [String]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return [] }
        let q = query.lowercased()
        return items.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Text("Type to search \(title.lowercased())s")
                        .foregroundStyle(Color.textSecondary)
                        .listRowBackground(Color.clear)
                } else if filtered.isEmpty {
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(Color.textSecondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filtered, id: \.self) { item in
                        Button {
                            onSelect(item)
                            dismiss()
                        } label: {
                            Text(item)
                                .foregroundStyle(Color.textPrimary)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBg)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search \(title.lowercased())s"
            )
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
