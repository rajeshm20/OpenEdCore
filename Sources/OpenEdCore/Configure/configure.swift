import Fluent
import FluentMySQLDriver
import FluentPostgresDriver
import FluentSQLiteDriver
import JWT
import JWTKit
import Logging
import NIOSSL
import SQLKit
import Vapor

extension Application {
    private struct EmailServiceKey: StorageKey {
        typealias Value = EmailSending
    }

    var emailService: any EmailSending {
        get {
            guard let service = storage[EmailServiceKey.self] else {
                fatalError("EmailService not configured")
            }
            return service
        }
        set { storage[EmailServiceKey.self] = newValue }
    }
}

private func shouldEnableTLS(certPath: String, keyPath: String) -> Bool {
    let flag = Environment.get("ENABLE_HTTPS")?.lowercased()
    let tlsRequested = flag == "1" || flag == "true" || flag == "yes"
    let hasTLSFiles =
        FileManager.default.fileExists(atPath: certPath)
        && FileManager.default.fileExists(atPath: keyPath)
    return tlsRequested && hasTLSFiles
}

func databaseTLSConfiguration(for environment: Environment) -> TLSConfiguration? {
    switch AppConfig.databaseTLSMode(for: environment) {
    case .disable:
        return nil
    case .verifyFull:
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        tls.minimumTLSVersion = (try? AppConfig.minimumTLSVersion(for: environment)) ?? .tlsv12
        tls.cipherSuites = AppConfig.tlsCipherSuites(for: environment)
        return tls
    case .noVerify:
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .none
        tls.minimumTLSVersion = (try? AppConfig.minimumTLSVersion(for: environment)) ?? .tlsv12
        tls.cipherSuites = AppConfig.tlsCipherSuites(for: environment)
        return tls
    }
}

private func configureDatabase(_ app: Application) throws {
    let driver = (Environment.get("DB_DRIVER") ?? Environment.get("DATABASE_DRIVER") ?? "postgres")
        .lowercased()

    if (app.environment == .testing && Environment.get("TEST_USE_EXTERNAL_DB") != "true")
        || driver == "sqlite"
    {
        app.databases.use(.sqlite(.memory), as: .sqlite, isDefault: true)
        return
    }

    switch driver {
    case "postgres", "psql", "postgresql":
        if let dbURL = Environment.get("DATABASE_URL"), !dbURL.isEmpty {
            try app.databases.use(
                .postgres(
                    url: dbURL,
                    maxConnectionsPerEventLoop: 8,
                    connectionPoolTimeout: .seconds(10)
                ),
                as: .psql,
                isDefault: true
            )
            return
        }

        guard let host = Environment.get("DATABASE_HOST"), !host.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_HOST environment variable is required")
        }
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? 5432
        if port == 3306 {
            app.logger.warning(
                "DATABASE_PORT is set to 3306 (MySQL default port) while DB_DRIVER is postgres! Ensure you connect to PostgreSQL on port 5432."
            )
        }
        guard let user = Environment.get("DATABASE_USER"), !user.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_USER environment variable is required")
        }
        guard let password = Environment.get("DATABASE_PASSWORD"), !password.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_PASSWORD environment variable is required")
        }
        guard let database = Environment.get("DATABASE_NAME"), !database.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_NAME environment variable is required")
        }

        let tlsConfig: PostgresConnection.Configuration.TLS
        switch AppConfig.databaseTLSMode(for: app.environment) {
        case .disable:
            tlsConfig = .disable
        case .verifyFull:
            if let tls = databaseTLSConfiguration(for: app.environment) {
                let sslContext = try NIOSSLContext(configuration: tls)
                tlsConfig = .require(sslContext)
            } else {
                tlsConfig = .disable
            }
        case .noVerify:
            if let tls = databaseTLSConfiguration(for: app.environment) {
                let sslContext = try NIOSSLContext(configuration: tls)
                tlsConfig = .prefer(sslContext)
            } else {
                tlsConfig = .disable
            }
        }

        let postgresConfig = SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: user,
            password: password,
            database: database,
            tls: tlsConfig
        )
        app.databases.use(
            .postgres(
                configuration: postgresConfig,
                maxConnectionsPerEventLoop: 8,
                connectionPoolTimeout: .seconds(10)
            ),
            as: .psql,
            isDefault: true
        )

    case "mysql":
        guard let host = Environment.get("DATABASE_HOST"), !host.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_HOST environment variable is required")
        }
        let port =
            Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
            ?? MySQLConfiguration.ianaPortNumber
        guard let user = Environment.get("DATABASE_USER"), !user.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_USER environment variable is required")
        }
        guard let password = Environment.get("DATABASE_PASSWORD"), !password.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_PASSWORD environment variable is required")
        }
        guard let database = Environment.get("DATABASE_NAME"), !database.isEmpty else {
            throw Abort(
                .internalServerError, reason: "DATABASE_NAME environment variable is required")
        }

        app.databases.use(
            .mysql(
                hostname: host,
                port: port,
                username: user,
                password: password,
                database: database,
                tlsConfiguration: databaseTLSConfiguration(for: app.environment),
                maxConnectionsPerEventLoop: 8,
                connectionPoolTimeout: .seconds(10)
            ), as: .mysql, isDefault: true)

    default:
        throw Abort(
            .internalServerError,
            reason:
                "Unsupported DB_DRIVER: '\(driver)'. Supported values: 'postgres', 'mysql', 'sqlite'."
        )
    }
}

