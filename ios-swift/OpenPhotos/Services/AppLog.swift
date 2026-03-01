import Foundation
import os

/// Centralized structured logging for the iOS app.
///
/// Why:
/// - `print(...)` is surprisingly expensive in Debug builds (especially when Xcode is attached),
///   and can contribute to UI hitches during sync/export/upload.
/// - `Logger` supports log levels and allows the system to drop debug-level logs in production,
///   reducing overhead while still keeping useful diagnostics.
enum AppLog {
    // Use a stable subsystem so logs can be filtered in Console / Instruments.
    static let subsystem = "com.openphotos"

    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let upload = Logger(subsystem: subsystem, category: "upload")
    static let db = Logger(subsystem: subsystem, category: "db")

    /// Debug logs are compiled out of Release builds.
    static func debug(_ logger: Logger, _ message: @autoclosure () -> String) {
        #if DEBUG
        // Evaluate the autoclosure before handing it to `Logger` to avoid Swift treating the
        // interpolation as capturing a non-escaping parameter.
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }

    static func info(_ logger: Logger, _ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }
}
