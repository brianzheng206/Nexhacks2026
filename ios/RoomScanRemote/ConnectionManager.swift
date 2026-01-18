//
//  ConnectionManager.swift
//  RoomScanRemote
//
//  Observable connection manager that wraps WSClient for SwiftUI
//

import Foundation
import Observation

@Observable
final class ConnectionManager {
    var connectionState: ConnectionState = .disconnected
    var connectionQuality: ConnectionQuality = .good
    
    // Computed properties for backward compatibility
    var isConnected: Bool {
        return connectionState.isConnected
    }
    
    var statusMessage: String {
        return connectionState.displayName
    }
    
    private let wsClient = WSClient.shared
    
    // Connection quality tracking
    private var frameSendTimes: [Date] = []
    private let qualityCheckInterval: TimeInterval = 5.0 // Check quality every 5 seconds
    private let maxLatencyForGood: TimeInterval = 0.5 // 500ms max latency for "good" quality
    private var lastQualityCheck: Date = Date()
    
    // Data tracking
    var bytesSent: Int64 = 0
    var bytesReceived: Int64 = 0
    var framesSent: Int = 0
    var messagesReceived: Int = 0
    
    // Latency tracking
    var averageLatency: TimeInterval = 0.0 // Average latency in seconds
    
    // Callbacks for different message types
    var onControlMessage: ((String) -> Void)?
    var onRoomUpdate: (([String: Any]) -> Void)?
    var onInstruction: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    
    init() {
        // Sync initial state with WSClient
        connectionState = wsClient.isConnected ? .connected : .disconnected
        setupWebSocketCallbacks()
    }
    
    private func setupWebSocketCallbacks() {
        // Update connection state when WSClient state changes
        // Note: This callback is called from WSClient, which already handles main thread dispatch
        wsClient.onConnectionStateChanged = { [weak self] isConnected in
            guard let self = self else { return }
            // Update on main thread (WSClient may call from background)
            DispatchQueue.main.async {
                if isConnected {
                    self.connectionState = .connected
                } else {
                    // Only transition to disconnected if not already in a connecting/reconnecting state
                    if case .connected = self.connectionState {
                        self.connectionState = .disconnected
                    }
                }
            }
        }
        
        // Forward other callbacks and track data received
        wsClient.onControlMessage = { [weak self] action in
            DispatchQueue.main.async {
                // Estimate message size (JSON string)
                let estimatedSize = action.data(using: .utf8)?.count ?? 0
                self?.recordMessageReceived(size: estimatedSize)
                self?.onControlMessage?(action)
            }
        }
        
        wsClient.onRoomUpdate = { [weak self] data in
            DispatchQueue.main.async {
                // Estimate message size (JSON dictionary)
                if let jsonData = try? JSONSerialization.data(withJSONObject: data) {
                    self?.recordMessageReceived(size: jsonData.count)
                }
                self?.onRoomUpdate?(data)
            }
        }
        
        wsClient.onInstruction = { [weak self] message in
            DispatchQueue.main.async {
                let estimatedSize = message.data(using: .utf8)?.count ?? 0
                self?.recordMessageReceived(size: estimatedSize)
                self?.onInstruction?(message)
            }
        }
        
        wsClient.onStatus = { [weak self] message in
            DispatchQueue.main.async {
                let estimatedSize = message.data(using: .utf8)?.count ?? 0
                self?.recordMessageReceived(size: estimatedSize)
                self?.onStatus?(message)
            }
        }
    }
    
    func connect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        // Update state to connecting on main thread
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .connecting
        }
        
        // Call WSClient connect - it will handle main thread dispatch for completion
        wsClient.connect(laptopHost: laptopHost, port: port, token: token) { [weak self] success, error in
            // WSClient already calls completion on main thread, but ensure we're on main thread for state updates
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(success, error)
                    return
                }
                
                if success {
                    self.connectionState = .connected
                    // Reset quality tracking on successful connection
                    self.frameSendTimes.removeAll()
                    self.lastQualityCheck = Date()
                    // Reset data counters
                    self.bytesSent = 0
                    self.bytesReceived = 0
                    self.framesSent = 0
                    self.messagesReceived = 0
                    self.averageLatency = 0.0
                } else {
                    let errorMessage = error ?? "Unknown error"
                    self.connectionState = .failed(errorMessage)
                }
                
                // Call the original completion
                completion(success, error)
            }
        }
    }
    
    func disconnect() {
        wsClient.disconnect()
        Task { @MainActor in
            connectionState = .disconnected
            frameSendTimes.removeAll()
            // Keep data counters for display until next connection
        }
    }
    
    func reconnect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        // Update state to reconnecting
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .reconnecting
        }
        connect(laptopHost: laptopHost, port: port, token: token, completion: completion)
    }
    
    func sendMessage(_ jsonString: String) {
        wsClient.sendMessage(jsonString)
    }
    
    // Check if WebSocket can accept a new frame immediately
    var canAcceptFrame: Bool {
        return wsClient.canAcceptFrame
    }
    
    // Send JPEG frame - returns true if frame was accepted, false if dropped
    // Also tracks send latency for connection quality assessment
    @discardableResult
    func sendJPEGFrame(_ data: Data) -> Bool {
        let sendTime = Date()
        let accepted = wsClient.sendJPEGFrame(data)
        
        if accepted {
            // Track send time for quality assessment and data counters
            Task { @MainActor in
                frameSendTimes.append(sendTime)
                framesSent += 1
                bytesSent += Int64(data.count)
                
                // Clean up old entries (keep last 10 seconds)
                let cutoffTime = Date().addingTimeInterval(-10.0)
                frameSendTimes.removeAll { $0 < cutoffTime }
                
                // Check connection quality periodically
                let now = Date()
                if now.timeIntervalSince(lastQualityCheck) >= qualityCheckInterval {
                    updateConnectionQuality()
                    lastQualityCheck = now
                }
            }
        }
        
        return accepted
    }
    
    func recordMessageReceived(size: Int) {
        // This is already called from main thread via DispatchQueue.main.async in callbacks
        messagesReceived += 1
        bytesReceived += Int64(size)
    }
    
    // Update connection quality based on frame send latency
    private func updateConnectionQuality() {
        guard connectionState.isConnected else { return }
        guard !frameSendTimes.isEmpty else {
            connectionQuality = .good
            return
        }
        
        // Calculate average time between sends (proxy for latency)
        // If frames are being sent frequently, connection is good
        // If there are large gaps, connection might be poor
        let sortedTimes = frameSendTimes.sorted()
        var maxGap: TimeInterval = 0
        
        for i in 1..<sortedTimes.count {
            let gap = sortedTimes[i].timeIntervalSince(sortedTimes[i-1])
            maxGap = max(maxGap, gap)
        }
        
        // If max gap is small, connection is good
        // If max gap is large, connection might be poor (frames backing up)
        connectionQuality = maxGap > maxLatencyForGood ? .poor : .good
    }
    
    var currentHost: String? {
        wsClient.currentHost
    }
    
    var currentPort: Int? {
        wsClient.currentPort
    }
}
