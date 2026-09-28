// MARK: - GraphQLAPI.swift
// GraphQL schema, resolvers, and types.
// Authorization rules must be IDENTICAL to REST endpoints — enforced via AuthorizationService.
// Never create a situation where REST enforces auth but GraphQL bypasses it.

import Fluent
import Graphiti
@preconcurrency import GraphQL
import JWTKit
import Vapor

// MARK: - GraphQL Request Body

struct GraphQLRequestBody: Content, @unchecked Sendable {
    let query: String
    let operationName: String?
    let variables: [String: Map]?

    func graphQLRequest() -> GraphQLRequest {
        GraphQLRequest(
            query: query,
            operationName: operationName,
            variables: variables ?? [:]
        )
    }
}

// MARK: - GraphQL Resolver

struct GraphQLResolver {
    private let studentRepository: any StudentRepository
    private let studentService: any StudentServiceProtocol

    init(
        studentRepository: any StudentRepository = DatabaseStudentRepository(),
        studentService: any StudentServiceProtocol = StudentService.shared
    ) {
        self.studentRepository = studentRepository
        self.studentService = studentService
    }

    // MARK: - Queries

    /// Fetches students based on the authenticated user's role.
    /// Authorization: same policy as REST GET /students — scoped by role via AuthorizationService.
    func students(request: Request, arguments: NoArguments) throws -> EventLoopFuture<[Student.Public]> {
        let repo = self.studentRepository
        return request.eventLoop.makeFutureWithTask {
            let requester = try await TokenService.authenticateStudent(from: request)
            let allStudents = try await repo.all(on: request.db)
            let accessible = AuthorizationService.filterAccessibleStudents(requester: requester, allStudents: allStudents)
            return accessible.map { $0.convertToPublic() }
        }
    }

    /// Fetches a single student by ID with resource-level authorization.
    /// Authorization: identical to REST GET /students/:id
    func student(request: Request, arguments: StudentByIDArguments) throws -> EventLoopFuture<Student.Public?> {
        let repo = self.studentRepository
        return request.eventLoop.makeFutureWithTask {
            let requester = try await TokenService.authenticateStudent(from: request)

            guard AuthorizationService.canAccessStudentRecord(requester: requester, targetStudentID: arguments.id) else {
                throw Abort(.forbidden, reason: "You are not authorized to access this student record")
            }

            guard let target = try await repo.find(byID: arguments.id, on: request.db) else {
                return nil
            }
            return target.convertToPublic()
        }
    }

    // MARK: - Mutations

    /// New canonical student signup mutation.
    /// Role is assigned server-side (always student). confirmPassword is validated but never persisted.
    func signupStudent(request: Request, arguments: SignupStudentArguments) throws -> EventLoopFuture<Student.Public> {
        let service = self.studentService
        return request.eventLoop.makeFutureWithTask {
            let input = arguments.input

            let validationErrors = validateStudentSignupRequest(
                firstName: input.firstName,
                lastName: input.lastName,
                email: input.email,
                password: input.password,
                confirmPassword: input.confirmPassword,
                countryCode: input.countryCode,
                contactNumber: input.contactNumber
            )

            if !validationErrors.isEmpty {
                let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
                throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
            }

            let signupRequest = StudentSignupRequest(
                firstName: input.firstName,
                lastName: input.lastName,
                email: input.email,
                password: input.password,
                confirmPassword: input.confirmPassword,
                countryCode: input.countryCode,
                contactNumber: input.contactNumber
            )

            let student = try await service.signupStudent(request: signupRequest, on: request.db)
            return student.convertToPublic()
        }
    }

    /// Legacy signup mutation — preserved for backward compatibility.
    /// Uses the old CreateRequest (name/email/password/dob/phoneNumber).
    /// Role forced to .student server-side.
    func signup(request: Request, arguments: SignupArguments) throws -> EventLoopFuture<Student.Public> {
        let repo = self.studentRepository
        return request.eventLoop.makeFutureWithTask {
            let input = arguments.input

            let validationErrors = validateStudentCreateRequest(
                name: input.name,
                email: input.email,
                password: input.password,
                dob: input.dob,
                phoneNumber: input.phoneNumber
            )

            if !validationErrors.isEmpty {
                let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
                throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
            }

            let normalizedEmail = input.email.lowercased().trimmingCharacters(in: .whitespaces)
            if try await repo.find(byEmail: normalizedEmail, on: request.db) != nil {
                throw Abort(.conflict, reason: "An account with this email already exists", identifier: "EMAIL_ALREADY_EXISTS")
            }

            let hashedPassword = try Bcrypt.hash(input.password)
            let student = Student(
                id: UUID(),
                firstName: nil,
                lastName: nil,
                name: input.name.trimmingCharacters(in: .whitespaces),
                email: normalizedEmail,
                passwordHash: hashedPassword,
                role: .student,   // always student via public signup
                status: .active,
                dob: input.dob,
                phoneNumber: input.phoneNumber
            )

            do {
                try await repo.create(student, on: request.db)
            } catch {
                throw StudentService.mapDatabaseError(error)
            }
            return student.convertToPublic()
        }
    }

