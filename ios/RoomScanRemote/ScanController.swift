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
    // @Published properties must only be updated on main thread
    // Use updateStateOnMain() helper method for all updates
    @Published var isScanning: Bool = false
    @Published var errorMessage: String?
    
    // ScanController owns the RoomCaptureSession - single source of truth
    @Published private(set) var roomCaptureSession: RoomCaptureSession?
    private var lastUpdateTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 0.2 // 5Hz = 200ms for room updates
    private let frameInterval: TimeInterval = 0.1 // 10 fps = 100ms for preview frames
    
    // Note: RoomPlan provides structured room data (walls, doors, windows, objects) through
    // RoomCaptureSessionDelegate callbacks. We don't need raw ARKit mesh streaming.
    // Minimum iOS version: iOS 16.0 (RoomPlan requirement)
    
    // Reusable CIContext for JPEG conversion - created eagerly on background queue
    // CIContext is heavyweight and expensive to create; reusing it is critical for performance
    // Must be accessed only on frameProcessingQueue to ensure thread safety
    private var ciContext: CIContext?
    
    // Background queue for frame processing - all Core Image operations happen here
    private let frameProcessingQueue = DispatchQueue(label: "com.roomscan.frameProcessing", qos: .userInitiated)
    
    // Backpressure control - all logic centralized here
    // Simple atomic flag: check and set happen on main thread (ARSession callback)
    // Reset happens on background queue, but we use a lock for thread safety
    private let processingLock = NSLock()
    private var _isProcessingFrame = false
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
        frameTimestamps.removeAll { $0 < cutoffTime }
        
        guard !frameTimestamps.isEmpty else {
            DispatchQueue.main.async {
                self.actualFPS = 0.0
            }
            return
        }
        
        let timeSpan = now.timeIntervalSince(frameTimestamps.first!)
        guard timeSpan > 0 else {
            DispatchQueue.main.async {
                self.actualFPS = 0.0
            }
            return
        }
        
        let calculatedFPS = Double(frameTimestamps.count) / timeSpan
        
        // Update on main thread if enough time has passed
        if now.timeIntervalSince(lastFPSUpdate) >= fpsUpdateInterval {
            DispatchQueue.main.async {
                self.actualFPS = calculatedFPS
            }
            lastFPSUpdate = now
        }
    }
    
    // Adaptive frame rate - adjust based on network conditions
    // Initialized to match frameInterval (0.1s = 10 fps), then adapts based on network conditions
    private var currentFrameInterval: TimeInterval = 0.1
    private let minFrameInterval: TimeInterval = 0.05 // Max 20 fps
    private let maxFrameInterval: TimeInterval = 0.2 // Min 5 fps
    private let adaptiveRateStep: TimeInterval = 0.01 // Adjust by 0.01s increments
    private var consecutiveDrops: Int = 0
    private let dropThresholdForSlowdown = 3 // Slow down after 3 consecutive drops
    
    // Token stored in memory - marked as sensitive (never logged, always masked)
    var token: String? {
        didSet {
            // Clear old token from memory when setting new one (best effort)
            if let oldValue = oldValue {
                var mutable = oldValue
                mutable.removeAll()
            }
        }
    }
    var connectionManager: ConnectionManager?
    
    // MARK: - Mesh Reconstruction Properties
    
    // Custom ARSession for mesh capture (iOS 17+)
    private var customARSession: ARSession?
    
    // Track mesh anchors for streaming detailed geometry
    private var lastMeshUpdateTime: TimeInterval = 0
    private let meshUpdateInterval: TimeInterval = 0.5 // 2Hz for mesh updates (more data)
    
    // Mesh processing queue (separate from frame processing)
    private let meshProcessingQueue = DispatchQueue(label: "com.roomscan.meshProcessing", qos: .userInitiated)
    
    // Track which mesh anchors we've already sent (to only send updates)
    private var sentMeshIdentifiers = Set<UUID>()
    
    // Mesh streaming statistics
    private var totalMeshesSent: Int = 0
    private var totalVerticesSent: Int = 0
    
    // MARK: - Thread-Safe State Updates
    
    /// Helper method to update @Published properties on main thread
    /// All @Published property updates MUST go through this method to ensure thread safety
    /// This method can be called from any thread and will dispatch to main thread
    private func updateStateOnMain(
        isScanning: Bool? = nil,
        errorMessage: String?? = nil,
        roomCaptureSession: RoomCaptureSession?? = nil
    ) {
        // If already on main thread, update directly (optimization)
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
            // Dispatch to main thread for background thread calls
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
        // Initialize CIContext eagerly on background queue to avoid main thread blocking
        prewarmCIContext()
    }
    
    init(connectionManager: ConnectionManager) {
        super.init()
        self.connectionManager = connectionManager
        // Initialize CIContext eagerly on background queue to avoid main thread blocking
        prewarmCIContext()
    }
    
    // Pre-warm CIContext on background queue before scanning starts
    private func prewarmCIContext() {
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            // Create CIContext on background queue - hardware accelerated, no caching for better performance
            self.ciContext = CIContext()
            logger.debug("CIContext initialized on background queue")
        }
    }
    
    func startScan() {
        guard !isScanning else { return }
        
        // Check if RoomPlan is supported
        guard RoomCaptureSession.isSupported else {
            updateStateOnMain(errorMessage: "RoomPlan is not supported on this device")
            logger.error("RoomPlan not supported on this device")
            return
        }
        
        // Check if mesh reconstruction is supported (requires LiDAR)
        let meshSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        logger.info("Mesh reconstruction supported: \(meshSupported)")
        
        // Create and configure custom ARSession with mesh reconstruction (iOS 17+)
        let arSession = ARSession()
        let arConfig = ARWorldTrackingConfiguration()
        arConfig.planeDetection = [.horizontal, .vertical]
        
        // Enable mesh reconstruction if supported (provides detailed geometry)
        if meshSupported {
            arConfig.sceneReconstruction = .meshWithClassification
            logger.info("Enabled mesh reconstruction with classification")
        } else {
            logger.info("Mesh reconstruction not supported - using RoomPlan parametric data only")
        }
        
        // Store reference to custom ARSession
        customARSession = arSession
        arSession.delegate = self
        
        // Use existing session if available (from RoomCaptureView), otherwise create new one with custom ARSession
        let session: RoomCaptureSession
        
        if let existingSession = roomCaptureSession {
            // Use existing session (likely from RoomCaptureView)
            session = existingSession
            
            // Ensure delegates are set
            if session.delegate !== self {
                session.delegate = self
            }
            if session.arSession.delegate !== self {
                session.arSession.delegate = self
            }
            
            logger.info("Using existing RoomCaptureSession from RoomCaptureView")
            
            // Note: When using RoomCaptureView's session, we can't use custom ARSession config
            // But we can still access mesh anchors if the device supports it
        } else {
            // Create new session with custom ARSession (iOS 17+ API)
            logger.info("Creating new RoomCaptureSession with custom ARSession for mesh capture")
            
            // Clear any existing session first
            if let oldSession = roomCaptureSession {
                oldSession.arSession.delegate = nil
                oldSession.delegate = nil
                oldSession.stop()
            }
            
            // iOS 17+: Initialize RoomCaptureSession with custom ARSession
            // This enables mesh reconstruction while using RoomPlan
            if #available(iOS 17.0, *) {
                session = RoomCaptureSession(arSession: arSession)
                logger.info("Created RoomCaptureSession with custom ARSession (iOS 17+)")
            } else {
                // Fallback for iOS 16: Use default session (no custom mesh support)
                session = RoomCaptureSession()
                logger.info("Fallback: Created default RoomCaptureSession (iOS 16)")
            }
            
            session.delegate = self
            session.arSession.delegate = self
            
            // Update session on main thread (thread-safe)
            updateStateOnMain(roomCaptureSession: session)
            
            logger.info("Created new RoomCaptureSession - ScanController owns this session")
        }
        
        // Configure RoomPlan
        let configuration = RoomCaptureSession.Configuration()
        
        // Run the RoomPlan session
        session.run(configuration: configuration)
        
        // Update scanning state on main thread
        updateStateOnMain(isScanning: true, errorMessage: nil)
        
        // Reset frame statistics and adaptive rate for new scan
        totalFramesProcessed = 0
        totalFramesDropped = 0
        framesSinceLastLog = 0
        consecutiveDrops = 0
        currentFrameInterval = frameInterval // Reset to initial rate
        isProcessingFrame = false
        frameTimestamps.removeAll()
        
        // Reset mesh tracking
        sentMeshIdentifiers.removeAll()
        totalMeshesSent = 0
        totalVerticesSent = 0
        lastMeshUpdateTime = 0
        
        // Ensure CIContext is ready before scanning starts
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
        
        // Clean up session - clear delegates first to prevent callbacks during cleanup
        // Then stop the session, then nil the reference
        if let session = roomCaptureSession {
            // Stop the session but keep it alive for RoomCaptureView to continue showing camera feed
            // Don't clear delegates or nil the session - RoomCaptureView may still need it
            // The session will be cleaned up when the view is deallocated
            session.stop()
            logger.info("Stopped RoomCaptureSession (keeping for camera feed display)")
        }
        
        // Clean up custom ARSession
        customARSession?.pause()
        customARSession = nil
        
        // Update state on main thread (thread-safe)
        updateStateOnMain(isScanning: false, roomCaptureSession: nil)
        
        // Log final statistics
        if totalFramesProcessed > 0 || totalFramesDropped > 0 {
            let dropRate = Double(totalFramesDropped) / Double(totalFramesProcessed + totalFramesDropped) * 100.0
            logger.info("Scan stopped - Frame Statistics: Processed: \(totalFramesProcessed), Dropped: \(totalFramesDropped), Drop Rate: \(String(format: "%.1f", dropRate))%")
        }
        
        // Log mesh statistics
        if totalMeshesSent > 0 {
            logger.info("Scan stopped - Mesh Statistics: Meshes sent: \(totalMeshesSent), Vertices sent: \(totalVerticesSent)")
        }
        
        // Reset processing flag
        isProcessingFrame = false
        
        sendStatusMessage(value: "scan_stopped")
        logger.info("Scan stopped")
    }
    
    deinit {
        // Ensure cleanup on deallocation - prevent memory leaks and delegate callbacks
        // Note: deinit can be called on any thread, so we need to be careful
        if let session = roomCaptureSession {
            // Always clear delegates first
            session.arSession.delegate = nil
            session.delegate = nil
            // Stop the session (safe to call even if already stopped)
            session.stop()
            // Update on main thread if we're not already on it
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
    
    // Send message via WebSocket
    private func sendMessage(_ message: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to serialize message")
            return
        }
        
        // Use ConnectionManager if available, otherwise fall back to WSClient
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
            
            logger.info("USDZ exported to: \(fileURL.path)")
            
            // Upload to server
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
            // Update error message on main thread (async function may be on background thread)
            updateStateOnMain(errorMessage: "Failed to export USDZ: \(error.localizedDescription)")
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
                // Update error message on main thread (URLSession callback is on background thread)
                self?.updateStateOnMain(errorMessage: "Upload failed: \(error.localizedDescription)")
                // Clean up temp file even on error
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.info("USDZ uploaded successfully")
                    
                    // Send status message to UI
                    self?.sendStatusMessage(value: "upload_complete")
                } else {
                    logger.error("Upload failed with status: \(httpResponse.statusCode)")
                    // Update error message on main thread (URLSession callback is on background thread)
                    self?.updateStateOnMain(errorMessage: "Upload failed with status: \(httpResponse.statusCode)")
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
        logger.debug("Instruction: \(instructionText)")
        
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
        // RoomCaptureSessionDelegate callbacks may be on background thread
        // Use thread-safe state update helper
        if let error = error {
                logger.error("Scan ended with error: \(error.localizedDescription)")
            updateStateOnMain(
                isScanning: false,
                errorMessage: "Scan error: \(error.localizedDescription)",
                roomCaptureSession: nil
            )
        } else {
                logger.info("Scan completed successfully")
            // Update state first
            updateStateOnMain(isScanning: false, roomCaptureSession: nil)
            // Export USDZ
            Task {
                await self.exportUSDZ(from: capturedRoomData)
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ScanController: ARSessionDelegate {
    // ARSessionDelegate handles:
    // 1. didUpdate frame - for JPEG preview streaming
    // 2. didAdd/didUpdate anchors - for mesh anchor capture (detailed 3D geometry)
    // RoomPlan provides structured data (walls, doors, windows, objects) via RoomCaptureSessionDelegate
    // ARKit mesh anchors provide detailed mesh geometry (vertices, faces, normals, classifications)
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Check connection status
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
        
        // Adaptive frame rate throttling
        let currentTime = Date().timeIntervalSince1970
        guard currentTime - lastFrameTime >= currentFrameInterval else { return }
        
        // Coordinated backpressure check: both local processing AND WebSocket must be ready
        // Drop frame immediately if either is busy - never queue more than 1 frame
        guard !isProcessingFrame && canAcceptFrame else {
            // Frame dropped due to backpressure
            totalFramesDropped += 1
            framesSinceLastLog += 1
            consecutiveDrops += 1
            
            // Adaptive rate: slow down if we're dropping too many frames
            if consecutiveDrops >= dropThresholdForSlowdown {
                currentFrameInterval = min(currentFrameInterval + adaptiveRateStep, maxFrameInterval)
                consecutiveDrops = 0
                frameLogger.info("Network congestion detected - reduced frame rate to \(1.0/currentFrameInterval) fps")
            }
            
            logStatisticsIfNeeded()
            return
        }
        
        // Reset consecutive drops counter on successful acceptance
        consecutiveDrops = 0
        
        // Speed up frame rate if we're not dropping frames (gradual recovery)
        if currentFrameInterval > minFrameInterval {
            currentFrameInterval = max(currentFrameInterval - adaptiveRateStep * 0.1, minFrameInterval)
        }
        
        lastFrameTime = currentTime
        isProcessingFrame = true
        totalFramesProcessed += 1
        framesSinceLastLog += 1
        
        // Track frame timestamp for FPS calculation
        frameTimestamps.append(Date())
        updateFPS()
        
        // Copy pixel buffer reference and camera info before dispatching
        let pixelBuffer = frame.capturedImage
        let cameraTransform = frame.camera.transform
        
        // Process on background queue - all Core Image operations must happen off main thread
        // We've already checked backpressure, so this frame will be processed
        frameProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            defer {
                // Mark processing complete so next frame can be processed
                // Thread-safe flag update (can be called from background queue)
                self.isProcessingFrame = false
            }
            
            // Convert pixel buffer to JPEG - always called on frameProcessingQueue
            // Pass camera transform for better orientation detection
            guard let jpegData = self.convertPixelBufferToJPEG(pixelBuffer, cameraTransform: cameraTransform) else {
                // Conversion failed, skip this frame
                DispatchQueue.main.async {
                    self.totalFramesDropped += 1
                    self.logStatisticsIfNeeded()
                }
                return
            }
            
            // Send as binary WebSocket message - check result
            // This can be called from background queue - WSClient handles thread safety
            let accepted: Bool
            if let connectionManager = self.connectionManager {
                accepted = connectionManager.sendJPEGFrame(jpegData)
            } else {
                accepted = WSClient.shared.sendJPEGFrame(jpegData)
            }
            
            if !accepted {
                // Frame was rejected by WebSocket (shouldn't happen if we checked canAcceptFrame, but handle it)
                DispatchQueue.main.async {
                    self.totalFramesDropped += 1
                    frameLogger.debug("Warning: Frame rejected by WebSocket despite canAcceptFrame check")
                }
            }
            
            DispatchQueue.main.async {
                self.logStatisticsIfNeeded()
            }
        }
    }
    
    // MARK: - Mesh Anchor Handling
    
    /// Called when new anchors are added to the session (including mesh anchors)
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        processMeshAnchors(anchors)
    }
    
    /// Called when existing anchors are updated (mesh geometry changes)
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
        
        // Process mesh anchors on background queue
        meshProcessingQueue.async { [weak self] in
            guard let self = self else { return }
            
            for meshAnchor in meshAnchors {
                self.processMeshAnchor(meshAnchor)
            }
        }
    }
    
    /// Process a single mesh anchor and send its geometry
    private func processMeshAnchor(_ meshAnchor: ARMeshAnchor) {
        let geometry = meshAnchor.geometry
        
        // Extract vertices as 2D array [[x,y,z], [x,y,z], ...]
        let vertices2D = extractVertices2D(from: geometry.vertices)
        let vertexCount = vertices2D.count
        
        // Extract face indices as 2D array [[i,j,k], [i,j,k], ...]
        let faces2D = extractFaces2D(from: geometry.faces)
        
        // Extract classifications if available (per-face)
        var faceClassifications: [Int]?
        if let classificationSource = geometry.classification {
            faceClassifications = extractClassifications(from: classificationSource, faceCount: geometry.faces.count)
        }
        
        // Generate per-vertex colors (server expects colors per vertex, not per face)
        let colors2D = generateVertexColors(
            vertexCount: vertexCount,
            faces: faces2D,
            faceClassifications: faceClassifications
        )
        
        // Send mesh data in server-expected format
        sendMeshUpdate(
            identifier: meshAnchor.identifier,
            transform: meshAnchor.transform,
            vertices: vertices2D,
            faces: faces2D,
            colors: colors2D
        )
        
        // Update statistics
        DispatchQueue.main.async {
            self.totalMeshesSent += 1
            self.totalVerticesSent += vertexCount
            self.sentMeshIdentifiers.insert(meshAnchor.identifier)
        }
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
            [0.5, 0.35, 0.25]   // 7: door - dark wood
        ]
        
        // Default color (gray) for all vertices
        let defaultColor: [Float] = [0.5, 0.5, 0.5]
        var vertexColors: [[Float]] = Array(repeating: defaultColor, count: vertexCount)
        
        // If we have classifications, assign colors based on face classifications
        // Each vertex gets the color of the first face that uses it
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
    
    /// Extract vertices as 2D array for server: [[x,y,z], [x,y,z], ...]
    private func extractVertices2D(from source: ARGeometrySource) -> [[Float]] {
        let buffer = source.buffer
        let count = source.count
        let stride = source.stride
        let offset = source.offset
        let componentsPerVector = source.componentsPerVector
        
        var result: [[Float]] = []
        result.reserveCapacity(count)
        
        let pointer = buffer.contents().advanced(by: offset)
        
        for i in 0..<count {
            let vertexPointer = pointer.advanced(by: i * stride)
            var vertex: [Float] = []
            vertex.reserveCapacity(componentsPerVector)
            
            for j in 0..<componentsPerVector {
                let value = vertexPointer.advanced(by: j * MemoryLayout<Float>.size).assumingMemoryBound(to: Float.self).pointee
                vertex.append(value)
            }
            result.append(vertex)
        }
        
        return result
    }
    
    /// Extract faces as 2D array for server: [[i,j,k], [i,j,k], ...]
    private func extractFaces2D(from element: ARGeometryElement) -> [[Int]] {
        let buffer = element.buffer
        let count = element.count
        let indexCountPerPrimitive = element.indexCountPerPrimitive // Should be 3 for triangles
        let bytesPerIndex = element.bytesPerIndex
        
        var result: [[Int]] = []
        result.reserveCapacity(count)
        
        let pointer = buffer.contents()
        
        for i in 0..<count {
            var face: [Int] = []
            face.reserveCapacity(indexCountPerPrimitive)
            
            for j in 0..<indexCountPerPrimitive {
                let indexOffset = (i * indexCountPerPrimitive + j) * bytesPerIndex
                let indexPointer = pointer.advanced(by: indexOffset)
                
                // Handle different index sizes
                if bytesPerIndex == 4 {
                    let value = indexPointer.assumingMemoryBound(to: UInt32.self).pointee
                    face.append(Int(value))
                } else if bytesPerIndex == 2 {
                    let value = indexPointer.assumingMemoryBound(to: UInt16.self).pointee
                    face.append(Int(value))
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
    
    /// Send mesh update to server (format matches server expectations)
    private func sendMeshUpdate(
        identifier: UUID,
        transform: simd_float4x4,
        vertices: [[Float]],
        faces: [[Int]],
        colors: [[Float]]
    ) {
        guard let token = token else { return }
        
        // Server expects: anchorId, vertices (2D), faces (2D), colors (2D), transform (1D)
        let message: [String: Any] = [
            "type": "mesh_update",
            "anchorId": identifier.uuidString,  // Server expects 'anchorId' not 'identifier'
            "transform": flattenTransform(transform),
            "vertices": vertices,
            "faces": faces,
            "colors": colors,
            "t": Int(Date().timeIntervalSince1970),
            "token": token
        ]
        
        sendMessage(message)
    }
    
    // Log frame statistics periodically
    private func logStatisticsIfNeeded() {
        guard framesSinceLastLog >= statisticsLogInterval else { return }
        
        let dropRate = totalFramesProcessed > 0 ? Double(totalFramesDropped) / Double(totalFramesProcessed + totalFramesDropped) * 100.0 : 0.0
        let targetFPS = 1.0 / currentFrameInterval
        
        frameLogger.debug("Frame Statistics: Processed: \(totalFramesProcessed), Dropped: \(totalFramesDropped), Drop Rate: \(String(format: "%.1f", dropRate))%, Actual FPS: \(String(format: "%.1f", actualFPS)), Target FPS: \(String(format: "%.1f", targetFPS)), Interval: \(String(format: "%.3f", currentFrameInterval))s")
        
        framesSinceLastLog = 0
    }
    
    // Convert pixel buffer to JPEG - MUST be called on frameProcessingQueue
    // All Core Image operations happen off the main thread
    private func convertPixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer, cameraTransform: simd_float4x4) -> Data? {
        // Ensure we're on the correct queue (debug check)
        assert(!Thread.isMainThread, "convertPixelBufferToJPEG must be called on frameProcessingQueue, not main thread")
        
        // Ensure CIContext is available (should be pre-warmed, but handle gracefully)
        guard let context = ciContext else {
            logger.debug("CIContext not available - creating fallback context")
            // Fallback: create temporary context (not ideal, but prevents crash)
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
        
        // Create CGImage using CIContext - add comprehensive error handling
        guard let cgImage = context.createCGImage(ciImage, from: extent) else {
            logger.error("Failed to create CGImage from CIImage - extent: \(extent), image size: \(extent.width)x\(extent.height)")
            return nil
        }
        
        // Detect actual device orientation using camera transform and pixel buffer properties
        let orientation = detectImageOrientation(from: pixelBuffer, cameraTransform: cameraTransform)
        
        // Convert to UIImage with detected orientation
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
        
        // Convert to JPEG Data with compression quality (0.6 = good balance of quality/size for streaming)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.6) else {
            logger.error("Failed to convert UIImage to JPEG")
            return nil
        }
        
        return jpegData
    }
    
    // Detect image orientation from pixel buffer properties and camera transform
    private func detectImageOrientation(from pixelBuffer: CVPixelBuffer, cameraTransform: simd_float4x4) -> UIImage.Orientation {
        // First, check pixel buffer attachment for orientation hint (most accurate)
        // Use CGImagePropertyOrientation key from ImageIO framework
        if let orientationValue = CVBufferGetAttachment(pixelBuffer, kCGImagePropertyOrientation, nil) {
            // The value is a CFNumber, extract the integer value
            if CFGetTypeID(orientationValue) == CFNumberGetTypeID(),
               let orientationNumber = orientationValue as? NSNumber {
                let orientationInt = orientationNumber.intValue
                // Map CGImagePropertyOrientation (EXIF) to UIImage.Orientation
                switch orientationInt {
                case 1: return .up           // EXIF: 1 = 0° (normal)
                case 3: return .down         // EXIF: 3 = 180°
                case 6: return .right        // EXIF: 6 = 90° CCW
                case 8: return .left        // EXIF: 8 = 90° CW
                case 2: return .upMirrored
                case 4: return .downMirrored
                case 5: return .leftMirrored
                case 7: return .rightMirrored
                default: break
                }
            }
        }
        
        // Fallback: Use device orientation (less accurate but better than hardcoding)
        // Note: UIDevice orientation can be unreliable, but it's better than nothing
        let deviceOrientation = UIDevice.current.orientation
        
        // For ARKit, the camera sensor orientation is typically fixed relative to device
        // Most iOS devices have cameras that produce landscape-right images
        // We adjust based on how the device is held
        switch deviceOrientation {
        case .portrait:
            // Device held portrait - camera image is rotated 90° CCW
            return .right
        case .portraitUpsideDown:
            // Device held portrait upside down - camera image is rotated 90° CW
            return .left
        case .landscapeLeft:
            // Device held landscape left - camera image is normal
            return .up
        case .landscapeRight:
            // Device held landscape right - camera image is upside down
            return .down
        case .faceUp, .faceDown:
            // Device flat - use default based on camera position
            // Most devices: landscape right is default
            return .right
        default:
            // Unknown orientation - default to right (most common for AR scanning in landscape)
            return .right
        }
    }
    
}

// MARK: - Safe Array Subscript Extension

extension Array {
    /// Safe subscript - returns nil if index is out of bounds
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
