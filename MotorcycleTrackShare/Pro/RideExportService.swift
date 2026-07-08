import Foundation

/// Supported export formats. The raw value is used as the file extension.
enum RideExportFormat: String, CaseIterable, Identifiable {
    case csv
    case gpx
    case json

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .csv:  return "CSV (samples)"
        case .gpx:  return "GPX (route)"
        case .json: return "JSON (full ride)"
        }
    }
    var uti: String {
        switch self {
        case .csv:  return "public.comma-separated-values-text"
        case .gpx:  return "public.xml"
        case .json: return "public.json"
        }
    }
}

/// Foundation for exporting a ride to CSV / GPX / JSON. All exports write to
/// the temporary directory and return a file URL callers hand to a share sheet.
///
/// This is deliberately self-contained: it takes plain input (a ride, its
/// samples, its route) and doesn't require access to any store.
struct RideExportService {

    enum ExportError: Error {
        case notEnoughData
        case writeFailed
    }

    /// Produce a file URL for the requested format. Throws when the format
    /// can't be produced from the given data (e.g. no route for GPX).
    func export(
        ride: SavedRide,
        route: [RidePoint],
        samples: @autoclosure () -> [RideSample],
        format: RideExportFormat
    ) throws -> URL {
        switch format {
        case .csv:  return try writeCSV(ride: ride, samples: samples())
        case .gpx:  return try writeGPX(ride: ride, route: route)
        case .json: return try writeJSON(ride: ride, samples: samples())
        }
    }

    // MARK: - CSV

    private func writeCSV(ride: SavedRide, samples: [RideSample]) throws -> URL {
        guard !samples.isEmpty else { throw ExportError.notEnoughData }

        var lines: [String] = []
        lines.reserveCapacity(samples.count + 1)
        lines.append("t,lat,lon,speed_mps,altitude_m,lean_deg,accel_x,accel_y,accel_z")

        for s in samples {
            let cols: [String] = [
                String(format: "%.3f", s.t),
                s.lat.map { String(format: "%.6f", $0) } ?? "",
                s.lon.map { String(format: "%.6f", $0) } ?? "",
                s.speedMps.map { String(format: "%.3f", $0) } ?? "",
                s.altitudeM.map { String(format: "%.2f", $0) } ?? "",
                s.leanDeg.map { String(format: "%.2f", $0) } ?? "",
                s.accelX.map { String(format: "%.3f", $0) } ?? "",
                s.accelY.map { String(format: "%.3f", $0) } ?? "",
                s.accelZ.map { String(format: "%.3f", $0) } ?? "",
            ]
            lines.append(cols.joined(separator: ","))
        }
        return try write(lines.joined(separator: "\n"), ride: ride, ext: "csv")
    }

    // MARK: - GPX

    private func writeGPX(ride: SavedRide, route: [RidePoint]) throws -> URL {
        guard !route.isEmpty else { throw ExportError.notEnoughData }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let started = iso.string(from: ride.summary.startTime)
        let safeName = xmlEscape(ride.name)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="RaceLine" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(safeName)</name>
            <time>\(started)</time>
          </metadata>
          <trk>
            <name>\(safeName)</name>
            <trkseg>
        """

        for point in route {
            xml += "\n      <trkpt lat=\"\(String(format: "%.6f", point.lat))\" "
            xml += "lon=\"\(String(format: "%.6f", point.lon))\"></trkpt>"
        }

        xml += """

            </trkseg>
          </trk>
        </gpx>

        """
        return try write(xml, ride: ride, ext: "gpx")
    }

    // MARK: - JSON

    private func writeJSON(ride: SavedRide, samples: [RideSample]) throws -> URL {
        let payload = RideJSONExport(ride: ride, samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try encoder.encode(payload) } catch { throw ExportError.writeFailed }
        let url = temporaryURL(ride: ride, ext: "json")
        do {
            try data.write(to: url, options: [.atomic])
        } catch { throw ExportError.writeFailed }
        return url
    }

    // MARK: - Shared

    private func write(_ contents: String, ride: SavedRide, ext: String) throws -> URL {
        let url = temporaryURL(ride: ride, ext: ext)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch { throw ExportError.writeFailed }
        return url
    }

    private func temporaryURL(ride: SavedRide, ext: String) -> URL {
        let base = FileManager.default.temporaryDirectory
        let filename = "\(fileSafeName(ride: ride)).\(ext)"
        let url = base.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func fileSafeName(ride: SavedRide) -> String {
        let cleaned = ride.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "ride" : cleaned
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return "raceline-\(base)-\(dateFormatter.string(from: ride.createdAt))"
    }

    private func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - JSON payload

/// Flat, forward-compatible JSON shape for the export. Kept independent of the
/// on-disk model so we can evolve either without breaking the other.
private struct RideJSONExport: Encodable {
    let format: String = "raceline.ride.v1"
    let id: UUID
    let name: String
    let createdAt: Date
    let rideType: String
    let summary: RideJSONExportSummary
    let route: [RideJSONExportPoint]
    let samples: [RideSample]
    let notes: String?
    let tags: [String]

    init(ride: SavedRide, samples: [RideSample]) {
        self.id = ride.id
        self.name = ride.name
        self.createdAt = ride.createdAt
        self.rideType = ride.effectiveRideType.rawValue
        self.summary = RideJSONExportSummary(from: ride.summary)
        self.route = ride.route.map { RideJSONExportPoint(lat: $0.lat, lon: $0.lon) }
        self.samples = samples
        self.notes = ride.notes
        self.tags = ride.effectiveTags
    }
}

private struct RideJSONExportSummary: Encodable {
    let startTime: Date
    let endTime: Date
    let durationSec: Double
    let distanceM: Double
    let maxSpeedMps: Double
    let avgSpeedMps: Double?
    let maxAbsLeanDeg: Double
    let elevationGainM: Double?
    let hardBrakingCount: Int?
    let aggressiveAccelCount: Int?

    init(from s: RideSummary) {
        self.startTime = s.startTime
        self.endTime = s.endTime
        self.durationSec = s.durationSec
        self.distanceM = s.distanceM
        self.maxSpeedMps = s.maxSpeedMps
        self.avgSpeedMps = s.avgSpeedMps
        self.maxAbsLeanDeg = s.maxAbsLeanDeg
        self.elevationGainM = s.elevationGainM
        self.hardBrakingCount = s.hardBrakingCount
        self.aggressiveAccelCount = s.aggressiveAccelCount
    }
}

private struct RideJSONExportPoint: Encodable {
    let lat: Double
    let lon: Double
}
