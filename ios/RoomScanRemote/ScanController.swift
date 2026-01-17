//
//  ScanController.swift
//  RoomScanRemote
//
//  Controller for RoomPlan scanning
//

import Foundation
import Combine
import ARKit
import RoomPlan
import CoreImage
import UIKit

class ScanController: NSObject, ObservableObject {
    @Published var isScanning: Bool = false
    @Published var errorMessage: String?
    
    private var roomCaptureSession: RoomCaptureSession?
    private var lastUpdateTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 0.2 // 5Hz = 200ms for room updates
    private let frameInterval: TimeInterval = 0.1 // 10 fps = 100ms for preview frames
    
    var token: String?
    
    override init() {
        super.init()
    }
    
    func startScan() {
        guard !isScanning else { return }
        
        // Check if RoomPlan is supported
        guard RoomCaptureSession.isSupported else {
            DispatchQueue.main.async {
                self.errorMessage = "RoomPlan is not supported on this device"
            }
            print("[ScanController] RoomPlan not supported")
            return
        }
        
        // Initialize RoomCaptureSession
        let roomCaptureSession = RoomCaptureSession()
        roomCaptureSession.delegate = self
        self.roomCaptureSession = roomCaptureSession
        
        // Set ARSession delegate for frame capture
        roomCaptureSession.arSession.delegate = self
        
        // Configure with coaching enabled
        let configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        
        // Run the session
        roomCaptureSession.run(configuration: configuration)
        
        DispatchQueue.main.async {
            self.isScanning = true
            self.errorMessage = nil
        }
        print("[ScanController] Scan started")
    }
    
    func stopScan() {
        guard isScanning else { return }
        
        // Clear ARSession delegate before stopping
        roomCaptureSession?.arSession.delegate = nil
        roomCaptureSession?.stop()
        roomCaptureSession = nil
        
        DispatchQueue.main.async {
            self.isScanning = false
        }
        print("[ScanController] Scan stopped")
    }
    
    // Send instruction message to server
    private func sendInstruction(_ instruction: String) {
        guard let token = token else { return }
        
        let message: [String: Any] = [
            "type": "instruction",
            "value": instruction,
            "token": token
        ]
        
        sendMessage(message)
    }
    
    // Send room update with throttling (~5Hz)
    private func sendRoomUpdate(capturedRoom: CapturedRoom) {
        let currentTime = Date().timeIntervalSince1970
        
        // Throttle to ~5Hz
        guard currentTime - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = currentTime
        
        guard let token = token else { return }
        
        // Extract minimal stats (counts only)
        let stats: [String: Int] = [
            "walls": capturedRoom.walls.count,
            "doors": capturedRoom.doors.count,
            "windows": capturedRoom.windows.count,
            "objects": capturedRoom.objects.count
        ]
        
        // Extract wall geometry
        var walls: [[String: Any]] = []
        for wall in capturedRoom.walls {
            var wallData: [String: Any] = [
                "identifier": wall.identifier.uuidString
            ]
            
            // Flatten 4x4 transform matrix (16 floats, column-major)
            let transform = wall.transform
            var transformArray: [Float] = []
            // Column 0
            transformArray.append(transform.columns.0.x)
            transformArray.append(transform.columns.0.y)
            transformArray.append(transform.columns.0.z)
            transformArray.append(transform.columns.0.w)
            // Column 1
            transformArray.append(transform.columns.1.x)
            transformArray.append(transform.columns.1.y)
            transformArray.append(transform.columns.1.z)
            transformArray.append(transform.columns.1.w)
            // Column 2
            transformArray.append(transform.columns.2.x)
            transformArray.append(transform.columns.2.y)
            transformArray.append(transform.columns.2.z)
            transformArray.append(transform.columns.2.w)
            // Column 3 (translation)
            transformArray.append(transform.columns.3.x)
            transformArray.append(transform.columns.3.y)
            transformArray.append(transform.columns.3.z)
            transformArray.append(transform.columns.3.w)
            wallData["transform"] = transformArray
            
            // Dimensions
            wallData["dimensions"] = [
                "width": wall.dimensions.x,
                "height": wall.dimensions.y,
                "length": wall.dimensions.z
            ]
            
            // polygonCorners if available (check if wall has edge information)
            // Note: RoomPlan Surfaces don't directly expose polygonCorners
            // We'll leave this empty for now and handle it if available in future API versions
            // wallData["polygonCorners"] = [] // Placeholder
            
            walls.append(wallData)
        }
        
        let message: [String: Any] = [
            "type": "room_update",
            "stats": stats,
            "walls": walls,
            "t": Int(currentTime),
            "token": token
        ]
        
        sendMessage(message)
    }
    
    // Send message via WebSocket
    private func sendMessage(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[ScanController] Failed to serialize message")
            return
        }
        
        let wsClient = WSClient.shared
        guard wsClient.isConnected else {
            print("[ScanController] Cannot send message: not connected")
            return
        }
        
