//
//  ConnectionState.swift
//  RoomScanRemote
//
//  Connection state enum for WebSocket connection management
//

import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String) // Contains error message
    
    var displayName: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting..."
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
    
    var isConnected: Bool {
        return self == .connected
    }
    
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reconnecting:
            return true
        case .disconnected, .failed:
            return false
        }
    }
}

enum ConnectionQuality: Equatable {
    case good
    case poor
    
    var displayName: String {
        switch self {
        case .good:
            return "Good"
        case .poor:
            return "Poor"
        }
    }
    
    var indicatorColor: String {
        switch self {
        case .good:
            return "green"
        case .poor:
            return "orange"
        }
    }
}
