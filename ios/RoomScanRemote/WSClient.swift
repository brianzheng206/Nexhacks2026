//
//  WSClient.swift
//  RoomScanRemote
//
//  WebSocket client using URLSessionWebSocketTask
//

import Foundation

private let logger = AppLogger.websocket

class WSClient {
    static let shared = WSClient()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    
    private(set) var isConnected: Bool = false
    
    var onConnectionStateChanged: ((Bool) -> Void)?
    var onControlMessage: ((String) -> Void)?
    var onRoomUpdate: (([String: Any]) -> Void)?
    var onInstruction: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    
    var currentHost: String?
    var currentPort: Int?
    // Token stored in memory - marked as sensitive (never logged)
    private var currentToken: String?
    private var helloCompletion: ((Bool, String?) -> Void)?
    private var isWaitingForHelloAck: Bool = false
    
    private init() {}
    
    func connect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        let trimmedHost = laptopHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            completion(false, "Invalid server address")
            return
        }

        // Cancel any existing timers
        connectionTimeoutTimer?.invalidate()
        helloAckTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer = nil

        currentHost = trimmedHost
        currentPort = port
        currentToken = token
        helloCompletion = completion
        
        let urlString = "ws://\(trimmedHost):\(port)"
        guard let url = URL(string: urlString) else {
            completion(false, "Invalid WebSocket URL")
            return
        }
        
        // Disconnect existing connection if any
        disconnect()
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        urlSession = session
        
        // Start receiving messages first (to catch hello_ack)
        receiveMessages()
        
        // Resume the connection
        webSocketTask?.resume()
        
        // Set connection timeout (10 seconds to establish WebSocket connection)
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Check if we're still waiting for connection
            if !self.isConnected && self.helloCompletion != nil {
                self.connectionTimeoutTimer = nil
                self.helloAckTimeoutTimer?.invalidate()
                self.helloAckTimeoutTimer = nil
                self.isWaitingForHelloAck = false
                logger.error("Connection timeout - failed to establish WebSocket connection after \(self.connectionTimeout) seconds")
                self.helloCompletion?(false, "Connection timeout - unable to reach server. Check network connection and server address.")
                self.helloCompletion = nil
                self.disconnect()
            }
        }
        
        // Give the WebSocket a brief moment to establish connection
        // URLSessionWebSocketTask will queue messages, but a small delay ensures better reliability
        // This is especially important on slower networks
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            // Send hello message - if connection isn't ready, send() will handle it
            self.sendHello(token: token)
        }
    }
    
    private func sendHello(token: String) {
        // Token should already be trimmed by PairingView, but trim again for safety
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedToken.isEmpty else {
            logger.error("Token validation failed - token is empty")
            helloCompletion?(false, "Invalid authentication. Please check your session token.")
            helloCompletion = nil
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            return
        }
        
        let helloMessage: [String: Any] = [
            "type": "hello",
            "role": "phone",
            "token": trimmedToken
        ]
        
        logger.info("Sending hello with token: \(trimmedToken.maskedForLogging) (length: \(trimmedToken.count))")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: helloMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            helloCompletion?(false, "Failed to create hello message")
            helloCompletion = nil
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { [weak self] error in
            guard let self = self else { return }
            
            if let error = error {
                logger.error("Error sending hello: \(error.localizedDescription)")
                let errorMsg: String
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet:
                        errorMsg = "No internet connection"
                    case .cannotConnectToHost:
                        errorMsg = "Cannot connect to server. Check IP address and ensure server is running."
                    case .timedOut:
                        errorMsg = "Connection timed out"
                    case .networkConnectionLost:
                        errorMsg = "Network connection lost"
                    case .dnsLookupFailed:
                        errorMsg = "DNS lookup failed. Check server address."
                    default:
                        errorMsg = "Connection error: \(urlError.localizedDescription)"
                    }
                } else {
                    errorMsg = "Failed to send hello: \(error.localizedDescription)"
                }
                self.connectionTimeoutTimer?.invalidate()
                self.connectionTimeoutTimer = nil
                self.helloCompletion?(false, errorMsg)
                self.helloCompletion = nil
            } else {
                logger.debug("Hello message sent successfully, waiting for hello_ack...")
                self.isWaitingForHelloAck = true
                
                // Set timeout for hello_ack (5 seconds after hello is sent)
                self.helloAckTimeoutTimer = Timer.scheduledTimer(withTimeInterval: self.helloAckTimeout, repeats: false) { [weak self] _ in
                    guard let self = self, self.isWaitingForHelloAck else { return }
                    self.isWaitingForHelloAck = false
                    self.helloAckTimeoutTimer = nil
                    logger.error("Hello_ack timeout - no response after \(self.helloAckTimeout) seconds")
                    self.helloCompletion?(false, "Server did not respond. Please check your connection and try again.")
                    self.helloCompletion = nil
                    self.disconnect()
                }
            }
        }
    }
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleTextMessage(text)
                case .data(let data):
                    self.handleBinaryMessage(data)
                @unknown default:
                    logger.debug("Unknown message type")
                }
                
                // Continue receiving messages
                self.receiveMessages()
                
            case .failure(let error):
                logger.error("Receive error: \(error.localizedDescription)")
                self.handleDisconnection()
            }
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.debug("Invalid message format")
            return
        }
        
        switch type {
        case "hello_ack":
            logger.info("Received hello_ack - connection established")
            isWaitingForHelloAck = false
            // Cancel timers on successful connection
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            helloAckTimeoutTimer?.invalidate()
            helloAckTimeoutTimer = nil
            updateConnectionState(true)
            onConnectionStateChanged?(true)
            helloCompletion?(true, nil)
            helloCompletion = nil
            
        case "control":
            if let action = json["action"] as? String {
                logger.debug("Received control: \(action)")
                onControlMessage?(action)
            }
            
        case "room_update":
            logger.debug("Received room_update")
            onRoomUpdate?(json)
            
        case "instruction":
            if let message = json["message"] as? String ?? json["text"] as? String {
                logger.debug("Received instruction: \(message)")
                onInstruction?(message)
            }
            
        case "status":
            if let message = json["message"] as? String ?? json["text"] as? String {
                logger.debug("Received status: \(message)")
                onStatus?(message)
            }
            
        default:
            logger.debug("Unknown message type: \(type)")
        }
    }
    
    private func handleBinaryMessage(_ data: Data) {
        // Binary messages are JPEG frames - we'll handle these when implementing RoomPlan
        logger.debug("Received binary data: \(data.count) bytes")
    }
    
    // Flag to track if a frame send is in progress (backpressure)
    // This is checked by ScanController before sending - no local backpressure logic here
    private(set) var isSendingFrame = false
    
    // Check if WebSocket can accept a new frame immediately
    var canAcceptFrame: Bool {
        return isConnected && !isSendingFrame
    }
    
    // Send JPEG frame - returns true if frame was accepted, false if dropped due to backpressure
    // This method is synchronous in terms of acceptance - it immediately returns whether the frame was queued
    @discardableResult
    func sendJPEGFrame(_ data: Data) -> Bool {
        guard isConnected else {
            // Not connected - frame dropped
            return false
        }
        
        // Backpressure: reject if previous frame is still being sent
        // ScanController should check canAcceptFrame before calling this
        guard !isSendingFrame else {
            return false
        }
        
        isSendingFrame = true
        
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { [weak self] error in
            // Reset flag on completion (success or error)
            self?.isSendingFrame = false
            
            if let error = error {
                logger.error("Error sending JPEG frame (\(data.count) bytes): \(error.localizedDescription)")
            }
        }
        
        return true
    }
    
    func sendMessage(_ jsonString: String) {
        guard isConnected else {
            logger.debug("Cannot send message: not connected")
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { error in
            if let error = error {
                logger.error("Error sending message: \(error.localizedDescription)")
            }
        }
    }
    
    private func handleDisconnection() {
        // Cancel any pending timers
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer?.invalidate()
        helloAckTimeoutTimer = nil
        
        updateConnectionState(false)
        onConnectionStateChanged?(false)
        
        // No automatic reconnection - user must explicitly reconnect
        // This gives user control and visibility into connection state
    }
    
    func disconnect() {
        // Cancel all timers
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer?.invalidate()
        helloAckTimeoutTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        updateConnectionState(false)
        onConnectionStateChanged?(false)
        
        // Clear connection info
        currentHost = nil
        currentPort = nil
        currentToken = nil
        helloCompletion = nil
        isWaitingForHelloAck = false
    }
    
    // Thread-safe method to update connection state
    private func updateConnectionState(_ newState: Bool) {
        // Ensure updates happen on main thread for thread safety
        if Thread.isMainThread {
            isConnected = newState
        } else {
            DispatchQueue.main.sync {
                isConnected = newState
            }
        }
    }
}
