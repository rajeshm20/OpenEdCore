// MARK: - CreateAccessRequest.swift
// Fluent migration creating access_requests table in PostgreSQL.

import Fluent

struct CreateAccessRequest: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("access_requests")
            .id()
            .field("email", .string, .required)
            .field("role", .string, .required)
            .field("source", .string, .required)
            .field("institution", .string)
            .field("note", .string)
            .field("status", .string, .required)
            .field("createdAt", .datetime)
            .field("updatedAt", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("access_requests").delete()
    }
}
