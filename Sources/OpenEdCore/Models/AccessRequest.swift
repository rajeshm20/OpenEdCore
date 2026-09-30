// MARK: - AccessRequest.swift
// Domain model for early access requests and landing page waitlist entries.
// Persisted in PostgreSQL via Fluent.

import Vapor
import Fluent

final class AccessRequest: Model, Content, @unchecked Sendable {
    static let schema = "access_requests"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "role")
    var role: String

    @Field(key: "source")
    var source: String // "gate_request" or "waitlist_page"

    @OptionalField(key: "institution")
    var institution: String?

    @OptionalField(key: "note")
    var note: String?

    @Field(key: "status")
    var status: String // "pending", "invited", "approved", "rejected"

    @Timestamp(key: "createdAt", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updatedAt", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        role: String = "general",
        source: String = "gate_request",
        institution: String? = nil,
        note: String? = nil,
        status: String = "pending"
    ) {
        self.id = id
        self.email = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.source = source
        self.institution = institution
        self.note = note
        self.status = status
    }

    // MARK: - Public JSON Representation
    struct Public: Content, Sendable {
        let id: String
        let email: String
        let role: String
        let source: String
        let institution: String?
        let note: String?
        let timestamp: String
        let status: String
    }

    func toPublic() -> Public {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let dateString = createdAt.map { formatter.string(from: $0) } ?? formatter.string(from: Date())

        return Public(
            id: id?.uuidString ?? UUID().uuidString,
            email: email,
            role: role,
            source: source,
            institution: institution,
            note: note,
            timestamp: dateString,
            status: status
        )
    }
}
