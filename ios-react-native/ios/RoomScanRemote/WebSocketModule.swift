//
//  WebSocketModule.swift
//  RoomScanRemote
//
//  React Native module for WebSocket client
//

import Foundation
import React

@objc(WebSocketModule)
class WebSocketModule: RCTEventEmitter {
  private var wsClient: WSClientNative?
  
  @objc
  static func requiresMainQueueSetup() -> Bool {
    return false
  }
  
  override init() {
    super.init()
    self.wsClient = WSClientNative()
    self.wsClient?.delegate = self
    
    // Listen for messages from other modules
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSendMessage(_:)),
      name: NSNotification.Name("SendWebSocketMessage"),
      object: nil
    )
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleSendJPEG(_:)),
      name: NSNotification.Name("SendWebSocketJPEG"),
      object: nil
    )
  }
  
  @objc private func handleSendMessage(_ notification: Notification) {
    if let message = notification.userInfo?["message"] as? String {
      sendMessage(message)
    }
  }
  
  @objc private func handleSendJPEG(_ notification: Notification) {
    if let data = notification.userInfo?["data"] as? Data {
      sendJPEGFrame(data)
    }
  }
  
  override func supportedEvents() -> [String]! {
    return ["connectionStateChanged", "controlMessage", "roomUpdate", "instruction", "status"]
  }
  
  @objc
  func connect(_ laptopIP: String, token: String, resolver: @escaping RCTPromiseResolveBlock, rejecter: @escaping RCTPromiseRejectBlock) {
    wsClient?.connect(laptopIP: laptopIP, token: token) { success, error in
      if success {
        resolver(true)
      } else {
        rejecter("CONNECTION_ERROR", error ?? "Connection failed", nil)
      }
    }
  }
  
  @objc
  func disconnect() {
    wsClient?.disconnect()
  }
  
  @objc
  func sendMessage(_ message: String) {
    wsClient?.sendMessage(message)
  }
  
  @objc
  func sendJPEGFrame(_ data: Data) {
    wsClient?.sendJPEGFrame(data)
  }
}

extension WebSocketModule: WSClientNativeDelegate {
  func connectionStateChanged(_ connected: Bool) {
    sendEvent(withName: "connectionStateChanged", body: connected)
  }
  
  func receivedControlMessage(_ action: String) {
    sendEvent(withName: "controlMessage", body: action)
  }
  
  func receivedRoomUpdate(_ data: [String: Any]) {
    sendEvent(withName: "roomUpdate", body: data)
  }
  
  func receivedInstruction(_ message: String) {
    sendEvent(withName: "instruction", body: message)
  }
  
  func receivedStatus(_ message: String) {
    sendEvent(withName: "status", body: message)
  }
}

