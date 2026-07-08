import Foundation

// MARK: - Public profile

/// Read-side view of a rider's public profile. Fields not marked public in
/// their privacy settings return nil from the server (RLS + column filtering
/// at the query site).
struct SocialProfile: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var username: String?
    var displayName: String?
    var bio: String?
    var avatarPath: String?
    var isPublic: Bool
    var showBikes: Bool
    var showRideStats: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName    = "display_name"
        case bio
        case avatarPath     = "avatar_path"
        case isPublic       = "is_public"
        case showBikes      = "show_bikes"
        case showRideStats  = "show_ride_stats"
    }
}

struct SocialProfileUpdate: Encodable {
    var username: String? = nil
    var displayName: String? = nil
    var bio: String? = nil
    var avatarPath: String? = nil
    var isPublic: Bool? = nil
    var showBikes: Bool? = nil
    var showRideStats: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case username
        case displayName    = "display_name"
        case bio
        case avatarPath     = "avatar_path"
        case isPublic       = "is_public"
        case showBikes      = "show_bikes"
        case showRideStats  = "show_ride_stats"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = username       { try c.encode(v, forKey: .username) }
        if let v = displayName    { try c.encode(v, forKey: .displayName) }
        if let v = bio            { try c.encode(v, forKey: .bio) }
        if let v = avatarPath     { try c.encode(v, forKey: .avatarPath) }
        if let v = isPublic       { try c.encode(v, forKey: .isPublic) }
        if let v = showBikes      { try c.encode(v, forKey: .showBikes) }
        if let v = showRideStats  { try c.encode(v, forKey: .showRideStats) }
    }
}

// MARK: - Privacy settings

enum SharedRouteVisibility: String, Codable, CaseIterable, Identifiable {
    case privateOnly = "private"
    case followers
    case groups
    case publicVisible = "public"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .privateOnly:   return "Only me"
        case .followers:     return "Followers"
        case .groups:        return "Group members"
        case .publicVisible: return "Public"
        }
    }

    var explainer: String {
        switch self {
        case .privateOnly:   return "Save the route to your account only."
        case .followers:     return "People who follow you can view."
        case .groups:        return "Members of the selected group can view."
        case .publicVisible: return "Anyone signed in to RaceLine can view."
        }
    }
}

struct SocialPrivacySettings: Codable, Equatable {
    let userID: UUID
    var shareRidesByDefault: Bool
    var hideRideStartByDefault: Bool
    var hideRideEndByDefault: Bool
    var showRideActivities: Bool
    var showChallengeActivities: Bool
    var showMaintenanceActivities: Bool
    var showGroupActivities: Bool
    var shareDefaultRouteVisibility: SharedRouteVisibility

    enum CodingKeys: String, CodingKey {
        case userID                      = "user_id"
        case shareRidesByDefault         = "share_rides_by_default"
        case hideRideStartByDefault      = "hide_ride_start_by_default"
        case hideRideEndByDefault        = "hide_ride_end_by_default"
        case showRideActivities          = "show_ride_activities"
        case showChallengeActivities     = "show_challenge_activities"
        case showMaintenanceActivities   = "show_maintenance_activities"
        case showGroupActivities         = "show_group_activities"
        case shareDefaultRouteVisibility = "share_default_route_visibility"
    }

    static func safeDefault(for userID: UUID) -> SocialPrivacySettings {
        SocialPrivacySettings(
            userID: userID,
            shareRidesByDefault: false,
            hideRideStartByDefault: true,
            hideRideEndByDefault: true,
            showRideActivities: false,
            showChallengeActivities: true,
            showMaintenanceActivities: false,
            showGroupActivities: true,
            shareDefaultRouteVisibility: .privateOnly
        )
    }
}

struct SocialPrivacySettingsUpdate: Encodable {
    var shareRidesByDefault: Bool?
    var hideRideStartByDefault: Bool?
    var hideRideEndByDefault: Bool?
    var showRideActivities: Bool?
    var showChallengeActivities: Bool?
    var showMaintenanceActivities: Bool?
    var showGroupActivities: Bool?
    var shareDefaultRouteVisibility: SharedRouteVisibility?

