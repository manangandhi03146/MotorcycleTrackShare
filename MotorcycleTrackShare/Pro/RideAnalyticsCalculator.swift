import Foundation

// MARK: - Result types

enum EventConsistency: String {
    case veryConsistent
    case consistent
    case mixed
    case inconsistent

    var displayName: String {
        switch self {
        case .veryConsistent: return "Very consistent"
        case .consistent:     return "Consistent"
        case .mixed:          return "Mixed"
        case .inconsistent:   return "Inconsistent"
        }
    }
}

enum RouteCharacter: String, CaseIterable {
    case stopAndGo
    case highway
    case twisty
    case elevated
    case mixed

    var displayName: String {
        switch self {
        case .stopAndGo: return "Stop-and-go traffic"
        case .highway:   return "Highway-style riding"
        case .twisty:    return "Twisty sections"
        case .elevated:  return "Elevation-heavy"
        case .mixed:     return "Mixed roads"
        }
    }
}

struct RideAnalytics {
    // Braking
    let hardBrakingCount: Int
    let strongestBrakingMps2: Double?         // negative (m/s²)
    let brakingConsistency: EventConsistency?

    // Acceleration
    let aggressiveAccelCount: Int
    let strongestAccelMps2: Double?           // positive (m/s²)
    let accelConsistency: EventConsistency?

    // Overall
    let smoothnessScore: Int?                 // 0..100 (higher = smoother)
    let hasTelemetry: Bool                    // false when no samples were available

    // Route insights (heuristic)
    let dominantCharacters: [RouteCharacter]
    let elevationGainM: Double?
    let elevationLossM: Double?

    static let empty = RideAnalytics(
        hardBrakingCount: 0,
        strongestBrakingMps2: nil,
        brakingConsistency: nil,
        aggressiveAccelCount: 0,
        strongestAccelMps2: nil,
        accelConsistency: nil,
        smoothnessScore: nil,
        hasTelemetry: false,
        dominantCharacters: [],
        elevationGainM: nil,
        elevationLossM: nil
    )
}

// MARK: - Sample loader

/// Reads the `samples.jsonl` file written by `RideRecorder`.
/// One `RideSample` per line. Robust to malformed lines — bad lines are skipped.
enum RideSampleLoader {
    static func load(from url: URL) -> [RideSample] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        let decoder = JSONDecoder()
        var samples: [RideSample] = []
        samples.reserveCapacity(text.count / 80) // rough hint

        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let sample = try? decoder.decode(RideSample.self, from: lineData)
            else { return }
            samples.append(sample)
        }
        return samples
    }
}

// MARK: - Calculator

enum RideAnalyticsCalculator {

    // Physically-motivated thresholds (adjust in one place if needed).
    private static let hardBrakingThreshold: Double     = -3.5     // ~ -0.35g
    private static let aggressiveAccelThreshold: Double =  3.0     // ~ +0.30g
    private static let eventDebounceSeconds: Double     = 1.5      // min gap between counted events

    /// Compute analytics from a ride's samples and summary. The summary values
    /// are trusted when available; sample-derived values fill in the rest and
    /// provide strongest-event peaks and consistency scores.
    static func analyze(samples: [RideSample], summary: RideSummary) -> RideAnalytics {
        guard !samples.isEmpty else {
            // Fall back to whatever the summary knows about.
            return RideAnalytics(
                hardBrakingCount: summary.hardBrakingCount ?? 0,
                strongestBrakingMps2: nil,
                brakingConsistency: nil,
                aggressiveAccelCount: summary.aggressiveAccelCount ?? 0,
                strongestAccelMps2: nil,
                accelConsistency: nil,
                smoothnessScore: nil,
                hasTelemetry: false,
                dominantCharacters: [],
                elevationGainM: summary.elevationGainM,
                elevationLossM: nil
            )
        }

        let brake = detectEvents(samples: samples, isBraking: true)
        let accel = detectEvents(samples: samples, isBraking: false)
        let smoothness = smoothnessScore(samples: samples)
        let elevation = elevationDeltas(samples: samples)
        let characters = routeCharacters(samples: samples, summary: summary)

        return RideAnalytics(
            hardBrakingCount: summary.hardBrakingCount ?? brake.count,
            strongestBrakingMps2: brake.peak,
            brakingConsistency: brake.consistency,
            aggressiveAccelCount: summary.aggressiveAccelCount ?? accel.count,
            strongestAccelMps2: accel.peak,
            accelConsistency: accel.consistency,
            smoothnessScore: smoothness,
            hasTelemetry: true,
            dominantCharacters: characters,
            elevationGainM: summary.elevationGainM ?? elevation.gain,
            elevationLossM: elevation.loss
        )
    }

