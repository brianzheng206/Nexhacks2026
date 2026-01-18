//  ScanController.swift
//  RoomScanRemote
//
//  Controller for RoomPlan scanning with detailed mesh capture
//
//  Requirements:
//  - iOS 17.0+ (RoomCaptureSession with custom ARSession)
//  - Device with LiDAR scanner (required for mesh reconstruction)
//
//  Features:
//  - RoomPlan structured room data (walls, doors, windows, objects)
//  - ARKit mesh anchors for detailed 3D geometry (vertices, faces, normals, classifications)
//  - Combined scanning for both parametric and detailed mesh data
//

import Foundation
import Combine
import ARKit
import RoomPlan
import CoreImage
import CoreVideo
import ImageIO
import UIKit
import Metal

private let logger = AppLogger.scanning
private let frameLogger = AppLogger.frameProcessing

class ScanController: NSObject, ObservableObject {
    @Published var isScanning: Bool = false
    @Published var errorMessage: String?
    @Published var roomCaptureSession: RoomCaptureSession?
    
    private var lastUpdateTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 0.2
    private let frameInterval: TimeInterval = 0.1
    
    private var ciContext: CIContext?
    private let frameProcessingQueue = DispatchQueue(label: "com.roomscan.frameProcessing", qos: .userInitiated)
    private let processingLock = NSLock()
    private var _isProcessingFrame = false
    
    // Lock for safe access to the latest AR frame
    private let frameLock = NSLock()
    private var _currentFrame: ARFrame?
    private var currentFrame: ARFrame? {
        get {
            frameLock.lock()
            defer { frameLock.unlock() }
            return _currentFrame
        }
        set {
            frameLock.lock()
            defer { frameLock.unlock() }
            _currentFrame = newValue
        }
    }
    
    private var isProcessingFrame: Bool {
        get {
            processingLock.lock()
            defer { processingLock.unlock() }
            return _isProcessingFrame
        }
        set {
            processingLock.lock()
            defer { processingLock.unlock() }
            _isProcessingFrame = newValue
        }
    }
    
    // Frame statistics for monitoring and adaptive rate control
    private var totalFramesProcessed: Int = 0
    private var totalFramesDropped: Int = 0
    private var framesSinceLastLog: Int = 0
    private let statisticsLogInterval = 100
    
    // Real-time FPS tracking (actual frames being sent)
    @Published private(set) var actualFPS: Double = 0.0
    private var frameTimestamps: [Date] = []
    private let fpsCalculationWindow: TimeInterval = 2.0 // Calculate FPS over last 2 seconds
    private var lastFPSUpdate: Date = Date()
    private let fpsUpdateInterval: TimeInterval = 0.5 // Update FPS display every 0.5 seconds
    
    private func updateFPS() {
        let now = Date()
        let cutoffTime = now.addingTimeInterval(-fpsCalculationWindow)
        
        // Clean up old timestamps to prevent memory growth
        frameTimestamps.removeAll { $0 < cutoffTime }
        
        guard !frameTimestamps.isEmpty else {
            // Only update on main thread if enough time has passed
            if now.timeIntervalSince(lastFPSUpdate) >= fpsUpdateInterval {
                DispatchQueue.main.async { [weak self] in
                    self?.actualFPS = 0.0
                }
                lastFPSUpdate = now
            }
            return
        }
        
        let timeSpan = now.timeIntervalSince(frameTimestamps.first!)
        guard timeSpan > 0 else {
            if now.timeIntervalSince(lastFPSUpdate) >= fpsUpdateInterval {
                DispatchQueue.main.async { [weak self] in
                    self?.actualFPS = 0.0
                }
                lastFPSUpdate = now
            }
            return
        }
        
        let calculatedFPS = Double(frameTimestamps.count) / timeSpan
        
        // Only update @Published property if enough time has passed to reduce UI updates
        if now.timeIntervalSince(lastFPSUpdate) >= fpsUpdateInterval {
            DispatchQueue.main.async { [weak self] in
                self?.actualFPS = calculatedFPS
            }
            lastFPSUpdate = now
        }
    }
    
    private var currentFrameInterval: TimeInterval = 0.1
    private let minFrameInterval: TimeInterval = 0.05
    private let maxFrameInterval: TimeInterval = 0.2
    private let adaptiveRateStep: TimeInterval = 0.01
    private var consecutiveDrops: Int = 0
    private let dropThresholdForSlowdown = 3
    
    var token: String? {
        didSet {
            if let oldValue = oldValue {
                var mutable = oldValue
                mutable.removeAll()
            }
        }
    }
    var connectionManager: ConnectionManager?
    
    // MARK: - Mesh Reconstruction Properties
    