private func configureMiddleware(_ app: Application) throws {
    // Configure log level: reads LOG_LEVEL env var (e.g. debug, info, notice, warning, error),
    // defaulting to .info in development/testing and .notice in production.
    if let logLevelStr = Environment.get("LOG_LEVEL")?.lowercased(),
        let level = Logger.Level(rawValue: logLevelStr)
    {
        app.logger.logLevel = level
    } else {
        app.logger.logLevel = app.environment == .production ? .notice : .info
    }

    let corsConfig = CORSMiddleware.Configuration(
        allowedOrigin: try AppConfig.corsAllowedOrigin(for: app.environment),
        allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith],
        allowCredentials: true
    )

    // Reset default middleware to replace Vapor's default ErrorMiddleware with UnifiedErrorMiddleware
    app.middleware = .init()

    // 1. RequestLoggingMiddleware: Outermost middleware logs every incoming request from mobile/web clients
    // and outgoing responses with latency, HTTP status code, client IP, and User-Agent.
    app.middleware.use(RequestLoggingMiddleware())

    // 2. CORSMiddleware: Placed before error handling so that 4xx/5xx error responses contain proper CORS headers.
    app.middleware.use(CORSMiddleware(configuration: corsConfig))

    // 3. SecurityHeadersMiddleware: Sets security headers on all responses (including errors and HTTPS HSTS).
    app.middleware.use(SecurityHeadersMiddleware(environment: app.environment))

    // 4. UnifiedErrorMiddleware: Formats all 4xx/5xx responses into the standardized error envelope.
    app.middleware.use(UnifiedErrorMiddleware(environment: app.environment))

    // 5. RateLimiterMiddleware: Throttles bursts and brute-force attempts.
    app.middleware.use(RateLimiterMiddleware())
}

private func configureJWT(_ app: Application) throws {
    let jwtSecret = try AppConfig.loadJWTSecret(for: app.environment)
    app.jwt.signers.use(.hs256(key: jwtSecret.data(using: .utf8)!))
    _ = try AppConfig.loadPasswordResetSecret(for: app.environment)
}

private func configureEmail(_ app: Application) {
    let fromEmail = Environment.get("FROM_EMAIL") ?? "noreply@openedschool.com"
    let provider = Environment.get("EMAIL_PROVIDER")?.lowercased()
    let mailpitHost = Environment.get("MAILPIT_HOST") ?? "localhost"
    let mailpitPort = Environment.get("MAILPIT_PORT").flatMap(Int.init) ?? 8025

    let mailpitService = MailpitEmailService(
        host: mailpitHost,
        port: mailpitPort,
        fromEmail: fromEmail,
        httpClient: app.http.client.shared
    )
    let consoleService = ConsoleEmailService(logger: app.logger)

    // Explicit Mailpit mode
    if provider == "mailpit" {
        app.logger.info(
            "Using Mailpit email service at http://\(mailpitHost):\(mailpitPort) with Console fallback"
        )
        app.emailService = FallbackEmailService(
            primary: mailpitService,
            fallback: consoleService,
            logger: app.logger
        )
        return
    }

    // Explicit Console mode
    if provider == "console" {
        app.logger.info("Using Console email logging")
        app.emailService = consoleService
        return
    }

    // Brevo configured
    if provider == "brevo" || Environment.get("BREVO_API_KEY") != nil,
        let brevoKey = Environment.get("BREVO_API_KEY"),
        !brevoKey.trimmingCharacters(in: .whitespaces).isEmpty,
        !brevoKey.contains("your_brevo_api_key")
    {
        let brevoService = BrevoEmailService(
            apiKey: brevoKey,
            fromEmail: fromEmail,
            httpClient: app.http.client.shared
        )
        if app.environment == .development || app.environment == .testing {
            let devFallback = FallbackEmailService(
                primary: mailpitService,
                fallback: consoleService,
                logger: app.logger
            )
            app.emailService = FallbackEmailService(
                primary: brevoService,
                fallback: devFallback,
                logger: app.logger
            )
        } else {
            app.logger.info("Using Brevo email service (from: \(fromEmail))")
            app.emailService = brevoService
        }
        return
    }

    // SendGrid configured
    if let sendGridKey = Environment.get("SENDGRID_API_KEY"),
        !sendGridKey.trimmingCharacters(in: .whitespaces).isEmpty,
        !sendGridKey.contains("your_sendgrid_api_key")
    {
        let sendGridService = SendGridEmailService(
            apiKey: sendGridKey,
            fromEmail: fromEmail,
            httpClient: app.http.client.shared
        )

        if app.environment == .development || app.environment == .testing {
            // In dev/testing: Primary is SendGrid, but if it fails (invalid key, rate limit, offline),
            // seamlessly fall back to Mailpit, and then to Console.
            let devFallback = FallbackEmailService(
                primary: mailpitService,
                fallback: consoleService,
                logger: app.logger
            )
            app.emailService = FallbackEmailService(
                primary: sendGridService,
                fallback: devFallback,
                logger: app.logger
            )
        } else {
            app.emailService = sendGridService
        }
    } else {
        if app.environment == .development || app.environment == .testing {
            app.logger.info(
                "SENDGRID_API_KEY not configured — using Mailpit (http://\(mailpitHost):\(mailpitPort)) with Console fallback"
            )
            app.emailService = FallbackEmailService(
                primary: mailpitService,
                fallback: consoleService,
                logger: app.logger
            )
        } else {
            app.logger.warning(
                "SENDGRID_API_KEY not set in production — falling back to console email logging")
            app.emailService = consoleService
        }
    }
}

