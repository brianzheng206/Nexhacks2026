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
    
    // Expose the RoomCaptureSession so it can be used with RoomCaptureView
    @Published private(set) var roomCaptureSession: RoomCaptureSession?
    private var lastUpdateTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 0.2 // 5Hz = 200ms for room updates
    private let frameInterval: TimeInterval = 0.1 // 10 fps = 100ms for preview frames
    private var lastMeshUpdateTime: TimeInterval = 0
    private let meshUpdateInterval: TimeInterval = 0.5 // 2Hz = 500ms for mesh updates (lower frequency due to size)
    
    // Reusable CIContext for JPEG conversion - creating this once prevents flickering
    // CIContext is heavyweight and expensive to create; reusing it is critical for performance
    private lazy var ciContext: CIContext = {
        // Use default options - hardware accelerated, no caching for better performance
        return CIContext()
    }()
    
    // Serial queue for frame processing to prevent out-of-order frames
    private let frameProcessingQueue = DispatchQueue(label: "com.roomscan.frameProcessing", qos: .userInitiated)
    
    // Flag to prevent frame queue buildup (backpressure)
    private var isProcessingFrame = false
    
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
        
        // Enable scene reconstruction for detailed mesh with classification
        // This gives us colored, detailed mesh instead of just boxes
        let arConfig = ARWorldTrackingConfiguration()
        arConfig.sceneReconstruction = .meshWithClassification // Enables detailed mesh with semantic colors
        arConfig.planeDetection = [.horizontal, .vertical]
        roomCaptureSession.arSession.run(arConfig, options: [.resetTracking, .removeExistingAnchors])
        
        // Configure RoomPlan with coaching enabled
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        
        // Run the RoomPlan session
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
    private func exportUSDZ(from capturedRoomData: CapturedRoomData) async {
        let builder = RoomBuilder(options: .beautifyObjects)
        
        do {
            let capturedRoom = try await builder.capturedRoom(from: capturedRoomData)
            
            // Create temporary file path
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "room_\(UUID().uuidString).usdz"
            let fileURL = tempDir.appendingPathComponent(fileName)
            
            // Export to USDZ
            try capturedRoom.export(to: fileURL, exportOptions: .mesh)
            
            print("[ScanController] USDZ exported to: \(fileURL.path)")
            
            // Upload to server
            if let host = WSClient.shared.currentHost, let token = token {
                let port = WSClient.shared.currentPort ?? 8080
                uploadUSDZ(fileURL: fileURL, host: host, port: port, token: token)
            } else {
                print("[ScanController] Cannot upload: missing server host or token")
            }
            
        } catch {
            print("[ScanController] Error exporting USDZ: \(error)")
            errorMessage = "Failed to export USDZ: \(error.localizedDescription)"
        }
    }
    
    // Upload USDZ to server
    func uploadUSDZ(fileURL: URL, host: String, port: Int, token: String) {
        let uploadURL = URL(string: "http://\(host):\(port)/upload/usdz?token=\(token)")!
        
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
        let instructionText = String(describing: instruction)
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
                Task {
                    await self.exportUSDZ(from: capturedRoomData)
                }
            }
            
            // Clean up
            self.roomCaptureSession = nil
        }
    }
}

// MARK: - ARSessionDelegate

