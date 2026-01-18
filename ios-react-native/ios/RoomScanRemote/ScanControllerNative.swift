//
//  ScanControllerNative.swift
//  RoomScanRemote
//
//  Native RoomPlan scan controller
//

import Foundation
import RoomPlan
import ARKit
import CoreImage
import UIKit

protocol ScanControllerNativeDelegate: AnyObject {
  func didUpdateRoom(_ stats: [String: Any])
  func didCompleteScan(_ downloadUrl: String?)
  func didReceiveError(_ error: String)
  func didReceiveInstruction(_ instruction: String)
}

class ScanControllerNative: NSObject {
  weak var delegate: ScanControllerNativeDelegate?
  private var roomCaptureSession: RoomCaptureSession?
  private var token: String
  private var laptopIP: String
  private var lastUpdateTime: TimeInterval = 0
  private var lastFrameTime: TimeInterval = 0
  private let updateInterval: TimeInterval = 0.2 // 5Hz
  private let frameInterval: TimeInterval = 0.1 // 10fps
  
  init(token: String, laptopIP: String) {
    self.token = token
    self.laptopIP = laptopIP
    super.init()
  }
  
  func startScan() {
    guard RoomCaptureSession.isSupported else {
      delegate?.didReceiveError("RoomPlan is not supported")
      return
    }
    
    let session = RoomCaptureSession()
    session.delegate = self
    session.arSession.delegate = self
    self.roomCaptureSession = session
    
    let configuration = RoomCaptureSession.Configuration()
    session.run(configuration: configuration)
  }
  
  func stopScan() {
    roomCaptureSession?.arSession.delegate = nil
    roomCaptureSession?.stop()
    roomCaptureSession = nil
  }
  
  private func sendRoomUpdate(capturedRoom: CapturedRoom) {
    let currentTime = Date().timeIntervalSince1970
    guard currentTime - lastUpdateTime >= updateInterval else { return }
    lastUpdateTime = currentTime
    
    let stats: [String: Int] = [
      "walls": capturedRoom.walls.count,
      "doors": capturedRoom.doors.count,
      "windows": capturedRoom.windows.count,
      "objects": capturedRoom.objects.count
    ]
    
    var walls: [[String: Any]] = []
    for wall in capturedRoom.walls {
      var wallData: [String: Any] = [
        "identifier": wall.identifier.uuidString
      ]
      
      // Flatten transform matrix
      let transform = wall.transform
      var transformArray: [Float] = []
      transformArray.append(contentsOf: [
        transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
        transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
        transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
        transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
      ])
      wallData["transform"] = transformArray
      
      wallData["dimensions"] = [
        "width": Float(wall.dimensions.x),
        "height": Float(wall.dimensions.y),
        "length": Float(wall.dimensions.z)
      ]
      
      walls.append(wallData)
    }
    
    let update: [String: Any] = [
      "stats": stats,
      "walls": walls,
      "t": Int(currentTime)
    ]
    
    delegate?.didUpdateRoom(update)
    
    // Send via WebSocket
    sendMessage([
      "type": "room_update",
      "stats": stats,
      "walls": walls,
      "t": Int(currentTime),
      "token": token
    ])
  }
  
  private func sendMessage(_ message: [String: Any]) {
    guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
      return
    }
    
    // Send via WebSocket - we need a shared instance
    // For now, use a notification or direct call to WSClientNative
    // This is a design limitation - ideally we'd inject the WS client
    NotificationCenter.default.post(
      name: NSNotification.Name("SendWebSocketMessage"),
      object: nil,
      userInfo: ["message": jsonString]
    )
  }
  
  private func exportAndUpload(capturedRoomData: CapturedRoomData) {
    let builder = RoomBuilder(options: .beautifyObjects)
    
    do {
      let capturedRoom = try builder.build(from: capturedRoomData)
      
      let tempDir = FileManager.default.temporaryDirectory
      let fileName = "room_\(UUID().uuidString).usdz"
      let fileURL = tempDir.appendingPathComponent(fileName)
      
      try capturedRoom.export(to: fileURL, exportOptions: .mesh)
      
      // Upload to server
      uploadUSDZ(fileURL: fileURL)
      
    } catch {
      delegate?.didReceiveError("Export failed: \(error.localizedDescription)")
    }
  }
  
  private func uploadUSDZ(fileURL: URL) {
    
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
      delegate?.didReceiveError("Failed to read USDZ file")
      return
    }
    
    body.append(fileData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    
    request.httpBody = body
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        self?.delegate?.didReceiveError("Upload failed: \(error.localizedDescription)")
        try? FileManager.default.removeItem(at: fileURL)
        return
      }
      
      if let httpResponse = response as? HTTPURLResponse {
        if httpResponse.statusCode == 200 {
          let downloadUrl = "http://\(laptopIP):8080/download/\(token)/room.usdz"
          self?.delegate?.didCompleteScan(downloadUrl)
          
          // Send status message
          self?.sendMessage([
            "type": "status",
            "value": "upload_complete",
            "token": token
          ])
        } else {
          self?.delegate?.didReceiveError("Upload failed with status: \(httpResponse.statusCode)")
        }
      }
      
      // Clean up temp file
      try? FileManager.default.removeItem(at: fileURL)
    }
    
    task.resume()
  }
}

extension ScanControllerNative: RoomCaptureSessionDelegate {
  func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    let instructionText = String(describing: instruction)
    delegate?.didReceiveInstruction(instructionText)
    sendMessage(["type": "instruction", "value": instructionText, "token": token])
  }
  
  func captureSession(_ session: RoomCaptureSession, didUpdate capturedRoom: CapturedRoom) {
    DispatchQueue.main.async {
      self.sendRoomUpdate(capturedRoom: capturedRoom)
    }
  }
  
  func captureSession(_ session: RoomCaptureSession, didEndWith capturedRoomData: CapturedRoomData, error: Error?) {
    DispatchQueue.main.async {
      if let error = error {
        self.delegate?.didReceiveError(error.localizedDescription)
      } else {
        self.exportAndUpload(capturedRoomData: capturedRoomData)
      }
    }
  }
}

extension ScanControllerNative: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let currentTime = Date().timeIntervalSince1970
    guard currentTime - lastFrameTime >= frameInterval else { return }
    lastFrameTime = currentTime
    
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self,
            let jpegData = self.convertPixelBufferToJPEG(frame.capturedImage) else {
        return
      }
      
      // Send via WebSocket notification
      NotificationCenter.default.post(
        name: NSNotification.Name("SendWebSocketJPEG"),
        object: nil,
        userInfo: ["data": jpegData]
      )
    }
  }
  
  private func convertPixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
    do {
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      let context = CIContext(options: [.useSoftwareRenderer: false])
      
      guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
        return nil
      }
      
      let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
      return uiImage.jpegData(compressionQuality: 0.7)
    } catch {
      return nil
    }
  }
}