    // MARK: - Event detection

    private struct EventStats {
        let count: Int
        let peak: Double?               // most extreme accel value (signed)
        let consistency: EventConsistency?
    }

    private static func detectEvents(samples: [RideSample], isBraking: Bool) -> EventStats {
        var count = 0
        var lastEventT: Double = -.infinity
        var peakValue: Double? = nil
        var eventValues: [Double] = []

        for s in samples {
            guard let ay = s.accelY else { continue }

            let crossed = isBraking
                ? ay <= hardBrakingThreshold
                : ay >= aggressiveAccelThreshold
            guard crossed else { continue }

            let debounced = (s.t - lastEventT) >= eventDebounceSeconds
            if debounced {
                count += 1
                lastEventT = s.t
                eventValues.append(ay)
            }

            if let p = peakValue {
                peakValue = isBraking ? min(p, ay) : max(p, ay)
            } else {
                peakValue = ay
            }
        }

        let consistency: EventConsistency?
        if eventValues.count >= 3 {
            let sd = stddev(eventValues)
            switch sd {
            case ..<0.5:  consistency = .veryConsistent
            case ..<1.2:  consistency = .consistent
            case ..<2.5:  consistency = .mixed
            default:      consistency = .inconsistent
            }
        } else if eventValues.count > 0 {
            consistency = .consistent
        } else {
            consistency = nil
        }

        return EventStats(count: count, peak: peakValue, consistency: consistency)
    }

    // MARK: - Smoothness

    /// 0..100, where higher = smoother. Based on the standard deviation of
    /// longitudinal acceleration; capped so pathological rides don't underflow.
    private static func smoothnessScore(samples: [RideSample]) -> Int? {
        let values = samples.compactMap { $0.accelY }
        guard values.count >= 30 else { return nil }
        let sd = stddev(values)
        // Empirically: sd ~0.5 → very smooth commute, sd ~3+ → aggressive/rough.
        let raw = 100.0 - min(100.0, sd * 28.0)
        return Int(max(0.0, min(100.0, raw)).rounded())
    }

    // MARK: - Elevation

    private static func elevationDeltas(samples: [RideSample]) -> (gain: Double?, loss: Double?) {
        // Simple noise-tolerant integrator: only accumulate when the altitude
        // change exceeds a small threshold since the last accumulated point.
        let noiseThreshold: Double = 1.5 // meters
        var gain = 0.0
        var loss = 0.0
        var lastAlt: Double? = nil
        var anySeen = false

        for s in samples {
            guard let alt = s.altitudeM else { continue }
            anySeen = true
            guard let previous = lastAlt else {
                lastAlt = alt
                continue
            }
            let delta = alt - previous
            if delta > noiseThreshold {
                gain += delta
                lastAlt = alt
            } else if delta < -noiseThreshold {
                loss += -delta
                lastAlt = alt
            }
        }

        guard anySeen else { return (nil, nil) }
        return (gain, loss)
    }

    // MARK: - Route character heuristic

    private static func routeCharacters(samples: [RideSample], summary: RideSummary) -> [RouteCharacter] {
        var results: [RouteCharacter] = []

        let speeds = samples.compactMap { $0.speedMps }
        let hasSpeed = speeds.count >= 30

        if hasSpeed {
            let lowSpeedShare = Double(speeds.filter { $0 < 4.5 }.count) / Double(speeds.count) // <10 mph
            let highSpeedShare = Double(speeds.filter { $0 >= 22.5 }.count) / Double(speeds.count) // >=50 mph
            if lowSpeedShare > 0.30 { results.append(.stopAndGo) }
            if highSpeedShare > 0.55 { results.append(.highway) }
        }

        // Twisty inference from yaw rate variability, when available.
        let yaws = samples.compactMap { $0.yawRad }
        if yaws.count >= 30 {
            let yawSd = stddev(yaws)
            if yawSd > 0.35 { results.append(.twisty) }
        }

        // Elevation-heavy if either summary or derived gain is large.
        let gainM = summary.elevationGainM ?? elevationDeltas(samples: samples).gain ?? 0
        if gainM >= 150 { results.append(.elevated) } // ~500 ft

        if results.isEmpty { results.append(.mixed) }
        return results
    }

    // MARK: - Utility

    private static func stddev(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }
}
