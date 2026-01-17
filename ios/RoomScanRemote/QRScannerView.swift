//
//  QRScannerView.swift
//  RoomScanRemote
//
//  QR code scanner using AVFoundation
//

import SwiftUI
import AVFoundation
import AudioToolbox

struct QRScannerView: UIViewControllerRepresentable {
    @Binding var scannedToken: String?
    @Binding var scannedHost: String?
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
        
        func didScanQRCode(token: String?, host: String?) {
            parent.scannedToken = token
            parent.scannedHost = host
            parent.dismiss()
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func didScanQRCode(token: String?, host: String?)
}

class QRScannerViewController: UIViewController {
    weak var delegate: QRScannerDelegate?
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    
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
            print("[QRScanner] No video capture device available")
            return
        }
        
        let videoInput: AVCaptureDeviceInput
        
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            print("[QRScanner] Error creating video input: \(error)")
            return
        }
        
        let captureSession = AVCaptureSession()
        self.captureSession = captureSession
        
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            print("[QRScanner] Cannot add video input")
            return
        }
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            print("[QRScanner] Cannot add metadata output")
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
    
    private func parseQRCode(_ string: String) -> (token: String?, host: String?) {
        // Try to parse roomscan://pair?token=...&host=...&port=...
        if let url = URL(string: string),
           url.scheme == "roomscan",
           url.host == "pair" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems
            
            let token = queryItems?.first(where: { $0.name == "token" })?.value
            let host = queryItems?.first(where: { $0.name == "host" })?.value
            
            return (token, host)
        }
        
        // Try to parse http://.../download/<token>/room.usdz
        if let url = URL(string: string),
           url.scheme == "http" || url.scheme == "https",
           let pathComponents = url.pathComponents,
           pathComponents.count >= 3 {
            // Extract token from path like /download/<token>/room.usdz
            let tokenIndex = pathComponents.firstIndex(of: "download")
            if let index = tokenIndex, index + 1 < pathComponents.count {
                let token = pathComponents[index + 1]
                let host = url.host
                return (token, host)
            }
        }
        
        // Try to parse as URL with query parameters
        if let url = URL(string: string),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            let token = queryItems.first(where: { $0.name == "token" })?.value
            let host = queryItems.first(where: { $0.name == "host" })?.value ?? url.host
            return (token, host)
        }
        
        return (nil, nil)
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }
            
            // Stop scanning
            captureSession?.stopRunning()
            
            // Parse QR code
            let (token, host) = parseQRCode(stringValue)
            
            // Vibrate on success
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            
            // Notify delegate
            delegate?.didScanQRCode(token: token, host: host)
        }
    }
}
