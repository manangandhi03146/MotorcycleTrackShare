import SwiftUI
import MapKit

/// Detail view for a single `shared_routes` row. Renders title, author info,
/// distance, visibility, and the sanitized route polyline on a map. Reached
/// from feed rows of kind `.sharedRoutePosted`.
struct SharedRouteDetailView: View {
    let routeID: UUID

    @EnvironmentObject private var authService: AuthService

    @State private var route: SharedRoute?
    @State private var author: SocialProfile?
    @State private var loading = true
    @State private var errorMessage: String?

    private let routeService = SharedRouteService()
    private let profileService = SocialProfileService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading {
                    LoadingBlock(message: "Loading route…").padding(.top, 40)
                } else if let route {
                    hero(route: route)
                    if !route.routePoints.isEmpty {
                        mapCard(points: route.routePoints)
                    } else {
                        emptyRouteCard
                    }
                    metaCard(route: route)
                } else if let errorMessage {
                    ErrorBlock(message: errorMessage) { Task { await load() } }
                } else {
                    EmptyStateView(
                        icon: "map",
                        title: "Route not available",
                        message: "It may have been deleted or the owner made it private."
                    )
                }
            }
            .padding(20)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle("Shared Ride")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appSurface, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await load() }
    }

    // MARK: - Cards

    private func hero(route: SharedRoute) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .foregroundStyle(Color.appAccent)
                Text("SHARED RIDE")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Color.appAccent)
            }
            Text(route.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            if let desc = route.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            authorRow
        }
        .minimalCard()
    }

    private var authorRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.appAccent.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(authorDisplayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                if let route {
                    Text(route.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Color.textGhost)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var authorDisplayName: String {
        if let author {
            if let name = author.displayName, !name.isEmpty { return name }
            if let name = author.username, !name.isEmpty     { return "@\(name)" }
        }
        return "A rider"
    }

    private func mapCard(points: [SharedRoutePoint]) -> some View {
        let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return VStack(alignment: .leading, spacing: 10) {
            Map(initialPosition: .region(regionFitting(points: points))) {
                MapPolyline(coordinates: coords)
                    .stroke(Color.appAccent, lineWidth: 4)
                if let first = coords.first {
                    Marker("Start", coordinate: first).tint(.green)
                }
                if let last = coords.last, coords.count > 1 {
                    Marker("End", coordinate: last).tint(.orange)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .minimalCard()
    }

    private var emptyRouteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Route data not available")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("The author may have trimmed or hidden every point for privacy.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .minimalCard()
    }

    private func metaCard(route: SharedRoute) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metaRow(label: "Distance", value: String(format: "%.1f mi", route.distanceMeters / 1609.344))
            metaRow(label: "Points shared", value: "\(route.routePoints.count)")
            metaRow(label: "Visibility", value: route.visibility.displayName)
            if route.hideStart || route.hideEnd || route.trimPoints > 0 {
                metaRow(label: "Privacy trim",
                        value: privacyTrimSummary(route: route))
            }
        }
        .minimalCard()
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
        }
    }

    private func privacyTrimSummary(route: SharedRoute) -> String {
        var parts: [String] = []
        if route.hideStart { parts.append("start hidden") }
        if route.hideEnd   { parts.append("end hidden") }
        if route.trimPoints > 0 { parts.append("−\(route.trimPoints) pts each end") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Geometry

    private func regionFitting(points: [SharedRoutePoint]) -> MKCoordinateRegion {
        guard !points.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }
        var minLat = points[0].lat, maxLat = points[0].lat
        var minLon = points[0].lon, maxLon = points[0].lon
        for p in points {
            if p.lat < minLat { minLat = p.lat }
            if p.lat > maxLat { maxLat = p.lat }
            if p.lon < minLon { minLon = p.lon }
            if p.lon > maxLon { maxLon = p.lon }
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let padding = 1.4
        let span = MKCoordinateSpan(
            latitudeDelta:  max(0.005, (maxLat - minLat) * padding),
            longitudeDelta: max(0.005, (maxLon - minLon) * padding)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let r = try await routeService.route(id: routeID)
            route = r
            author = try? await profileService.fetchProfile(userID: r.authorID)
        } catch let e as SocialError {
            if case .notFound = e {
                errorMessage = "This route isn't available."
            } else {
                errorMessage = e.errorDescription ?? "Couldn't load this route."
            }
        } catch {
            guard !isCancellationError(error) else { return }
            errorMessage = userFacingSupabaseError(error, feature: "shared route")
        }
    }
}
