//
//  WSClient.swift
//  RoomScanRemote
//
//  WebSocket client using URLSessionWebSocketTask
//

import Foundation
import Combine

class WSClient: ObservableObject {
    static let shared = WSClient()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    
    @Published var isConnected: Bool = false
    
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
    
    private init() {}
    
    func connect(laptopHost: String, port: Int = 8080, token: String, completion: @escaping (Bool, String?) -> Void) {
        let trimmedHost = laptopHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            completion(false, "Invalid server address")
            return
        }

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
        
        // Give the WebSocket a brief moment to establish connection
        // URLSessionWebSocketTask will queue messages, but a small delay ensures better reliability
        // This is especially important on slower networks
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            // Send hello message - if connection isn't ready, send() will handle it
            self.sendHello(token: token)
        }
        
        // Set timeout for hello_ack
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isWaitingForHelloAck else { return }
            self.isWaitingForHelloAck = false
            print("[WSClient] Connection timeout - no hello_ack received after 5 seconds")
            self.helloCompletion?(false, "Connection timeout - server may be unreachable or token invalid")
            self.helloCompletion = nil
        }
    }
    
    private func sendHello(token: String) {
        // Trim whitespace from token to handle copy-paste issues
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let helloMessage: [String: Any] = [
            "type": "hello",
            "role": "phone",
            "token": trimmedToken
        ]
        
        print("[WSClient] Sending hello with token: '\(trimmedToken)' (length: \(trimmedToken.count))")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: helloMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            helloCompletion?(false, "Failed to create hello message")
            helloCompletion = nil
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                print("[WSClient] Error sending hello: \(error)")
                let errorMsg: String
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet:
                        errorMsg = "No internet connection"
                    case .cannotConnectToHost:
                        errorMsg = "Cannot connect to server. Check IP address and ensure server is running."
                    case .timedOut:
                        errorMsg = "Connection timed out"
                    default:
                        errorMsg = "Connection error: \(urlError.localizedDescription)"
                    }
                } else {
                    errorMsg = "Failed to send hello: \(error.localizedDescription)"
                }
                self?.helloCompletion?(false, errorMsg)
                self?.helloCompletion = nil
            } else {
                print("[WSClient] Hello message sent successfully, waiting for hello_ack...")
                self?.isWaitingForHelloAck = true
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
                    print("[WSClient] Unknown message type")
                }
                
                // Continue receiving messages
                self.receiveMessages()
                
            case .failure(let error):
                print("[WSClient] Receive error: \(error)")
                self.handleDisconnection()
            }
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[WSClient] Invalid message format: \(text)")
            return
        }
        
        switch type {
        case "hello_ack":
            print("[WSClient] Received hello_ack")
            isWaitingForHelloAck = false
            isConnected = true
            onConnectionStateChanged?(true)
            helloCompletion?(true, nil)
            helloCompletion = nil
            
        case "control":
            if let action = json["action"] as? String {
                print("[WSClient] Received control: \(action)")
                onControlMessage?(action)
            }
            
        case "room_update":
            print("[WSClient] Received room_update")
            onRoomUpdate?(json)
            
        case "instruction":
            if let message = json["message"] as? String ?? json["text"] as? String {
                print("[WSClient] Received instruction: \(message)")
                onInstruction?(message)
            }
            
        case "status":
            if let message = json["message"] as? String ?? json["text"] as? String {
                print("[WSClient] Received status: \(message)")
                onStatus?(message)
            }
            
        default:
            print("[WSClient] Unknown message type: \(type)")
        }
    }
    
    private func handleBinaryMessage(_ data: Data) {
        // Binary messages are JPEG frames - we'll handle these when implementing RoomPlan
        print("[WSClient] Received binary data: \(data.count) bytes")
    }
    
    // Flag to track if a frame send is in progress (backpressure)
    private var isSendingFrame = false
    
    func sendJPEGFrame(_ data: Data) {
        guard isConnected else {
            // Silently skip if not connected (avoid log spam)
            return
        }
        
        // Backpressure: skip if previous frame is still being sent
        // This prevents WebSocket buffer buildup which causes flickering/lag
        guard !isSendingFrame else {
            return
        }
        
        isSendingFrame = true
        
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { [weak self] error in
            self?.isSendingFrame = false
            
            if let error = error {
                print("[WSClient] Error sending JPEG frame (\(data.count) bytes): \(error)")
            }
        }
    }
    
    func sendMessage(_ jsonString: String) {
        guard isConnected else {
            print("[WSClient] Cannot send message: not connected")
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("[WSClient] Error sending message: \(error)")
            }
        }
    }
    
    private func handleDisconnection() {
        isConnected = false
        onConnectionStateChanged?(false)
        
        // Attempt to reconnect
        if let host = currentHost, let token = currentToken {
            let port = currentPort ?? 8080
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.connect(laptopHost: host, port: port, token: token) { _, _ in }
            }
        }
    }
    
    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        isConnected = false
        onConnectionStateChanged?(false)
    }
}
