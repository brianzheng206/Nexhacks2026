//
//  WebSocketManager.swift
//  RoomSensor
//
//  Created on 2024
//

import Foundation

protocol WebSocketManagerDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect(error: Error?)
    func webSocketDidReceiveControl(action: String)
    func webSocketDidReceiveStatus(framesCaptured: Int, chunksUploaded: Int, depthOk: Bool)
}

class WebSocketManager {
    weak var delegate: WebSocketManagerDelegate?
    
    private let laptopIP: String
    private let token: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    
    init(laptopIP: String, token: String) {
        self.laptopIP = laptopIP
        self.token = token
    }
    
    func connect(completion: @escaping (Bool, String?) -> Void) {
        // Construct WebSocket URL
        let wsURLString = "ws://\(laptopIP):8080/ws?token=\(token)"
        guard let url = URL(string: wsURLString) else {
            completion(false, "Invalid URL: \(wsURLString)")
            return
        }
        
        let urlSession = URLSession(configuration: .default)
        self.urlSession = urlSession
        
        let webSocketTask = urlSession.webSocketTask(with: url)
        self.webSocketTask = webSocketTask
        
        // Send hello message on connect
        webSocketTask.resume()
        
        // Send hello message
        sendHello { [weak self] success in
            if success {
                self?.receiveMessages()
                self?.delegate?.webSocketDidConnect()
                completion(true, nil)
            } else {
                completion(false, "Failed to send hello message")
            }
        }
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        delegate?.webSocketDidDisconnect(error: nil)
    }
    
    func sendControl(action: String) {
        let message: [String: Any] = [
            "type": "control",
            "action": action
        ]
        
        sendJSON(message)
    }
    
    func sendBinary(data: Data) {
        guard let webSocketTask = webSocketTask else { return }
        
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask.send(message) { error in
            if let error = error {
                print("WebSocket binary send error: \(error)")
            }
        }
    }
    
    func sendJSON(_ json: [String: Any]) {
        sendJSON(json, completion: nil)
    }
    
    private func sendHello(completion: @escaping (Bool) -> Void) {
        let hello: [String: Any] = [
            "type": "hello",
            "role": "phone",
            "token": token
        ]
        
        sendJSON(hello, completion: completion)
    }
    
    private func sendJSON(_ json: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let webSocketTask = webSocketTask else {
            completion?(false)
            return
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion?(false)
            return
        }
        
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask.send(message) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                self.handleMessage(message)
                // Continue receiving
                self.receiveMessages()
                
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                self.delegate?.webSocketDidDisconnect(error: error)
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
            
        case .data(let data):
            // Binary data (JPEG preview frames) - not handled in this skeleton
            print("Received binary data: \(data.count) bytes")
            
        @unknown default:
            print("Unknown message type")
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("Failed to parse JSON message: \(text)")
            return
        }
        
        guard let type = json["type"] as? String else {
            return
        }
        
        switch type {
        case "hello_ack":
            print("Received hello_ack")
            
        case "control":
            if let action = json["action"] as? String {
                delegate?.webSocketDidReceiveControl(action: action)
            }
            
        case "status", "instruction":
            // Handle status updates
            let framesCaptured = json["framesCaptured"] as? Int ?? 0
            let chunksUploaded = json["chunksUploaded"] as? Int ?? 0
            let depthOk = json["depthOk"] as? Bool ?? false
            delegate?.webSocketDidReceiveStatus(
                framesCaptured: framesCaptured,
                chunksUploaded: chunksUploaded,
                depthOk: depthOk
            )
            
        default:
            print("Unknown message type: \(type)")
        }
    }
}
