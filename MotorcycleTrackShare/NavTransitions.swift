import SwiftUI

/// Cross-view navigation animations used to smooth over the hard cuts
/// that switch statements would otherwise produce when swapping tabs
/// or segmented content. Two goals:
///   * Fast enough that navigation doesn't feel slower.
///   * Skip entirely when Reduce Motion is on (returns `.identity`).
enum NavTransition {

    /// Standard curve — quick enough (200ms) not to feel like a delay,
    /// slow enough that the eye tracks the swap instead of flashing.
    static let animation: Animation = .easeOut(duration: 0.2)

    /// Cross-fade for peer tabs where there's no natural spatial
    /// relationship (Rides vs. Garage vs. Social vs. Profile). Tiny
    /// scale-in makes the destination "settle" rather than snap.
    static func tabSwap(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(
                with: .scale(scale: 0.985, anchor: .center)
            ),
            removal: .opacity
        )
    }

    /// Directional slide for segmented content that lives in a
    /// horizontal row (e.g. Feed / Groups / Challenges / Riders). The
    /// incoming view enters from the side the user "moved toward";
    /// the outgoing one exits the opposite way. Falls back to a fade
    /// if `direction == 0` (initial appearance) or Reduce Motion is on.
    static func segmentSwap(direction: Int, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        if direction == 0 { return .opacity }
        let insertEdge: Edge = direction > 0 ? .trailing : .leading
        let removeEdge: Edge = direction > 0 ? .leading  : .trailing
        return .asymmetric(
            insertion: .move(edge: insertEdge).combined(with: .opacity),
            removal:   .move(edge: removeEdge).combined(with: .opacity)
        )
    }
}