extension ScanController: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        // Handle mesh anchors for detailed 3D reconstruction
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                sendMeshUpdate(meshAnchor: meshAnchor)
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Update mesh anchors as they refine
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastMeshUpdateTime >= meshUpdateInterval else { return }
        lastMeshUpdateTime = currentTime
        
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                sendMeshUpdate(meshAnchor: meshAnchor)
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Throttle to ~10 fps
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastFrameTime >= frameInterval else { return }
        
        // Backpressure: skip this frame if still processing the previous one
        // This prevents frame queue buildup which causes flickering
        guard !isProcessingFrame else { return }
        
        lastFrameTime = currentTime
        isProcessingFrame = true
        
        // Copy pixel buffer reference before dispatching
        let pixelBuffer = frame.capturedImage
        
        // Process on serial queue to ensure frame ordering
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            defer {
                // Mark processing complete so next frame can be processed
                self.isProcessingFrame = false
            }
            
            guard let jpegData = self.convertPixelBufferToJPEG(pixelBuffer) else {
                // Conversion failed, skip this frame
                return
            }
            
            // Send as binary WebSocket message
            WSClient.shared.sendJPEGFrame(jpegData)
        }
    }
    
    private func convertPixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        // Create CIImage from CVPixelBuffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Use the reusable CIContext (critical for performance - creating new context per frame causes flickering)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            print("[ScanController] Failed to create CGImage from CIImage")
            return nil
        }
        
        // Convert to UIImage
        // ARFrame images are typically in landscape orientation, adjust as needed
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        
        // Convert to JPEG Data with compression quality (0.6 = good balance of quality/size for streaming)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.6) else {
            print("[ScanController] Failed to convert UIImage to JPEG")
            return nil
        }
        
        return jpegData
    }
    
    // Send mesh update with colors and detail
    // Uses verified ARKit APIs: ARMeshAnchor.geometry provides ARGeometrySource/ARGeometryElement
    private func sendMeshUpdate(meshAnchor: ARMeshAnchor) {
        guard let token = token else { return }
        
        let geometry = meshAnchor.geometry
        let transform = meshAnchor.transform
        
        // Access vertices through ARGeometrySource - verified API
        // ARMeshGeometry.vertices is an ARGeometrySource
        let vertexSource = geometry.vertices
        let vertexCount = vertexSource.count
        
        guard vertexCount > 0 else {
            print("[ScanController] Empty mesh")
            return
        }
        
        // Extract vertices from ARGeometrySource buffer - verified API
        var vertexArray: [[Float]] = []
        let vertexBuffer = vertexSource.buffer
        let vertexPointer = vertexBuffer.contents().assumingMemoryBound(to: SIMD3<Float>.self)
        let vertexStride = vertexSource.stride / MemoryLayout<SIMD3<Float>>.size
        
        for i in 0..<vertexCount {
            let vertex = vertexPointer[i * vertexStride]
            vertexArray.append([vertex.x, vertex.y, vertex.z])
        }
        
        // Access faces through ARGeometryElement - verified API
        // ARMeshGeometry.faces is an ARGeometryElement
        let faceElement = geometry.faces
        let faceCount = faceElement.count
        var faceArray: [[Int]] = []
        
        // Extract face indices from ARGeometryElement buffer - verified API
        let faceBuffer = faceElement.buffer
        let facePointer = faceBuffer.contents().assumingMemoryBound(to: UInt32.self)
        let indicesPerPrimitive = faceElement.indicesPerPrimitive // Should be 3 for triangles
        let faceStride = faceElement.stride / MemoryLayout<UInt32>.size
        
        for i in 0..<faceCount {
            let baseIndex = i * faceStride * indicesPerPrimitive
            if baseIndex + 2 < faceElement.count * faceStride * indicesPerPrimitive {
                faceArray.append([
                    Int(facePointer[baseIndex]),
                    Int(facePointer[baseIndex + 1]),
                    Int(facePointer[baseIndex + 2])
                ])
            }
        }
        
        // Get colors based on classification (semantic coloring)
        // classificationOf(faceWithIndex:) is a verified API
        var colorArray: [[Float]] = []
        
        // For each vertex, find which faces use it and get their classification
        for vertexIndex in 0..<vertexCount {
            var classifications: [ARMeshClassification] = []
            
            // Sample faces to find which ones use this vertex
            for faceIndex in 0..<min(faceCount, 100) { // Limit for performance
                // Get face indices for this face
                let baseIndex = faceIndex * faceStride * indicesPerPrimitive
                let v0 = Int(facePointer[baseIndex])
                let v1 = Int(facePointer[baseIndex + 1])
                let v2 = Int(facePointer[baseIndex + 2])
                
                // Check if this vertex is part of this face
                if v0 == vertexIndex || v1 == vertexIndex || v2 == vertexIndex {
                    // Get classification using verified API
                    let classification = geometry.classificationOf(faceWithIndex: faceIndex)
                    classifications.append(classification)
                }
            }
            
            // Use most common classification, or default
            let mostCommon = classifications.first ?? .none
            let color = getColorForClassification(mostCommon)
            colorArray.append([color.r, color.g, color.b, 1.0])
        }
        
        // Flatten transform matrix
        var transformArray: [Float] = []
        transformArray.append(transform.columns.0.x)
        transformArray.append(transform.columns.0.y)
        transformArray.append(transform.columns.0.z)
        transformArray.append(transform.columns.0.w)
        transformArray.append(transform.columns.1.x)
        transformArray.append(transform.columns.1.y)
        transformArray.append(transform.columns.1.z)
        transformArray.append(transform.columns.1.w)
        transformArray.append(transform.columns.2.x)
        transformArray.append(transform.columns.2.y)
        transformArray.append(transform.columns.2.z)
        transformArray.append(transform.columns.2.w)
        transformArray.append(transform.columns.3.x)
        transformArray.append(transform.columns.3.y)
        transformArray.append(transform.columns.3.z)
        transformArray.append(transform.columns.3.w)
        
        let message: [String: Any] = [
            "type": "mesh_update",
            "token": token,
            "anchorId": meshAnchor.identifier.uuidString,
            "vertices": vertexArray,
            "faces": faceArray,
            "colors": colorArray,
            "transform": transformArray,
            "t": Int(Date().timeIntervalSince1970)
        ]
        
        sendMessage(message)
    }
    
    // Get color based on classification (semantic coloring)
    private func getColorForClassification(_ classification: ARMeshClassification) -> (r: Float, g: Float, b: Float) {
        switch classification {
        case .wall:
            return (0.8, 0.8, 0.9) // Light gray-blue for walls
        case .floor:
            return (0.7, 0.7, 0.7) // Gray for floor
        case .ceiling:
            return (0.9, 0.9, 0.9) // White for ceiling
        case .table:
            return (0.6, 0.4, 0.2) // Brown for tables
        case .seat:
            return (0.4, 0.2, 0.6) // Purple for seats
        case .window:
            return (0.5, 0.7, 0.9) // Light blue for windows
        case .door:
            return (0.5, 0.3, 0.1) // Brown for doors
        case .none:
            return (0.5, 0.5, 0.5) // Gray for unclassified
        @unknown default:
            return (0.5, 0.5, 0.5) // Default gray
        }
    }
}
