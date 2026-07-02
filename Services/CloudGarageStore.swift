import Foundation
import Supabase
import UIKit

struct CloudGarageStore {
    private let client  = SupabaseManager.shared.client
    private let storage = CloudStorageService()

    // MARK: - Upsert bike + optional photo

    func syncBike(_ bike: GarageBike, userID: UUID, photo: UIImage? = nil) async throws -> UUID {
        let payload = BikeUpsertPayload(bike: bike, userID: userID)

        struct ReturnedID: Decodable { let id: UUID }
        let returned: ReturnedID = try await client
            .from("bikes")
            .upsert(payload, onConflict: "user_id,local_id")
            .select("id")
            .single()
            .execute()
            .value

        if let photo {
            let path = photoStoragePath(userID: userID, bikeID: bike.id)
            try await storage.uploadPhoto(photo, path: path, bucket: "bike-photos")
        }

        return returned.id
    }

    // MARK: - Bulk upsert (used by "Re-sync All Data")

    /// Batched variant of `syncBike` for the DB row only. Photos are
    /// left to the caller so they can be uploaded concurrently while
    /// the row upsert is one round trip regardless of bike count.
    /// Returns a `local_id → remote_id` map so the caller can update
    /// `updateCloudInfo` per bike. Chunks at 100 rows to stay well
    /// under PostgREST's default 1MB body limit.
    func syncBikesBulk(_ bikes: [GarageBike], userID: UUID) async throws -> [UUID: UUID] {
        guard !bikes.isEmpty else { return [:] }

        struct Returned: Decodable { let id: UUID; let localId: UUID
            enum CodingKeys: String, CodingKey { case id; case localId = "local_id" }
        }

        var remoteByLocal: [UUID: UUID] = [:]
        let chunks = bikes.chunked(into: 100)
        for chunk in chunks {
            let payloads = chunk.map { BikeUpsertPayload(bike: $0, userID: userID) }
            let returned: [Returned] = try await client
                .from("bikes")
                .upsert(payloads, onConflict: "user_id,local_id")
                .select("id, local_id")
                .execute()
                .value
            for row in returned { remoteByLocal[row.localId] = row.id }
        }
        return remoteByLocal
    }

    // MARK: - Photo helpers

    func createSignedPhotoURL(userID: UUID, bikeID: UUID) async throws -> URL {
        let path = photoStoragePath(userID: userID, bikeID: bikeID)
        return try await storage.createSignedURL(path: path, bucket: "bike-photos")
    }

    func deleteBike(remoteID: UUID, deletePhoto: Bool, userID: UUID, bikeID: UUID) async throws {
        try await client.from("bikes").delete().eq("id", value: remoteID.uuidString).execute()
        if deletePhoto {
            try? await storage.deleteObject(path: photoStoragePath(userID: userID, bikeID: bikeID),
                                            bucket: "bike-photos")
        }
    }

    // MARK: - Path helpers

    func photoStoragePath(userID: UUID, bikeID: UUID) -> String {
        "\(userID.uuidString)/bikes/\(bikeID.uuidString)/photo.jpg"
    }
}

// MARK: - Batching helper

extension Array {
    /// Splits into fixed-size chunks. Used by the cloud stores to keep
    /// individual PostgREST bodies below the ~1MB limit and Postgres
    /// statements below the reasonable-lock window.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - DB payload

private struct BikeUpsertPayload: Encodable {
    let userId: UUID
    let localId: UUID
    let nickname: String
    let year: Int?
    let make: String
    let model: String
    let notes: String?
    let odometerMiles: Double?
    let isDefault: Bool
    let isArchived: Bool
    let photoPath: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case localId = "local_id"
        case nickname, year, make, model, notes
        case odometerMiles = "odometer_miles"
        case isDefault = "is_default"
        case isArchived = "is_archived"
        case photoPath = "photo_path"
        case createdAt = "created_at"
    }

    init(bike: GarageBike, userID: UUID) {
        userId       = userID
        localId      = bike.id
        nickname     = bike.nickname
        year         = bike.year
        make         = bike.make
        model        = bike.model
        notes        = bike.notes
        odometerMiles = bike.odometerMiles
        isDefault    = bike.effectiveIsDefault
        isArchived   = bike.effectiveIsArchived
        photoPath    = bike.cloudPhotoPath
        createdAt    = bike.createdAt
    }
}
