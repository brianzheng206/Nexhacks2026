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
    
    private var frameSendTimes: [Date] = []
    private let qualityCheckInterval: TimeInterval = 5.0
    private let maxLatencyForGood: TimeInterval = 0.5
    private var lastQualityCheck: Date = Date()
    
    var bytesSent: Int64 = 0
    var bytesReceived: Int64 = 0
    var framesSent: Int = 0
    var messagesReceived: Int = 0
    
    var averageLatency: TimeInterval = 0.0
    
    var onControlMessage: ((String) -> Void)?
    var onRoomUpdate: (([String: Any]) -> Void)?
    var onInstruction: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    
    // Automatic reconnection
    private var autoReconnectEnabled: Bool = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private let initialReconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private var storedHost: String?
    private var storedPort: Int = 8080
    private var storedToken: String?
    
    init() {
        connectionState = wsClient.isConnected ? .connected : .disconnected
        setupWebSocketCallbacks()
    }
    
    private func setupWebSocketCallbacks() {
        wsClient.onConnectionStateChanged = { [weak self] isConnected in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // Use a debounce mechanism to prevent rapid state changes that cause flickering
                let currentState = self.connectionState
                
                if isConnected {
                    // Only update to connected if we're in a connecting/connected/reconnecting state
                    // This prevents race conditions and flickering
                    switch currentState {
                    case .connecting, .connected, .reconnecting:
                        // Only update if not already connected to prevent unnecessary updates
                        if currentState != .connected {
                            self.connectionState = .connected
                            self.reconnectAttempts = 0
                            self.cancelAutoReconnect()
                        }
                    case .disconnected, .failed:
                        // If we're disconnected/failed, don't auto-update to connected
                        // This prevents stale callbacks from updating state
                        break
                    }
                } else {
                    // Only update to disconnected if we were actually connected
                    // Add a small delay to debounce rapid disconnection events
                    switch currentState {
                    case .connected, .reconnecting:
                        // Debounce: only update if we're still disconnected after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            guard let self = self, !self.wsClient.isConnected else { return }
                            self.connectionState = .disconnected
                            // Trigger auto-reconnect if enabled
                            if self.autoReconnectEnabled {
                                self.startAutoReconnect()
                            }
                        }
                    case .connecting:
                        // If we were connecting and got disconnected, don't change state yet
                        // Let the completion handler handle it
                        break
                    case .disconnected, .failed:
                        // Already disconnected, no change needed
                        break
                    }
                }
            }
        }
        
        wsClient.onControlMessage = { [weak self] action in
            DispatchQueue.main.async {
                let estimatedSize = action.data(using: .utf8)?.count ?? 0
                self?.recordMessageReceived(size: estimatedSize)
                self?.onControlMessage?(action)
            }
        }
        
        wsClient.onRoomUpdate = { [weak self] data in
            DispatchQueue.main.async {
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
        // Store connection parameters for auto-reconnect
        storedHost = laptopHost
        storedPort = port
        storedToken = token
        
        // Cancel any ongoing auto-reconnect
        cancelAutoReconnect()
        
        // Update state to connecting on main thread
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .connecting
        }
        
        // Call WSClient connect - it will handle main thread dispatch for completion
        wsClient.connect(laptopHost: laptopHost, port: port, token: token) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(success, error)
                    return
                }
                
                if success {
                    self.connectionState = .connected
                    self.reconnectAttempts = 0
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
        autoReconnectEnabled = false
        cancelAutoReconnect()
        wsClient.disconnect()
        Task { @MainActor in
            connectionState = .disconnected
            frameSendTimes.removeAll()
            // Keep data counters for display until next connection
            storedHost = nil
            storedPort = 8080
            storedToken = nil
        }
    }
    
    func reconnect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .reconnecting
        }
        connect(laptopHost: laptopHost, port: port, token: token, completion: completion)
    }
    
    func enableAutoReconnect() {
        autoReconnectEnabled = true
    }
    
    func disableAutoReconnect() {
        autoReconnectEnabled = false
        cancelAutoReconnect()
    }
    
    private func startAutoReconnect() {
        guard autoReconnectEnabled else { return }
        guard let host = storedHost, let token = storedToken else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            DispatchQueue.main.async { [weak self] in
                self?.connectionState = .failed("Reconnection failed after \(self?.maxReconnectAttempts ?? 5) attempts")
            }
            return
        }
        
        cancelAutoReconnect()
        
        reconnectAttempts += 1
        let delay = min(initialReconnectDelay * pow(2.0, Double(reconnectAttempts - 1)), maxReconnectDelay)
        
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .reconnecting
        }
        
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // Task was cancelled
                return
            }
            
            guard let self = self else { return }
            
            self.wsClient.connect(laptopHost: host, port: self.storedPort, token: token) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if success {
                        self.connectionState = .connected
                        self.reconnectAttempts = 0
                    } else {
                        // Will trigger another reconnect attempt via onConnectionStateChanged
                        if self.reconnectAttempts >= self.maxReconnectAttempts {
                            self.connectionState = .failed(error ?? "Reconnection failed")
                        }
                    }
                }
            }
        }
    }
    
    private func cancelAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }
    
    func sendMessage(_ jsonString: String) {
        wsClient.sendMessage(jsonString)
    }
    
    var canAcceptFrame: Bool {
        return wsClient.canAcceptFrame
    }
    
    @discardableResult
    func sendJPEGFrame(_ data: Data) -> Bool {
        let sendTime = Date()
        let accepted = wsClient.sendJPEGFrame(data)
        
        if accepted {
            Task { @MainActor in
                frameSendTimes.append(sendTime)
                framesSent += 1
                bytesSent += Int64(data.count)
                
                let cutoffTime = Date().addingTimeInterval(-10.0)
                frameSendTimes.removeAll { $0 < cutoffTime }
                
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
        messagesReceived += 1
        bytesReceived += Int64(size)
    }
    
    private func updateConnectionQuality() {
        guard connectionState.isConnected else { return }
        
        // Clean up old frame send times to prevent memory growth
        let cutoffTime = Date().addingTimeInterval(-10.0)
        frameSendTimes.removeAll { $0 < cutoffTime }
        
        guard !frameSendTimes.isEmpty else {
            connectionQuality = .good
            return
        }
        
        let sortedTimes = frameSendTimes.sorted()
        var maxGap: TimeInterval = 0
        
        for i in 1..<sortedTimes.count {
            let gap = sortedTimes[i].timeIntervalSince(sortedTimes[i-1])
            maxGap = max(maxGap, gap)
        }
        
        connectionQuality = maxGap > maxLatencyForGood ? .poor : .good
    }
    
    var currentHost: String? {
        wsClient.currentHost
    }
    
    var currentPort: Int? {
        wsClient.currentPort
    }
}