    private var customARSession: ARSession?
    private var lastMeshUpdateTime: TimeInterval = 0
    private let meshUpdateInterval: TimeInterval = 0.5
    private let meshProcessingQueue = DispatchQueue(label: "com.roomscan.meshProcessing", qos: .userInitiated)
    private var sentMeshIdentifiers = Set<UUID>()
    private var totalMeshesSent: Int = 0
    private var totalVerticesSent: Int = 0
    
    // MARK: - Thread-Safe State Updates
    
    /// Updates @Published properties on main thread. All @Published updates must use this method.
    private func updateStateOnMain(
        isScanning: Bool? = nil,
        errorMessage: String?? = nil,
        roomCaptureSession: RoomCaptureSession?? = nil
    ) {
        if Thread.isMainThread {
            if let isScanning = isScanning {
                self.isScanning = isScanning
            }
            if let errorMessage = errorMessage {
                self.errorMessage = errorMessage
            }
            if let roomCaptureSession = roomCaptureSession {
                self.roomCaptureSession = roomCaptureSession
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let isScanning = isScanning {
                    self.isScanning = isScanning
                }
                if let errorMessage = errorMessage {
                    self.errorMessage = errorMessage
                }
                if let roomCaptureSession = roomCaptureSession {
                    self.roomCaptureSession = roomCaptureSession
                }
            }
        }
    }
    
    override init() {
        super.init()
        prewarmCIContext()
    }
    
    init(connectionManager: ConnectionManager) {
        super.init()
        self.connectionManager = connectionManager
        prewarmCIContext()
    }
    
