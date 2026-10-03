//
//  BrevoEmailService.swift
//  OpenEdCore
//
//  Created for Brevo Transactional Email API (v3) integration.
//

import Vapor
import AsyncHTTPClient

struct BrevoEmailService: EmailSending {
    let apiKey: String
    let fromEmail: String
    let fromName: String
    let httpClient: HTTPClient

    init(
        apiKey: String,
        fromEmail: String,
        fromName: String = "OpenEd School",
        httpClient: HTTPClient
    ) {
        self.apiKey = apiKey
        self.fromEmail = fromEmail
        self.fromName = fromName
        self.httpClient = httpClient
    }

    func send(to email: String, subject: String, body: String) async throws {
        var request = HTTPClientRequest(url: "https://api.brevo.com/v3/smtp/email")
        request.method = .POST
        request.headers.add(name: "api-key", value: apiKey)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "accept", value: "application/json")

        let payload: [String: Any] = [
            "sender": [
                "name": fromName,
                "email": fromEmail
            ],
            "to": [
                ["email": email]
            ],
            "subject": subject,
            "textContent": body
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.body = .bytes(jsonData)

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        guard (200...299).contains(response.status.code) else {
            var responseBody = try await response.body.collect(upTo: 1024 * 1024)
            let bodyString = responseBody.readString(length: responseBody.readableBytes) ?? "<empty body>"
            throw Abort(
                .internalServerError,
                reason: "Brevo API failed [\(response.status.code)]: \(bodyString)"
            )
        }
    }
}