    /// Authenticates user and returns a JWT. Role is always from the server-side record.
    func login(request: Request, arguments: LoginArguments) throws -> EventLoopFuture<AuthPayload> {
        let service = self.studentService
        return request.eventLoop.makeFutureWithTask {
            let credentials = Student.LoginRequest(
                email: arguments.input.email,
                password: arguments.input.password
            )

            guard let student = try await service.authenticate(credentials: credentials, on: request.db) else {
                throw Abort(.unauthorized, reason: "Invalid email or password")
            }

            let token = try TokenService.signAccessToken(for: student, on: request)
            return AuthPayload(user: student.convertToPublic(), token: token)
        }
    }

    /// Updates a student's non-sensitive profile fields.
    /// Authorization: only the student themselves can update their own record.
    struct UpdateArguments: Codable {
        let input: StudentGraphQLUpdateInput
    }

    func updateStudent(context: Request, arguments: UpdateArguments) async throws -> Student.Public {
        let authenticated = try await TokenService.authenticateStudent(from: context)

        guard AuthorizationService.canAccessStudentRecord(requester: authenticated, targetStudentID: arguments.input.id) else {
            throw Abort(.forbidden, reason: "You can only update your own student record")
        }

        guard let student = try await self.studentRepository.find(byID: arguments.input.id, on: context.db) else {
            throw Abort(.notFound, reason: "Student not found")
        }

        let validationErrors = validateStudentUpdateRequest(
            dob: arguments.input.dob,
            name: arguments.input.name,
            phoneNumber: arguments.input.phoneNumber
        )

        if !validationErrors.isEmpty {
            let errorMessages = validationErrors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            throw Abort(.badRequest, reason: "Validation failed: \(errorMessages)")
        }

        if let dob = arguments.input.dob { student.dob = dob }
        if let name = arguments.input.name { student.name = name }
        if let phoneNumber = arguments.input.phoneNumber { student.phoneNumber = phoneNumber }

        try await self.studentRepository.update(student, on: context.db)
        return student.convertToPublic()
    }
}

// MARK: - Argument Types

struct StudentByIDArguments: Codable {
    let id: UUID
}

struct SignupStudentArguments: Codable {
    let input: StudentGraphQLSignupInput
}

struct SignupArguments: Codable {
    let input: StudentGraphQLCreateInput
}

struct LoginArguments: Codable {
    let input: StudentGraphQLLoginInput
}

// MARK: - Input Types

/// New canonical signup input — matches StudentSignupRequest
struct StudentGraphQLSignupInput: Codable {
    let firstName: String
    let lastName: String
    let email: String
    let password: String
    let confirmPassword: String
    let countryCode: String
    let contactNumber: String
}

/// Legacy signup input — backward compat
struct StudentGraphQLCreateInput: Codable {
    let name: String
    let email: String
    let password: String
    let dob: Date?
    let phoneNumber: String?
}

struct StudentGraphQLLoginInput: Codable {
    let email: String
    let password: String
}

struct StudentGraphQLUpdateInput: Codable {
    let id: UUID
    let dob: Date?
    let name: String?
    let phoneNumber: String?
}

// MARK: - Response Types

struct AuthPayload: Codable {
    let user: Student.Public
    let token: String
}

// MARK: - GraphQL API Class

final class StudentGraphQLAPI: API, @unchecked Sendable {
    typealias Resolver = GraphQLResolver
    typealias ContextType = Request

    let resolver = GraphQLResolver()
    let schema: Graphiti.Schema<GraphQLResolver, Request>

    init() throws {
        schema = try StudentGraphQLSchema.build()
    }
}

// MARK: - Schema Builder

