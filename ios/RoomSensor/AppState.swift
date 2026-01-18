//
//  AppState.swift
//  RoomSensor
//
//  Created on 2024
//

import Foundation
import Combine
import ARKit

enum ScanningState {
    case disconnected
    case connected
    case scanning
    case uploading(chunkNumber: Int)
}

class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var scanningState: ScanningState = .disconnected
    @Published var laptopIP: String?
    @Published var token: String?
    
    private var webSocketManager: WebSocketManager?
    private var arkitManager: ARKitManager?
    
    func connect(laptopIP: String, token: String, completion: @escaping (Bool, String?) -> Void) {
        self.laptopIP = laptopIP
        self.token = token
        
        webSocketManager = WebSocketManager(laptopIP: laptopIP, token: token)
        webSocketManager?.delegate = self
        
        webSocketManager?.connect { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.isConnected = true
                    self?.scanningState = .connected
                }
                completion(success, error)
            }
        }
    }
    
    func finalizeMesh(completion: @escaping (Bool, String?) -> Void) {
        guard let laptopIP = laptopIP, let token = token else {
            completion(false, "Not connected")
            return
        }
        
        let urlString = "http://\(laptopIP):8080/finalize?token=\(token)"
        guard let url = URL(string: urlString) else {
            completion(false, "Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                completion(false, "Server error")
                return
            }
            
            completion(true, nil)
        }
        
        task.resume()
    }
    
    func disconnect() {
        webSocketManager?.disconnect()
        webSocketManager = nil
        isConnected = false
        scanningState = .disconnected
    }
    
    func startScan() {
        // Start ARKit session first
        if arkitManager == nil {
            arkitManager = ARKitManager()
            arkitManager?.webSocketManager = webSocketManager
            arkitManager?.delegate = self
            arkitManager?.laptopIP = laptopIP
            arkitManager?.token = token
        }
        arkitManager?.startSession()
        
        scanningState = .scanning
        
        // Note: We don't send control message back to server
        // The server already forwarded it to us
    }
    
    func stopScan() {
        // Stop ARKit session (this will flush remaining keyframes)
        arkitManager?.stopSession { [weak self] in
            // Called after all uploads are complete
            DispatchQueue.main.async {
                self?.scanningState = .connected
                
                // Send ready_to_finalize status
                let status: [String: Any] = [
                    "type": "status",
                    "value": "ready_to_finalize"
                ]
                self?.webSocketManager?.sendJSON(status)
            }
        }
    }
    
    func getARSession() -> ARSession? {
        return arkitManager?.getARSession()
    }
}

extension AppState: WebSocketManagerDelegate {
    func webSocketDidConnect() {
        DispatchQueue.main.async {
            self.isConnected = true
            self.scanningState = .connected
        }
    }
    
    func webSocketDidDisconnect(error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.scanningState = .disconnected
        }
    }
    
    func webSocketDidReceiveControl(action: String) {
        DispatchQueue.main.async {
            switch action {
            case "start":
                self.startScan()
            case "stop":
                self.stopScan()
            default:
                break
            }
        }
    }
    
    func webSocketDidReceiveStatus(framesCaptured: Int, chunksUploaded: Int, depthOk: Bool) {
        // Handle status updates if needed
    }
}

extension AppState: ARKitManagerDelegate {
    func arkitDidUpdateStatus(frames: Int, keyframes: Int, depthOk: Bool) {
        // Update status if needed
    }
    
    func arkitDidError(message: String) {
        DispatchQueue.main.async {
            print("ARKit error: \(message)")
            // Post notification for UI to display
            NotificationCenter.default.post(name: NSNotification.Name("ARKitError"), object: message)
        }
    }
}

extension AppState {
    func resetSession() {
        arkitManager?.resetSession()
    }
}