private func configureMigrations(_ app: Application) throws {
    // Reconcile legacy migration history if project was renamed from StudentAppBackend to OpenEdCore
    if let sql = app.db as? any SQLDatabase {
        _ = try? sql.raw(
            """
                UPDATE _fluent_migrations 
                SET name = REPLACE(name, 'StudentAppBackend.', 'OpenEdCore.') 
                WHERE name LIKE 'StudentAppBackend.%';
            """
        ).run().wait()
    }

    app.migrations.add(CreateStudent())
    app.migrations.add(CreateRevokedToken())
    app.migrations.add(CreatePasswordResetToken())
    // Phase 2: Role, status, firstName, lastName, countryCode, contactNumber (E.164), timestamps
    app.migrations.add(AddRoleStatusPhoneToStudents())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(HardenPasswordResetTokens())
    app.migrations.add(CreateAccessRequest())
    app.migrations.add(CreateInvitePasscode())

    if AppConfig.shouldAutoMigrate(in: app.environment) {
        app.logger.notice("AUTO_MIGRATE enabled — running migrations on startup")
        try app.autoMigrate().wait()
    } else if app.environment == .production {
        app.logger.notice(
            "Skipping autoMigrate in production — run the migrate command before starting the app")
    }
}

func configureTLS(_ app: Application) throws {
    guard app.environment != .testing else {
        return
    }

    let certPath = Environment.get("TLS_CERT") ?? "certs/cert.pem"
    let keyPath = Environment.get("TLS_KEY") ?? "certs/key.pem"

    let flag = Environment.get("ENABLE_HTTPS")?.lowercased()
    let tlsRequested = flag == "1" || flag == "true" || flag == "yes"

    // In development environments, run certificate pre-flight check if HTTPS is requested
    if tlsRequested && app.environment == .development {
        _ = try? CertificateManager.ensureDevelopmentCertificates(app: app)
    }

    let tlsEnabled = shouldEnableTLS(certPath: certPath, keyPath: keyPath)

    #if DEBUG
        app.logger.debug(
            "TLS cert path: \(certPath), exists: \(FileManager.default.fileExists(atPath: certPath))"
        )
        app.logger.debug(
            "TLS key path: \(keyPath), exists: \(FileManager.default.fileExists(atPath: keyPath))")
    #endif

    guard tlsEnabled else {
        app.logger.notice("HTTPS disabled. Starting server on HTTP.")
        return
    }

    do {
        let certs = try NIOSSLCertificate.fromPEMFile(certPath).map {
            NIOSSLCertificateSource.certificate($0)
        }
        let nioPrivateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        let minTLSVersion = try AppConfig.minimumTLSVersion(for: app.environment)
        let cipherSuites = AppConfig.tlsCipherSuites(for: app.environment)

        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: .privateKey(nioPrivateKey)
        )
        tls.minimumTLSVersion = minTLSVersion
        tls.cipherSuites = cipherSuites

        app.http.server.configuration.tlsConfiguration = tls
        app.logger.notice(
            "Loaded \(certs.count) TLS certificate(s). Enforcing minimum TLS version: \(minTLSVersion) with hardened cipher suites."
        )
    } catch {
        if app.environment == .production {
            app.logger.error("Failed to configure TLS in production: \(error)")
            throw error
        } else {
            app.logger.warning(
                "TLS certificates could not be loaded. Continuing without HTTPS: \(error)")
        }
    }
}

public func configure(_ app: Application) throws {
    try AppConfig.validateProductionSecrets(for: app.environment)
    try configureDatabase(app)
    try configureMiddleware(app)
    try configureJWT(app)
    configureEmail(app)
    try configureTLS(app)
    try configureMigrations(app)
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080
    try routes(app)
}

#if DEBUG
    public func main() async throws {
        try await configure(Application.make())
    }
#endif