    enum CodingKeys: String, CodingKey {
        case shareRidesByDefault         = "share_rides_by_default"
        case hideRideStartByDefault      = "hide_ride_start_by_default"
        case hideRideEndByDefault        = "hide_ride_end_by_default"
        case showRideActivities          = "show_ride_activities"
        case showChallengeActivities     = "show_challenge_activities"
        case showMaintenanceActivities   = "show_maintenance_activities"
        case showGroupActivities         = "show_group_activities"
        case shareDefaultRouteVisibility = "share_default_route_visibility"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = shareRidesByDefault         { try c.encode(v, forKey: .shareRidesByDefault) }
        if let v = hideRideStartByDefault      { try c.encode(v, forKey: .hideRideStartByDefault) }
        if let v = hideRideEndByDefault        { try c.encode(v, forKey: .hideRideEndByDefault) }
        if let v = showRideActivities          { try c.encode(v, forKey: .showRideActivities) }
        if let v = showChallengeActivities     { try c.encode(v, forKey: .showChallengeActivities) }
        if let v = showMaintenanceActivities   { try c.encode(v, forKey: .showMaintenanceActivities) }
        if let v = showGroupActivities         { try c.encode(v, forKey: .showGroupActivities) }
        if let v = shareDefaultRouteVisibility { try c.encode(v.rawValue, forKey: .shareDefaultRouteVisibility) }
    }
}

// MARK: - Follows

struct Follow: Codable, Equatable, Hashable {
    let followerID: UUID
    let followeeID: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case followerID = "follower_id"
        case followeeID = "followee_id"
        case createdAt  = "created_at"
    }
}

// MARK: - Groups

enum GroupMemberRole: String, Codable {
    case owner, admin, member

    var displayName: String {
        switch self {
        case .owner:  return "Owner"
        case .admin:  return "Admin"
        case .member: return "Member"
        }
    }
}

struct GroupSummary: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let ownerID: UUID
    let name: String
    let description: String?
    let isPublic: Bool
    let joinCode: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID     = "owner_id"
        case name
        case description
        case isPublic    = "is_public"
        case joinCode    = "join_code"
        case createdAt   = "created_at"
    }
}

/// Insert payload for `groups`. Includes `owner_id` explicitly so the
/// RLS INSERT policy (`WITH CHECK (owner_id = auth.uid())`) and the
/// RETURNING read from `.select().single()` both see a concrete owner
/// tied to the current Supabase session (see migration 016).
struct GroupInsert: Encodable {
    let ownerID: UUID
    let name: String
    let description: String?
    let isPublic: Bool
    let joinCode: String

    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case name
        case description
        case isPublic = "is_public"
        case joinCode = "join_code"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ownerID.uuidString.lowercased(), forKey: .ownerID)
        try c.encode(name, forKey: .name)
        if let description { try c.encode(description, forKey: .description) }
        try c.encode(isPublic, forKey: .isPublic)
        try c.encode(joinCode, forKey: .joinCode)
    }
}

struct GroupMember: Codable, Identifiable, Equatable, Hashable {
    var id: String { "\(groupID.uuidString)-\(userID.uuidString)" }

    let groupID: UUID
    let userID: UUID
    let role: GroupMemberRole
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case groupID  = "group_id"
        case userID   = "user_id"
        case role
        case joinedAt = "joined_at"
    }
}

// MARK: - Group rides (Phase 4)

enum GroupRideStatus: String, Codable, CaseIterable {
    case planned, active, completed, cancelled

    var displayName: String {
        switch self {
        case .planned:   return "Planned"
        case .active:    return "Active"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }
}

enum GroupRideVisibility: String, Codable, CaseIterable, Identifiable {
    case groupOnly = "group_only"
    case publicVisible = "public"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .groupOnly:     return "Group only"
        case .publicVisible: return "Public"
        }
    }
}

/// One waypoint / stop on a shared group ride route. Stored as JSONB
/// inside `group_rides.waypoints`.
struct GroupRideWaypoint: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude
    }
}

