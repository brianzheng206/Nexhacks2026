//
//  QRScannerView.swift
//  RoomScanRemote
//
//  QR code scanner using AVFoundation
//

import SwiftUI
import AVFoundation
import AudioToolbox
import UIKit

private let logger = AppLogger.qrScanner

struct QRScannerView: UIViewControllerRepresentable {
    @Binding var scannedToken: String?
    @Binding var scannedHost: String?
    @Binding var scannedPort: Int?
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // No updates needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QRScannerDelegate {
        var parent: QRScannerView
        
        init(_ parent: QRScannerView) {
            self.parent = parent
        }
        
        func didScanQRCode(token: String?, host: String?, port: Int?, error: String?) {
            if let error = error {
                // Show error alert
                DispatchQueue.main.async {
                    let alert = UIAlertController(
                        title: "Invalid QR Code",
                        message: error,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    // Note: We can't easily show alert from here without view controller reference
                    // The error will be handled by the parent view
                }
            } else {
                parent.scannedToken = token
                parent.scannedHost = host
                parent.scannedPort = port
                parent.dismiss()
            }
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func didScanQRCode(token: String?, host: String?, port: Int?, error: String?)
}

class QRScannerViewController: UIViewController {
    weak var delegate: QRScannerDelegate?
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    
    // Track last scanned value to prevent duplicate scans
    private var lastScannedValue: String?
    private var lastScanTime: Date?
    private let scanDebounceInterval: TimeInterval = 1.0 // Ignore duplicate scans within 1 second
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        // Setup camera
        setupCamera()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if let session = captureSession, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }
    }
    
    private func setupCamera() {
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            logger.error("No video capture device available")
            return
        }
        
        let videoInput: AVCaptureDeviceInput
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            logger.error("Error creating video input: \(error.localizedDescription)")
            return
        }
        
        let captureSession = AVCaptureSession()
        self.captureSession = captureSession
        
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            logger.error("Cannot add video input")
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            logger.error("Cannot add metadata output")
            return
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.frame = view.layer.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        if let previewLayer = previewLayer {
            view.layer.addSublayer(previewLayer)
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
        
        // Add cancel button
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.7)
        cancelButton.layer.cornerRadius = 8
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)
        
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            cancelButton.widthAnchor.constraint(equalToConstant: 100),
            cancelButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        // Add instruction label
        let instructionLabel = UILabel()
        instructionLabel.text = "Point camera at QR code"
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        instructionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        instructionLabel.layer.cornerRadius = 8
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)
        
        NSLayoutConstraint.activate([
            instructionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instructionLabel.widthAnchor.constraint(equalToConstant: 250),
            instructionLabel.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    
    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
    
    private func parseQRCode(_ string: String) -> (token: String?, host: String?, port: Int?, error: String?) {
        // Try to parse roomscan://pair?token=...&host=...&port=...
        if let url = URL(string: string),
           url.scheme == "roomscan",
           url.host == "pair" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems
            
            let token = queryItems?.first(where: { $0.name == "token" })?.value
            let host = queryItems?.first(where: { $0.name == "host" })?.value
            let portValue = queryItems?.first(where: { $0.name == "port" })?.value
            let port = portValue.flatMap { Int($0) }
            
            if token == nil {
                return (nil, nil, nil, "QR code missing session token. Expected format: roomscan://pair?token=...&host=...&port=...")
            }
            if host == nil {
                return (nil, nil, nil, "QR code missing server address. Expected format: roomscan://pair?token=...&host=...&port=...")
            }
            
            return (token, host, port, nil)
        }
        
        // Try to parse http://.../download/<token>/room.usdz
        if let url = URL(string: string) {
            let pathComponents = url.pathComponents
            if pathComponents.count >= 3 {
                // Extract token from path like /download/<token>/room...
                if let tokenIndex = pathComponents.firstIndex(of: "download"), tokenIndex + 1 < pathComponents.count {
                    let token = pathComponents[tokenIndex + 1]
                    let host = url.host
                    if token.isEmpty {
                        return (nil, nil, nil, "QR code missing session token in URL path. Expected format: http://host:port/download/<token>/room.usdz")
                    }
                    return (token, host, url.port, nil)
                }
            }
        }
        
        // Try to parse as URL with query parameters
        if let url = URL(string: string),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            let token = queryItems.first(where: { $0.name == "token" })?.value
            let host = queryItems.first(where: { $0.name == "host" })?.value ?? url.host
            if token == nil {
                return (nil, nil, nil, "QR code missing token parameter. Expected format: http://host:port?token=...&host=...")
            }
            return (token, host, url.port, nil)
        }
        
        // No valid format found
        return (nil, nil, nil, "Invalid QR code format. Expected one of:\n• roomscan://pair?token=<session_token>&host=<server>&port=<port>\n• http://host:port/download/<session_token>/room.usdz\n• http://host:port?token=<session_token>&host=<server>")
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    // Track last scanned value to prevent duplicate scans
    private var lastScannedValue: String?
    private var lastScanTime: Date?
    private let scanDebounceInterval: TimeInterval = 1.0 // Ignore duplicate scans within 1 second
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first else { return }
        guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
        guard let stringValue = readableObject.stringValue else { return }
        
        // Debounce: Ignore duplicate scans within debounce interval
        let now = Date()
        if let lastValue = lastScannedValue, lastValue == stringValue,
           let lastTime = lastScanTime, now.timeIntervalSince(lastTime) < scanDebounceInterval {
            logger.debug("Ignoring duplicate QR scan (debounced)")
            return
        }
        
        lastScannedValue = stringValue
        lastScanTime = now
        
        // Stop scanning to prevent multiple detections
        captureSession?.stopRunning()
        
        // Parse QR code
        let (token, host, port, error) = parseQRCode(stringValue)
        
        if error == nil && token != nil {
            // Success - provide haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            // Also vibrate for older devices
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        } else {
            // Error - provide error haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
        }
        
        // Notify delegate (only once per unique scan)
        delegate?.didScanQRCode(token: token, host: host, port: port, error: error)
    }
}
