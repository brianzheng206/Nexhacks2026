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
    
    private var connectionTimeoutTimer: Timer?
    private var helloAckTimeoutTimer: Timer?
    private let connectionTimeout: TimeInterval = 10.0
    private let helloAckTimeout: TimeInterval = 5.0
    
    private init() {}
    
    func connect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        logger.info("========== CONNECT CALLED ==========")
        logger.info("Host: \(laptopHost), Port: \(port), Token length: \(token.count)")
        
        let trimmedHost = laptopHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            logger.error("Invalid server address - empty host")
            completion(false, "Invalid server address")
            return
        }

        logger.debug("Cancelling any existing timers...")
        connectionTimeoutTimer?.invalidate()
        helloAckTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer = nil

        currentHost = trimmedHost
        currentPort = port
        currentToken = token
        helloCompletion = completion
        isWaitingForHelloAck = false
        
        let urlString = "ws://\(trimmedHost):\(port)"
        logger.info("WebSocket URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            logger.error("Invalid WebSocket URL: \(urlString)")
            completion(false, "Invalid WebSocket URL")
            return
        }
        
        if let existingHost = currentHost, let existingPort = currentPort,
           existingHost == trimmedHost && existingPort == port,
           let existingToken = currentToken, existingToken == token {
            logger.debug("Already connecting to same host/port/token - skipping disconnect")
        } else {
            logger.debug("Disconnecting any existing connection...")
            disconnectInternal(clearCompletion: false)
        }
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        urlSession = session
        
        logger.info("Created URLSession and WebSocketTask")
        logger.info(">>> Setting up receiveMessages() BEFORE resume()")
        receiveMessages()
        logger.info(">>> Calling webSocketTask.resume()...")
        webSocketTask?.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            logger.info(">>> Sending hello after 0.2s delay...")
            self.sendHello(token: token)
        }
        
        logger.debug("Setting hello_ack timeout timer: \(helloAckTimeout)s")
        helloAckTimeoutTimer = Timer.scheduledTimer(withTimeInterval: helloAckTimeout, repeats: false) { [weak self] _ in
            guard let self = self, self.isWaitingForHelloAck else { return }
            logger.error(">>> HELLO_ACK TIMEOUT - no response after \(self.helloAckTimeout) seconds")
            self.isWaitingForHelloAck = false
            self.helloAckTimeoutTimer = nil
            self.helloCompletion?(false, "Connection timeout - server may be unreachable or token invalid")
            self.helloCompletion = nil
        }
        
        logger.debug("Setting connection timeout timer: \(connectionTimeout)s")
        connectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectionTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected && self.helloCompletion != nil {
                logger.error(">>> CONNECTION TIMEOUT - failed after \(self.connectionTimeout) seconds")
                self.connectionTimeoutTimer = nil
                self.helloAckTimeoutTimer?.invalidate()
                self.helloAckTimeoutTimer = nil
                self.isWaitingForHelloAck = false
                self.helloCompletion?(false, "Connection timeout - unable to reach server")
                self.helloCompletion = nil
                self.disconnect()
            }
        }
    }
    
    private func sendHello(token: String) {
        logger.info("========== SEND HELLO ==========")
        
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        
        logger.debug("Token after trim: length=\(trimmedToken.count), masked=\(trimmedToken.maskedForLogging)")
        
        guard !trimmedToken.isEmpty else {
            logger.error("Token validation failed - token is empty after trimming")
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
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: helloMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to create hello message JSON")
            helloCompletion?(false, "Failed to create hello message")
            helloCompletion = nil
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            return
        }
        
        logger.info("Sending hello message: \(jsonString.prefix(100))...")
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { [weak self] error in
            guard let self = self else { return }
            
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
                self.connectionTimeoutTimer?.invalidate()
                self.connectionTimeoutTimer = nil
                self.helloCompletion?(false, errorMsg)
                self.helloCompletion = nil
            } else {
                logger.info(">>> HELLO SENT SUCCESSFULLY - waiting for hello_ack...")
                self.isWaitingForHelloAck = true
            }
        }
    }
    
    private func receiveMessages() {
        logger.debug(">>> receiveMessages() called")
        
        guard let task = webSocketTask else {
            logger.error("Cannot receive messages: webSocketTask is nil")
            return
        }
        
        logger.debug("Setting up receive handler...")
        
        task.receive { [weak self] result in
            guard let self = self else {
                logger.debug("receiveMessages callback - self is nil")
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
                
                self.receiveMessages()
                
            case .failure(let error):
                logger.error(">>> RECEIVE ERROR: \(error.localizedDescription)")
                if self.isConnected || self.helloCompletion != nil {
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
            
            isWaitingForHelloAck = false
            
            // Cancel timers on successful connection
            logger.debug("Cancelling timers...")
            connectionTimeoutTimer?.invalidate()
            connectionTimeoutTimer = nil
            helloAckTimeoutTimer?.invalidate()
            helloAckTimeoutTimer = nil
            
            logger.debug("Updating connection state to true...")
            updateConnectionState(true)
            
            logger.debug("Calling onConnectionStateChanged callback...")
            onConnectionStateChanged?(true)
            
            logger.debug("Calling helloCompletion callback...")
            let completion = helloCompletion
            helloCompletion = nil
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
        logger.info(">>> handleDisconnection called")
        
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer?.invalidate()
        helloAckTimeoutTimer = nil
        
        updateConnectionState(false)
        onConnectionStateChanged?(false)
        
        // If we have a pending completion, call it with failure
        if let completion = helloCompletion {
            logger.debug("Calling pending helloCompletion with failure")
            helloCompletion = nil
            DispatchQueue.main.async {
                completion(false, "Connection lost")
            }
        }
    }
    
    private func disconnectInternal(clearCompletion: Bool) {
        connectionTimeoutTimer?.invalidate()
        connectionTimeoutTimer = nil
        helloAckTimeoutTimer?.invalidate()
        helloAckTimeoutTimer = nil
        
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
        logger.info(">>> disconnect() called")
        disconnectInternal(clearCompletion: true)
        onConnectionStateChanged?(false)
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
