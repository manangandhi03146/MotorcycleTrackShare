import Foundation
import Supabase

// MARK: - Report vocabulary

/// The kind of content being reported. Mirrors the CHECK constraint on
/// `content_reports.content_type` (migration 025).
enum ReportedContentType: String {
    case profile
    case sharedRoute = "shared_route"
    case activity
    case group
    case groupRide = "group_ride"
    case other
}

/// Why the content is being reported. Mirrors the CHECK constraint on
/// `content_reports.reason` (migration 025).
enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case violence
    case sexual
    case illegal
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:       return "Spam or misleading"
        case .harassment: return "Harassment or bullying"
        case .hate:       return "Hate speech"
        case .violence:   return "Violence or threats"
        case .sexual:     return "Nudity or sexual content"
        case .illegal:    return "Illegal activity"
        case .other:      return "Something else"
        }
    }
}

// MARK: - Blocked rider

/// Minimal display info for a rider the current account has blocked, returned
/// by the `get_blocked_riders` RPC (migration 026).
struct BlockedRider: Decodable, Identifiable {
    let id: UUID
    let username: String?
    let displayName: String?
    let avatarPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarPath  = "avatar_path"
    }

    var name: String {
        let dn = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dn, !dn.isEmpty { return dn }
        let un = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let un, !un.isEmpty { return "@\(un)" }
        return "Blocked rider"
    }
}

// MARK: - ModerationService

/// Central authority for the App Store Guideline 1.2 safety features:
/// blocking abusive users, reporting objectionable content, and recording
/// agreement to the community guidelines.
///
/// `blockedIDs` is published so views can filter blocked authors client-side
/// as defense-in-depth; the authoritative filtering happens in the RESTRICTIVE
/// RLS policies added in migration 025.
@MainActor
final class ModerationService: ObservableObject {
    private let client = SupabaseManager.shared.client

    @Published private(set) var blockedIDs: Set<UUID> = []

    private enum Table {
        static let blocks   = "user_blocks"
        static let reports  = "content_reports"
        static let profiles = "profiles"
    }

    // MARK: - Session

    private func currentUserID() async throws -> UUID {
        do {
            return try await client.auth.session.user.id
        } catch {
            throw SocialError.notSignedIn
        }
    }

    // MARK: - Blocking

    func isBlocked(_ userID: UUID) -> Bool {
        blockedIDs.contains(userID)
    }

    /// Loads the set of users the current account has blocked. Safe to call
    /// on every social entry — cheap and idempotent.
    func refreshBlocked() async {
        do {
            let me = try await currentUserID()
            struct Row: Decodable { let blocked_id: UUID }
            let rows: [Row] = try await client
                .from(Table.blocks)
                .select("blocked_id")
                .eq("blocker_id", value: me.uuidString)
                .execute()
                .value
            blockedIDs = Set(rows.map(\.blocked_id))
        } catch {
            // Non-fatal: leave the existing set in place.
            print("ModerationService.refreshBlocked failed:", error)
        }
    }

    private struct BlockInsert: Encodable {
        let blocker_id: String
        let blocked_id: String
    }

    func block(_ userID: UUID) async throws {
        let me = try await currentUserID()
        guard me != userID else { throw SocialError.validation("You can't block yourself.") }
        try await client
            .from(Table.blocks)
            .upsert(BlockInsert(
                blocker_id: me.uuidString.lowercased(),
                blocked_id: userID.uuidString.lowercased()
            ), onConflict: "blocker_id,blocked_id")
            .execute()
        blockedIDs.insert(userID)
    }

    func unblock(_ userID: UUID) async throws {
        let me = try await currentUserID()
        try await client
            .from(Table.blocks)
            .delete()
            .eq("blocker_id", value: me.uuidString)
            .eq("blocked_id", value: userID.uuidString)
            .execute()
        blockedIDs.remove(userID)
    }

    /// Display info for the riders the current account has blocked, for the
    /// "Blocked accounts" management screen. Blocked profiles are hidden by the
    /// RESTRICTIVE RLS policy from migration 025, so this goes through the
    /// `get_blocked_riders` SECURITY DEFINER RPC (migration 026) which only ever
    /// returns riders the caller themselves blocked.
    func blockedRiders() async throws -> [BlockedRider] {
        guard !blockedIDs.isEmpty else { return [] }
        return try await client
            .rpc("get_blocked_riders")
            .execute()
            .value
    }

    // MARK: - Reporting

    private struct ReportInsert: Encodable {
        let reporter_id: String
        let reported_user_id: String?
        let content_type: String
        let content_id: String?
        let reason: String
        let details: String?
    }

    func report(contentType: ReportedContentType,
                contentID: UUID?,
                reportedUserID: UUID?,
                reason: ReportReason,
                details: String?) async throws {
        let me = try await currentUserID()
        let trimmed = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client
            .from(Table.reports)
            .insert(ReportInsert(
                reporter_id: me.uuidString.lowercased(),
                reported_user_id: reportedUserID?.uuidString.lowercased(),
                content_type: contentType.rawValue,
                content_id: contentID?.uuidString.lowercased(),
                reason: reason.rawValue,
                details: (trimmed?.isEmpty ?? true) ? nil : trimmed
            ))
            .execute()
    }

    // MARK: - Community guidelines acceptance

    func hasAcceptedTerms() async -> Bool {
        do {
            let me = try await currentUserID()
            struct Row: Decodable { let accepted_terms_at: Date? }
            let row: Row = try await client
                .from(Table.profiles)
                .select("accepted_terms_at")
                .eq("id", value: me.uuidString)
                .single()
                .execute()
                .value
            return row.accepted_terms_at != nil
        } catch {
            return false
        }
    }

    private struct TermsUpdate: Encodable { let accepted_terms_at: Date }

    func acceptTerms() async throws {
        let me = try await currentUserID()
        try await client
            .from(Table.profiles)
            .update(TermsUpdate(accepted_terms_at: Date()))
            .eq("id", value: me.uuidString)
            .execute()
    }
}

// MARK: - Text moderation

/// Lightweight client-side objectionable-text guard applied when the user
/// submits free text (profile name/bio, group name/description, route titles).
/// This is a first-line filter, not a substitute for the report/block flow —
/// it blocks the most egregious slurs and obvious sexual/hateful terms from
/// being stored at all, satisfying the "filter objectionable material" prong
/// of Guideline 1.2.
enum TextModeration {
    /// Substrings that are never acceptable in user-facing text. Kept
    /// deliberately small and matched case-insensitively on word-ish
    /// boundaries. Extend server-side later for a fuller list.
    private static let blockedSubstrings: [String] = [
        "nigger", "nigga", "faggot", "fag", "retard", "kike", "spic",
        "chink", "wetback", "cunt", "rape", "childporn", "cp",
    ]

    static func isObjectionable(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
        // Collapse common leetspeak so "n1gger" is caught too.
        let deleeted = normalized
            .replacingOccurrences(of: "1", with: "i")
            .replacingOccurrences(of: "3", with: "e")
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "@", with: "a")
            .replacingOccurrences(of: "$", with: "s")
        for term in blockedSubstrings where term.count > 2 {
            // Whole-word-ish match to avoid false positives (e.g. "scunthorpe").
            if deleeted.range(of: "\\b\(term)\\b", options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Throws a validation error if the text contains objectionable content.
    static func validate(_ text: String, field: String = "text") throws {
        if isObjectionable(text) {
            throw SocialError.validation("That \(field) contains language that isn't allowed. Please revise it.")
        }
    }
}
