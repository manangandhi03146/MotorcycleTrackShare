import SwiftUI
import UserNotifications

/// First-launch walkthrough. Explains what RaceLine does and primes the user
/// for the system permission prompts that follow.
///
/// Permission handling follows App Review guideline 5.1.1(iv): each priming
/// page explains *why* a permission is needed, and the page's single forward
/// button ("Continue") triggers the real system prompt. There is deliberately
/// no "Allow" wording on the button and no exit/skip control that would let the
/// user bypass the prompt — tapping Continue always proceeds to the request.
///
/// Completion is tracked in `UserDefaults` under `hasSeenIntroTutorial` so it
/// only appears once, but the Settings screen has a row to re-show it on demand.
///
/// Note: lean angle, acceleration, and braking come from `CMMotionManager`
/// device-motion, which requires **no** authorization — so there is no
/// Motion & Fitness prompt here and the app does not declare that permission.
struct IntroTutorialView: View {
    /// Called when the user finishes the tutorial (taps Get Started on the
    /// last page). The caller is responsible for setting the
    /// `hasSeenIntroTutorial` flag and moving to the next screen.
    let onFinish: () -> Void

    @State private var currentPage = 0

    /// Retained for the view's lifetime so the location permission dialog
    /// reliably presents — a locally-scoped `CLLocationManager` can deallocate
    /// before the system prompt appears. `requestPermission()` is a no-op once
    /// the user has already decided.
    @StateObject private var locationService = LocationService()

    private static let pages: [IntroPage] = [
        IntroPage(
            icon: "__sportbike__",
            title: "Welcome to RaceLine",
            body: "Turn your phone into a motorcycle telemetry rig. Record street rides and track days, then analyze speed, lean angle, GPS, and more.",
            permission: nil
        ),
        IntroPage(
            icon: "speedometer",
            title: "Track every ride",
            body: "Tap Start Ride and RaceLine records your route, speed, elevation, lean angles, hard braking events, and aggressive acceleration in real time.",
            permission: nil
        ),
        IntroPage(
            icon: "wrench.and.screwdriver.fill",
            title: "Manage your bikes",
            body: "Add the bikes in your garage, tag each ride to the one you took out, and log maintenance with mileage-based reminders.",
            permission: nil
        ),
        IntroPage(
            icon: "location.fill",
            title: "Location access",
            body: "RaceLine needs your location while you ride to capture route, speed, and elevation. Location is only collected while a ride is actively recording — never in the background. Tap Continue to grant access.",
            permission: .location
        ),
        IntroPage(
            icon: "bell.badge.fill",
            title: "Maintenance reminders",
            body: "RaceLine can remind you when an oil change, tire swap, or service is due. Tap Continue to choose whether to allow notifications.",
            permission: .notifications
        ),
        IntroPage(
            icon: "checkmark.seal.fill",
            title: "You're all set",
            body: "Sign in with Apple or Google to back up your rides and sync them across devices. Let's ride.",
            permission: nil
        ),
    ]

    private var isLastPage: Bool { currentPage >= Self.pages.count - 1 }

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Paged content
                TabView(selection: $currentPage) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { index, page in
                        IntroPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .indexViewStyle(.page(backgroundDisplayMode: .never))

                // Custom dots — TabView's built-in dots look anemic on dark.
                HStack(spacing: 8) {
                    ForEach(0..<Self.pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.appAccent : Color.textGhost)
                            .frame(width: i == currentPage ? 10 : 7,
                                   height: i == currentPage ? 10 : 7)
                            .animation(.easeInOut(duration: 0.2), value: currentPage)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)

                // Primary action. On a permission page this fires the system
                // prompt *before* advancing, so the user always proceeds to the
                // permission request (guideline 5.1.1(iv)).
                PrimaryButton(title: isLastPage ? "Get Started" : "Continue") {
                    advance()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
    }

    private func advance() {
        requestPermissionIfNeeded(for: Self.pages[currentPage])

        if isLastPage {
            finish()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentPage += 1
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasSeenIntroTutorial")
        onFinish()
    }

    // MARK: - Permission requests

    private func requestPermissionIfNeeded(for page: IntroPage) {
        switch page.permission {
        case .location:
            locationService.requestPermission()
        case .notifications:
            Task { await requestNotifications() }
        case nil:
            break
        }
    }

    private func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }
}

// MARK: - Page model + view

private enum IntroPermission {
    case location
    case notifications
}

private struct IntroPage {
    let icon: String
    let title: String
    let body: String
    /// When set, tapping "Continue" on this page fires the matching system
    /// permission prompt before advancing to the next page.
    let permission: IntroPermission?
}

private struct IntroPageView: View {
    let page: IntroPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(Color.appAccent.opacity(0.15))
                    .frame(width: 140, height: 140)
                if page.icon == "__sportbike__" {
                    SportbikeIcon(height: 72)
                        .foregroundStyle(Color.appAccent)
                } else {
                    Image(systemName: page.icon)
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }
            }

            VStack(spacing: 14) {
                Text(page.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)

                Text(page.body)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }
}
