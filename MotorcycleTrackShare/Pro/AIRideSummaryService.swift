import Foundation

// MARK: - Public API

/// The rendered result of an AI ride summary request. The UI switches on this.
enum AIRideSummaryState: Equatable {
    case idle
    case loading
    case success(String)
    case unavailable(reason: String)
    case failure(reason: String)

    var text: String? {
        if case let .success(text) = self { return text }
        return nil
    }
}

/// Everything the summarizer needs to describe a ride. Deliberately excludes
/// personal identifiers so the payload can safely be sent to a remote LLM.
struct AIRideSummaryInput {
    let rideType: RideType
    let distanceMi: Double
    let durationSec: Double
    let avgSpeedMph: Double
    let maxSpeedMph: Double
    let maxLeanDeg: Double
    let elevationGainM: Double?
    let smoothnessScore: Int?
    let hardBrakingCount: Int
    let aggressiveAccelCount: Int
    let strongestBrakingMps2: Double?
    let strongestAccelMps2: Double?
    let dominantCharacters: [RouteCharacter]
    let hasTelemetry: Bool

    static func from(ride: SavedRide, analytics: RideAnalytics) -> AIRideSummaryInput {
        let s = ride.summary
        return AIRideSummaryInput(
            rideType: ride.effectiveRideType,
            distanceMi: s.distanceMi,
            durationSec: s.durationSec,
            avgSpeedMph: s.avgSpeedMph ?? s.computedAvgSpeedMph,
            maxSpeedMph: s.maxSpeedMph,
            maxLeanDeg: s.maxAbsLeanDeg,
            elevationGainM: s.elevationGainM ?? analytics.elevationGainM,
            smoothnessScore: analytics.smoothnessScore,
            hardBrakingCount: analytics.hardBrakingCount,
            aggressiveAccelCount: analytics.aggressiveAccelCount,
            strongestBrakingMps2: analytics.strongestBrakingMps2,
            strongestAccelMps2: analytics.strongestAccelMps2,
            dominantCharacters: analytics.dominantCharacters,
            hasTelemetry: analytics.hasTelemetry
        )
    }
}

// MARK: - Service protocol

protocol AIRideSummaryService {
    /// Requests a natural-language summary. Implementations should handle their
    /// own cancellation via `Task.checkCancellation()`.
    func summarize(_ input: AIRideSummaryInput) async -> AIRideSummaryState
}

// MARK: - Factory

/// Returns the currently-configured summary service.
///
/// Today this is always the local, deterministic summarizer. When a real
/// remote LLM is wired up, switch on a config flag or plist value here and
/// return a `RemoteAIRideSummaryService` instead — no call site changes.
enum AIRideSummaryFactory {
    static func makeService() -> AIRideSummaryService {
        // TODO: Wire remote LLM here when the backend endpoint is ready.
        //       Read the API base URL from a compile-time config (never bundle
        //       a shared secret; go through a backend proxy).
        LocalAIRideSummaryService()
    }
}

// MARK: - Local (offline) implementation

/// Deterministic on-device summarizer used until a real LLM is wired up.
/// The tone matches the rider-friendly voice used elsewhere in the app.
struct LocalAIRideSummaryService: AIRideSummaryService {

    func summarize(_ input: AIRideSummaryInput) async -> AIRideSummaryState {
        // Small artificial delay so the UI's loading state is visible; keeps
        // parity with what a real network call will feel like.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return .idle }

        guard input.durationSec >= 30, input.distanceMi >= 0.05 else {
            return .unavailable(reason: "This ride is too short to summarize.")
        }

        var paragraphs: [String] = []

        paragraphs.append(overviewLine(input))
        if let paceLine = paceLine(input) { paragraphs.append(paceLine) }
        if let smoothnessLine = smoothnessLine(input) { paragraphs.append(smoothnessLine) }
        if let brakeAccelLine = brakeAccelLine(input) { paragraphs.append(brakeAccelLine) }
        if let terrainLine = terrainLine(input) { paragraphs.append(terrainLine) }
        paragraphs.append(closingNote(input))

        return .success(paragraphs.joined(separator: "\n\n"))
    }

    // MARK: - Composition helpers

    private func overviewLine(_ i: AIRideSummaryInput) -> String {
        let mins = Int((i.durationSec / 60).rounded())
        let miles = String(format: "%.1f", i.distanceMi)
        let mode = i.rideType.displayName.lowercased()
        return "You logged a \(mins)-minute \(mode) ride covering about \(miles) miles."
    }

    private func paceLine(_ i: AIRideSummaryInput) -> String? {
        guard i.avgSpeedMph > 0 else { return nil }
        let avg = String(format: "%.0f", i.avgSpeedMph)
        let peak = String(format: "%.0f", i.maxSpeedMph)
        return "Average pace held around \(avg) mph, with a peak of \(peak) mph."
    }

    private func smoothnessLine(_ i: AIRideSummaryInput) -> String? {
        guard let score = i.smoothnessScore else { return nil }
        let descriptor: String
        switch score {
        case 85...:  descriptor = "very smooth"
        case 70..<85: descriptor = "smooth"
        case 50..<70: descriptor = "reasonably smooth with a few sharper inputs"
        default:     descriptor = "on the busier side, with noticeable throttle and brake changes"
        }
        return "Your throttle and brake inputs registered as \(descriptor) (smoothness score \(score)/100)."
    }

    private func brakeAccelLine(_ i: AIRideSummaryInput) -> String? {
        guard i.hasTelemetry else { return nil }
        var parts: [String] = []
        switch i.hardBrakingCount {
        case 0:  parts.append("no hard-braking events")
        case 1:  parts.append("one hard-braking moment")
        default: parts.append("\(i.hardBrakingCount) hard-braking moments")
        }
        switch i.aggressiveAccelCount {
        case 0:  parts.append("no aggressive acceleration")
        case 1:  parts.append("one aggressive acceleration event")
        default: parts.append("\(i.aggressiveAccelCount) aggressive acceleration events")
        }
        return "We flagged " + parts.joined(separator: " and ") + " across the ride."
    }

    private func terrainLine(_ i: AIRideSummaryInput) -> String? {
        var pieces: [String] = []
        for character in i.dominantCharacters where character != .mixed {
            switch character {
            case .stopAndGo: pieces.append("stop-and-go traffic")
            case .highway:   pieces.append("sustained highway pace")
            case .twisty:    pieces.append("twisty road sections")
            case .elevated:  pieces.append("noticeable elevation change")
            case .mixed:     break
            }
        }
        if pieces.isEmpty { return nil }
        return "The route featured " + pieces.joined(separator: ", ") + "."
    }

    private func closingNote(_ i: AIRideSummaryInput) -> String {
        if i.rideType == .track {
            return "Nice session. Keep the focus on repeatable inputs and clean lines lap after lap."
        }
        if i.hardBrakingCount == 0 && i.aggressiveAccelCount == 0 {
            return "A composed ride overall — clean, predictable inputs are exactly what safer street riding looks like."
        }
        return "Consider using the braking and acceleration breakdowns below to spot patterns worth smoothing out on your next ride."
    }
}
