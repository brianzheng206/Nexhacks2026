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
    private var currentToken: String?
    private var helloCompletion: ((Bool, String?) -> Void)?
    private var isWaitingForHelloAck: Bool = false
    
    // Connection state management
    private let connectionLock = NSLock()
    private var isConnecting: Bool = false
    private var shouldReceiveMessages: Bool = false
    
    private var connectionTimeoutTimer: Timer?
    private var helloAckTimeoutTimer: Timer?
    private var keepaliveTimer: Timer?
    private let connectionTimeout: TimeInterval = 10.0
    private let helloAckTimeout: TimeInterval = 5.0
    private let keepaliveInterval: TimeInterval = 20.0
    
    private init() {}
    
    func connect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        logger.info("========== CONNECT CALLED ==========")
        logger.info("Host: \(laptopHost), Port: \(port), Token length: \(token.count)")
        
        let trimmedHost = laptopHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedHost.isEmpty else {
            logger.error("Invalid server address - empty host")
            DispatchQueue.main.async {
                completion(false, "Invalid server address")
            }
            return
        }
        
        // If already connected with same credentials, return success immediately
        if isConnected,
           let existingHost = currentHost, existingHost == trimmedHost,
           let existingPort = currentPort, existingPort == port,
           let existingToken = currentToken, existingToken == trimmedToken {
            logger.info("Already connected with same credentials - returning success")
            DispatchQueue.main.async {
                completion(true, nil)
            }
            return
        }
        
        // Prevent multiple simultaneous connection attempts
        if isConnecting {
            logger.warn("Connection already in progress - queuing completion")
            let existingCompletion = helloCompletion
            helloCompletion = { success, error in
                existingCompletion?(success, error)
                completion(success, error)
            }
            return
        }
        
        isConnecting = true

        logger.debug("Cancelling any existing timers...")
        cleanupTimers()
        
        // Disconnect existing connection if credentials changed
        if currentHost != nil || currentPort != nil || currentToken != nil {
            logger.debug("Disconnecting existing connection (credentials changed)...")
            disconnectInternal(clearCompletion: false, releaseLock: false)
        }

        currentHost = trimmedHost
        currentPort = port
        currentToken = trimmedToken
        helloCompletion = completion
        isWaitingForHelloAck = false
        shouldReceiveMessages = false
        
        let urlString = "ws://\(trimmedHost):\(port)"
        logger.info("WebSocket URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            logger.error("Invalid WebSocket URL: \(urlString)")
            isConnecting = false
            DispatchQueue.main.async {
                completion(false, "Invalid WebSocket URL")
            }
            return
        }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        urlSession = session
        
        logger.info("Created URLSession and WebSocketTask")
        shouldReceiveMessages = true
        logger.info(">>> Setting up receiveMessages() BEFORE resume()")
        receiveMessages()
        logger.info(">>> Calling webSocketTask.resume()...")
        webSocketTask?.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            logger.info(">>> Sending hello after 0.2s delay...")
            self.sendHello(token: trimmedToken)
        }
        
        logger.debug("Setting hello_ack timeout timer: \(helloAckTimeout)s")
        helloAckTimeoutTimer = Timer.scheduledTimer(withTimeInterval: helloAckTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.connectionLock.lock()
            defer { self.connectionLock.unlock() }
            
            guard self.isWaitingForHelloAck else { return }
            logger.error(">>> HELLO_ACK TIMEOUT - no response after \(self.helloAckTimeout) seconds")
            self.isWaitingForHelloAck = false
            self.isConnecting = false
            self.cleanupTimers()
            let completion = self.helloCompletion
            self.helloCompletion = nil
            DispatchQueue.main.async {
                completion?(false, "Connection timeout - server may be unreachable or token invalid")
            }
        }
        
        logger.debug("Setting connection timeout timer: \(connectionTimeout)s")
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.connectionLock.lock()
            defer { self.connectionLock.unlock() }
            
            if !self.isConnected && self.helloCompletion != nil {
                logger.error(">>> CONNECTION TIMEOUT - failed after \(self.connectionTimeout) seconds")
                self.isConnecting = false
                self.cleanupTimers()
                let completion = self.helloCompletion
                self.helloCompletion = nil
                self.disconnectInternal(clearCompletion: false, releaseLock: false)
                DispatchQueue.main.async {
                    completion?(false, "Connection timeout - unable to reach server")
                }
            }
        }
    }
    
    private func sendHello(token: String) {
        connectionLock.lock()
        let task = webSocketTask
        let completion = helloCompletion
        connectionLock.unlock()
        
        logger.info("========== SEND HELLO ==========")
        
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        
        logger.debug("Token after trim: length=\(trimmedToken.count), masked=\(trimmedToken.maskedForLogging)")
        
        guard !trimmedToken.isEmpty else {
            logger.error("Token validation failed - token is empty after trimming")
            connectionLock.lock()
            cleanupTimers()
            isConnecting = false
            let completion = helloCompletion
            helloCompletion = nil
            connectionLock.unlock()
            DispatchQueue.main.async {
                completion?(false, "Invalid authentication. Please check your session token.")
            }
            return
        }
        
        guard let task = task else {
            logger.error("Cannot send hello - webSocketTask is nil")
            connectionLock.lock()
            cleanupTimers()
            isConnecting = false
            let completion = helloCompletion
            helloCompletion = nil
            connectionLock.unlock()
            DispatchQueue.main.async {
                completion?(false, "Connection not established")
            }
            return
        }
        
        let helloMessage: [String: Any] = [
            "type": "hello",
            "role": "phone",
            "token": trimmedToken
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: helloMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to create hello message JSON")
            connectionLock.lock()
            cleanupTimers()
            isConnecting = false
            let completion = helloCompletion
            helloCompletion = nil
            connectionLock.unlock()
            DispatchQueue.main.async {
                completion?(false, "Failed to create hello message")
            }
            return
        }
        
        logger.info("Sending hello message: \(jsonString.prefix(100))...")
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        task.send(message) { [weak self] error in
            guard let self = self else { return }
            
            self.connectionLock.lock()
            defer { self.connectionLock.unlock() }
            
            if let error = error {
                logger.error(">>> HELLO SEND FAILED: \(error.localizedDescription)")
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
                self.cleanupTimers()
                self.isConnecting = false
                let completion = self.helloCompletion
                self.helloCompletion = nil
                DispatchQueue.main.async {
                    completion?(false, errorMsg)
                }
            } else {
                logger.info(">>> HELLO SENT SUCCESSFULLY - waiting for hello_ack...")
                self.isWaitingForHelloAck = true
            }
        }
    }
    
    private func receiveMessages() {
        connectionLock.lock()
        let shouldReceive = shouldReceiveMessages
        let task = webSocketTask
        connectionLock.unlock()
        
        guard shouldReceive, let task = task else {
            logger.debug(">>> receiveMessages() - not receiving (shouldReceive: \(shouldReceive), task: \(task != nil))")
            return
        }
        
        logger.debug(">>> receiveMessages() called")
        
        task.receive { [weak self] result in
            guard let self = self else {
                logger.debug("receiveMessages callback - self is nil")
                return
            }
            
            self.connectionLock.lock()
            let shouldContinue = self.shouldReceiveMessages
            self.connectionLock.unlock()
            
            guard shouldContinue else {
                logger.debug(">>> receiveMessages() - stopped receiving")
                return
            }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    logger.debug(">>> RECEIVED TEXT MESSAGE: \(text.prefix(200))...")
                    self.handleTextMessage(text)
                case .data(let data):
                    logger.debug(">>> RECEIVED BINARY MESSAGE: \(data.count) bytes")
                    self.handleBinaryMessage(data)
                @unknown default:
                    logger.debug(">>> RECEIVED UNKNOWN MESSAGE TYPE")
                }
                
                // Continue receiving messages
                self.receiveMessages()
                
            case .failure(let error):
                logger.error(">>> RECEIVE ERROR: \(error.localizedDescription)")
                
                // Check if this is a normal close vs an error
                if let urlError = error as? URLError {
                    // Some errors are expected (like connection closed)
                    if urlError.code == .networkConnectionLost || urlError.code == .timedOut {
                        logger.debug("Network error detected - handling disconnection")
                    }
                }
                
                // Only handle disconnection if we were connected or connecting
                self.connectionLock.lock()
                let wasConnected = self.isConnected
                let wasConnecting = self.isConnecting || self.helloCompletion != nil
                self.connectionLock.unlock()
                
                if wasConnected || wasConnecting {
                    self.handleDisconnection()
                }
            }
        }
    }
    
    private func handleTextMessage(_ text: String) {
        logger.debug("Parsing text message...")
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            logger.error("Invalid message format - cannot parse JSON or missing 'type' field")
            return
        }
        
        logger.info(">>> MESSAGE TYPE: \(type)")
        
        switch type {
        case "hello_ack":
            logger.info("========== HELLO_ACK RECEIVED ==========")
            logger.info("Connection SUCCESSFUL!")
            
            connectionLock.lock()
            isWaitingForHelloAck = false
            isConnecting = false
            
            // Cancel timers on successful connection
            logger.debug("Cancelling timers...")
            cleanupTimers()
            
            logger.debug("Updating connection state to true...")
            updateConnectionState(true)
            
            logger.debug("Calling onConnectionStateChanged callback...")
            let stateCallback = onConnectionStateChanged
            let completion = helloCompletion
            helloCompletion = nil
            connectionLock.unlock()
            
            // Start keepalive timer
            startKeepalive()
            
            stateCallback?(true)
            
            logger.debug("Calling helloCompletion callback...")
            DispatchQueue.main.async {
                completion?(true, nil)
            }
            
            logger.info("Connection handshake complete!")
            
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
        logger.debug("Received binary data: \(data.count) bytes")
    }
    
    private(set) var isSendingFrame = false
    
    var canAcceptFrame: Bool {
        return isConnected && !isSendingFrame
    }
    
    @discardableResult
    func sendJPEGFrame(_ data: Data) -> Bool {
        guard isConnected else {
            return false
        }
        
        guard !isSendingFrame else {
            return false
        }
        
        isSendingFrame = true
        
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { [weak self] error in
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
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        logger.info(">>> handleDisconnection called")
        
        // Only handle if we were actually connected or connecting
        guard isConnected || isConnecting || helloCompletion != nil else {
            logger.debug(">>> handleDisconnection - already disconnected, ignoring")
            return
        }
        
        cleanupTimers()
        shouldReceiveMessages = false
        
        updateConnectionState(false)
        let stateCallback = onConnectionStateChanged
        
        // If we have a pending completion, call it with failure
        let completion = helloCompletion
        helloCompletion = nil
        isConnecting = false
        
        connectionLock.unlock()
        
        stateCallback?(false)
        
        if let completion = completion {
            logger.debug("Calling pending helloCompletion with failure")
            DispatchQueue.main.async {
                completion(false, "Connection lost")
            }
        }
    }
    
    private func disconnectInternal(clearCompletion: Bool, releaseLock: Bool = true) {
        if releaseLock {
            connectionLock.lock()
        }
        defer {
            if releaseLock {
                connectionLock.unlock()
            }
        }
        
        logger.info(">>> disconnectInternal called (clearCompletion: \(clearCompletion))")
        
        cleanupTimers()
        shouldReceiveMessages = false
        isConnecting = false
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        updateConnectionState(false)
        
        currentHost = nil
        currentPort = nil
        currentToken = nil
        isWaitingForHelloAck = false
        
        if clearCompletion {
            helloCompletion = nil
        }
    }
    
    func disconnect() {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        
        logger.info(">>> disconnect() called")
        disconnectInternal(clearCompletion: true, releaseLock: false)
        let stateCallback = onConnectionStateChanged
        connectionLock.unlock()
        
        stateCallback?(false)
    }
    
    private func cleanupTimers() {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer?.invalidate()
        helloAckTimeoutTimer = nil
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }
    
    private func startKeepalive() {
        cleanupTimers()
        
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: keepaliveInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            self.connectionLock.lock()
            let connected = self.isConnected
            let task = self.webSocketTask
            self.connectionLock.unlock()
            
            guard connected, let task = task else {
                self.cleanupTimers()
                return
            }
            
            // Send ping to keep connection alive
            task.sendPing { [weak self] error in
                if let error = error {
                    logger.error("Keepalive ping failed: \(error.localizedDescription)")
                    self?.handleDisconnection()
                } else {
                    logger.debug("Keepalive ping successful")
                }
            }
        }
    }
    
    private func updateConnectionState(_ newState: Bool) {
        logger.debug("updateConnectionState: \(isConnected) -> \(newState)")
        
        if Thread.isMainThread {
            isConnected = newState
        } else {
            DispatchQueue.main.sync {
                isConnected = newState
            }
        }
    }
}
