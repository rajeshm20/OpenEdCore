import Vapor
import AsyncHTTPClient

/// Mailpit implementation for local development and testing (https://github.com/axllent/mailpit).
/// Dispatches transactional messages directly via Mailpit's REST API (`POST /api/v1/send`).
/// Uses Vapor's built-in `AsyncHTTPClient` so no extra SMTP package dependencies are required.
struct MailpitEmailService: EmailSending {
    let host: String
    let port: Int
    let fromEmail: String
    let fromName: String
    let httpClient: HTTPClient

    init(
        host: String = "localhost",
        port: Int = 8025,
        fromEmail: String = "noreply@openedschool.com",
        fromName: String = "OpenEd School",
        httpClient: HTTPClient
    ) {
        self.host = host
        self.port = port
        self.fromEmail = fromEmail
        self.fromName = fromName
        self.httpClient = httpClient
    }

    func send(to email: String, subject: String, body: String) async throws {
        var request = HTTPClientRequest(url: "http://\(host):\(port)/api/v1/send")
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")

        let payload: [String: Any] = [
            "From": [
                "Email": fromEmail,
                "Name": fromName
            ],
            "To": [
                ["Email": email]
            ],
            "Subject": subject,
            "Text": body
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.body = .bytes(jsonData)

        let response = try await httpClient.execute(request, timeout: .seconds(5))
        guard (200...299).contains(response.status.code) else {
            var respBody = try await response.body.collect(upTo: 1024 * 1024)
            let bodyString = respBody.readString(length: respBody.readableBytes) ?? "<empty body>"
            throw Abort(
                .internalServerError,
                reason: "Mailpit failed [\(response.status.code)]: \(bodyString)"
            )
        }
    }
}

/// Fallback email wrapper that attempts delivery via primary provider,
/// and automatically delegates to fallback on failure (e.g. SendGrid -> Mailpit -> Console in dev).
struct FallbackEmailService: EmailSending {
    let primary: any EmailSending
    let fallback: any EmailSending
    let logger: Logger

    init(primary: any EmailSending, fallback: any EmailSending, logger: Logger) {
        self.primary = primary
        self.fallback = fallback
        self.logger = logger
    }

    func send(to email: String, subject: String, body: String) async throws {
        do {
            try await primary.send(to: email, subject: subject, body: body)
        } catch {
            logger.warning("Primary email service failed (\(error)). Falling back to secondary email provider...")
            try await fallback.send(to: email, subject: subject, body: body)
        }
    }
}
