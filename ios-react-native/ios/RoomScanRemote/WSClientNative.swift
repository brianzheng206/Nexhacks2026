//
//  WSClientNative.swift
//  RoomScanRemote
//
//  Native WebSocket client implementation
//

import Foundation

protocol WSClientNativeDelegate: AnyObject {
  func connectionStateChanged(_ connected: Bool)
  func receivedControlMessage(_ action: String)
  func receivedRoomUpdate(_ data: [String: Any])
  func receivedInstruction(_ message: String)
  func receivedStatus(_ message: String)
}

class WSClientNative {
  weak var delegate: WSClientNativeDelegate?
  private var webSocketTask: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var isConnectedValue: Bool = false
  private var currentToken: String?
  private var currentLaptopIP: String?
  
  var isConnected: Bool {
    return isConnectedValue
  }
  
  var laptopIP: String? {
    return currentLaptopIP
  }
  
  func connect(laptopIP: String, token: String, completion: @escaping (Bool, String?) -> Void) {
    currentToken = token
    currentLaptopIP = laptopIP
    let urlString = "ws://\(laptopIP):8080"
    guard let url = URL(string: urlString) else {
      completion(false, "Invalid URL")
      return
    }
    
    disconnect()
    
    let session = URLSession(configuration: .default)
    webSocketTask = session.webSocketTask(with: url)
    urlSession = session
    
    webSocketTask?.resume()
    receiveMessages()
    sendHello(token: token, completion: completion)
  }
  
  private func sendHello(token: String, completion: @escaping (Bool, String?) -> Void) {
    let helloMessage: [String: Any] = [
      "type": "hello",
      "role": "phone",
      "token": token
    ]
    
    guard let jsonData = try? JSONSerialization.data(withJSONObject: helloMessage),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
      completion(false, "Failed to create hello message")
      return
    }
    
    let message = URLSessionWebSocketTask.Message.string(jsonString)
    webSocketTask?.send(message) { [weak self] error in
      if let error = error {
        completion(false, error.localizedDescription)
      } else {
        // Wait for hello_ack
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          self?.isConnectedValue = true
          self?.delegate?.connectionStateChanged(true)
          completion(true, nil)
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
          // Binary data (JPEG frames) - not needed in React Native side
          break
        @unknown default:
          break
        }
        self.receiveMessages()
        
      case .failure:
        self.isConnectedValue = false
        self.delegate?.connectionStateChanged(false)
      }
    }
  }
  
  private func handleTextMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String else {
      return
    }
    
    switch type {
    case "hello_ack":
      isConnectedValue = true
      delegate?.connectionStateChanged(true)
      
    case "control":
      if let action = json["action"] as? String {
        delegate?.receivedControlMessage(action)
      }
      
    case "room_update":
      delegate?.receivedRoomUpdate(json)
      
    case "instruction":
      if let message = json["message"] as? String ?? json["text"] as? String {
        delegate?.receivedInstruction(message)
      }
      
    case "status":
      if let message = json["message"] as? String ?? json["text"] as? String {
        delegate?.receivedStatus(message)
      }
      
    default:
      break
    }
  }
  
  func sendMessage(_ message: String) {
    guard isConnectedValue else { return }
    let wsMessage = URLSessionWebSocketTask.Message.string(message)
    webSocketTask?.send(wsMessage) { _ in }
  }
  
  func sendJPEGFrame(_ data: Data) {
    guard isConnectedValue else { return }
    let wsMessage = URLSessionWebSocketTask.Message.data(data)
    webSocketTask?.send(wsMessage) { _ in }
  }
  
  func disconnect() {
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    urlSession = nil
    isConnectedValue = false
    delegate?.connectionStateChanged(false)
  }
}
