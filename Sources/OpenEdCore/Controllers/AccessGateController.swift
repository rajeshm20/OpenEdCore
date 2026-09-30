// MARK: - AccessGateController.swift
// Handles early access requests, waitlist submissions, and unique invite passcode verification.
// All access state and invite passcodes are persisted in PostgreSQL via Fluent.

import Vapor
import Fluent

struct AccessGateController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let gate = routes.grouped("gate")

        // Guest Early Access / Waitlist
        gate.post("request-access", use: handleRequestAccess)
        gate.get("access-requests", use: handleGetAccessRequests)
        gate.delete("access-requests", ":id", use: handleDeleteAccessRequest)

        // Unique Invite Passcodes
        gate.post("invite-codes", use: handleCreateInviteCode)
        gate.get("invite-codes", use: handleGetInviteCodes)
        gate.post("invite-codes", ":id", "extend", use: handleExtendInviteCode)
        gate.post("invite-codes", ":id", "revoke", use: handleRevokeInviteCode)

        // Passcode Verification & First-Use Expiry Tracking
        gate.post("verify-code", use: handleVerifyCode)
    }

    // MARK: - DTOs

    struct RequestAccessInput: Content, Sendable {
        let email: String
        let name: String?
        let role: String?
        let source: String?
        let institution: String?
        let note: String?
    }

    struct RequestAccessResponse: Content, Sendable {
        let entry: AccessRequest.Public
        let alreadyExisted: Bool
    }

    struct CreateInviteCodeInput: Content, Sendable {
        let guestEmail: String
        let role: String?
        let institution: String?
        let requestId: String?
        let validDaysFromFirstUse: Int?
    }

    struct VerifyCodeInput: Content, Sendable {
        let code: String
    }

    struct VerifyCodeResponse: Content, Sendable {
        let valid: Bool
        let isMaster: Bool?
        let isFirstUsage: Bool?
        let remainingDays: Int?
        let reason: String?
        let codeRecord: InvitePasscode.Public?
    }

    struct ExtendCodeInput: Content, Sendable {
        let additionalDays: Int?
    }

    struct StatusResponse: Content, Sendable {
        let success: Bool
        let message: String?
    }

    // MARK: - Handlers

    @Sendable
    func handleRequestAccess(_ req: Request) async throws -> RequestAccessResponse {
        let input = try req.content.decode(RequestAccessInput.self)
        let normalizedEmail = input.email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEmail.isEmpty, normalizedEmail.contains("@") else {
            throw Abort(.badRequest, reason: "A valid email address is required.")
        }

        // Check if an access request with this email already exists
        if let existing = try await AccessRequest.query(on: req.db)
            .filter(\.$email == normalizedEmail)
            .first() {
            return RequestAccessResponse(
                entry: existing.toPublic(),
                alreadyExisted: true
            )
        }

        let combinedRole = input.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = (combinedRole == nil || combinedRole!.isEmpty) ? "guest" : combinedRole!

        let newRequest = AccessRequest(
            email: normalizedEmail,
            role: role,
            source: input.source ?? "gate_request",
            institution: input.institution,
            note: input.note,
            status: "pending"
        )

        try await newRequest.save(on: req.db)
        req.logger.info("New access request saved in PostgreSQL: \(normalizedEmail) (role: \(role))")

        return RequestAccessResponse(
            entry: newRequest.toPublic(),
            alreadyExisted: false
        )
    }

    @Sendable
    func handleGetAccessRequests(_ req: Request) async throws -> [AccessRequest.Public] {
        let list = try await AccessRequest.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        return list.map { $0.toPublic() }
    }

    @Sendable
    func handleDeleteAccessRequest(_ req: Request) async throws -> StatusResponse {
        guard let idParam = req.parameters.get("id"), let uuid = UUID(uuidString: idParam) else {
            throw Abort(.badRequest, reason: "Invalid request ID")
        }

        guard let target = try await AccessRequest.find(uuid, on: req.db) else {
            throw Abort(.notFound, reason: "Access request not found")
        }

        try await target.delete(on: req.db)
        return StatusResponse(success: true, message: "Deleted access request")
    }

    @Sendable
    func handleCreateInviteCode(_ req: Request) async throws -> InvitePasscode.Public {
        let input = try req.content.decode(CreateInviteCodeInput.self)
        let cleanEmail = input.guestEmail.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanEmail.isEmpty, cleanEmail.contains("@") else {
            throw Abort(.badRequest, reason: "A valid guest email is required.")
        }

        // Return existing code if one already exists for this email
        if let existing = try await InvitePasscode.query(on: req.db)
            .filter(\.$guestEmail == cleanEmail)
            .first() {
            return existing.toPublic()
        }

        let validDays = max(1, input.validDaysFromFirstUse ?? 7)
        let uniqueCode = try await generateUniquePasscode(on: req.db)

        let record = InvitePasscode(
            code: uniqueCode,
            guestEmail: cleanEmail,
            requestId: input.requestId,
            role: input.role ?? "guest",
            institution: input.institution,
            validDaysFromFirstUse: validDays,
            firstUsedAt: nil,
            expiresAt: nil,
            useCount: 0,
            status: "unclaimed"
        )

        try await record.save(on: req.db)
        req.logger.info("Generated unique invite passcode \(uniqueCode) for \(cleanEmail) (valid: \(validDays) days from first use)")

        // If associated with an access request, mark that request as approved
        if let reqIdStr = input.requestId, let uuid = UUID(uuidString: reqIdStr) {
            if let accessReq = try await AccessRequest.find(uuid, on: req.db) {
                accessReq.status = "approved"
                try await accessReq.save(on: req.db)
            }
        }

        return record.toPublic()
    }

    @Sendable
    func handleGetInviteCodes(_ req: Request) async throws -> [InvitePasscode.Public] {
        let records = try await InvitePasscode.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        let now = Date()
        var updatedRecords: [InvitePasscode.Public] = []

        for record in records {
            // Check dynamic expiration for active passcodes
            if record.status == "active", let expires = record.expiresAt, expires <= now {
                record.status = "expired"
                try await record.save(on: req.db)
            }
            updatedRecords.append(record.toPublic())
        }

        return updatedRecords
    }

    @Sendable
    func handleVerifyCode(_ req: Request) async throws -> VerifyCodeResponse {
        let input = try req.content.decode(VerifyCodeInput.self)
        let normalized = input.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Passcode cannot be empty.")
        }

        // 1. Look up in PostgreSQL invite_codes
        if let target = try await InvitePasscode.query(on: req.db)
            .filter(\.$code == normalized)
            .first() {

            if target.status == "revoked" {
                throw Abort(.forbidden, reason: "This invite passcode has been revoked. Contact the school administrator.")
            }

            let now = Date()

            // Case A: First time this passcode is being used!
            if target.firstUsedAt == nil || target.status == "unclaimed" {
                let expiryDate = now.addingTimeInterval(Double(target.validDaysFromFirstUse * 86400))
                target.firstUsedAt = now
                target.expiresAt = expiryDate
                target.status = "active"
                target.useCount = 1
                try await target.save(on: req.db)

                req.logger.notice("Passcode \(normalized) activated on first use by \(target.guestEmail). Expires in \(target.validDaysFromFirstUse) days.")

                return VerifyCodeResponse(
                    valid: true,
                    isMaster: false,
                    isFirstUsage: true,
                    remainingDays: target.validDaysFromFirstUse,
                    reason: nil,
                    codeRecord: target.toPublic()
                )
            }

            // Case B: Passcode was already unlocked previously - verify expiration
            if let expiresAt = target.expiresAt {
                if now > expiresAt {
                    target.status = "expired"
                    try await target.save(on: req.db)
                    throw Abort(.forbidden, reason: "This invite passcode has expired. Please contact the administrator.")
                }

                // Still valid! Calculate remaining days
                let remainingSeconds = expiresAt.timeIntervalSince(now)
                let remainingDays = max(1, Int(ceil(remainingSeconds / 86400)))

                target.useCount += 1
                try await target.save(on: req.db)

                return VerifyCodeResponse(
                    valid: true,
                    isMaster: false,
                    isFirstUsage: false,
                    remainingDays: remainingDays,
                    reason: nil,
                    codeRecord: target.toPublic()
                )
            }

            return VerifyCodeResponse(
                valid: true,
                isMaster: false,
                isFirstUsage: false,
                remainingDays: target.validDaysFromFirstUse,
                reason: nil,
                codeRecord: target.toPublic()
            )
        }

        // 2. Fallback: Check staging master code
        let masterCode = (Environment.get("STAGING_INVITE_CODE") ?? "OPENED2026").uppercased()
        if normalized == masterCode {
            return VerifyCodeResponse(
                valid: true,
                isMaster: true,
                isFirstUsage: false,
                remainingDays: 7,
                reason: nil,
                codeRecord: nil
            )
        }

        throw Abort(.unauthorized, reason: "Invalid invite passcode.")
    }

    @Sendable
    func handleExtendInviteCode(_ req: Request) async throws -> InvitePasscode.Public {
        guard let idParam = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing code ID or code string")
        }

        let input = try? req.content.decode(ExtendCodeInput.self)
        let additionalDays = input?.additionalDays ?? 7

        var target: InvitePasscode?

        if let uuid = UUID(uuidString: idParam) {
            target = try await InvitePasscode.find(uuid, on: req.db)
        }
        if target == nil {
            target = try await InvitePasscode.query(on: req.db)
                .filter(\.$code == idParam.uppercased())
                .first()
        }

        guard let record = target else {
            throw Abort(.notFound, reason: "Invite passcode not found")
        }

        let baseDate = record.expiresAt.map { max($0, Date()) } ?? Date()
        record.expiresAt = baseDate.addingTimeInterval(Double(additionalDays * 86400))
        record.validDaysFromFirstUse += additionalDays
        record.status = "active"

        try await record.save(on: req.db)
        req.logger.notice("Passcode \(record.code) extended by +\(additionalDays) days.")

        return record.toPublic()
    }

    @Sendable
    func handleRevokeInviteCode(_ req: Request) async throws -> StatusResponse {
        guard let idParam = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing code ID or code string")
        }

        var target: InvitePasscode?

        if let uuid = UUID(uuidString: idParam) {
            target = try await InvitePasscode.find(uuid, on: req.db)
        }
        if target == nil {
            target = try await InvitePasscode.query(on: req.db)
                .filter(\.$code == idParam.uppercased())
                .first()
        }

        guard let record = target else {
            throw Abort(.notFound, reason: "Invite passcode not found")
        }

        record.status = "revoked"
        try await record.save(on: req.db)
        req.logger.notice("Passcode \(record.code) has been revoked.")

        return StatusResponse(success: true, message: "Passcode revoked successfully")
    }

    // MARK: - Helpers

    private func generateUniquePasscode(on db: any Database) async throws -> String {
        let chars = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

        for _ in 0..<10 {
            var part1 = ""
            var part2 = ""
            for _ in 0..<4 {
                part1.append(chars.randomElement()!)
                part2.append(chars.randomElement()!)
            }
            let candidate = "SCH-\(part1)-\(part2)"

            let existing = try await InvitePasscode.query(on: db)
                .filter(\.$code == candidate)
                .first()

            if existing == nil {
                return candidate
            }
        }

        return "SCH-\(UUID().uuidString.prefix(4))-\(UUID().uuidString.suffix(4))".uppercased()
    }
}
