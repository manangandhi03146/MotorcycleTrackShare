import Foundation
import Network
import UIKit

// Monitors network state and drives pending-upload queue.
@MainActor
final class SyncService: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var isOnline = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.tread.network-monitor")

    private weak var rideStore: RideStore?
    private weak var garageStore: GarageStore?
    private weak var authService: AuthService?

    // MARK: - Setup

    func configure(rideStore: RideStore, garageStore: GarageStore, authService: AuthService) {
        self.rideStore    = rideStore
        self.garageStore  = garageStore
        self.authService  = authService
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let online = path.status == .satisfied
                self?.isOnline = online
                if online {
                    await self?.syncPendingIfNeeded()
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    // MARK: - Manual sync

    func syncNow() async {
        await syncPendingIfNeeded()
    }

    func forceResyncAll() async {
        guard let auth = authService, auth.isLoggedIn,
              let userID = auth.userID else { return }
        isSyncing = true
        lastSyncError = nil
        rideStore?.markAllCloudRidesPendingUpload()
        await syncAllBikes(userID: userID)
        isSyncing = false
        await syncPendingIfNeeded()
    }

    // MARK: - Bike sync

    /// Bulk-syncs every bike in one PostgREST round trip, then uploads
    /// photos concurrently. Replaces the old per-bike loop that fired
    /// one DB call per bike (N round trips) with a single upsert (1
    /// round trip regardless of N). Photo uploads still happen per
    /// item but overlap in a TaskGroup instead of serially.
    private func syncAllBikes(userID: UUID) async {
        guard let store = garageStore else { return }
        let cloudStore = CloudGarageStore()
        let bikes = store.bikes
        guard !bikes.isEmpty else { return }

        // 1. Single batched DB upsert (chunked internally at 100).
        let remoteByLocal: [UUID: UUID]
        do {
            remoteByLocal = try await cloudStore.syncBikesBulk(bikes, userID: userID)
        } catch {
            print("SyncService: bulk bike upsert failed: \(error)")
            return
        }

        // 2. Update local cloud IDs for everything the server accepted.
        for bike in bikes {
            guard let remoteID = remoteByLocal[bike.id] else { continue }
            _ = store.updateCloudInfo(id: bike.id, remoteID: remoteID,
                                      cloudPhotoPath: bike.cloudPhotoPath)
        }

        // 3. Photos in parallel — HTTPS PUTs to storage, independent
        //    of each other and independent of the DB row that already
        //    landed above. A failure here is best-effort and doesn't
        //    invalidate the sync. Resolve the file URLs on-actor
        //    first so the TaskGroup children only do networking.
        struct PhotoWork { let bikeID: UUID; let photoURL: URL }
        let photoWork: [PhotoWork] = bikes.compactMap { bike in
            guard remoteByLocal[bike.id] != nil,
                  let url = store.photoURL(for: bike) else { return nil }
            return PhotoWork(bikeID: bike.id, photoURL: url)
        }
        await withTaskGroup(of: Void.self) { group in
            for item in photoWork {
                group.addTask {
                    guard let data = try? Data(contentsOf: item.photoURL),
                          let photo = UIImage(data: data) else { return }
                    let path = cloudStore.photoStoragePath(userID: userID, bikeID: item.bikeID)
                    do {
                        try await CloudStorageService().uploadPhoto(photo, path: path, bucket: "bike-photos")
                    } catch {
                        print("SyncService: bike photo upload failed for \(item.bikeID): \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Core sync logic

    private func syncPendingIfNeeded() async {
        guard !isSyncing,
              isOnline,
              let auth = authService, auth.isLoggedIn,
              let userID = auth.userID else { return }

        isSyncing = true
        lastSyncError = nil
        defer {
            isSyncing = false
            lastSyncDate = Date()
        }

        // 1. Push any locally-recorded rides waiting to upload.
        //    DB rows go in a single batched upsert (chunked to 50);
        //    photo + telemetry uploads run concurrently after the
        //    rows have landed so slow media never blocks the row
        //    persistence.
        if let store = rideStore {
            let pending = store.pendingUploadRides + store.failedSyncRides
            if !pending.isEmpty {
                await syncPendingRides(pending, userID: userID, store: store)
            }
        }

        // 2. Pull any rides from the cloud that don't exist locally
        //    (e.g. recorded on another device with the same account).
        await pullRemoteRides(userID: userID)
    }

    // MARK: - Pull from cloud

    /// Fetches every ride summary from Supabase for the signed-in user and
    /// creates a local mirror for anything missing on disk. Photos and full
    /// telemetry files are downloaded so the ride works offline afterwards.
    private func pullRemoteRides(userID: UUID) async {
        guard let store = rideStore else { return }
        let cloud = CloudRideStore()

        let remotes: [CloudRideSummary]
        do {
            remotes = try await cloud.fetchRideSummaries(userID: userID)
        } catch {
            print("SyncService: failed to fetch remote rides: \(error)")
            return
        }

        let localIDs = Set(store.rides.map { $0.id })

        for remote in remotes {
            guard let candidateID = remote.localId, !localIDs.contains(candidateID) else { continue }

            var photoData: Data? = nil
            if remote.hasPhoto, let path = remote.photoPath {
                do {
                    let image = try await cloud.downloadPhoto(path: path)
                    photoData = image.jpegData(compressionQuality: 0.9)
                } catch {
                    print("SyncService: photo download failed for \(remote.id): \(error)")
                }
            }

            var telemetryData: Data? = nil
            if remote.hasFullTelemetry {
                let path = cloud.telemetryStoragePath(userID: userID, rideID: candidateID)
                do {
                    telemetryData = try await cloud.downloadTelemetry(path: path)
                } catch {
                    print("SyncService: telemetry download failed for \(remote.id): \(error)")
                }
            }

            store.ingestRemote(remote, photoData: photoData, telemetryData: telemetryData)
        }
    }

    /// Bulk-syncs a batch of rides: one batched DB upsert for the
    /// rows, then per-ride photo + telemetry uploads concurrently.
    /// Errors on the DB batch flag every ride in the batch as failed.
    /// Media failures are best-effort — the DB row is the canonical
    /// sync event (matches the original per-ride semantics).
    private func syncPendingRides(_ rides: [SavedRide],
                                  userID: UUID,
                                  store: RideStore) async {
        let cloudStore = CloudRideStore()

        // 1. One batched upsert (chunked at 50 rows internally).
        let remoteByLocal: [UUID: UUID]
        do {
            remoteByLocal = try await cloudStore.syncRidesBulk(rides, userID: userID)
        } catch {
            for ride in rides { _ = store.markSyncFailed(id: ride.id) }
            lastSyncError = Self.friendlyMessage(for: error)
            print("SyncService: bulk ride upsert failed: \(error)")
            return
        }

        // 2. Any rides the server didn't return get flagged as failed
        //    so the next sync tick will retry them individually.
        for ride in rides where remoteByLocal[ride.id] == nil {
            _ = store.markSyncFailed(id: ride.id)
        }

        // 3. Media uploads in parallel per ride. Each ride's photo and
        //    telemetry upload are independent HTTPS calls; a slow
        //    upload for one ride doesn't stall the others.
        //
        //    We resolve the local file URLs up here on the MainActor
        //    (RideStore is @MainActor) so the TaskGroup children only
        //    do networking — they don't call back into store from a
        //    background executor.
        struct MediaWork {
            let rideID: UUID
            let photoURL: URL?
            let telemetryURL: URL?
        }
        let work: [MediaWork] = rides.compactMap { ride in
            guard remoteByLocal[ride.id] != nil else { return nil }
            return MediaWork(
                rideID: ride.id,
                photoURL: store.photoURL(for: ride),
                telemetryURL: ride.effectiveStorageMode.uploadsFullTelemetry
                    ? store.telemetryURL(for: ride)
                    : nil
            )
        }

        await withTaskGroup(of: (UUID, String?, String?).self) { group in
            for item in work {
                group.addTask {
                    var photoPath: String? = nil
                    var telemetryPath: String? = nil

                    if let photoURL = item.photoURL,
                       let data = try? Data(contentsOf: photoURL),
                       let image = UIImage(data: data) {
                        let path = cloudStore.photoStoragePath(userID: userID, rideID: item.rideID)
                        do {
                            try await CloudStorageService().uploadPhoto(
                                image, path: path, bucket: "ride-photos"
                            )
                            photoPath = path
                        } catch {
                            print("SyncService: photo upload failed for ride \(item.rideID): \(error)")
                        }
                    }

                    if let telemetryURL = item.telemetryURL {
                        let path = cloudStore.telemetryStoragePath(userID: userID, rideID: item.rideID)
                        do {
                            try await cloudStore.uploadTelemetry(fileURL: telemetryURL, path: path)
                            telemetryPath = path
                        } catch {
                            print("SyncService: telemetry upload failed for ride \(item.rideID): \(error)")
                        }
                    }

                    return (item.rideID, photoPath, telemetryPath)
                }
            }

            for await (rideID, photoPath, telemetryPath) in group {
                guard let remoteID = remoteByLocal[rideID] else { continue }
                store.updateCloudInfo(id: rideID, remoteID: remoteID,
                                      cloudPhotoPath: photoPath,
                                      cloudTelemetryPath: telemetryPath)
            }
        }
    }

    private func syncRide(_ ride: SavedRide, userID: UUID) async {
        guard let store = rideStore else { return }

        // Get photo if available
        let photo: UIImage?
        if let photoURL = store.photoURL(for: ride),
           let data = try? Data(contentsOf: photoURL) {
            photo = UIImage(data: data)
        } else {
            photo = nil
        }

        do {
            let cloudStore = CloudRideStore()
            // Canonical sync = the row upsert. If this succeeds the ride is
            // considered synced; photo/telemetry are best-effort follow-ups.
            let remoteID = try await cloudStore.syncRide(ride, userID: userID, photo: photo)

            var telemetryPath: String? = nil
            if ride.effectiveStorageMode.uploadsFullTelemetry,
               let telemetryURL = store.telemetryURL(for: ride) {
                let path = cloudStore.telemetryStoragePath(userID: userID, rideID: ride.id)
                do {
                    try await cloudStore.uploadTelemetry(fileURL: telemetryURL, path: path)
                    telemetryPath = path
                } catch {
                    // Don't mark the ride as failed — the summary row is in the cloud.
                    print("SyncService: telemetry upload failed for ride \(ride.id): \(error)")
                }
            }

            let photoPath = photo != nil ? cloudStore.photoStoragePath(userID: userID, rideID: ride.id) : nil
            store.updateCloudInfo(id: ride.id, remoteID: remoteID,
                                  cloudPhotoPath: photoPath,
                                  cloudTelemetryPath: telemetryPath)
        } catch {
            store.markSyncFailed(id: ride.id)
            lastSyncError = Self.friendlyMessage(for: error)
            print("SyncService: failed to sync ride \(ride.id): \(error)")
        }
    }

    // MARK: - Error formatting

    private static func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        if let range = raw.range(of: "Ride limit reached", options: .caseInsensitive) {
            return String(raw[range.lowerBound...])
        }
        return "Some rides failed to sync. Tap Retry to try again."
    }
}
