// MARK: - InvitePasscode.swift
// Domain model for unique guest access passcodes with first-use expiration tracking.
// Persisted in PostgreSQL via Fluent.

import Vapor
import Fluent

final class InvitePasscode: Model, Content, @unchecked Sendable {
    static let schema = "invite_codes"

    @ID(key: .id)
    var id: UUID?

    /// Unique passcode string, e.g. "SCH-7K9M-4W2P"
    @Field(key: "code")
    var code: String

    @Field(key: "guestEmail")
    var guestEmail: String

    @OptionalField(key: "requestId")
    var requestId: String?

    @Field(key: "role")
    var role: String

    @OptionalField(key: "institution")
    var institution: String?

    /// Duration in days once guest redeems passcode for the first time
    @Field(key: "validDaysFromFirstUse")
    var validDaysFromFirstUse: Int

    /// First redemption timestamp (nil until unlocked at access-gate)
    @OptionalField(key: "firstUsedAt")
    var firstUsedAt: Date?

    /// Computed expiration timestamp: firstUsedAt + (validDaysFromFirstUse * 86400)
    @OptionalField(key: "expiresAt")
    var expiresAt: Date?

    @Field(key: "useCount")
    var useCount: Int

    /// Status: "unclaimed" (never used), "active" (first-use clock running), "expired", "revoked"
    @Field(key: "status")
    var status: String

    @Timestamp(key: "createdAt", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updatedAt", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        code: String,
        guestEmail: String,
        requestId: String? = nil,
        role: String = "guest",
        institution: String? = nil,
        validDaysFromFirstUse: Int = 7,
        firstUsedAt: Date? = nil,
        expiresAt: Date? = nil,
        useCount: Int = 0,
        status: String = "unclaimed"
    ) {
        self.id = id
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.guestEmail = guestEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestId = requestId
        self.role = role
        self.institution = institution
        self.validDaysFromFirstUse = validDaysFromFirstUse
        self.firstUsedAt = firstUsedAt
        self.expiresAt = expiresAt
        self.useCount = useCount
        self.status = status
    }

    // MARK: - Public JSON Representation
    struct Public: Content, Sendable {
        let id: String
        let code: String
        let guestEmail: String
        let requestId: String?
        let role: String
        let institution: String?
        let validDaysFromFirstUse: Int
        let firstUsedAt: String?
        let expiresAt: String?
        let createdAt: String
        let useCount: Int
        let status: String
    }

    func toPublic() -> Public {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let createdStr = createdAt.map { formatter.string(from: $0) } ?? formatter.string(from: Date())
        let firstUsedStr = firstUsedAt.map { formatter.string(from: $0) }
        let expiresStr = expiresAt.map { formatter.string(from: $0) }

        return Public(
            id: id?.uuidString ?? UUID().uuidString,
            code: code,
            guestEmail: guestEmail,
            requestId: requestId,
            role: role,
            institution: institution,
            validDaysFromFirstUse: validDaysFromFirstUse,
            firstUsedAt: firstUsedStr,
            expiresAt: expiresStr,
            createdAt: createdStr,
            useCount: useCount,
            status: status
        )
    }
}
