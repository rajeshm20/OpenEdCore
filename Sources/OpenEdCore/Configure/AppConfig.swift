import NIOSSL
import Vapor

enum AppConfig {
    enum DatabaseTLSMode {
        case disable
        case verifyFull
        case noVerify
    }

    static let minimumJWTSecretLength = 32
    static let defaultJWTAccessTTL: TimeInterval = 3600

    /// Industry-standard hardened cipher suites for TLS 1.2 enforcing Perfect Forward Secrecy (ECDHE)
    /// and Authenticated Encryption (AEAD: AES-GCM and ChaCha20-Poly1305).
    /// Disallows legacy CBC-mode ciphers, static RSA, RC4, 3DES, and MD5.
    static let defaultSecureCipherSuites: String = [
        "ECDHE-ECDSA-AES128-GCM-SHA256",
        "ECDHE-RSA-AES128-GCM-SHA256",
            "ECDHE-ECDSA-AES256-GCM-SHA384",
            "ECDHE-RSA-AES256-GCM-SHA384",
            "ECDHE-ECDSA-CHACHA20-POLY1305",
            "ECDHE-RSA-CHACHA20-POLY1305",
        ].joined(separator: ":")

        static func jwtAccessTTL() -> TimeInterval {
            guard let raw = Environment.get("JWT_ACCESS_TTL"), let seconds = TimeInterval(raw),
                seconds > 0
            else {
                return defaultJWTAccessTTL
            }
            return seconds
        }

        static let defaultJWTRefreshTTL: TimeInterval = 604800 // 7 days

        static func jwtRefreshTTL() -> TimeInterval {
            guard let raw = Environment.get("JWT_REFRESH_TTL"), let seconds = TimeInterval(raw),
                seconds > 0
        else {
            return defaultJWTRefreshTTL
        }
        return seconds
    }

    static func loadJWTSecret(for environment: Environment) throws -> String {
        if let secret = Environment.get("JWT_SECRET"), !secret.isEmpty {
            if environment == .production && secret.count < minimumJWTSecretLength {
                throw Abort(
                    .internalServerError,
                    reason:
                        "JWT_SECRET must be at least \(minimumJWTSecretLength) characters in production"
                )
            }
            return secret
        }   

        if environment == .testing {
            return "test-jwt-secret-at-least-32-characters-long"
        }

        throw Abort(.internalServerError, reason: "JWT_SECRET environment variable is required")
    }

    static let minimumPasswordResetSecretLength = 32

    static func loadPasswordResetSecret(for environment: Environment) throws -> String {
        if let secret = Environment.get("PASSWORD_RESET_HMAC_SECRET"), !secret.isEmpty {
            if environment == .production && secret.count < minimumPasswordResetSecretLength {
                throw Abort(
                    .internalServerError,
                    reason:
                        "PASSWORD_RESET_HMAC_SECRET must be at least \(minimumPasswordResetSecretLength) characters in production"
                )
            }
            return secret
        }

        if environment == .production {
            throw Abort(
                .internalServerError,
                reason: "PASSWORD_RESET_HMAC_SECRET environment variable is required in production"
            )
        }

        if environment == .testing || environment == .development {
            return "studentapp-reset-secret-salt-min-32-chars"
        }

        return "studentapp-reset-secret-salt-min-32-chars"
    }

    static func shouldAutoMigrate(in environment: Environment) -> Bool {
        if environment == .testing {
            return false
        }

        let flag = Environment.get("AUTO_MIGRATE")?.lowercased()
        return flag == "1" || flag == "true" || flag == "yes"
    }

    static func isGraphiQLEnabled(in environment: Environment) -> Bool {
        if environment == .production {
            return false
        }

        let flag = Environment.get("ENABLE_GRAPHIQL")?.lowercased()
        return flag == "1" || flag == "true" || flag == "yes"
    }

    static func corsAllowedOrigin(for environment: Environment) throws
        -> CORSMiddleware.AllowOriginSetting
    {
        if let raw = Environment.get("ALLOWED_ORIGIN"), !raw.isEmpty, raw != "*" {
            let origins = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if origins.count > 1 {
                return .any(origins)
            } else if let single = origins.first {
                return .custom(single)
            }
        }

        if environment == .production {
            throw Abort(
                .internalServerError,
                reason: "ALLOWED_ORIGIN must be set to an explicit origin in production"
            )
        }

        return .any([
            "http://localhost:3000",
            "http://127.0.0.1:3000",
            "http://localhost:8081",
            "http://127.0.0.1:8081"
        ])
    }