        // Send via WebSocket (we'll need to add a method to WSClient for this)
        wsClient.sendMessage(jsonString)
    }
    
    // Export USDZ file
    private func exportUSDZ(from capturedRoomData: CapturedRoomData) {
        let builder = RoomBuilder(options: .beautifyObjects)
        
        do {
            let capturedRoom = try builder.captureRoom(from: capturedRoomData)
            
            // Create temporary file path
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "room_\(UUID().uuidString).usdz"
            let fileURL = tempDir.appendingPathComponent(fileName)
            
            // Export to USDZ
            try capturedRoom.export(to: fileURL, exportOptions: .mesh)
            
            print("[ScanController] USDZ exported to: \(fileURL.path)")
            
            // Upload to server
            if let laptopIP = WSClient.shared.currentLaptopIP, let token = token {
                uploadUSDZ(fileURL: fileURL, laptopIP: laptopIP, token: token)
            } else {
                print("[ScanController] Cannot upload: missing laptopIP or token")
            }
            
        } catch {
            print("[ScanController] Error exporting USDZ: \(error)")
            errorMessage = "Failed to export USDZ: \(error.localizedDescription)"
        }
    }
    
    // Upload USDZ to server
    func uploadUSDZ(fileURL: URL, laptopIP: String, token: String) {
        let uploadURL = URL(string: "http://\(laptopIP):8080/upload/usdz?token=\(token)")!
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"room.usdz\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        
        guard let fileData = try? Data(contentsOf: fileURL) else {
            print("[ScanController] Failed to read file data from: \(fileURL.path)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to read USDZ file"
            }
            return
        }
        
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[ScanController] Upload error: \(error)")
                DispatchQueue.main.async {
                    self?.errorMessage = "Upload failed: \(error.localizedDescription)"
                }
                // Clean up temp file even on error
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("[ScanController] USDZ uploaded successfully")
                    
                    // Send status message to UI
                    self?.sendStatusMessage(value: "upload_complete")
                } else {
                    print("[ScanController] Upload failed with status: \(httpResponse.statusCode)")
                    DispatchQueue.main.async {
                        self?.errorMessage = "Upload failed with status: \(httpResponse.statusCode)"
                    }
                }
            }
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        task.resume()
    }
    
    // Send status message to server
    private func sendStatusMessage(value: String) {
        guard let token = token else { return }
        
        let message: [String: Any] = [
            "type": "status",
            "value": value,
            "token": token
        ]
        
        sendMessage(message)
    }
}

// MARK: - RoomCaptureSessionDelegate

extension ScanController: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let instructionText = instruction.localizedDescription
        print("[ScanController] Instruction: \(instructionText)")
        
        DispatchQueue.main.async {
            self.sendInstruction(instructionText)
        }
    }
    
    func captureSession(_ session: RoomCaptureSession, didUpdate capturedRoom: CapturedRoom) {
        // Throttled update at ~5Hz
        DispatchQueue.main.async {
            self.sendRoomUpdate(capturedRoom: capturedRoom)
        }
    }
    
    func captureSession(_ session: RoomCaptureSession, didEndWith capturedRoomData: CapturedRoomData, error: Error?) {
        DispatchQueue.main.async {
            self.isScanning = false
            
            if let error = error {
                print("[ScanController] Scan ended with error: \(error)")
                self.errorMessage = "Scan error: \(error.localizedDescription)"
            } else {
                print("[ScanController] Scan completed successfully")
                // Export USDZ
                self.exportUSDZ(from: capturedRoomData)
            }
            
            // Clean up
            self.roomCaptureSession = nil
        }
    }
}

// MARK: - ARSessionDelegate

extension ScanController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Throttle to ~10 fps
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastFrameTime >= frameInterval else { return }
        lastFrameTime = currentTime
        
        // Convert CVPixelBuffer to JPEG Data on background queue to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            guard let jpegData = self.convertPixelBufferToJPEG(frame.capturedImage) else {
                // Conversion failed, skip this frame (error already logged)
                return
            }
            
            // Send as binary WebSocket message
            WSClient.shared.sendJPEGFrame(jpegData)
        }
    }
    
    private func convertPixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        do {
            // Create CIImage from CVPixelBuffer
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            // Create CIContext with options for better performance
            let context = CIContext(options: [
                .useSoftwareRenderer: false,
                .workingColorSpace: NSNull()
            ])
            
            // Convert to CGImage
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                print("[ScanController] Failed to create CGImage from CIImage")
                return nil
            }
            
            // Convert to UIImage
            // ARFrame images are typically in landscape orientation, adjust as needed
            let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
            
            // Convert to JPEG Data with compression quality (0.7 = good balance of quality/size)
            guard let jpegData = uiImage.jpegData(compressionQuality: 0.7) else {
                print("[ScanController] Failed to convert UIImage to JPEG")
                return nil
            }
            
            return jpegData
        } catch {
            // Safeguard: catch any errors during conversion
            print("[ScanController] Error converting pixel buffer to JPEG: \(error)")
            return nil
        }
    }
}