    private func prewarmCIContext() {
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            self.ciContext = CIContext()
            logger.debug("CIContext initialized on background queue")
        }
    }
    
    func startScan() {
        guard !isScanning else { return }
        
        guard RoomCaptureSession.isSupported else {
            updateStateOnMain(errorMessage: "RoomPlan is not supported on this device")
            logger.error("RoomPlan not supported on this device")
            return
        }
        
        let meshSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        logger.info("Mesh reconstruction supported: \(meshSupported)")
        
        let arSession = ARSession()
        let arConfig = ARWorldTrackingConfiguration()
        arConfig.planeDetection = [.horizontal, .vertical]
        
        if meshSupported {
            arConfig.sceneReconstruction = .meshWithClassification
            logger.info("Enabled mesh reconstruction with classification")
        } else {
            logger.info("Mesh reconstruction not supported - using RoomPlan parametric data only")
        }
        
        customARSession = arSession
        arSession.delegate = self
        
        let session: RoomCaptureSession
        
        if let existingSession = roomCaptureSession {
            session = existingSession
            
            // Only set delegates when starting a scan
            if session.delegate !== self {
                session.delegate = self
            }
            if session.arSession.delegate !== self {
                session.arSession.delegate = self
            }
            
            logger.info("Using existing RoomCaptureSession from RoomCaptureView")
        } else {
            logger.info("Creating new RoomCaptureSession with custom ARSession for mesh capture")
            
            if let oldSession = roomCaptureSession {
                oldSession.arSession.delegate = nil
                oldSession.delegate = nil
                oldSession.stop()
            }
            
            if #available(iOS 17.0, *) {
                session = RoomCaptureSession(arSession: arSession)
                logger.info("Created RoomCaptureSession with custom ARSession (iOS 17+)")
            } else {
                session = RoomCaptureSession()
                logger.info("Fallback: Created default RoomCaptureSession (iOS 16)")
            }
            
            session.delegate = self
            session.arSession.delegate = self
            updateStateOnMain(roomCaptureSession: session)
            
            logger.info("Created new RoomCaptureSession - ScanController owns this session")
        }
        
        let configuration = RoomCaptureSession.Configuration()
        session.run(configuration: configuration)
        updateStateOnMain(isScanning: true, errorMessage: nil)
        
        totalFramesProcessed = 0
        totalFramesDropped = 0
        framesSinceLastLog = 0
        consecutiveDrops = 0
        currentFrameInterval = frameInterval
        isProcessingFrame = false
        frameTimestamps.removeAll()
        
        sentMeshIdentifiers.removeAll()
        totalMeshesSent = 0
        totalVerticesSent = 0
        lastMeshUpdateTime = 0
        
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            if self.ciContext == nil {
                self.ciContext = CIContext()
                logger.debug("CIContext created during scan start")
            }
        }
        
        sendStatusMessage(value: "scan_started")
        logger.info("Scan started - frame rate: \(1.0/frameInterval) fps, mesh enabled: \(meshSupported)")
    }
    
    func stopScan() {
        guard isScanning else { return }
        
        // Remove ARSession delegate to stop processing frames when not scanning
        // This prevents unnecessary frame processing when just showing camera feed
        if let session = roomCaptureSession {
            // Keep the session running for camera feed, but remove our delegate
            // The RoomCaptureView will continue to show the camera feed
            session.arSession.delegate = nil
            session.stop()
            logger.info("Stopped RoomCaptureSession (keeping for camera feed display)")
        }
        
        customARSession?.pause()
        customARSession = nil
        updateStateOnMain(isScanning: false, roomCaptureSession: nil)
        
        // Clean up frame processing state
        isProcessingFrame = false
        
        // Clean up frame timestamps to free memory
        frameTimestamps.removeAll()
        actualFPS = 0.0
        
        if totalFramesProcessed > 0 || totalFramesDropped > 0 {
            let dropRate = Double(totalFramesDropped) / Double(totalFramesProcessed + totalFramesDropped) * 100.0
            logger.info("Scan stopped - Frame Statistics: Processed: \(totalFramesProcessed), Dropped: \(totalFramesDropped), Drop Rate: \(String(format: "%.1f", dropRate))%")
        }
        
        if totalMeshesSent > 0 {
            logger.info("Scan stopped - Mesh Statistics: Meshes sent: \(totalMeshesSent), Vertices sent: \(totalVerticesSent)")
        }
        
        sendStatusMessage(value: "scan_stopped")
        logger.info("Scan stopped")
    }
    
    deinit {
        if let session = roomCaptureSession {
            session.arSession.delegate = nil
            session.delegate = nil
            session.stop()
            if Thread.isMainThread {
                roomCaptureSession = nil
            } else {
                DispatchQueue.main.sync {
                    roomCaptureSession = nil
                }
            }
            logger.debug("Deallocated - cleaned up RoomCaptureSession")
        }
    }
    
    private func sendInstruction(_ instruction: String) {
        guard let token = token else { return }
        
        let message: [String: Any] = [
            "type": "instruction",
            "value": instruction,
            "token": token
        ]
        
        sendMessage(message)
    }
    
    private func sendRoomUpdate(capturedRoom: CapturedRoom) {
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = currentTime
        
        guard let token = token else { return }
        
        let stats: [String: Int] = [
            "walls": capturedRoom.walls.count,
            "doors": capturedRoom.doors.count,
            "windows": capturedRoom.windows.count,
            "objects": capturedRoom.objects.count
        ]
        
        let walls = capturedRoom.walls.map { serializeSurface($0) }
        let doors = capturedRoom.doors.map { serializeSurface($0) }
        let windows = capturedRoom.windows.map { serializeSurface($0) }
        let objects = capturedRoom.objects.map { serializeObject($0) }
        
        let message: [String: Any] = [
            "type": "room_update",
            "stats": stats,
            "walls": walls,
            "doors": doors,
            "windows": windows,
            "objects": objects,
            "t": Int(currentTime),
            "token": token
        ]
        
        sendMessage(message)
    }
    
    private func sendMessage(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to serialize message")
            return
        }
        
        if let connectionManager = connectionManager {
            guard connectionManager.isConnected else {
                logger.debug("Cannot send message: not connected")
                return
            }
            connectionManager.sendMessage(jsonString)
        } else {
            let wsClient = WSClient.shared
            guard wsClient.isConnected else {
                logger.debug("Cannot send message: not connected")
                return
            }
            wsClient.sendMessage(jsonString)
        }
    }
    
    /// Send a pre-serialized message (already a dictionary) - used when serialization happens on delegate thread
    private func sendMessageDirect(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to serialize message")
            return
        }
        
        if let connectionManager = connectionManager {
            guard connectionManager.isConnected else {
                logger.debug("Cannot send message: not connected")
                return
            }
            connectionManager.sendMessage(jsonString)
        } else {
            let wsClient = WSClient.shared
            guard wsClient.isConnected else {
                logger.debug("Cannot send message: not connected")
                return
            }
            wsClient.sendMessage(jsonString)
        }
    }

    private func serializeSurface(_ surface: CapturedRoom.Surface) -> [String: Any] {
        return [
            "identifier": surface.identifier.uuidString,
            "transform": flattenTransform(surface.transform),
            "dimensions": [
                "width": surface.dimensions.x,
                "height": surface.dimensions.y,
                "length": surface.dimensions.z
            ]
        ]
    }

    private func serializeObject(_ object: CapturedRoom.Object) -> [String: Any] {
        return [
            "identifier": object.identifier.uuidString,
            "category": String(describing: object.category),
            "transform": flattenTransform(object.transform),
            "dimensions": [
                "width": object.dimensions.x,
                "height": object.dimensions.y,
                "length": object.dimensions.z
            ]
        ]
    }

    private func flattenTransform(_ transform: simd_float4x4) -> [Float] {
        return [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
        ]
    }
    
    private func exportUSDZ(from capturedRoomData: CapturedRoomData) async {
        let builder = RoomBuilder(options: .beautifyObjects)
        
        do {
            let capturedRoom = try await builder.capturedRoom(from: capturedRoomData)
            
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "room_\(UUID().uuidString).usdz"
            let fileURL = tempDir.appendingPathComponent(fileName)
            
            try capturedRoom.export(to: fileURL, exportOptions: .mesh)
            
            logger.info("USDZ exported to: \(fileURL.path)")
            
            let host: String?
            let port: Int
            if let connectionManager = connectionManager {
                host = connectionManager.currentHost
                port = connectionManager.currentPort ?? 8080
            } else {
                host = WSClient.shared.currentHost
                port = WSClient.shared.currentPort ?? 8080
            }
            
            if let host = host, let token = token {
                uploadUSDZ(fileURL: fileURL, host: host, port: port, token: token)
            } else {
                logger.error("Cannot upload: missing server host or token")
            }
            
        } catch {
            logger.error("Error exporting USDZ: \(error.localizedDescription)")
            updateStateOnMain(errorMessage: "Failed to export USDZ: \(error.localizedDescription)")
        }
    }
    
    func uploadUSDZ(fileURL: URL, host: String, port: Int, token: String) {
        // Safely construct URL - avoid force unwrap
        guard let uploadURL = URL(string: "http://\(host):\(port)/upload/usdz?token=\(token)") else {
            logger.error("Failed to construct upload URL for host: \(host), port: \(port)")
            updateStateOnMain(errorMessage: "Invalid upload URL")
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"room.usdz\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        
        guard let fileData = try? Data(contentsOf: fileURL) else {
            logger.error("Failed to read file data from: \(fileURL.path)")
            // Update error message on main thread (URLSession callback may be on background thread)
            updateStateOnMain(errorMessage: "Failed to read USDZ file")
            return
        }
        
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                logger.error("Upload error: \(error.localizedDescription)")
                self?.updateStateOnMain(errorMessage: "Upload failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.info("USDZ uploaded successfully")
                    self?.sendStatusMessage(value: "upload_complete")
                } else {
                    logger.error("Upload failed with status: \(httpResponse.statusCode)")
                    self?.updateStateOnMain(errorMessage: "Upload failed with status: \(httpResponse.statusCode)")
                }
            }
            
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        task.resume()
    }
    
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
        // Capture instruction text on current thread before dispatching
        let instructionText = String(describing: instruction)
        logger.debug("Instruction: \(instructionText)")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Only send if still scanning
            guard self.isScanning else { return }
            self.sendInstruction(instructionText)
        }
    }
    
    func captureSession(_ session: RoomCaptureSession, didUpdate capturedRoom: CapturedRoom) {
        // Only process if still scanning
        guard isScanning else { return }
        
        // Serialize room data on current thread before dispatching to avoid accessing capturedRoom on wrong thread
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastUpdateTime >= updateInterval else { return }
        
        guard let token = token else { return }
        
        // Serialize immediately on callback thread
        let stats: [String: Int] = [
            "walls": capturedRoom.walls.count,
            "doors": capturedRoom.doors.count,
            "windows": capturedRoom.windows.count,
            "objects": capturedRoom.objects.count
        ]
        
        let walls = capturedRoom.walls.map { serializeSurface($0) }
        let doors = capturedRoom.doors.map { serializeSurface($0) }
        let windows = capturedRoom.windows.map { serializeSurface($0) }
        let objects = capturedRoom.objects.map { serializeObject($0) }
        
        lastUpdateTime = currentTime
        
        let message: [String: Any] = [
            "type": "room_update",
            "stats": stats,
            "walls": walls,
            "doors": doors,
            "windows": windows,
            "objects": objects,
            "t": Int(currentTime),
            "token": token
        ]
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.sendMessageDirect(message)
        }
    }
    
    func captureSession(_ session: RoomCaptureSession, didEndWith capturedRoomData: CapturedRoomData, error: Error?) {
        if let error = error {
            logger.error("Scan ended with error: \(error.localizedDescription)")
            updateStateOnMain(
                isScanning: false,
                errorMessage: "Scan error: \(error.localizedDescription)",
                roomCaptureSession: nil
            )
        } else {
            logger.info("Scan completed successfully")
            updateStateOnMain(isScanning: false, roomCaptureSession: nil)
            
            // Use Task with weak self to prevent retain cycle
            Task { [weak self] in
                guard let self = self else { return }
                await self.exportUSDZ(from: capturedRoomData)
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ScanController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Store the latest frame for mesh coloring
        self.currentFrame = frame
        
        // Only process frames when actively scanning to reduce CPU/memory usage
        guard isScanning else { return }
        
        // Capture connection state safely
        let isConnected: Bool
        let canAcceptFrame: Bool
        if let connectionManager = connectionManager {
            isConnected = connectionManager.isConnected
            canAcceptFrame = connectionManager.canAcceptFrame
        } else {
            isConnected = WSClient.shared.isConnected
            canAcceptFrame = WSClient.shared.canAcceptFrame
        }
        guard isConnected else { return }
        
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastFrameTime >= currentFrameInterval else { return }
        
        guard !isProcessingFrame && canAcceptFrame else {
            totalFramesDropped += 1
            framesSinceLastLog += 1
            consecutiveDrops += 1
            
            if consecutiveDrops >= dropThresholdForSlowdown {
                currentFrameInterval = min(currentFrameInterval + adaptiveRateStep, maxFrameInterval)
                consecutiveDrops = 0
                frameLogger.info("Network congestion detected - reduced frame rate to \(1.0/currentFrameInterval) fps")
            }
            
            logStatisticsIfNeeded()
            return
        }
        
        consecutiveDrops = 0
        
        if currentFrameInterval > minFrameInterval {
            currentFrameInterval = max(currentFrameInterval - adaptiveRateStep * 0.1, minFrameInterval)
        }
        
        lastFrameTime = currentTime
        isProcessingFrame = true
        totalFramesProcessed += 1
        framesSinceLastLog += 1
        
        frameTimestamps.append(Date())
        updateFPS()
        
        // Capture pixel buffer data - the buffer might be reused by ARKit
        let pixelBuffer = frame.capturedImage
        let cameraTransform = frame.camera.transform
        
        // Retain the pixel buffer for the async operation
        CVPixelBufferRetain(pixelBuffer)
        
        frameProcessingQueue.async { [weak self] in
            // Release the pixel buffer when done
            defer {
                CVPixelBufferRelease(pixelBuffer)
            }
            
            guard let self = self else { return }
            
            defer {
                self.isProcessingFrame = false
            }
            
            // Check if still scanning before processing
            guard self.isScanning else { return }
            
            guard let jpegData = self.convertPixelBufferToJPEG(pixelBuffer, cameraTransform: cameraTransform) else {
                DispatchQueue.main.async { [weak self] in
                    self?.totalFramesDropped += 1
                    self?.logStatisticsIfNeeded()
                }
                return
            }
            
            let accepted: Bool
            if let connectionManager = self.connectionManager {
                accepted = connectionManager.sendJPEGFrame(jpegData)
            } else {
                accepted = WSClient.shared.sendJPEGFrame(jpegData)
            }
            
            if !accepted {
                DispatchQueue.main.async { [weak self] in
                    self?.totalFramesDropped += 1
                    frameLogger.debug("Warning: Frame rejected by WebSocket despite canAcceptFrame check")
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.logStatisticsIfNeeded()
            }
        }
    }
    
    // MARK: - Mesh Anchor Handling
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        processMeshAnchors(anchors)
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        processMeshAnchors(anchors)
    }
    
    /// Process mesh anchors and stream their geometry to the server
    private func processMeshAnchors(_ anchors: [ARAnchor]) {
        guard isScanning else { return }
        
        // Throttle mesh updates to avoid flooding the network
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastMeshUpdateTime >= meshUpdateInterval else { return }
        
        // Filter for mesh anchors only
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        
        lastMeshUpdateTime = currentTime
        
        // Limit number of mesh anchors processed per update to prevent memory pressure
        // Increased from 5 to 20 for better coverage
        let maxAnchorsPerUpdate = 20
        let anchorsToProcess = Array(meshAnchors.prefix(maxAnchorsPerUpdate))
        
        // Process mesh anchors on background queue
        meshProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if still scanning before processing
            guard self.isScanning else { return }
            
            for meshAnchor in anchorsToProcess {
                // Check if still scanning before each anchor
                guard self.isScanning else { break }
                self.processMeshAnchor(meshAnchor)
            }
        }
    }
    
    private func processMeshAnchor(_ meshAnchor: ARMeshAnchor) {
        // Check if still scanning before processing
        guard isScanning else { return }
        
        // Wrap in autoreleasepool to ensure proper memory management of Metal buffers
        autoreleasepool {
            let geometry = meshAnchor.geometry
            
            // Capture anchor data immediately to avoid issues if anchor is modified
            let anchorIdentifier = meshAnchor.identifier
            let anchorTransform = meshAnchor.transform
            
            let vertices2D = extractVertices2D(from: geometry.vertices)
            let vertexCount = vertices2D.count
            
            // Skip empty meshes
            guard vertexCount > 0 else {
                logger.debug("Skipping empty mesh anchor: \(anchorIdentifier)")
                return
            }
            
            // Limit mesh size to prevent memory issues
            // Increased to 100,000 for more detail
            let maxVertices = 100000
            guard vertexCount <= maxVertices else {
                logger.debug("Skipping oversized mesh: \(vertexCount) vertices (max: \(maxVertices))")
                return
            }
            
            let faces2D = extractFaces2D(from: geometry.faces)
            
            // Skip if no faces
            guard !faces2D.isEmpty else {
                logger.debug("Skipping mesh with no faces: \(anchorIdentifier)")
                return
            }
            
            // Try to use real-world colors from camera frame first
            // Fallback to semantic colors if frame not available
            var colors2D: [[Float]]
            
            if let frame = self.currentFrame {
                colors2D = generateRealWorldColors(
                    vertices: vertices2D,
                    transform: anchorTransform,
                    frame: frame
                )
            } else {
                var faceClassifications: [Int]?
                if let classificationSource = geometry.classification {
                    faceClassifications = extractClassifications(from: classificationSource, faceCount: geometry.faces.count)
                }
                
                colors2D = generateVertexColors(
                    vertexCount: vertexCount,
                    faces: faces2D,
                    faceClassifications: faceClassifications
                )
            }
            
            // Check if still scanning before sending
            guard isScanning else { return }
            
            // Send mesh data in server-expected format
            sendMeshUpdate(
                identifier: anchorIdentifier,
                transform: anchorTransform,
                vertices: vertices2D,
                faces: faces2D,
                colors: colors2D
            )
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.totalMeshesSent += 1
                self.totalVerticesSent += vertexCount
                self.sentMeshIdentifiers.insert(anchorIdentifier)
            }
        }
    }
    
    /// Generate real-world colors by projecting vertices onto the camera image
    private func generateRealWorldColors(
        vertices: [[Float]],
        transform: simd_float4x4,
        frame: ARFrame
    ) -> [[Float]] {
        let pixelBuffer = frame.capturedImage
        
        // Lock the base address for safe access
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        // Ensure we have Y and CbCr planes (bi-planar)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            return Array(repeating: [0.5, 0.5, 0.5], count: vertices.count)
        }
        
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return Array(repeating: [0.5, 0.5, 0.5], count: vertices.count)
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        
        let camera = frame.camera
        
        // Use .right orientation as capturedImage is usually landscape (native sensor)
        // Projecting with .right matches the buffer layout (0,0 is top-left of buffer)
        let orientation: UIInterfaceOrientation = .right
        let viewportSize = CGSize(width: 1, height: 1) // Normalized coordinates
        
        var colors: [[Float]] = []
        colors.reserveCapacity(vertices.count)
        
        for vertex in vertices {
            // Convert vertex to world space
            // Vertices are [x, y, z] floats
            let localVertex = simd_float4(vertex[0], vertex[1], vertex[2], 1)
            let worldVertex = transform * localVertex
            let worldPos = simd_float3(worldVertex.x, worldVertex.y, worldVertex.z)
            
            // Project to 2D image coordinates (0..1)
            let projectedPoint = camera.projectPoint(worldPos, orientation: orientation, viewportSize: viewportSize)
            
            // Check bounds (0..1)
            if projectedPoint.x >= 0 && projectedPoint.x < 1 && projectedPoint.y >= 0 && projectedPoint.y < 1 {
                // Sample color from pixel buffer
                // projectedPoint x,y maps to pixel coordinates
                let x = Int(projectedPoint.x * CGFloat(width))
                let y = Int(projectedPoint.y * CGFloat(height))
                
                // Read Y (Luma) - plane 0
                let yIndex = y * yBytesPerRow + x
                let yValue = baseAddress.load(fromByteOffset: yIndex, as: UInt8.self)
                
                // Read UV (Chroma) - plane 1 - Subsampled 2x2 usually
                let uvIndex = (y / 2) * uvBytesPerRow + (x / 2) * 2
                let cbValue = uvBaseAddress.load(fromByteOffset: uvIndex, as: UInt8.self)
                let crValue = uvBaseAddress.load(fromByteOffset: uvIndex + 1, as: UInt8.self)
                
                // Convert YCbCr to RGB
                // Y is [16, 235], Cb/Cr are [16, 240] usually, or full range [0, 255]
                // Assuming full range or close approximation
                let y = Float(yValue)
                let cb = Float(cbValue) - 128.0
                let cr = Float(crValue) - 128.0
                
                let r = max(0, min(255, y + 1.402 * cr))
                let g = max(0, min(255, y - 0.344136 * cb - 0.714136 * cr))
                let b = max(0, min(255, y + 1.772 * cb))
                
                colors.append([r / 255.0, g / 255.0, b / 255.0])
            } else {
                // Out of view - use a neutral gray
                colors.append([0.5, 0.5, 0.5])
            }
        }
        
        return colors
    }
    
    /// Generate per-vertex colors based on face classifications
    /// Server expects colors array to match vertices array (per-vertex colors)
    /// ARMeshClassification values:
    /// 0 = none, 1 = wall, 2 = floor, 3 = ceiling, 4 = table, 5 = seat, 6 = window, 7 = door
    private func generateVertexColors(vertexCount: Int, faces: [[Int]], faceClassifications: [Int]?) -> [[Float]] {
        // Color mapping for mesh classifications
        let classificationColors: [[Float]] = [
            [0.5, 0.5, 0.5],    // 0: none - gray
            [0.8, 0.8, 0.9],    // 1: wall - light blue-gray
            [0.6, 0.5, 0.4],    // 2: floor - brown
            [0.9, 0.9, 0.85],   // 3: ceiling - off-white
            [0.6, 0.4, 0.3],    // 4: table - wood brown
            [0.4, 0.6, 0.8],    // 5: seat - blue
            [0.7, 0.9, 1.0],    // 6: window - light blue
            [0.5, 0.35, 0.25]
        ]
        
        let defaultColor: [Float] = [0.5, 0.5, 0.5]
        var vertexColors: [[Float]] = Array(repeating: defaultColor, count: vertexCount)
        
        if let classifications = faceClassifications {
            for (faceIndex, face) in faces.enumerated() {
                let classIndex = classifications[safe: faceIndex] ?? 0
                let color = classificationColors[safe: min(classIndex, classificationColors.count - 1)] ?? defaultColor
                
                // Assign this color to each vertex in the face
                for vertexIndex in face {
                    if vertexIndex >= 0 && vertexIndex < vertexCount {
                        vertexColors[vertexIndex] = color
                    }
                }
            }
        }
        
        return vertexColors
    }
    
    private func extractVertices2D(from source: ARGeometrySource) -> [[Float]] {
        let buffer = source.buffer
        let count = source.count
        let stride = source.stride
        let offset = source.offset
        let componentsPerVector = source.componentsPerVector
        
        // Safety check for valid buffer
        guard count > 0, stride > 0, componentsPerVector > 0 else {
            logger.debug("Invalid vertex source: count=\(count), stride=\(stride), components=\(componentsPerVector)")
            return []
        }
        
        // Validate buffer size
        let requiredSize = offset + (count * stride)
        guard buffer.length >= requiredSize else {
            logger.error("Buffer too small for vertex extraction: need \(requiredSize), have \(buffer.length)")
            return []
        }
        
        var result: [[Float]] = []
        result.reserveCapacity(count)
        
        let pointer = buffer.contents().advanced(by: offset)
        
        for i in 0..<count {
            let vertexPointer = pointer.advanced(by: i * stride)
            var vertex: [Float] = []
            vertex.reserveCapacity(componentsPerVector)
            
            for j in 0..<componentsPerVector {
                let value = vertexPointer.advanced(by: j * MemoryLayout<Float>.size).assumingMemoryBound(to: Float.self).pointee
                // Check for NaN or infinite values
                if value.isNaN || value.isInfinite {
                    vertex.append(0.0)
                } else {
                    vertex.append(value)
                }
            }
            result.append(vertex)
        }
        
        return result
    }
    
    private func extractFaces2D(from element: ARGeometryElement) -> [[Int]] {
        let buffer = element.buffer
        let count = element.count
        let indexCountPerPrimitive = element.indexCountPerPrimitive
        let bytesPerIndex = element.bytesPerIndex
        
        // Safety checks
        guard count > 0, indexCountPerPrimitive > 0, bytesPerIndex > 0 else {
            logger.debug("Invalid face element: count=\(count), indices=\(indexCountPerPrimitive), bytes=\(bytesPerIndex)")
            return []
        }
        
        // Validate buffer size
        let requiredSize = count * indexCountPerPrimitive * bytesPerIndex
        guard buffer.length >= requiredSize else {
            logger.error("Buffer too small for face extraction: need \(requiredSize), have \(buffer.length)")
            return []
        }
        
        var result: [[Int]] = []
        result.reserveCapacity(count)
        
        let pointer = buffer.contents()
        
        for i in 0..<count {
            var face: [Int] = []
            face.reserveCapacity(indexCountPerPrimitive)
            
            for j in 0..<indexCountPerPrimitive {
                let indexOffset = (i * indexCountPerPrimitive + j) * bytesPerIndex
                let indexPointer = pointer.advanced(by: indexOffset)
                
                if bytesPerIndex == 4 {
                    let value = indexPointer.assumingMemoryBound(to: UInt32.self).pointee
                    face.append(Int(value))
                } else if bytesPerIndex == 2 {
                    let value = indexPointer.assumingMemoryBound(to: UInt16.self).pointee
                    face.append(Int(value))
                } else {
                    // Unknown bytes per index - skip
                    logger.debug("Unknown bytesPerIndex: \(bytesPerIndex)")
                }
            }
            result.append(face)
        }
        
        return result
    }
    
    /// Extract classification data from ARGeometrySource
    private func extractClassifications(from source: ARGeometrySource, faceCount: Int) -> [Int] {
        let buffer = source.buffer
        let count = source.count
        let stride = source.stride
        let offset = source.offset
        
        // Safety checks
        guard count > 0, stride > 0 else {
            logger.debug("Invalid classification source: count=\(count), stride=\(stride)")
            return []
        }
        
        // Validate buffer size
        let requiredSize = offset + (count * stride)
        guard buffer.length >= requiredSize else {
            logger.error("Buffer too small for classification extraction: need \(requiredSize), have \(buffer.length)")
            return []
        }
        
        var result: [Int] = []
        result.reserveCapacity(count)
        
        let pointer = buffer.contents().advanced(by: offset)
        
        for i in 0..<count {
            let classPointer = pointer.advanced(by: i * stride)
            let value = classPointer.assumingMemoryBound(to: UInt8.self).pointee
            result.append(Int(value))
        }
        
        return result
    }
    
    private func sendMeshUpdate(
        identifier: UUID,
        transform: simd_float4x4,
        vertices: [[Float]],
        faces: [[Int]],
        colors: [[Float]]
    ) {
        guard let token = token else { return }
        
        let message: [String: Any] = [
            "type": "mesh_update",
            "anchorId": identifier.uuidString,
            "transform": flattenTransform(transform),
            "vertices": vertices,
            "faces": faces,
            "colors": colors,
            "t": Int(Date().timeIntervalSince1970),
            "token": token
        ]
        
        sendMessage(message)
    }
    
    private func logStatisticsIfNeeded() {
        guard framesSinceLastLog >= statisticsLogInterval else { return }
        
        let dropRate = totalFramesProcessed > 0 ? Double(totalFramesDropped) / Double(totalFramesProcessed + totalFramesDropped) * 100.0 : 0.0
        let targetFPS = 1.0 / currentFrameInterval
        
        frameLogger.debug("Frame Statistics: Processed: \(totalFramesProcessed), Dropped: \(totalFramesDropped), Drop Rate: \(String(format: "%.1f", dropRate))%, Actual FPS: \(String(format: "%.1f", actualFPS)), Target FPS: \(String(format: "%.1f", targetFPS)), Interval: \(String(format: "%.3f", currentFrameInterval))s")
        
        framesSinceLastLog = 0
    }
    
    private func convertPixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer, cameraTransform: simd_float4x4) -> Data? {
        assert(!Thread.isMainThread, "convertPixelBufferToJPEG must be called on frameProcessingQueue, not main thread")
        
        guard let context = ciContext else {
            logger.debug("CIContext not available - creating fallback context")
            let fallbackContext = CIContext()
            return convertPixelBufferToJPEGInternal(pixelBuffer: pixelBuffer, context: fallbackContext, cameraTransform: cameraTransform)
        }
        
        return convertPixelBufferToJPEGInternal(pixelBuffer: pixelBuffer, context: context, cameraTransform: cameraTransform)
    }
    
    // Internal conversion method - uses provided CIContext
    private func convertPixelBufferToJPEGInternal(pixelBuffer: CVPixelBuffer, context: CIContext, cameraTransform: simd_float4x4) -> Data? {
        // Create CIImage from CVPixelBuffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Validate extent before creating CGImage
        let extent = ciImage.extent
        guard !extent.isInfinite && !extent.isNull && extent.width > 0 && extent.height > 0 else {
            logger.error("Invalid CIImage extent: \(extent)")
            return nil
        }
        
        guard let cgImage = context.createCGImage(ciImage, from: extent) else {
            logger.error("Failed to create CGImage from CIImage - extent: \(extent), image size: \(extent.width)x\(extent.height)")
            return nil
        }
        
        let orientation = detectImageOrientation(from: pixelBuffer, cameraTransform: cameraTransform)
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.6) else {
            logger.error("Failed to convert UIImage to JPEG")
            return nil
        }
        
        return jpegData
    }
    
    private func detectImageOrientation(from pixelBuffer: CVPixelBuffer, cameraTransform: simd_float4x4) -> UIImage.Orientation {
        if let orientationNumber = CVBufferCopyAttachment(pixelBuffer, kCGImagePropertyOrientation, nil) as? CFNumber {
            var orientationInt: Int32 = 0
            if CFNumberGetValue(orientationNumber, .sInt32Type, &orientationInt) {
                switch orientationInt {
                case 1: return .up
                case 3: return .down
                case 6: return .right
                case 8: return .left
                case 2: return .upMirrored
                case 4: return .downMirrored
                case 5: return .leftMirrored
                case 7: return .rightMirrored
                default: break
                }
            }
        }
        
        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        case .faceUp, .faceDown:
            return .right
        default:
            return .right
        }
    }
    
}



extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
