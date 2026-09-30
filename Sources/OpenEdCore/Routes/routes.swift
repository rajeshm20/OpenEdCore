import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: HealthController())
    try app.register(collection: AuthController())
    try app.register(collection: StudentController())
    try app.register(collection: AccessGateController())
    try registerGraphQLRoutes(app)

    #if DEBUG
    for route in app.routes.all {
        let path = route.path.map { "\($0)" }.joined(separator: "/")
        app.logger.debug("Registered route: \(route.method.rawValue) /\(path)")
    }
    #endif
}