/// Full group ride model. `description` doubles as the free-form
/// "ride notes" field the create sheet exposes; keeping the DB
/// column name for backward compatibility.
struct GroupRide: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let groupID: UUID
    let authorID: UUID
    let rideID: UUID?
    let title: String
    let description: String?
    let destinationName: String?
    let destinationAddress: String?
    let destinationLatitude: Double?
    let destinationLongitude: Double?
    let waypoints: [GroupRideWaypoint]
    let googleMapsURL: String?
    let status: GroupRideStatus
    let visibility: GroupRideVisibility
    let liveLocationEnabled: Bool
    let scheduledAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case groupID                 = "group_id"
        case authorID                = "author_id"
        case rideID                  = "ride_id"
        case title
        case description
        case destinationName         = "destination_name"
        case destinationAddress      = "destination_address"
        case destinationLatitude     = "destination_latitude"
        case destinationLongitude    = "destination_longitude"
        case waypoints
        case googleMapsURL           = "google_maps_url"
        case status
        case visibility
        case liveLocationEnabled     = "live_location_enabled"
        case scheduledAt             = "scheduled_at"
        case startedAt               = "started_at"
        case completedAt             = "completed_at"
        case createdAt               = "created_at"
    }
}

struct GroupRideInsert: Encodable {
    let groupID: UUID
    let authorID: UUID
    let title: String
    let description: String?
    let destinationName: String?
    let destinationAddress: String?
    let destinationLatitude: Double?
    let destinationLongitude: Double?
    let waypoints: [GroupRideWaypoint]
    let googleMapsURL: String?
    let visibility: GroupRideVisibility
    let liveLocationEnabled: Bool
    let scheduledAt: Date?

    enum CodingKeys: String, CodingKey {
        case groupID                 = "group_id"
        case authorID                = "author_id"
        case title
        case description
        case destinationName         = "destination_name"
        case destinationAddress      = "destination_address"
        case destinationLatitude     = "destination_latitude"
        case destinationLongitude    = "destination_longitude"
        case waypoints
        case googleMapsURL           = "google_maps_url"
        case visibility
        case liveLocationEnabled     = "live_location_enabled"
        case scheduledAt             = "scheduled_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupID.uuidString.lowercased(),  forKey: .groupID)
        try c.encode(authorID.uuidString.lowercased(), forKey: .authorID)
        try c.encode(title, forKey: .title)
        if let description        { try c.encode(description,        forKey: .description) }
        if let destinationName    { try c.encode(destinationName,    forKey: .destinationName) }
        if let destinationAddress { try c.encode(destinationAddress, forKey: .destinationAddress) }
        if let destinationLatitude  { try c.encode(destinationLatitude,  forKey: .destinationLatitude) }
        if let destinationLongitude { try c.encode(destinationLongitude, forKey: .destinationLongitude) }
        try c.encode(waypoints, forKey: .waypoints)
        if let googleMapsURL { try c.encode(googleMapsURL, forKey: .googleMapsURL) }
        try c.encode(visibility.rawValue, forKey: .visibility)
        try c.encode(liveLocationEnabled, forKey: .liveLocationEnabled)
        if let scheduledAt { try c.encode(scheduledAt, forKey: .scheduledAt) }
    }
}

enum GroupRideParticipantStatus: String, Codable, CaseIterable {
    case interested, joined, riding, completed, cancelled

    var displayName: String {
        switch self {
        case .interested: return "Interested"
        case .joined:     return "Joined"
        case .riding:     return "Riding"
        case .completed:  return "Completed"
        case .cancelled:  return "Cancelled"
        }
    }
}

struct GroupRideParticipant: Codable, Identifiable, Equatable, Hashable {
    var id: String { "\(groupRideID.uuidString)-\(userID.uuidString)" }

    let groupRideID: UUID
    let userID: UUID
    let status: GroupRideParticipantStatus
    let joinedAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case groupRideID = "group_ride_id"
        case userID      = "user_id"
        case status
        case joinedAt    = "joined_at"
        case updatedAt   = "updated_at"
    }
}

struct GroupRideLiveLocation: Codable, Identifiable, Equatable, Hashable {
    var id: String { "\(groupRideID.uuidString)-\(userID.uuidString)" }

    let groupRideID: UUID
    let userID: UUID
    let latitude: Double
    let longitude: Double
    let heading: Double?
    let speedMPS: Double?
    let sharingEnabled: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case groupRideID    = "group_ride_id"
        case userID         = "user_id"
        case latitude
        case longitude
        case heading
        case speedMPS       = "speed_mps"
        case sharingEnabled = "sharing_enabled"
        case updatedAt      = "updated_at"
    }
}

