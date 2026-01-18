//
//  ARKitManager.swift
//  RoomSensor
//
//  Created on 2024
//

import Foundation
import ARKit
import CoreVideo
import UIKit
import simd
import ImageIO

protocol ARKitManagerDelegate: AnyObject {
    func arkitDidUpdateStatus(frames: Int, keyframes: Int, depthOk: Bool)
    func arkitDidError(message: String)
}

class KeyframeInfo {
    let frameId: String
    let rgbPath: URL
    let depthPath: URL
    let metaPath: URL
    var isUploaded: Bool = false
    
    init(frameId: String, rgbPath: URL, depthPath: URL, metaPath: URL, isUploaded: Bool = false) {
        self.frameId = frameId
        self.rgbPath = rgbPath
        self.depthPath = depthPath
        self.metaPath = metaPath
        self.isUploaded = isUploaded
    }
}

class ARKitManager: NSObject {
    weak var delegate: ARKitManagerDelegate?
    
    private let arSession = ARSession()
    private var isScanning = false
    private var frameCount = 0
    private var keyframeCount = 0
    private var lastKeyframeTime: TimeInterval = 0
    private var lastKeyframeTransform: simd_float4x4?
    
    // Preview streaming
    private var lastPreviewTime: TimeInterval = 0
    private let previewFPS: TimeInterval = 10.0 // 10 fps
    private let previewInterval: TimeInterval = 1.0 / 10.0
    
    // Keyframe thresholds
    private let minTranslation: Float = 0.15 // meters
    private let minRotation: Float = 10.0 * .pi / 180.0 // 10 degrees in radians
    private let minTimeInterval: TimeInterval = 0.25 // seconds
    
    // File management
    private let fileManager = FileManager.default
    private var keyframeBuffer: [KeyframeInfo] = []
    private var uploadedKeyframeIds: Set<String> = []
    private var chunkIdCounter: Int = 0
    
    // Chunk upload
    private var chunkUploader: ChunkUploader?
    private var uploadTimer: Timer?
    private let uploadInterval: TimeInterval = 3.0 // Upload every 3 seconds
    private let keyframesPerChunk: Int = 15 // 10-20 keyframes per chunk
    
    // WebSocket for sending data
    weak var webSocketManager: WebSocketManager?
    var laptopIP: String?
    var token: String?
    