    /// Determines the minimum TLS version to enforce for TLS listeners and clients.
    /// Defaults to TLS 1.2 (.tlsv12). Supports upgrading to TLS 1.3 (.tlsv13).
    /// Strictly rejects insecure versions (TLS 1.0, TLS 1.1) in production.
    static func minimumTLSVersion(for environment: Environment) throws -> TLSVersion {
        guard
            let raw = Environment.get("TLS_MIN_VERSION")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased(),
            !raw.isEmpty
        else {
            return .tlsv12
        }

        switch raw {
        case "1.2", "tlsv12", "tlsv1.2", "tls1.2":
            return .tlsv12
        case "1.3", "tlsv13", "tlsv1.3", "tls1.3":
            return .tlsv13
        case "1.0", "1.1", "tlsv1", "tlsv1.0", "tlsv11", "tlsv1.1", "tls1.0", "tls1.1":
            if environment == .production {
                throw Abort(
                    .internalServerError,
                    reason:
                        "Insecure TLS version '\(raw)' is forbidden in production. Minimum supported version is TLS 1.2."
                )
            }
            // Clamped to TLS 1.2 for security in non-production environments
            return .tlsv12
        default:
            throw Abort(
                .internalServerError,
                reason:
                    "Unsupported TLS_MIN_VERSION: '\(raw)'. Supported values are '1.2' and '1.3'."
            )
        }
    }

    /// Returns the cipher suites string to use for TLS 1.2 negotiations.
    /// Can be overridden via TLS_CIPHER_SUITES environment variable.
    static func tlsCipherSuites(for environment: Environment) -> String {
        if let custom = Environment.get("TLS_CIPHER_SUITES")?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !custom.isEmpty
        {
            return custom
        }
        return defaultSecureCipherSuites
    }

    static func validateDatabaseConfiguration(for environment: Environment) throws {
        // Testing environment without explicit DB driver defaults to SQLite memory
        if environment == .testing && Environment.get("DB_DRIVER") == nil && Environment.get("DATABASE_DRIVER") == nil {
            return
        }

        let driver = (Environment.get("DB_DRIVER") ?? Environment.get("DATABASE_DRIVER") ?? "postgres").lowercased()
        if driver == "sqlite" {
            return
        }

        if let dbURL = Environment.get("DATABASE_URL"), !dbURL.isEmpty {
            return
        }

        // Validate discrete DB configuration variables
        guard let host = Environment.get("DATABASE_HOST"), !host.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_HOST environment variable is required")
        }

