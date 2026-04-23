import Foundation
import os.log

enum TNTLog {
    static let logger = Logger(subsystem: "com.tnt.app", category: "TNT")

    static func info(_ message: String) {
        logger.info("\(message)")
        print("[TNT] \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message)")
        print("[TNT] ERROR: \(message)")
    }

    static func debug(_ message: String) {
        logger.debug("\(message)")
        // Always print to console so users can see debug logs in Release builds too
        print("[TNT] DEBUG: \(message)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message)")
        print("[TNT] WARN: \(message)")
    }
}