    override init() {
        super.init()
        arSession.delegate = self
    }
    
    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            let errorMsg = "ARWorldTrackingConfiguration is not supported on this device"
            print(errorMsg)
            delegate?.arkitDidError(message: errorMsg)
            return
        }
        
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable depth with error handling
        if configuration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if configuration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            let errorMsg = "Depth sensing is not available on this device. ARKit depth requires iPhone with LiDAR or newer iPhone models."
            print(errorMsg)
            delegate?.arkitDidError(message: errorMsg)
            // Continue anyway - might work without depth
        }
        
        arSession.run(configuration)
        isScanning = true
        frameCount = 0
        keyframeCount = 0
        lastKeyframeTime = 0
        lastKeyframeTransform = nil
        
        // Load unsent chunks from persistence
        loadUnsentChunks()
        
        // Initialize chunk uploader
        if let laptopIP = laptopIP, let token = token {
            chunkUploader = ChunkUploader(laptopIP: laptopIP, token: token)
            
            // Retry unsent chunks on reconnect
            retryUnsentChunks()
        }
        
        // Start periodic upload timer
        startUploadTimer()
    }
    
    private var stopCompletion: (() -> Void)?
    
    func stopSession(completion: (() -> Void)? = nil) {
        arSession.pause()
        isScanning = false
        
        // Stop upload timer
        stopUploadTimer()
        
        // Store completion handler
        stopCompletion = completion
        
        // Flush remaining keyframes (will call completion when done)
        flushRemainingKeyframes()
    }
    
    func getARSession() -> ARSession {
        return arSession
    }
    
    // MARK: - Chunk Management
    
    private func getBufferDirectory() -> URL {
        let cachesPath = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bufferDir = cachesPath.appendingPathComponent("keyframe_buffer")
        
        if !fileManager.fileExists(atPath: bufferDir.path) {
            try? fileManager.createDirectory(at: bufferDir, withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: bufferDir.appendingPathComponent("rgb"), withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: bufferDir.appendingPathComponent("depth"), withIntermediateDirectories: true)
            try? fileManager.createDirectory(at: bufferDir.appendingPathComponent("meta"), withIntermediateDirectories: true)
        }
        
        return bufferDir
    }
    
    private func createChunkDirectory(chunkId: String) -> URL? {
        let cachesPath = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let chunkDir = cachesPath.appendingPathComponent("chunk_\(chunkId)")
        
        do {
            try fileManager.createDirectory(at: chunkDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: chunkDir.appendingPathComponent("rgb"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: chunkDir.appendingPathComponent("depth"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: chunkDir.appendingPathComponent("meta"), withIntermediateDirectories: true)
            
            return chunkDir
        } catch {
            print("Failed to create chunk directory: \(error)")
            return nil
        }
    }
    
    // MARK: - Preview Streaming
    
    private func sendPreviewFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let webSocketManager = webSocketManager else { return }
        
        let currentTime = CACurrentMediaTime()
        if currentTime - lastPreviewTime < previewInterval {
            return // Throttle to ~10 fps
        }
        lastPreviewTime = currentTime
        
        // Convert CVPixelBuffer to JPEG
        guard let jpegData = pixelBufferToJPEG(pixelBuffer, quality: 0.5) else {
            print("Failed to convert pixel buffer to JPEG")
            return
        }
        
        // Send as binary WebSocket message
        webSocketManager.sendBinary(data: jpegData)
    }
    
    // MARK: - Keyframe Recording
    
    private func shouldRecordKeyframe(currentTransform: simd_float4x4, currentTime: TimeInterval) -> Bool {
        // Time-based: record if >= 0.25s since last keyframe
        if currentTime - lastKeyframeTime >= minTimeInterval {
            return true
        }
        
        guard let lastTransform = lastKeyframeTransform else {
            return true // First keyframe
        }
        
        // Translation check: moved > 0.15m
        let translation = currentTransform.columns.3 - lastTransform.columns.3
        let translationDistance = simd_length(simd_float3(translation.x, translation.y, translation.z))
        if translationDistance > minTranslation {
            return true
        }
        
        // Rotation check: rotated > 10 degrees
        let rotationDelta = currentTransform * simd_inverse(lastTransform)
        let angle = rotationAngle(from: rotationDelta)
        if angle > minRotation {
            return true
        }
        
        return false
    }
    
    private func rotationAngle(from transform: simd_float4x4) -> Float {
        // Extract rotation angle from transform matrix
        let trace = transform.columns.0.x + transform.columns.1.y + transform.columns.2.z
        let angle = acos((trace - 1.0) / 2.0)
        return abs(angle)
    }
    
    private func recordKeyframe(frame: ARFrame) {
        let bufferDir = getBufferDirectory()
        let frameId = String(format: "%06d", keyframeCount)
        let timestamp = frame.timestamp
        
        // Save RGB (higher quality)
        let rgbPath = bufferDir.appendingPathComponent("rgb/\(frameId).jpg")
        guard let rgbData = pixelBufferToJPEG(frame.capturedImage, quality: 0.85),
              (try? rgbData.write(to: rgbPath)) != nil else {
            print("Failed to save RGB for keyframe \(frameId)")
            return
        }
        
        // Save depth
        let depthPath = bufferDir.appendingPathComponent("depth/\(frameId).png")
        guard let depthData = extractDepthData(frame: frame),
              (try? depthData.write(to: depthPath)) != nil else {
            print("Failed to save depth for keyframe \(frameId)")
            return
        }
        
        // Save metadata
        let metaPath = bufferDir.appendingPathComponent("meta/\(frameId).json")
        guard let metaData = createMetaJSON(frame: frame, frameId: frameId, timestamp: timestamp),
              (try? metaData.write(to: metaPath)) != nil else {
            print("Failed to save metadata for keyframe \(frameId)")
            return
        }
        
        // Add to buffer
        let keyframeInfo = KeyframeInfo(
            frameId: frameId,
            rgbPath: rgbPath,
            depthPath: depthPath,
            metaPath: metaPath
        )
        keyframeBuffer.append(keyframeInfo)
        
        keyframeCount += 1
        lastKeyframeTime = timestamp
        lastKeyframeTransform = frame.camera.transform
        
        // Update delegate
        delegate?.arkitDidUpdateStatus(frames: frameCount, keyframes: keyframeCount, depthOk: frame.sceneDepth != nil)
    }
    
    // MARK: - Image Conversion
    
    private func pixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right) // ARKit images are rotated
        return uiImage.jpegData(compressionQuality: quality)
    }
    
    private func extractDepthData(frame: ARFrame) -> Data? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return nil
        }
        
        let depthMap = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        
        // Convert depth from meters to millimeters (uint16)
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        // Allocate buffer for uint16 depth values
        let depthDataSize = width * height * MemoryLayout<UInt16>.size
        guard let depthData = malloc(depthDataSize) else {
            return nil
        }
        defer { free(depthData) }
        
        let depthArray = depthData.assumingMemoryBound(to: UInt16.self)
        
        for i in 0..<(width * height) {
            let depthMeters = depthPointer[i]
            let depthMM = UInt16(min(max(depthMeters * 1000.0, 0), 65535))
            depthArray[i] = depthMM
        }
        
        // Create 16-bit grayscale image
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            .union(.byteOrder16Little) // Little-endian for uint16
        
        guard let context = CGContext(
            data: depthData,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 2,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        
        guard let cgImage = context.makeImage() else {
            return nil
        }
        
        // Convert to PNG data
        // Note: PNG doesn't natively support 16-bit, but we'll save as PNG anyway
        // The worker will need to handle this, or we could use TIFF
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return mutableData as Data
    }
    
    // MARK: - Metadata Creation
    
    private func createMetaJSON(frame: ARFrame, frameId: String, timestamp: TimeInterval) -> Data? {
        let camera = frame.camera
        
        // Get color intrinsics
        let colorIntrinsics = camera.intrinsics
        let colorSize = frame.capturedImage.size
        
        // Get depth size and compute depth intrinsics
        var depthSize: CGSize
        var depthIntrinsics: simd_float3x3
        
        if let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth {
            let depthMap = sceneDepth.depthMap
            let depthW = CVPixelBufferGetWidth(depthMap)
            let depthH = CVPixelBufferGetHeight(depthMap)
            depthSize = CGSize(width: depthW, height: depthH)
            
            // Scale intrinsics from color to depth resolution
            let scaleX = Float(depthW) / Float(colorSize.width)
            let scaleY = Float(depthH) / Float(colorSize.height)
            
            depthIntrinsics = simd_float3x3(
                simd_float3(colorIntrinsics[0][0] * scaleX, 0, colorIntrinsics[0][2] * scaleX),
                simd_float3(0, colorIntrinsics[1][1] * scaleY, colorIntrinsics[1][2] * scaleY),
                simd_float3(0, 0, 1)
            )
        } else {
            // Fallback to color size if no depth
            depthSize = colorSize
            depthIntrinsics = colorIntrinsics
        }
        
        // Get camera-to-world transform (T_wc)
        let T_wc = frame.camera.transform
        
        // Create JSON
        let meta: [String: Any] = [
            "timestamp": timestamp,
            "K_color": [
                [Double(colorIntrinsics[0][0]), 0, Double(colorIntrinsics[0][2])],
                [0, Double(colorIntrinsics[1][1]), Double(colorIntrinsics[1][2])],
                [0, 0, 1]
            ],
            "K_depth": [
                [Double(depthIntrinsics[0][0]), 0, Double(depthIntrinsics[0][2])],
                [0, Double(depthIntrinsics[1][1]), Double(depthIntrinsics[1][2])],
                [0, 0, 1]
            ],
            "colorSize": [Int(colorSize.width), Int(colorSize.height)],
            "depthSize": [Int(depthSize.width), Int(depthSize.height)],
            "T_wc": [
                [Double(T_wc.columns.0.x), Double(T_wc.columns.0.y), Double(T_wc.columns.0.z), Double(T_wc.columns.0.w)],
                [Double(T_wc.columns.1.x), Double(T_wc.columns.1.y), Double(T_wc.columns.1.z), Double(T_wc.columns.1.w)],
                [Double(T_wc.columns.2.x), Double(T_wc.columns.2.y), Double(T_wc.columns.2.z), Double(T_wc.columns.2.w)],
                [Double(T_wc.columns.3.x), Double(T_wc.columns.3.y), Double(T_wc.columns.3.z), Double(T_wc.columns.3.w)]
            ],
            "depthScale": 1000.0
        ]
        
        return try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
    }
    
    // MARK: - Status Updates
    
    private func sendStatusUpdate() {
        guard let webSocketManager = webSocketManager else { return }
        
        let status: [String: Any] = [
            "type": "status",
            "scanning": isScanning,
            "frames": frameCount,
            "keyframes": keyframeCount,
            "depthOK": arSession.currentFrame?.sceneDepth != nil || arSession.currentFrame?.smoothedSceneDepth != nil
        ]
        
        webSocketManager.sendJSON(status)
    }
    
    private var statusUpdateTimer: Timer?
    
    private func startStatusUpdates() {
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendStatusUpdate()
        }
    }
    
    private func stopStatusUpdates() {
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = nil
    }
    
    // MARK: - Chunk Upload
    
    private func startUploadTimer() {
        uploadTimer = Timer.scheduledTimer(withTimeInterval: uploadInterval, repeats: true) { [weak self] _ in
            self?.processChunkUpload()
        }
    }
    
    private func stopUploadTimer() {
        uploadTimer?.invalidate()
        uploadTimer = nil
    }
    
    private func processChunkUpload() {
        guard isScanning, let chunkUploader = chunkUploader else { return }
        
        // Get unuploaded keyframes
        let unuploadedKeyframes = keyframeBuffer.filter { !$0.isUploaded && !uploadedKeyframeIds.contains($0.frameId) }
        
        guard unuploadedKeyframes.count >= keyframesPerChunk else {
            return // Not enough keyframes yet
        }
        
        // Take last K keyframes
        let keyframesToUpload = Array(unuploadedKeyframes.suffix(keyframesPerChunk))
        uploadChunk(keyframes: keyframesToUpload, chunkUploader: chunkUploader)
    }
    
    private func uploadChunk(keyframes: [KeyframeInfo], chunkUploader: ChunkUploader, isFinal: Bool = false) {
        chunkIdCounter += 1
        let chunkId = String(format: "chunk_%06d", chunkIdCounter)
        
        guard let chunkDir = createChunkDirectory(chunkId: chunkId) else {
            print("Failed to create chunk directory for \(chunkId)")
            return
        }
        
        // Copy keyframes to chunk directory
        var frameIds: [String] = []
        for keyframe in keyframes {
            let frameId = keyframe.frameId
            
            // Copy files
            let destRgb = chunkDir.appendingPathComponent("rgb/\(frameId).jpg")
            let destDepth = chunkDir.appendingPathComponent("depth/\(frameId).png")
            let destMeta = chunkDir.appendingPathComponent("meta/\(frameId).json")
            
            do {
                try fileManager.copyItem(at: keyframe.rgbPath, to: destRgb)
                try fileManager.copyItem(at: keyframe.depthPath, to: destDepth)
                try fileManager.copyItem(at: keyframe.metaPath, to: destMeta)
                frameIds.append(frameId)
            } catch {
                print("Failed to copy keyframe \(frameId): \(error)")
            }
        }
        
        guard !frameIds.isEmpty else {
            print("No keyframes copied for chunk \(chunkId)")
            try? fileManager.removeItem(at: chunkDir)
            return
        }
        
        // Create index.json
        let indexPath = chunkDir.appendingPathComponent("index.json")
        let indexData: [String: Any] = ["frames": frameIds]
        if let jsonData = try? JSONSerialization.data(withJSONObject: indexData, options: .prettyPrinted) {
            try? jsonData.write(to: indexPath)
        }
        
        // Zip the chunk
        let zipURL = chunkDir.deletingLastPathComponent().appendingPathComponent("\(chunkId).zip")
        guard zipDirectory(chunkDir, to: zipURL) else {
            print("Failed to zip chunk \(chunkId)")
            try? fileManager.removeItem(at: chunkDir)
            return
        }
        
        // Upload
        chunkUploader.uploadChunk(chunkZipURL: zipURL, chunkId: chunkId, frameCount: frameIds.count) { [weak self] success, error in
            if success {
                // Mark keyframes as uploaded
                for frameId in frameIds {
                    self?.uploadedKeyframeIds.insert(frameId)
                }
                
                // Update buffer
                for i in 0..<(self?.keyframeBuffer.count ?? 0) {
                    if frameIds.contains(self?.keyframeBuffer[i].frameId ?? "") {
                        self?.keyframeBuffer[i].isUploaded = true
                    }
                }
                
                // Send WebSocket notification
                let message: [String: Any] = [
                    "type": "chunk_uploaded",
                    "chunkId": chunkId,
                    "count": frameIds.count
                ]
                self?.webSocketManager?.sendJSON(message)
                
                // Clean up
                try? self?.fileManager.removeItem(at: chunkDir)
                try? self?.fileManager.removeItem(at: zipURL)
                
                // Remove from unsent chunks if persisted
                self?.removeUnsentChunk(chunkId: chunkId)
                
                print("Chunk \(chunkId) uploaded and cleaned up")
                
                // If this was the final chunk, call completion
                if isFinal {
                    self?.stopCompletion?()
                    self?.stopCompletion = nil
                }
            } else {
                print("Failed to upload chunk \(chunkId): \(error?.localizedDescription ?? "Unknown error")")
                // Keep files for retry and persist
                self?.saveUnsentChunk(chunkId: chunkId, zipURL: zipURL, chunkDir: chunkDir, frameIds: frameIds)
                
                // If this was the final chunk and it failed, still call completion after a delay
                // (or implement retry logic)
                if isFinal {
                    // Give it one more chance, then call completion anyway
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.stopCompletion?()
                        self?.stopCompletion = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Persistence for unsent chunks
    
    private func saveUnsentChunk(chunkId: String, zipURL: URL, chunkDir: URL, frameIds: [String]) {
        var unsentChunks = loadUnsentChunksList()
        unsentChunks.append([
            "chunkId": chunkId,
            "zipPath": zipURL.path,
            "chunkPath": chunkDir.path,
            "frameIds": frameIds
        ])
        
        UserDefaults.standard.set(unsentChunks, forKey: persistenceKey)
    }
    
    private func removeUnsentChunk(chunkId: String) {
        var unsentChunks = loadUnsentChunksList()
        unsentChunks.removeAll { $0["chunkId"] as? String == chunkId }
        UserDefaults.standard.set(unsentChunks, forKey: persistenceKey)
    }
    
    private func loadUnsentChunksList() -> [[String: Any]] {
        return UserDefaults.standard.array(forKey: persistenceKey) as? [[String: Any]] ?? []
    }
    
    private func loadUnsentChunks() {
        // Load metadata only - files should still be on disk
        let unsentChunks = loadUnsentChunksList()
        print("Loaded \(unsentChunks.count) unsent chunks from persistence")
    }
    
    private func retryUnsentChunks() {
        guard let chunkUploader = chunkUploader else { return }
        
        let unsentChunks = loadUnsentChunksList()
        for chunkInfo in unsentChunks {
            guard let chunkId = chunkInfo["chunkId"] as? String,
                  let zipPath = chunkInfo["zipPath"] as? String,
                  let frameIds = chunkInfo["frameIds"] as? [String] else {
                continue
            }
            
            let zipURL = URL(fileURLWithPath: zipPath)
            if fileManager.fileExists(atPath: zipPath) {
                print("Retrying unsent chunk: \(chunkId)")
                chunkUploader.uploadChunk(chunkZipURL: zipURL, chunkId: chunkId, frameCount: frameIds.count) { [weak self] success, error in
                    if success {
                        self?.removeUnsentChunk(chunkId: chunkId)
                        // Clean up files
                        if let chunkPath = chunkInfo["chunkPath"] as? String {
                            try? self?.fileManager.removeItem(at: URL(fileURLWithPath: chunkPath))
                        }
                        try? self?.fileManager.removeItem(at: zipURL)
                    }
                }
            } else {
                // File doesn't exist, remove from list
                removeUnsentChunk(chunkId: chunkId)
            }
        }
    }
    
    func resetSession() {
        // Clear all local data for current token
        keyframeBuffer = []
        uploadedKeyframeIds = []
        chunkIdCounter = 0
        
        // Clear unsent chunks
        UserDefaults.standard.removeObject(forKey: persistenceKey)
        
        // Clear buffer directory
        let bufferDir = getBufferDirectory()
        try? fileManager.removeItem(at: bufferDir)
        
        // Clear chunk directories in caches
        let cachesPath = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        if let enumerator = fileManager.enumerator(at: cachesPath, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.hasPrefix("chunk_") {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        }
        
        print("Session reset - all local data cleared")
    }
    
    private func flushRemainingKeyframes() {
        guard let chunkUploader = chunkUploader else {
            // No uploader, call completion immediately
            stopCompletion?()
            stopCompletion = nil
            return
        }
        
        // Get all unuploaded keyframes
        let unuploadedKeyframes = keyframeBuffer.filter { !$0.isUploaded && !uploadedKeyframeIds.contains($0.frameId) }
        
        guard !unuploadedKeyframes.isEmpty else {
            // No keyframes to upload, call completion immediately
            stopCompletion?()
            stopCompletion = nil
            return
        }
        
        // Upload as final chunk, then call completion
        uploadChunk(keyframes: unuploadedKeyframes, chunkUploader: chunkUploader, isFinal: true)
    }
    
    private func zipDirectory(_ directory: URL, to zipURL: URL) -> Bool {
        // NOTE: For production, use a proper ZIP library like ZipArchive (https://github.com/marmelroy/Zip)
        // This is a placeholder that uses a basic approach
        // On iOS, Process() is not available, so we need a library-based solution
        
        // For now, create a tar-like archive or use a library
        // Simplest solution: Add ZipArchive via SPM/CocoaPods
        // import ZipArchive
        // return SSZipArchive.createZipFile(atPath: zipURL.path, withContentsOfDirectory: directory.path)
        
        // Temporary workaround: Create a simple archive format
        // This should be replaced with proper ZIP library
        return createSimpleArchive(from: directory, to: zipURL)
    }
    
    private func createSimpleArchive(from directory: URL, to archiveURL: URL) -> Bool {
        // This is a temporary implementation
        // TODO: Replace with proper ZIP library (e.g., ZipArchive)
        
        var archiveData = Data()
        let fileManager = FileManager.default
        
        // Add directory marker
        let dirName = directory.lastPathComponent
        archiveData.append("DIR:\(dirName)\n".data(using: .utf8) ?? Data())
        
        // Collect all files
        var files: [(URL, String)] = []
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }
                
                let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
                files.append((fileURL, relativePath))
            }
        }
        
        // Write files
        for (fileURL, relativePath) in files {
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            
            // File entry: "FILE:path:size\n" + data
            let header = "FILE:\(relativePath):\(fileData.count)\n"
            archiveData.append(header.data(using: .utf8) ?? Data())
            archiveData.append(fileData)
        }
        
        // Write archive
        do {
            try archiveData.write(to: archiveURL)
            print("Created archive at \(archiveURL.path)")
            return true
        } catch {
            print("Failed to write archive: \(error)")
            return false
        }
    }
}

// MARK: - ARSessionDelegate

extension ARKitManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning else { return }
        
        frameCount += 1
        
        // Preview streaming (throttled to ~10 fps)
        sendPreviewFrame(frame.capturedImage)
        
        // Keyframe recording
        if shouldRecordKeyframe(currentTransform: frame.camera.transform, currentTime: frame.timestamp) {
            recordKeyframe(frame: frame)
        }
        
        // Periodic status updates
        if statusUpdateTimer == nil {
            startStatusUpdates()
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("ARSession failed: \(error)")
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        print("ARSession was interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        print("ARSession interruption ended")
    }
}

// MARK: - CVPixelBuffer Extension

extension CVPixelBuffer {
    var size: CGSize {
        return CGSize(width: CVPixelBufferGetWidth(self), height: CVPixelBufferGetHeight(self))
    }
}