        guard let user = Environment.get("DATABASE_USER"), !user.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_USER environment variable is required")
        }

        guard let password = Environment.get("DATABASE_PASSWORD"), !password.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_PASSWORD environment variable is required")
        }

        guard let database = Environment.get("DATABASE_NAME"), !database.isEmpty else {
            throw Abort(.internalServerError, reason: "DATABASE_NAME environment variable is required")
        }

        if let portStr = Environment.get("DATABASE_PORT"), !portStr.isEmpty {
            guard Int(portStr) != nil else {
                throw Abort(.internalServerError, reason: "DATABASE_PORT must be a valid integer, got '\(portStr)'")
            }
        }
    }

    // MARK: - HSTS (HTTP Strict Transport Security)

    /// Safe rollout HSTS max-age default: 30 days (2,592,000 seconds).
    /// A conservative default avoids extended lockouts during rollout.
    /// Can be increased up to 1-2 years (e.g. 63072000) for preload list submission once fully vetted.
    static let defaultHSTSMaxAge: Int = 2_592_000

    /// Minimum max-age required by browser preload lists (1 year = 31,536,000 seconds).
    static let minimumPreloadMaxAge: Int = 31_536_000

    /// Determines whether HSTS header generation is enabled.
    /// In production, defaults to true unless explicitly disabled with HSTS_ENABLED=false/0/no/off.
    /// In non-production environments (development, testing), defaults to false to avoid unexpected caching
    /// unless explicitly enabled with HSTS_ENABLED=true/1/yes/on.
    static func isHSTSEnabled(for environment: Environment) -> Bool {
        guard
            let raw = Environment.get("HSTS_ENABLED")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
        else {
            return environment == .production
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Returns the HSTS max-age directive in seconds.
    /// Defaults to 2,592,000 (30 days rollout default). Rejects negative or non-integer values.
    static func hstsMaxAge(for environment: Environment) throws -> Int {
        guard
            let raw = Environment.get("HSTS_MAX_AGE")?.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return defaultHSTSMaxAge
        }

        guard let seconds = Int(raw), seconds >= 0 else {
            throw Abort(
                .internalServerError,
                reason: "Invalid HSTS_MAX_AGE: '\(raw)'. Must be a non-negative integer representing seconds."
            )
        }
        return seconds
    }

    /// Determines whether to include the includeSubDomains directive.
    /// Defaults to false for safe phased rollout. Requires explicit opt-in via HSTS_INCLUDE_SUBDOMAINS=true/1/yes/on.
    static func hstsIncludeSubDomains(for environment: Environment) -> Bool {
        guard
            let raw = Environment.get("HSTS_INCLUDE_SUBDOMAINS")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
        else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Determines whether to include the preload directive.
    /// Defaults to false to prevent accidental and irreversible browser preload list inclusion.
    /// Requires explicit opt-in via HSTS_PRELOAD=true/1/yes/on.
    static func hstsPreload(for environment: Environment) -> Bool {
        guard
            let raw = Environment.get("HSTS_PRELOAD")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
        else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Determines whether to trust forwarded headers (X-Forwarded-Proto, Forwarded).
    /// Defaults to true in containerized and reverse-proxy deployments where edge proxies (Caddy, ALB, Nginx) terminate TLS.
    /// Set to false (TRUST_PROXY_HEADERS=false) if the backend is exposed directly to untrusted clients.
    static func trustProxyHeaders(for environment: Environment) -> Bool {
        guard
            let raw = Environment.get("TRUST_PROXY_HEADERS")?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
        else {
            return true
        }
        return raw != "false" && raw != "0" && raw != "no" && raw != "off"
    }

    /// Constructs the Strict-Transport-Security header value based on environment settings.
    /// Returns nil if HSTS is disabled.
    static func hstsHeaderValue(for environment: Environment) throws -> String? {
        guard isHSTSEnabled(for: environment) else {
            return nil
        }

        let maxAge = try hstsMaxAge(for: environment)
        var directives = ["max-age=\(maxAge)"]

        if hstsIncludeSubDomains(for: environment) {
            directives.append("includeSubDomains")
        }

        if hstsPreload(for: environment) {
            directives.append("preload")
        }

        return directives.joined(separator: "; ")
    }

    static func validateProductionSecrets(for environment: Environment) throws {
        guard environment == .production else {
            return
        }

        try validateDatabaseConfiguration(for: environment)

        if let password = Environment.get("DATABASE_PASSWORD"),
            password == "newpassword" || password == "password"
        {
            throw Abort(
                .internalServerError,
                reason: "DATABASE_PASSWORD must not use default values in production"
            )
        }

        // Validate TLS minimum version setting
        _ = try minimumTLSVersion(for: environment)

        // Validate HTTPS certificate configuration if enabled in production
        let httpsFlag = Environment.get("ENABLE_HTTPS")?.lowercased()
        if httpsFlag == "1" || httpsFlag == "true" || httpsFlag == "yes" {
            let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
            let keyPath = Environment.get("TLS_KEY") ?? "certs/key.pem"
            if !FileManager.default.fileExists(atPath: certPath)
                || !FileManager.default.fileExists(atPath: keyPath)
            {
                throw Abort(
                    .internalServerError,
                    reason:
                        "ENABLE_HTTPS is set to true in production but TLS_CERT ('\(certPath)') or TLS_KEY ('\(keyPath)') is missing"
                )
            }
        }

        // Validate HSTS configuration if enabled in production
        if isHSTSEnabled(for: environment) {
            let maxAge = try hstsMaxAge(for: environment)

            // If preload directive is enabled, enforce preload submission eligibility requirements:
            // Chrome and Firefox require max-age >= 1 year (31,536,000s) and includeSubDomains.
            if hstsPreload(for: environment) {
                guard hstsIncludeSubDomains(for: environment) else {
                    throw Abort(
                        .internalServerError,
                        reason:
                            "HSTS_PRELOAD=true requires HSTS_INCLUDE_SUBDOMAINS=true per browser preload list requirements."
                    )
                }
                guard maxAge >= minimumPreloadMaxAge else {
                    throw Abort(
                        .internalServerError,
                        reason:
                            "HSTS_PRELOAD=true requires HSTS_MAX_AGE >= \(minimumPreloadMaxAge) (1 year) per browser preload list requirements (currently \(maxAge))."
                    )
                }
            }
        }
    }

    static func databaseTLSMode(for environment: Environment) -> DatabaseTLSMode {
        switch Environment.get("DATABASE_TLS_MODE")?.lowercased() {
        case "disable", "disabled", "off":
            return .disable
        case "insecure", "no-verify", "skip-verify":
            return .noVerify
        case "require", "verify-full", "full":
            return .verifyFull
        default:
            return environment == .production ? .verifyFull : .noVerify
        }
    }

    // MARK: - Development Certificate Auto-Renewal

    /// Determines whether development TLS certificates should be automatically generated/renewed if expired or missing.
    /// In .development, defaults to true unless explicitly disabled with AUTO_RENEW_DEV_CERTS=false/0/no/off.
    /// In .production and .testing, defaults to false (strictly prohibited in production).
    static func autoRenewDevCerts(for environment: Environment) -> Bool {
        guard environment != .production else {
            return false
        }
        guard let raw = Environment.get("AUTO_RENEW_DEV_CERTS")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return environment == .development
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    /// Number of days before certificate expiration to trigger an automated renewal warning or refresh.
    /// Defaults to 30 days. Configurable via DEV_CERT_RENEWAL_THRESHOLD_DAYS (must be non-negative).
    static func devCertRenewalThresholdDays(for environment: Environment) -> Int {
        guard let raw = Environment.get("DEV_CERT_RENEWAL_THRESHOLD_DAYS")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let days = Int(raw), days >= 0 else {
            return 30
        }
        return days
    }
}
