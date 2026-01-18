//
//  Logger.swift
//  RoomScanRemote
//
//  Centralized logging with categories, log levels, and token masking
//

import Foundation
import OSLog

extension String {
    /// Masks sensitive token strings - shows first 4 characters only
    var maskedForLogging: String {
        guard self.count > 4 else {
            return String(repeating: "*", count: self.count)
        }
        let prefix = self.prefix(4)
        let masked = String(repeating: "*", count: max(0, self.count - 4))
        return "\(prefix)\(masked)"
    }
}

enum LogCategory: String {
    case connection = "Connection"
    case scanning = "Scanning"
    case websocket = "WebSocket"
    case qrScanner = "QRScanner"
    case frameProcessing = "FrameProcessing"
    case general = "General"
}

enum LogLevel {
    case debug
    case info
    case error
    
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .error:
            return .error
        }
    }
}

struct AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.roomscan.remote"
    
    #if DEBUG
    private static let enableDebugLogging = true
    #else
    private static let enableDebugLogging = false
    #endif
    
    private let logger: Logger
    
    init(category: LogCategory) {
        self.logger = Logger(subsystem: AppLogger.subsystem, category: category.rawValue)
    }
    
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        guard AppLogger.enableDebugLogging else { return }
        logger.debug("\(message, privacy: .public)")
    }
    
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger.info("\(message, privacy: .public)")
    }
    
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger.error("\(message, privacy: .public)")
    }
    
    func log(_ level: LogLevel, _ message: String, maskingTokens: Bool = true) {
        let safeMessage = maskingTokens ? maskTokensInMessage(message) : message
        
        switch level {
        case .debug:
            debug(safeMessage)
        case .info:
            info(safeMessage)
        case .error:
            error(safeMessage)
        }
    }
    
    private func maskTokensInMessage(_ message: String) -> String {
        var masked = message
        
        if let range = masked.range(of: "token=['\"]", options: .regularExpression) {
            let start = range.upperBound
            if let end = masked[start...].range(of: "['\"]", options: .regularExpression)?.lowerBound {
                let tokenRange = start..<end
                let token = String(masked[tokenRange])
                masked.replaceSubrange(tokenRange, with: token.maskedForLogging)
            }
        }
        
        if let range = masked.range(of: "\"token\"\\s*:\\s*[\"']", options: .regularExpression) {
            let start = range.upperBound
            if let end = masked[start...].range(of: "[\"']", options: .regularExpression)?.lowerBound {
                let tokenRange = start..<end
                let token = String(masked[tokenRange])
                masked.replaceSubrange(tokenRange, with: token.maskedForLogging)
            }
        }
        
        return masked
    }
}

extension AppLogger {
    static let connection = AppLogger(category: .connection)
    static let scanning = AppLogger(category: .scanning)
    static let websocket = AppLogger(category: .websocket)
    static let qrScanner = AppLogger(category: .qrScanner)
    static let frameProcessing = AppLogger(category: .frameProcessing)
    static let general = AppLogger(category: .general)
}
