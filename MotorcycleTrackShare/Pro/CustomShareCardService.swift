import Foundation
import SwiftUI

/// Available share card layouts. The current app renders the `.classic` layout
/// via `ShareCardView`; additional Pro layouts land here without breaking that.
enum ShareCardLayout: String, CaseIterable, Identifiable, Codable {
    case classic
    case minimalist
    case dataOverlay
    case stackedStats

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:       return "Classic"
        case .minimalist:    return "Minimalist"
        case .dataOverlay:   return "Data Overlay"
        case .stackedStats:  return "Stacked Stats"
        }
    }

    var teaser: String {
        switch self {
        case .classic:       return "The original RaceLine card."
        case .minimalist:    return "Photo forward, stats reduced to a single line."
        case .dataOverlay:   return "Full telemetry overlay with route trace."
        case .stackedStats:  return "Big-number stat blocks stacked over the photo."
        }
    }

    /// Whether the layout is fully implemented today. Foundations that are
    /// scaffolded but not yet rendered return false so the UI can label them
    /// honestly ("Preview coming soon") instead of shipping a broken card.
    var isImplemented: Bool {
        self == .classic
    }
}

/// User preferences that persist across share sessions. The current share
/// screen (`ShareCardScreen`) keeps its own transient state; this service
/// stores the durable choices so opening a new ride share picks up where the
/// last one left off.
struct ShareCardPreferences: Codable, Equatable {
    var layout: ShareCardLayout
    var showWatermark: Bool
    var accentColorHex: String?

    static let `default` = ShareCardPreferences(
        layout: .classic,
        showWatermark: true,
        accentColorHex: nil
    )
}

/// Foundation for future custom share card layouts. Persists the user's layout
/// preference, exposes the layout catalog, and reports which layouts are ready
/// to render today. The existing share flow continues to use `.classic` and is
/// untouched.
@MainActor
final class CustomShareCardService: ObservableObject {

    @Published private(set) var preferences: ShareCardPreferences

    private let defaults: UserDefaults
    private let storageKey = "raceline.shareCard.preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode(ShareCardPreferences.self, from: data) {
            self.preferences = stored
        } else {
            self.preferences = .default
        }
    }

    // MARK: - Catalog

    var availableLayouts: [ShareCardLayout] { ShareCardLayout.allCases }
    var readyLayouts: [ShareCardLayout] { availableLayouts.filter { $0.isImplemented } }
    var upcomingLayouts: [ShareCardLayout] { availableLayouts.filter { !$0.isImplemented } }

    // MARK: - Preferences

    func setLayout(_ layout: ShareCardLayout) {
        guard layout.isImplemented else { return }
        preferences.layout = layout
        persist()
    }

    func setWatermark(_ enabled: Bool) {
        preferences.showWatermark = enabled
        persist()
    }

    func setAccentColorHex(_ hex: String?) {
        preferences.accentColorHex = hex
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
