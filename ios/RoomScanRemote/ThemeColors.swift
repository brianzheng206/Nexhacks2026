//
//  ThemeColors.swift
//  RoomScanRemote
//
//  Color theme matching the frontend design
//

import SwiftUI

extension Color {
    // Dark theme colors matching frontend
    static let appBackground = Color(hex: "1a1a1a")
    static let appPanel = Color(hex: "2d2d2d")
    static let appAccent = Color(hex: "667eea")
    static let appText = Color(hex: "e0e0e0")
    static let appTextSecondary = Color(hex: "999999")
    static let appBorder = Color(hex: "667eea")
    
    // Status colors
    static let statusConnected = Color.green
    static let statusScanning = Color(hex: "667eea")
    static let statusError = Color.red
    static let statusWarning = Color.orange
    
    // Button colors
    static let buttonPrimary = Color(hex: "667eea")
    static let buttonSecondary = Color(hex: "764ba2")
    static let buttonSuccess = Color.green
    static let buttonDanger = Color.red
    static let buttonDisabled = Color(hex: "4a4a4a")
    
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
