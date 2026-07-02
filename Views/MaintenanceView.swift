import SwiftUI
import UIKit

// Maintenance was previously a top-level tab; it now lives inside each bike's
// detail screen (see `BikeMaintenanceSection` in GarageView). The reusable
// pieces below — MaintenanceRecordRow, AddMaintenanceSheet, EditMaintenanceSheet —
// stay here so they can be shared across the app.

// MARK: - Record Row

struct MaintenanceRecordRow: View {
    let record: MaintenanceRecord
    let bikeName: String?
    let receiptURL: URL?
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    private var isDue: Bool { record.isDateReminderDue() }

    private var dueBadge: String? {
        if let miles = record.reminderIntervalMiles {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            let formatted = formatter.string(from: miles as NSNumber) ?? "\(Int(miles))"
            return "Every \(formatted) mi"
        }
        guard let days = record.daysTilDue() else { return nil }
        if days < 0 { return "Overdue" }
        if days == 0 { return "Due today" }
        return "Due in \(days)d"
    }

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(isDue ? Color.orange.opacity(0.18) : Color.appSurface2)
                        .frame(width: 44, height: 44)
                    Image(systemName: record.type.iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isDue ? .orange : Color.appAccent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if let badge = dueBadge {
                            Text(badge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isDue ? .white : Color.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isDue ? Color.red : Color.orange.opacity(0.18))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        Text(formattedDate(record.date))
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                        if let bike = bikeName {
                            Text("·")
                                .foregroundStyle(Color.textGhost)
                            Text(bike)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                        if let odometer = record.odometerMiles {
                            Text("·")
                                .foregroundStyle(Color.textGhost)
                            Text(String(format: "%.0f mi", odometer))
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    if let notes = record.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { onEdit() }
            Button("Delete", role: .destructive) { showDeleteConfirm = true }
        }
        .confirmationDialog("Delete \(record.title)?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Record", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the \"\(record.title)\" record and its receipt photo. This can't be undone.")
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Add Sheet

struct AddMaintenanceSheet: View {
    @ObservedObject var garageStore: GarageStore
    /// When non-nil, the sheet is scoped to this bike: the bike picker is
    /// hidden and every new record is attached to this bikeID. Used from
    /// `GarageBikeDetailScreen` where the bike context is already known.
    let presetBikeID: UUID?
    let onSave: (MaintenanceRecord, UIImage?) -> Void
    let onCancel: () -> Void

    @State private var type: MaintenanceType = .oilChange
    @State private var title = ""
    @State private var date = Date()
    @State private var selectedBikeID: UUID?
    @State private var odometerText = ""
    @State private var notes = ""
    @State private var reminderMiles: Double? = nil
    @State private var receiptPhoto: UIImage?
    @State private var showPhotoDialog = false
    @State private var photoSource: PhotoPickerSource?
    @State private var showTypeDialog = false
    @State private var showBikeDialog = false
    @State private var showReminderDialog = false

    init(garageStore: GarageStore,
         presetBikeID: UUID? = nil,
         onSave: @escaping (MaintenanceRecord, UIImage?) -> Void,
         onCancel: @escaping () -> Void) {
        self.garageStore = garageStore
        self.presetBikeID = presetBikeID
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedBikeID = State(initialValue: presetBikeID)
    }

    private enum PhotoPickerSource: String, Identifiable {
        case camera, library
        var id: String { rawValue }
        var sourceType: UIImagePickerController.SourceType {
            self == .camera ? .camera : .photoLibrary
        }
    }

    private let reminderOptions: [(label: String, miles: Double?)] = [
        ("No reminder", nil),
        ("Every 500 mi", 500),
        ("Every 1,000 mi", 1_000),
        ("Every 2,000 mi", 2_000),
        ("Every 3,000 mi", 3_000),
        ("Every 5,000 mi", 5_000),
        ("Every 10,000 mi", 10_000)
    ]

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Log Maintenance",
                    onCancel: onCancel,
                    isSaveDisabled: type == .custom && title.trimmingCharacters(in: .whitespaces).isEmpty,
                    onSave: {
                        let finalTitle: String
                        if type == .custom {
                            let trimmed = title.trimmingCharacters(in: .whitespaces)
                            finalTitle = trimmed.isEmpty ? "Custom" : trimmed
                        } else {
                            finalTitle = type.displayName
                        }
                        let record = MaintenanceRecord(
                            bikeID: selectedBikeID,
                            type: type,
                            title: finalTitle,
                            date: date,
                            odometerMiles: Double(odometerText),
                            notes: notes.isEmpty ? nil : notes,
                            reminderIntervalDays: nil,
                            reminderIntervalMiles: reminderMiles
                        )
                        onSave(record, receiptPhoto)
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        AppFieldGroup(label: "TYPE") {
                            DropdownFieldButton(
                                selectionText: type.displayName,
                                leadingIcon: type.iconName
                            ) { showTypeDialog = true }
                        }

                        if type == .custom {
                            AppFieldGroup(label: "TITLE") {
                                TextField("", text: $title, prompt: .appPrompt("Title"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            }
                        }

                        AppFieldGroup(label: "DATE") {
                            DatePicker("", selection: $date, displayedComponents: [.date])
                                .labelsHidden()
                                .tint(Color.appAccent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .appFieldChrome()
                        }

                        // Bike picker is only rendered when the caller hasn't
                        // pre-scoped the sheet to a specific bike.
                        if presetBikeID == nil, !garageStore.bikes.isEmpty {
                            AppFieldGroup(label: "BIKE") {
                                DropdownFieldButton(
                                    selectionText: selectedBikeLabel
                                ) { showBikeDialog = true }
                            }
                        }

                        AppFieldGroup(label: "ODOMETER (OPTIONAL)") {
                            TextField("", text: $odometerText,
                                      prompt: Text("Miles at service").foregroundColor(Color.textGhost))
                                .keyboardType(.decimalPad)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "NOTES (OPTIONAL)") {
                            TextField("", text: $notes, axis: .vertical)
                                .lineLimit(3, reservesSpace: true)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "REMINDER") {
                            DropdownFieldButton(
                                selectionText: selectedReminderLabel
                            ) { showReminderDialog = true }
                        }

                        AppFieldGroup(label: "RECEIPT PHOTO (OPTIONAL)") {
                            Button { showPhotoDialog = true } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.appSurface2)
                                        .frame(height: 110)
                                    if let receiptPhoto {
                                        Image(uiImage: receiptPhoto)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 110)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "doc.text.viewfinder")
                                                .font(.system(size: 22, weight: .semibold))
                                                .foregroundStyle(Color.appAccent)
                                            Text("Add Receipt Photo")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Color.textPrimary)
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
        .onChange(of: type) { _, newType in
            if title.isEmpty || MaintenanceType.allCases.map(\.displayName).contains(title) {
                title = newType.displayName
            }
        }
        .onAppear { if title.isEmpty { title = type.displayName } }
        .confirmationDialog("Receipt Photo", isPresented: $showPhotoDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { photoSource = .camera }
            }
            Button("Choose from Library") { photoSource = .library }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Maintenance Type", isPresented: $showTypeDialog, titleVisibility: .visible) {
            ForEach(MaintenanceType.allCases, id: \.self) { t in
                Button(t.displayName) { type = t }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Bike", isPresented: $showBikeDialog, titleVisibility: .visible) {
            Button("No specific bike") { selectedBikeID = nil }
            ForEach(garageStore.bikes.filter { !$0.effectiveIsArchived }) { bike in
                Button(bike.title) { selectedBikeID = bike.id }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Reminder", isPresented: $showReminderDialog, titleVisibility: .visible) {
            ForEach(reminderOptions.indices, id: \.self) { i in
                Button(reminderOptions[i].label) { reminderMiles = reminderOptions[i].miles }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $photoSource) { src in
            UIKitImagePicker(sourceType: src.sourceType) { receiptPhoto = $0 }
                .ignoresSafeArea()
        }
    }

    private var selectedReminderLabel: String {
        reminderOptions.first(where: { $0.miles == reminderMiles })?.label ?? "No reminder"
    }

    private var selectedBikeLabel: String {
        guard let id = selectedBikeID,
              let bike = garageStore.bikes.first(where: { $0.id == id }) else {
            return "No specific bike"
        }
        return bike.title
    }
}

// MARK: - Edit Sheet

struct EditMaintenanceSheet: View {
    let record: MaintenanceRecord
    let receiptURL: URL?
    @ObservedObject var garageStore: GarageStore
    let onSave: (MaintenanceRecord, UIImage?) -> Void
    let onCancel: () -> Void

    @State private var type: MaintenanceType
    @State private var title: String
    @State private var date: Date
    @State private var selectedBikeID: UUID?
    @State private var odometerText: String
    @State private var notes: String
    @State private var reminderMiles: Double?
    @State private var receiptPhoto: UIImage?
    @State private var showPhotoDialog = false
    @State private var showTypeDialog = false
    @State private var showBikeDialog = false
    @State private var showReminderDialog = false
    @State private var photoSource: PhotoPickerSource?

    private enum PhotoPickerSource: String, Identifiable {
        case camera, library
        var id: String { rawValue }
        var sourceType: UIImagePickerController.SourceType {
            self == .camera ? .camera : .photoLibrary
        }
    }

    private let reminderOptions: [(label: String, miles: Double?)] = [
        ("No reminder", nil),
        ("Every 500 mi", 500),
        ("Every 1,000 mi", 1_000),
        ("Every 2,000 mi", 2_000),
        ("Every 3,000 mi", 3_000),
        ("Every 5,000 mi", 5_000),
        ("Every 10,000 mi", 10_000)
    ]

    init(record: MaintenanceRecord, receiptURL: URL?, garageStore: GarageStore,
         onSave: @escaping (MaintenanceRecord, UIImage?) -> Void,
         onCancel: @escaping () -> Void) {
        self.record = record
        self.receiptURL = receiptURL
        self.garageStore = garageStore
        self.onSave = onSave
        self.onCancel = onCancel
        _type = State(initialValue: record.type)
        _title = State(initialValue: record.title)
        _date = State(initialValue: record.date)
        _selectedBikeID = State(initialValue: record.bikeID)
        _odometerText = State(initialValue: record.odometerMiles.map { String(format: "%.0f", $0) } ?? "")
        _notes = State(initialValue: record.notes ?? "")
        _reminderMiles = State(initialValue: record.reminderIntervalMiles)
    }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                AppSheetHeader(
                    title: "Edit Record",
                    onCancel: onCancel,
                    isSaveDisabled: type == .custom && title.trimmingCharacters(in: .whitespaces).isEmpty,
                    onSave: {
                        let finalTitle: String
                        if type == .custom {
                            let trimmed = title.trimmingCharacters(in: .whitespaces)
                            finalTitle = trimmed.isEmpty ? "Custom" : trimmed
                        } else {
                            finalTitle = type.displayName
                        }
                        let updated = MaintenanceRecord(
                            id: record.id, createdAt: record.createdAt,
                            bikeID: selectedBikeID, type: type,
                            title: finalTitle,
                            date: date,
                            odometerMiles: Double(odometerText),
                            notes: notes.isEmpty ? nil : notes,
                            reminderIntervalDays: nil,
                            reminderIntervalMiles: reminderMiles,
                            receiptPhotoFilename: record.receiptPhotoFilename,
                            isArchived: record.isArchived,
                            remoteID: record.remoteID, syncStatus: record.syncStatus
                        )
                        onSave(updated, receiptPhoto)
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        AppFieldGroup(label: "TYPE") {
                            DropdownFieldButton(
                                selectionText: type.displayName,
                                leadingIcon: type.iconName
                            ) { showTypeDialog = true }
                        }

                        if type == .custom {
                            AppFieldGroup(label: "TITLE") {
                                TextField("", text: $title, prompt: .appPrompt("Title"))
                                    .foregroundStyle(Color.textPrimary)
                                    .appFieldChrome()
                            }
                        }

                        AppFieldGroup(label: "DATE") {
                            DatePicker("", selection: $date, displayedComponents: [.date])
                                .labelsHidden()
                                .tint(Color.appAccent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .appFieldChrome()
                        }

                        if !garageStore.bikes.isEmpty {
                            AppFieldGroup(label: "BIKE") {
                                DropdownFieldButton(
                                    selectionText: selectedBikeLabel
                                ) { showBikeDialog = true }
                            }
                        }

                        AppFieldGroup(label: "ODOMETER (OPTIONAL)") {
                            TextField("", text: $odometerText, prompt: .appPrompt("Miles at service"))
                                .keyboardType(.decimalPad)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "NOTES (OPTIONAL)") {
                            TextField("", text: $notes, axis: .vertical)
                                .lineLimit(3, reservesSpace: true)
                                .foregroundStyle(Color.textPrimary)
                                .appFieldChrome()
                        }

                        AppFieldGroup(label: "REMINDER") {
                            DropdownFieldButton(
                                selectionText: selectedReminderLabel
                            ) { showReminderDialog = true }
                        }

                        AppFieldGroup(label: "RECEIPT PHOTO (OPTIONAL)") {
                            Button { showPhotoDialog = true } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.appSurface2)
                                        .frame(height: 110)
                                    if let img = receiptPhoto {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 110)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else if let url = receiptURL,
                                              let data = try? Data(contentsOf: url),
                                              let img = UIImage(data: data) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 110)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "doc.text.viewfinder")
                                                .font(.system(size: 22, weight: .semibold))
                                                .foregroundStyle(Color.appAccent)
                                            Text("Replace Receipt Photo")
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Color.textPrimary)
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
        .confirmationDialog("Receipt Photo", isPresented: $showPhotoDialog, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { photoSource = .camera }
            }
            Button("Choose from Library") { photoSource = .library }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Maintenance Type", isPresented: $showTypeDialog, titleVisibility: .visible) {
            ForEach(MaintenanceType.allCases, id: \.self) { t in
                Button(t.displayName) { type = t }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Bike", isPresented: $showBikeDialog, titleVisibility: .visible) {
            Button("No specific bike") { selectedBikeID = nil }
            ForEach(garageStore.bikes.filter { !$0.effectiveIsArchived }) { bike in
                Button(bike.title) { selectedBikeID = bike.id }
            }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog("Reminder", isPresented: $showReminderDialog, titleVisibility: .visible) {
            ForEach(reminderOptions.indices, id: \.self) { i in
                Button(reminderOptions[i].label) { reminderMiles = reminderOptions[i].miles }
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $photoSource) { src in
            UIKitImagePicker(sourceType: src.sourceType) { receiptPhoto = $0 }
                .ignoresSafeArea()
        }
    }

    private var selectedReminderLabel: String {
        reminderOptions.first(where: { $0.miles == reminderMiles })?.label ?? "No reminder"
    }

    private var selectedBikeLabel: String {
        guard let id = selectedBikeID,
              let bike = garageStore.bikes.first(where: { $0.id == id }) else {
            return "No specific bike"
        }
        return bike.title
    }
}


// MARK: - DropdownFieldButton

/// Button-based dropdown that visually matches the field chrome used elsewhere
/// in this app. Kept intentionally as a `Button` (not a `Menu`) because in
/// iOS 26 SwiftUI `Menu` gestures inside nested sheets are held by the sheet's
/// drag-to-dismiss arbitration and require a second tap. Buttons never hit
/// this gate — pair with `.confirmationDialog(_:isPresented:)` at the call site.
struct DropdownFieldButton: View {
    let selectionText: String
    var leadingIcon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
                Text(selectionText)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            .appFieldChrome()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
