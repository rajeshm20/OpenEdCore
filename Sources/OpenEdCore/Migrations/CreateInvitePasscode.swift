// MARK: - CreateInvitePasscode.swift
// Fluent migration creating invite_codes table in PostgreSQL.

import Fluent

struct CreateInvitePasscode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("invite_codes")
            .id()
            .field("code", .string, .required)
            .unique(on: "code")
            .field("guestEmail", .string, .required)
            .field("requestId", .string)
            .field("role", .string, .required)
            .field("institution", .string)
            .field("validDaysFromFirstUse", .int, .required)
            .field("firstUsedAt", .datetime)
            .field("expiresAt", .datetime)
            .field("useCount", .int, .required)
            .field("status", .string, .required)
            .field("createdAt", .datetime)
            .field("updatedAt", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("invite_codes").delete()
    }
}
