import Vapor
import Logging

/// Outermost request-logging middleware.
/// Logs incoming requests with HTTP method, path, client IP, and User-Agent,
/// and logs responses with HTTP status and processing duration in milliseconds.
public final class RequestLoggingMiddleware: AsyncMiddleware, @unchecked Sendable {
    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let startTime = DispatchTime.now()
        let method = request.method.rawValue
        let path = request.url.string

        let clientIP = request.headers.first(name: "X-Forwarded-For")
            ?? request.remoteAddress?.ipAddress
            ?? "unknown-ip"
        let userAgent = request.headers.first(name: .userAgent) ?? "none"

        request.logger.info("--> \(method) \(path) [Client: \(clientIP) | UA: \(userAgent)]")

        do {
            let response = try await next.respond(to: request)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            let durationString = String(format: "%.2fms", durationMs)

            let status = response.status
            if status.code >= 500 {
                request.logger.error("<-- \(method) \(path) \(status.code) \(status.reasonPhrase) (\(durationString))")
            } else if status.code >= 400 {
                request.logger.warning("<-- \(method) \(path) \(status.code) \(status.reasonPhrase) (\(durationString))")
            } else {
                request.logger.info("<-- \(method) \(path) \(status.code) \(status.reasonPhrase) (\(durationString))")
            }

            return response
        } catch {
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            let durationString = String(format: "%.2fms", durationMs)
            request.logger.error("<-- \(method) \(path) FAILED with error: \(error) (\(durationString))")
            throw error
        }
    }
}
