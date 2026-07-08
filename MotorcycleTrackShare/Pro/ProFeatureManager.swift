import Foundation

/// Discrete features that will be gated by the future RaceLine Pro subscription.
/// New features can be added here without touching call sites.
enum ProFeature: String, CaseIterable {
    case unlimitedBikes
    case unlimitedGroups
    case advancedAnalytics
    case aiRideSummary
    case cloudBackup
    case customShareCards
    case exportData

    var displayName: String {
        switch self {
        case .unlimitedBikes:    return "Unlimited Bikes"
        case .unlimitedGroups:   return "Unlimited Group Ownership"
        case .advancedAnalytics: return "Advanced Analytics"
        case .aiRideSummary:     return "AI Ride Summaries"
        case .cloudBackup:       return "Unlimited Cloud Rides"
        case .customShareCards:  return "Custom Share Cards"
        case .exportData:        return "Export Data"
        }
    }

    var teaser: String {
        switch self {
        case .unlimitedBikes:    return "Track every bike in your stable — no cap."
        case .unlimitedGroups:   return "Own more than 5 crews — no cap on groups you create."
        case .advancedAnalytics: return "Deeper stats, smoothness scoring, and hard-event breakdowns."
        case .aiRideSummary:     return "A rider-friendly recap of every ride, generated automatically."
        case .cloudBackup:       return "Sync every ride to the cloud without the 10-ride free cap."
        case .customShareCards:  return "Custom layouts, colors, and watermark-free share cards."
        case .exportData:        return "Export any ride to CSV, GPX, or JSON for external tools."
        }
    }
}

/// The user's subscription tier. Kept explicit and enumerable so future flows
/// (trials, promo codes, family sharing) can be added without ambiguity.
enum ProTier: String, Codable {
    case free
    case pro
}

/// Central authority for feature access and free-tier limits.
///
/// This is intentionally decoupled from any payment SDK. When StoreKit is added
/// later, the entry point will be `applyEntitlement(_:)` — no call site needs to
/// change.
@MainActor
final class ProFeatureManager: ObservableObject {
    /// Free tier bike ceiling. Applied everywhere the app checks bike limits.
    static let freeBikeLimit: Int = 2

    /// Free tier cap on groups a user can OWN (not join). Joining other
    /// groups is unlimited on all tiers.
    static let freeGroupLimit: Int = 5

    /// During Phase 2 development every feature is exposed to free users so the
    /// app remains fully usable while payment infrastructure lands later.
    private static let phaseTwoExposedToFree: Set<ProFeature> = [
        .advancedAnalytics,
        .aiRideSummary,
        .exportData,
        .customShareCards,
        .cloudBackup,
    ]

    @Published private(set) var tier: ProTier

    init(tier: ProTier = .free) {
        self.tier = tier
    }

    // MARK: - Access checks

    var isPro: Bool { tier == .pro }

    /// Whether the given feature is currently available to the user.
    /// Phase 2 keeps most features unlocked for free during rollout; the
    /// bike limit is the one hard cap enforced today.
    func hasAccess(to feature: ProFeature) -> Bool {
        if isPro { return true }
        return Self.phaseTwoExposedToFree.contains(feature)
    }

    /// The free-tier bike cap, or nil if unlimited.
    func bikeLimit() -> Int? {
        isPro ? nil : Self.freeBikeLimit
    }

    /// Whether the user can add another bike given how many they already have.
    func canAddBike(currentCount: Int) -> Bool {
        guard let limit = bikeLimit() else { return true }
        return currentCount < limit
    }

    /// The free-tier group ownership cap, or nil if unlimited.
    func groupLimit() -> Int? {
        isPro ? nil : Self.freeGroupLimit
    }

    /// Whether the user can create another group given how many they already own.
    func canCreateGroup(currentOwnedCount: Int) -> Bool {
        guard let limit = groupLimit() else { return true }
        return currentOwnedCount < limit
    }

    // MARK: - Entitlement mutation (future StoreKit hook)

    /// Called by the future subscription layer when the user's entitlement
    /// changes. No StoreKit code lives here yet — this is the seam.
    func applyEntitlement(_ tier: ProTier) {
        guard tier != self.tier else { return }
        self.tier = tier
    }
}