struct GroupRideLiveLocationUpsert: Encodable {
    let groupRideID: UUID
    let userID: UUID
    let latitude: Double
    let longitude: Double
    let heading: Double?
    let speedMPS: Double?
    let sharingEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case groupRideID    = "group_ride_id"
        case userID         = "user_id"
        case latitude
        case longitude
        case heading
        case speedMPS       = "speed_mps"
        case sharingEnabled = "sharing_enabled"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupRideID.uuidString.lowercased(), forKey: .groupRideID)
        try c.encode(userID.uuidString.lowercased(),      forKey: .userID)
        try c.encode(latitude,  forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        if let heading  { try c.encode(heading,  forKey: .heading) }
        if let speedMPS { try c.encode(speedMPS, forKey: .speedMPS) }
        try c.encode(sharingEnabled, forKey: .sharingEnabled)
    }
}

// MARK: - Challenges

enum ChallengeType: String, Codable, CaseIterable, Identifiable {
    case weeklyMileage         = "weeklyMileage"
    case monthlyStreak         = "monthlyStreak"
    case mostRides             = "mostRides"
    case longestRide           = "longestRide"
    case maintenanceStreak     = "maintenanceStreak"
    case smoothnessImprovement = "smoothnessImprovement"
    case trackSession          = "trackSession"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weeklyMileage:         return "Weekly Mileage"
        case .monthlyStreak:         return "Monthly Ride Streak"
        case .mostRides:             return "Most Rides"
        case .longestRide:           return "Longest Ride"
        case .maintenanceStreak:     return "Maintenance Streak"
        case .smoothnessImprovement: return "Smoothness Improvement"
        case .trackSession:          return "Track Session"
        }
    }

    var systemImage: String {
        switch self {
        case .weeklyMileage:         return "figure.outdoor.cycle"
        case .monthlyStreak:         return "flame"
        case .mostRides:             return "list.bullet.rectangle"
        case .longestRide:           return "arrow.left.and.right"
        case .maintenanceStreak:     return "wrench.and.screwdriver"
        case .smoothnessImprovement: return "waveform.path.ecg"
        case .trackSession:          return "flag.checkered"
        }
    }
}

struct Challenge: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let ownerID: UUID?
    let groupID: UUID?
    let slug: String
    let title: String
    let description: String?
    let challengeType: ChallengeType
    let goalValue: Double
    let goalUnit: String
    let startsAt: Date
    let endsAt: Date?
    let isActive: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID       = "owner_id"
        case groupID       = "group_id"
        case slug
        case title
        case description
        case challengeType = "challenge_type"
        case goalValue     = "goal_value"
        case goalUnit      = "goal_unit"
        case startsAt      = "starts_at"
        case endsAt        = "ends_at"
        case isActive      = "is_active"
        case createdAt     = "created_at"
    }
}

struct ChallengeProgress: Codable, Identifiable, Equatable {
    var id: String { "\(challengeID.uuidString)-\(userID.uuidString)" }

    let challengeID: UUID
    let userID: UUID
    let currentValue: Double
    let completedAt: Date?
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case challengeID  = "challenge_id"
        case userID       = "user_id"
        case currentValue = "current_value"
        case completedAt  = "completed_at"
        case joinedAt     = "joined_at"
    }
}

// MARK: - Shared routes

struct SharedRoutePoint: Codable, Hashable {
    let lat: Double
    let lon: Double

    init(_ point: RidePoint) {
        self.lat = point.lat
        self.lon = point.lon
    }
    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

struct SharedRoute: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let authorID: UUID
    let rideID: UUID?
    let title: String
    let description: String?
    let distanceMeters: Double
    let visibility: SharedRouteVisibility
    let groupID: UUID?
    let hideStart: Bool
    let hideEnd: Bool
    let trimPoints: Int
    let routePoints: [SharedRoutePoint]
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case authorID       = "author_id"
        case rideID         = "ride_id"
        case title
        case description
        case distanceMeters = "distance_meters"
        case visibility
        case groupID        = "group_id"
        case hideStart      = "hide_start"
        case hideEnd        = "hide_end"
        case trimPoints     = "trim_points"
        case routePoints    = "route_points"
        case createdAt      = "created_at"
    }
}

struct SharedRouteInsert: Encodable {
    let authorID: UUID
    let rideID: UUID?
    let title: String
    let description: String?
    let distanceMeters: Double
    let visibility: SharedRouteVisibility
    let groupID: UUID?
    let hideStart: Bool
    let hideEnd: Bool
    let trimPoints: Int
    let routePoints: [SharedRoutePoint]

