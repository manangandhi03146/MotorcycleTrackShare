import Foundation

/// User-visible state of the cloud backup pipeline. The Settings UI mirrors this.
///
/// Note: rides and bikes already sync today via `SyncService` + `CloudRideStore`
/// + `CloudGarageStore`, with a 10-ride free cap enforced server-side. This
/// enum reflects that reality and reserves the Pro upgrade for lifting the cap
/// and adding coverage for maintenance + settings.
enum CloudBackupStatus: Equatable {
    case active(coverage: Set<CloudBackupDomain>, freeRideCap: Int?)
    case paused
    case failed(reason: String)

    var displayName: String {
        switch self {
        case .active:  return "Active"
        case .paused:  return "Paused"
        case .failed:  return "Attention needed"
        }
    }
}

/// The discrete data domains the backup covers. Kept explicit so partial
/// coverage (e.g. rides only) can be represented honestly.
enum CloudBackupDomain: String, CaseIterable, Codable {
    case rides
    case bikes
    case maintenance
    case settings
}

/// Foundation for full-fidelity cloud backup. Today this reports status only —
/// actual per-domain uploads are handled by the existing `SyncService`,
/// `CloudRideStore`, and `CloudGarageStore`. This service exists so future work
/// (versioning, restore-from-cloud, per-domain toggles) has a single seam.
@MainActor
final class CloudBackupService: ObservableObject {

    /// Server-side cap on how many rides a free account can keep in the cloud.
    /// Enforced by a Supabase trigger; mirrored here for UI copy.
    static let freeRideCap: Int = 10

    /// Which domains currently sync end-to-end for free users. Rides and bikes
    /// are already live via the existing sync stack; maintenance + settings
    /// stay pending until Pro lands.
    static let coveredDomainsForFree: Set<CloudBackupDomain> = [.rides, .bikes]

    @Published private(set) var status: CloudBackupStatus = .active(
        coverage: CloudBackupService.coveredDomainsForFree,
        freeRideCap: CloudBackupService.freeRideCap
    )
    @Published private(set) var lastAttemptedAt: Date?

    // MARK: - Status control

    func markPaused() {
        status = .paused
    }

    func markResumed() {
        status = .active(coverage: Self.coveredDomainsForFree,
                         freeRideCap: Self.freeRideCap)
    }

    /// Called by higher-level sync code when a run finishes. Kept generic so
    /// the actual sync engine can live elsewhere without depending on us.
    func recordAttempt(succeeded: Bool, reason: String? = nil) {
        lastAttemptedAt = Date()
        if succeeded {
            status = .active(coverage: Self.coveredDomainsForFree,
                             freeRideCap: Self.freeRideCap)
        } else if let reason {
            status = .failed(reason: reason)
        }
    }

    // TODO: Once Pro is live, drop `freeRideCap` on entitled accounts, expand
    //       covered domains to include maintenance + settings, and add
    //       versioned restore flows here.
}