enum StudentGraphQLSchema {
    static func build() throws -> Graphiti.Schema<GraphQLResolver, Request> {
        let coders = Coders()
        coders.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                // 1. Try standard YYYY-MM-DD (e.g. "2012-10-24")
                let ymd = DateFormatter()
                ymd.dateFormat = "yyyy-MM-dd"
                ymd.timeZone = TimeZone(secondsFromGMT: 0)
                ymd.locale = Locale(identifier: "en_US_POSIX")
                if let d = ymd.date(from: str) {
                    return d
                }

                // 2. Try ISO8601 with fractional seconds
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: str) {
                    return d
                }

                // 3. Try standard ISO8601
                iso.formatOptions = [.withInternetDateTime]
                if let d = iso.date(from: str) {
                    return d
                }

                // 4. Try date-time without Z or with space
                let fallback = DateFormatter()
                fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                fallback.timeZone = TimeZone(secondsFromGMT: 0)
                fallback.locale = Locale(identifier: "en_US_POSIX")
                if let d = fallback.date(from: str) {
                    return d
                }

                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid date format '\(str)'. Expected 'YYYY-MM-DD' or ISO-8601 format."
                )
            }

            if let timestamp = try? container.decode(Double.self) {
                if timestamp > 100_000_000_000 {
                    return Date(timeIntervalSince1970: timestamp / 1000.0)
                }
                return Date(timeIntervalSince1970: timestamp)
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected Date string (e.g. 'YYYY-MM-DD') or timestamp"
            )
        }
        coders.encoder.dateEncodingStrategy = .iso8601

        return try Graphiti.Schema<GraphQLResolver, Request>(coders: coders) {
            Scalar(UUID.self)
            Scalar(Date.self)

            // MARK: - Enum Types

            Enum(UserRole.self, as: "UserRole") {
                Value(.admin)
                Value(.principal)
                Value(.teacher)
                Value(.student)
            }

            Enum(AccountStatus.self, as: "AccountStatus") {
                Value(.active)
                Value(.inactive)
                Value(.suspended)
                Value(.pending)
            }

            // MARK: - Object Types

            Type(Student.Public.self, as: "Student") {
                Field("id", at: \.id)
                Field("firstName", at: \.firstName)
                Field("lastName", at: \.lastName)
                Field("name", at: \.name)
                Field("email", at: \.email)
                Field("role", at: \.role)
                Field("status", at: \.status)
                Field("dob", at: \.dob)
                Field("phoneNumber", at: \.phoneNumber)
                Field("contactNumber", at: \.contactNumber)
                Field("countryCode", at: \.countryCode)
            }

            Type(AuthPayload.self) {
                Field("user", at: \.user)
                Field("token", at: \.token)
            }

            // MARK: - Input Types

            Input(StudentGraphQLSignupInput.self, as: "StudentSignupInput") {
                InputField("firstName", at: \.firstName)
                InputField("lastName", at: \.lastName)
                InputField("email", at: \.email)
                InputField("password", at: \.password)
                InputField("confirmPassword", at: \.confirmPassword)
                InputField("countryCode", at: \.countryCode)
                InputField("contactNumber", at: \.contactNumber)
            }

            Input(StudentGraphQLCreateInput.self) {
                InputField("name", at: \.name)
                InputField("email", at: \.email)
                InputField("password", at: \.password)
                InputField("dob", at: \.dob)
                InputField("phoneNumber", at: \.phoneNumber)
            }

            Input(StudentGraphQLLoginInput.self) {
                InputField("email", at: \.email)
                InputField("password", at: \.password)
            }

            Input(StudentGraphQLUpdateInput.self) {
                InputField("id", at: \.id)
                InputField("dob", at: \.dob)
                InputField("name", at: \.name)
                InputField("phoneNumber", at: \.phoneNumber)
            }

            // MARK: - Queries

            Query {
                Field("students", at: GraphQLResolver.students)
                Field("student", at: GraphQLResolver.student) {
                    Argument("id", at: \.id)
                }
            }

            // MARK: - Mutations

            Mutation {
                // New canonical student signup
                Field("signupStudent", at: GraphQLResolver.signupStudent) {
                    Argument("input", at: \.input)
                }
                // Legacy signup (backward compat)
                Field("signup", at: GraphQLResolver.signup) {
                    Argument("input", at: \.input)
                }
                Field("login", at: GraphQLResolver.login) {
                    Argument("input", at: \.input)
                }
                Field("updateStudent", at: GraphQLResolver.updateStudent) {
                    Argument("input", at: \.input)
                }
            }
        }
    }
}
