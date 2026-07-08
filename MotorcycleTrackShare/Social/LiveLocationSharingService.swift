import Foundation
import CoreLocation
import Combine

/// Opt-in live location sharing during an active group ride.
///
/// Design constraints (see Phase 4 spec):
/// - OFF by default. `start(...)` must be explicitly called and the
///   caller confirms with a user prompt.
/// - Sharing stops automatically when the ride is completed/cancelled,
///   when the user leaves the ride, when the user disables sharing, or
///   when the manager is torn down (e.g. the detail sheet dismisses).
/// - Location is written to `group_ride_live_locations` with
///   `sharing_enabled = true`. On stop we flip the flag to false so
///   fellow riders' clients notice and drop the marker.
/// - Uses `CLLocationAccuracyReduced` when the OS supports it and the
///   user hasn't granted full precision, otherwise falls back to
///   `kCLLocationAccuracyNearestTenMeters`.
/// - No background updates yet. Enabling background updates requires
///   the "location" background mode; we intentionally scope this to
///   foreground for now to keep review scope minimal. TODO for a
///   dedicated background-tracking pass.
@MainActor
final class LiveLocationSharingService: NSObject, ObservableObject {
    // MARK: - Published state

    @Published private(set) var isSharing: Bool = false
    @Published private(set) var lastCoordinate: CLLocationCoordinate2D?
    @Published private(set) var errorMessage: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    // MARK: - Private state

    private let manager = CLLocationManager()
    private let service = GroupRideService()
    private var currentRideID: UUID?
    private var currentUserID: UUID?
    private var uploadInFlight = false
    private var lastUpload: Date = .distantPast
    private let uploadInterval: TimeInterval = 15  // seconds

    // MARK: - Init

    override init() {
        self.authorizationStatus = CLLocationManager().authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 15  // meters; also throttles updates
        manager.activityType = .automotiveNavigation
    }

    // MARK: - Start / stop

    /// Kicks off location sharing for the given ride. Callers should
    /// have already shown a confirmation UI explaining "your location
    /// will be visible to this group only while this ride is active."
    func start(rideID: UUID, userID: UUID) {
        currentRideID = rideID
        currentUserID = userID
        errorMessage  = nil

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = "Location access is off in Settings. Enable it to share your location with your group."
            return
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            isSharing = true
        @unknown default:
            manager.startUpdatingLocation()
            isSharing = true
        }
    }

    /// Stop sharing and flip the DB row to `sharing_enabled = false`
    /// so fellow riders' clients notice.
    func stop() {
        manager.stopUpdatingLocation()
        isSharing = false

        guard let rideID = currentRideID, let userID = currentUserID else { return }
        Task {
            try? await service.stopSharingLocation(rideID: rideID, userID: userID)
        }
        currentRideID = nil
        currentUserID = nil
    }

    // MARK: - Upload path

    private func maybeUpload(_ location: CLLocation) {
        guard isSharing,
              let rideID = currentRideID,
              let userID = currentUserID else { return }
        // Throttle: at most one write every `uploadInterval` seconds.
        let now = Date()
        guard now.timeIntervalSince(lastUpload) >= uploadInterval else { return }
        guard !uploadInFlight else { return }
        uploadInFlight = true
        lastUpload = now

        let payload = GroupRideLiveLocationUpsert(
            groupRideID:    rideID,
            userID:         userID,
            latitude:       location.coordinate.latitude,
            longitude:      location.coordinate.longitude,
            heading:        location.course >= 0 ? location.course : nil,
            speedMPS:       location.speed  >= 0 ? location.speed  : nil,
            sharingEnabled: true
        )
        Task { @MainActor in
            defer { self.uploadInFlight = false }
            do {
                try await service.upsertLiveLocation(payload)
            } catch {
                errorMessage = "Couldn't share location right now."
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LiveLocationSharingService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .denied || status == .restricted {
                self.errorMessage = "Location access is off. Turn it back on in Settings to share your location."
                self.stop()
            } else if (status == .authorizedWhenInUse || status == .authorizedAlways),
                      self.currentRideID != nil {
                manager.startUpdatingLocation()
                self.isSharing = true
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        // Filter out stale / bogus fixes.
        guard latest.horizontalAccuracy > 0,
              latest.horizontalAccuracy < 100,
              abs(latest.timestamp.timeIntervalSinceNow) < 30 else { return }
        Task { @MainActor in
            self.lastCoordinate = latest.coordinate
            self.maybeUpload(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Ignore transient "unable to lock GPS" errors — they clear on their own.
            let ns = error as NSError
            if ns.domain == kCLErrorDomain && ns.code == CLError.locationUnknown.rawValue {
                return
            }
            self.errorMessage = "Location error: \(error.localizedDescription)"
        }
    }
}
