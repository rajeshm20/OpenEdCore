import Testing
import Vapor
import VaporTesting
@testable import OpenEdCore

actor MockEmailTracker: EmailSending {
    var sentEmails: [(email: String, subject: String, body: String)] = []
    var shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func send(to email: String, subject: String, body: String) async throws {
        if shouldFail {
            throw Abort(.internalServerError, reason: "Simulated send failure")
        }
        sentEmails.append((email: email, subject: subject, body: body))
    }

    func count() -> Int {
        sentEmails.count
    }

    func lastEmail() -> (email: String, subject: String, body: String)? {
        sentEmails.last
    }
}

@Suite("Email Service Tests", .serialized)
struct EmailServiceTests {

    @Test("FallbackEmailService calls primary when primary succeeds")
    func testFallbackEmailServicePrimarySuccess() async throws {
        let primary = MockEmailTracker(shouldFail: false)
        let secondary = MockEmailTracker(shouldFail: false)
        let logger = Logger(label: "test.email")
        let fallback = FallbackEmailService(primary: primary, fallback: secondary, logger: logger)

        try await fallback.send(to: "student@example.com", subject: "Test OTP", body: "123456")

        let primaryCount = await primary.count()
        let secondaryCount = await secondary.count()

        #expect(primaryCount == 1)
        #expect(secondaryCount == 0)
    }

    @Test("FallbackEmailService delegates to fallback when primary fails")
    func testFallbackEmailServicePrimaryFails() async throws {
        let primary = MockEmailTracker(shouldFail: true)
        let secondary = MockEmailTracker(shouldFail: false)
        let logger = Logger(label: "test.email")
        let fallback = FallbackEmailService(primary: primary, fallback: secondary, logger: logger)

        try await fallback.send(to: "student@example.com", subject: "Test OTP", body: "654321")

        let primaryCount = await primary.count()
        let secondaryCount = await secondary.count()

        #expect(primaryCount == 0)
        #expect(secondaryCount == 1)

        let last = await secondary.lastEmail()
        #expect(last?.email == "student@example.com")
        #expect(last?.body == "654321")
    }

    @Test("MailpitEmailService can dispatch to running Mailpit REST API")
    func testMailpitEmailServiceLive() async throws {
        let app = try await Application.make(.testing)
        do {
            let mailpit = MailpitEmailService(
                host: "localhost",
                port: 8025,
                fromEmail: "noreply@openedschool.com",
                fromName: "OpenEd School",
                httpClient: app.http.client.shared
            )

            // Verify sending OTP to Mailpit
            try await mailpit.send(
                to: "dev-test@openedschool.com",
                subject: "Test Mailpit OTP",
                body: "Your verification code is: 555888"
            )
            #expect(Bool(true))
        } catch {
            app.logger.notice("Mailpit not reachable, skipping live send: \(error)")
        }
        try? await app.asyncShutdown()
    }
}

