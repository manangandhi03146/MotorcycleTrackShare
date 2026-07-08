import Foundation
import UIKit
import CoreLocation

/// Builds Google Maps route URLs and opens them, either in the
/// installed Google Maps app or as a browser fallback.
///
/// We deliberately use the public "Maps URLs" API — no API key
/// required and no billing exposure — because we only need to hand
/// the destination + waypoints over to whichever navigation app
/// the user prefers. Turn-by-turn navigation stays with Google Maps.
///
/// Reference: https://developers.google.com/maps/documentation/urls/get-started
enum GoogleMapsRouteService {

    // MARK: - URL construction

    /// Builds a universal Google Maps directions link. Prefer this over
    /// the app-scheme URL because it works whether the app is installed
    /// or not (opens in browser → Maps app if installed).
    static func directionsURL(destinationName: String?,
                              destinationAddress: String?,
                              destinationLatitude: Double?,
                              destinationLongitude: Double?,
                              waypoints: [GroupRideWaypoint] = [],
                              travelMode: TravelMode = .driving) -> URL? {
        guard let destination = destinationParameter(name: destinationName,
                                                     address: destinationAddress,
                                                     latitude: destinationLatitude,
                                                     longitude: destinationLongitude) else {
            return nil
        }

        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: destination),
            URLQueryItem(name: "travelmode", value: travelMode.rawValue)
        ]
        if let waypointParam = waypointParameter(waypoints) {
            items.append(URLQueryItem(name: "waypoints", value: waypointParam))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Convenience overload for callers holding an already-composed
    /// `GroupRide` — used from the detail view and activity feed.
    static func directionsURL(for ride: GroupRide, travelMode: TravelMode = .driving) -> URL? {
        directionsURL(destinationName: ride.destinationName,
                      destinationAddress: ride.destinationAddress,
                      destinationLatitude: ride.destinationLatitude,
                      destinationLongitude: ride.destinationLongitude,
                      waypoints: ride.waypoints,
                      travelMode: travelMode)
    }

    // MARK: - Opening

    /// Opens the given URL, preferring the Google Maps app if installed.
    /// Falls back to whatever handler iOS uses for `https` URLs (mobile
    /// Safari, which will then bounce into Maps app if configured).
    static func open(url: URL) {
        // Attempt the comgooglemaps app scheme first. If Google Maps
        // isn't installed, `canOpenURL` returns false and we open the
        // universal https URL instead.
        if let deep = googleMapsAppURL(from: url),
           UIApplication.shared.canOpenURL(deep) {
            UIApplication.shared.open(deep)
            return
        }
        UIApplication.shared.open(url)
    }

    // MARK: - Helpers

    enum TravelMode: String {
        case driving, walking, bicycling, transit, twoWheeler = "two-wheeler"
    }

    /// Formats the destination for the Maps URL: prefer coordinates when
    /// available (deterministic), else name+address, else whichever is
    /// present. Empty values return nil so we don't send bogus links.
    private static func destinationParameter(name: String?,
                                             address: String?,
                                             latitude: Double?,
                                             longitude: Double?) -> String? {
        if let lat = latitude, let lon = longitude,
           CLLocationCoordinate2D(latitude: lat, longitude: lon).isValidCoordinate {
            return "\(lat),\(lon)"
        }
        let combined = [name, address]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: ", ")
        return combined.isEmpty ? nil : combined
    }

    /// Waypoints are pipe-delimited in the Google Maps URL: `A|B|C`.
    /// Each waypoint uses "lat,lon" if we have coordinates, else the
    /// name/address string. Google Maps supports up to 9 waypoints.
    private static func waypointParameter(_ points: [GroupRideWaypoint]) -> String? {
        let encoded = points.prefix(9).compactMap { p -> String? in
            if let lat = p.latitude, let lon = p.longitude,
               CLLocationCoordinate2D(latitude: lat, longitude: lon).isValidCoordinate {
                return "\(lat),\(lon)"
            }
            let combined = [p.name, p.address]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
                .joined(separator: ", ")
            return combined.isEmpty ? nil : combined
        }
        return encoded.isEmpty ? nil : encoded.joined(separator: "|")
    }

    /// Converts an `https://www.google.com/maps/dir/?…` URL into the
    /// `comgooglemaps://` app-scheme equivalent so the Google Maps app
    /// opens directly. Only used if the app is installed.
    private static func googleMapsAppURL(from httpsURL: URL) -> URL? {
        guard var components = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = "comgooglemaps"
        components.host = ""
        components.path = ""
        // The universal URL uses ?api=1 while the app scheme just wants
        // the query params without the leading path. Strip empty items.
        return components.url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension CLLocationCoordinate2D {
    var isValidCoordinate: Bool {
        CLLocationCoordinate2DIsValid(self) && (latitude != 0 || longitude != 0)
    }
}