    enum CodingKeys: String, CodingKey {
        case authorID       = "author_id"
        case rideID         = "ride_id"
        case title
        case description
        case distanceMeters = "distance_meters"
        case visibility
        case groupID        = "group_id"
        case hideStart      = "hide_start"
        case hideEnd        = "hide_end"
        case trimPoints     = "trim_points"
        case routePoints    = "route_points"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(authorID.uuidString.lowercased(), forKey: .authorID)
        if let rideID { try c.encode(rideID.uuidString.lowercased(), forKey: .rideID) }
        try c.encode(title, forKey: .title)
        if let description { try c.encode(description, forKey: .description) }
        try c.encode(distanceMeters, forKey: .distanceMeters)
        try c.encode(visibility.rawValue, forKey: .visibility)
        if let groupID { try c.encode(groupID.uuidString.lowercased(), forKey: .groupID) }
        try c.encode(hideStart, forKey: .hideStart)
        try c.encode(hideEnd, forKey: .hideEnd)
        try c.encode(trimPoints, forKey: .trimPoints)
        try c.encode(routePoints, forKey: .routePoints)
    }
}

// MARK: - Activity feed

enum ActivityKind: String, Codable, CaseIterable {
    case rideCompleted, challengeJoined, challengeCompleted
    case maintenanceLogged, groupRideCreated, sharedRoutePosted
    case joinedGroup, bikeAdded

    var systemImage: String {
        switch self {
        case .rideCompleted:      return "flag.checkered"
        case .challengeJoined:    return "target"
        case .challengeCompleted: return "star.fill"
        case .maintenanceLogged:  return "wrench.and.screwdriver"
        case .groupRideCreated:   return "person.3"
        case .sharedRoutePosted:  return "map"
        case .joinedGroup:        return "person.2.badge.plus"
        case .bikeAdded:          return "motorcycle"
        }
    }
}

enum ActivityVisibility: String, Codable, CaseIterable {
    case followers, groups
    case publicVisible = "public"

    var displayName: String {
        switch self {
        case .followers:     return "Followers"
        case .groups:        return "Group members"
        case .publicVisible: return "Public"
        }
    }
}

struct ActivityEvent: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let actorID: UUID
    let kind: ActivityKind
    let subjectID: UUID?
    let subjectKind: String?
    let title: String?
    let summary: String?
    let visibility: ActivityVisibility
    let groupID: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case actorID     = "actor_id"
        case kind
        case subjectID   = "subject_id"
        case subjectKind = "subject_kind"
        case title
        case summary
        case visibility
        case groupID     = "group_id"
        case createdAt   = "created_at"
    }
}

struct ActivityEventInsert: Encodable {
    let actorID: UUID
    let kind: ActivityKind
    let subjectID: UUID?
    let subjectKind: String?
    let title: String?
    let summary: String?
    let visibility: ActivityVisibility
    let groupID: UUID?

    enum CodingKeys: String, CodingKey {
        case actorID     = "actor_id"
        case kind
        case subjectID   = "subject_id"
        case subjectKind = "subject_kind"
        case title
        case summary
        case visibility
        case groupID     = "group_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actorID.uuidString.lowercased(), forKey: .actorID)
        try c.encode(kind.rawValue, forKey: .kind)
        if let subjectID { try c.encode(subjectID.uuidString.lowercased(), forKey: .subjectID) }
        if let subjectKind { try c.encode(subjectKind, forKey: .subjectKind) }
        if let title { try c.encode(title, forKey: .title) }
        if let summary { try c.encode(summary, forKey: .summary) }
        try c.encode(visibility.rawValue, forKey: .visibility)
        if let groupID { try c.encode(groupID.uuidString.lowercased(), forKey: .groupID) }
    }
}

// MARK: - Errors

/// Errors surfaced to social-feature UI. Copy is user-facing; the underlying
/// Supabase message is logged separately for diagnostics.
enum SocialError: LocalizedError {
    case notSignedIn
    case notFound
    case forbidden
    case invalidJoinCode
    case alreadyMember
    case duplicateUsername
    case validation(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .notSignedIn:       return "You need to sign in to use social features."
        case .notFound:          return "We couldn't find what you were looking for."
        case .forbidden:         return "You don't have permission to do that."
        case .invalidJoinCode:   return "That join code doesn't match any group."
        case .alreadyMember:     return "You're already in this group."
        case .duplicateUsername: return "That username is already taken."
        case .validation(let m): return m
        case .unknown:           return "Something went wrong. Please try again."
        }
    }
}
