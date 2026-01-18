@ -1,218 +0,0 @@
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
    
    var currentLaptopIP: String?
    private var currentToken: String?
    private var helloCompletion: ((Bool, String?) -> Void)?
    private var isWaitingForHelloAck: Bool = false
    
    private init() {}
    
    func connect(laptopIP: String, token: String, completion: @escaping (Bool, String?) -> Void) {
        currentLaptopIP = laptopIP
        currentToken = token
        helloCompletion = completion
        
        let urlString = "ws://\(laptopIP):8080"
        guard let url = URL(string: urlString) else {
            completion(false, "Invalid URL")
            return
        }
        
        // Disconnect existing connection if any
        disconnect()
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        urlSession = session
        
        webSocketTask?.resume()
        
        // Start receiving messages first (to catch hello_ack)
        receiveMessages()
        
        // Send hello message
        sendHello(token: token)
        
        // Set timeout for hello_ack
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.isWaitingForHelloAck else { return }
            self.isWaitingForHelloAck = false
            self.helloCompletion?(false, "Connection timeout")
            self.helloCompletion = nil
        }
    }
    
    private func sendHello(token: String) {
        let helloMessage: [String: Any] = [
            "type": "hello",
            "role": "phone",
            "token": token
        ]
        
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
                self?.helloCompletion?(false, "Failed to send hello: \(error.localizedDescription)")
                self?.helloCompletion = nil
            } else {
                print("[WSClient] Hello message sent, waiting for ack...")
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
        // Binary messages no longer used - mesh is displayed via HTTP polling
        print("[WSClient] Received binary data: \(data.count) bytes (ignored)")
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
        if let ip = currentLaptopIP, let token = currentToken {
            reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.connect(laptopIP: ip, token: token) { _, _ in }
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