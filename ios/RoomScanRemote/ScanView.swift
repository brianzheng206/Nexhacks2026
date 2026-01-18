//
//  ScanView.swift
//  RoomScanRemote
//
//  Scan screen with real-time 3D visualization and controls
//

import SwiftUI
import RoomPlan
import ARKit

struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let scanController: ScanController
    
    func makeUIView(context: Context) -> RoomCaptureView {
        let roomCaptureView = RoomCaptureView(frame: .zero)
        
        if let session = roomCaptureView.captureSession {
            session.delegate = scanController
            session.arSession.delegate = scanController
            scanController.roomCaptureSession = session
            enableMeshReconstruction(on: session.arSession)
        }
        
        return roomCaptureView
    }
    
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Only update if session changed - avoid unnecessary reassignments that cause jitter
        // SwiftUI calls this frequently, so we minimize work here
        if let session = uiView.captureSession {
            // Only reassign if delegate is actually different to avoid unnecessary updates
            if session.delegate !== scanController {
                session.delegate = scanController
            }
            if session.arSession.delegate !== scanController {
                session.arSession.delegate = scanController
            }
            // Only update if session reference changed
            if scanController.roomCaptureSession !== session {
                scanController.roomCaptureSession = session
            }
        }
    }
    
    private func enableMeshReconstruction(on arSession: ARSession) {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            return
        }
    }
}

struct ScanPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            
            Text("3D Room Preview")
                .font(.headline)
                .foregroundColor(.gray)
            
            Text("Start scanning to see the\nreal-time 3D reconstruction")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

struct ScanView: View {
    let serverHost: String
    let serverPort: Int
    let token: String
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanController = ScanController()
    @State private var connectionManager = ConnectionManager()
    
    init(serverHost: String, serverPort: Int, token: String) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.token = token
    }
    @State private var statusMessage: String = "Connected"
    @State private var showLocalControls: Bool = true
    @State private var showReconnectAlert: Bool = false
    @State private var reconnectError: String?
    @State private var wasConnected: Bool = false
    @State private var isReconnecting: Bool = false
    @State private var showExitConfirmation: Bool = false
    @State private var hasAppeared: Bool = false
    @State private var hasCleanedUp: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                headerView
                    .frame(height: 60)
                    .background(Color(UIColor.systemBackground))
                
                ZStack {
                    RoomCaptureViewRepresentable(scanController: scanController)
                        .ignoresSafeArea(edges: .horizontal)
                    
                    VStack {
                        Spacer()
                        statusOverlay
                            .padding(.bottom, 8)
                    }
                }
                .frame(height: geometry.size.height * 0.55)
                
                controlsPanel
                    .frame(maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
            }
        }
        .alert("Connection Lost", isPresented: $showReconnectAlert) {
            Button("Reconnect") {
                reconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reconnectError ?? "WebSocket connection failed. Would you like to reconnect?")
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            
            scanController.token = token
            scanController.connectionManager = connectionManager
            
            setupWebSocketHandlers()
            
            // Ensure connection is established - reconnect if needed
            if !connectionManager.isConnected {
                connectionManager.connect(laptopHost: serverHost, port: serverPort, token: token) { success, error in
                    if success {
                        statusMessage = "Connected"
                        wasConnected = true
                    } else {
                        reconnectError = error ?? "Connection failed"
                        showReconnectAlert = true
                    }
                }
            } else {
                wasConnected = true
            }
            
            updateStatus()
            updateConnectionState()
        }
        .onDisappear {
            cleanup()
        }
        .confirmationDialog("Leave Scan Session?", isPresented: $showExitConfirmation) {
            Button("Leave", role: .destructive) {
                cleanupAndDismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if scanController.isScanning {
                Text("A scan is in progress. Leaving will stop the scan and disconnect from the server.")
            } else {
                Text("Are you sure you want to leave? This will disconnect from the server.")
            }
        }
        .onChange(of: connectionManager.connectionState) { _, newState in
            updateConnectionState()
            handleConnectionStateChange(newState)
        }
        .onChange(of: connectionManager.connectionQuality) { _, quality in
            updateStatus()
        }
        .onChange(of: scanController.isScanning) { _ in
            updateStatus()
        }
    }
    
    private var headerView: some View {
        HStack {
            Button(action: handleBack) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                    Text("Close")
                }
                .font(.subheadline)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(10)
            }

            Text("RoomScan Remote")
                .font(.headline)
                .fontWeight(.bold)
            
            Spacer()
            
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if connectionManager.isConnected {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(connectionManager.connectionQuality == .good ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(connectionManager.connectionQuality.displayName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }
    
    private var statusOverlay: some View {
        HStack(spacing: 12) {
            if scanController.isScanning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .opacity(0.8)
                    Text("SCANNING")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(16)
            }
        }
    }
    
    private var controlsPanel: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button(action: startScan) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Scan")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(scanController.isScanning || !connectionManager.isConnected || !RoomCaptureSession.isSupported ? Color.gray : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(scanController.isScanning || !connectionManager.isConnected || !RoomCaptureSession.isSupported)
                
                Button(action: stopScan) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Stop Scan")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(!scanController.isScanning ? Color.gray : Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!scanController.isScanning)
            }
            .padding(.horizontal)
            
            HStack {
                Image(systemName: "wifi")
                    .foregroundColor(.secondary)
                Text("Server: \(serverHost):\(serverPort)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                    .frame(height: 12)
                
                Image(systemName: "key")
                    .foregroundColor(.secondary)
                Text("Token: \(token.maskedForLogging)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
        }
        .padding(.vertical, 16)
    }
    
    private var statusColor: Color {
        switch connectionManager.connectionState {
        case .connected:
            return scanController.isScanning ? .blue : .green
        case .connecting, .reconnecting:
            return .orange
        case .disconnected:
            return .gray
        case .failed:
            return .red
        }
    }
    
    private func setupWebSocketHandlers() {
        connectionManager.onControlMessage = { action in
            if action == "start" {
                startScan()
            } else if action == "stop" {
                stopScan()
            }
        }
    }
    
    private func reconnect() {
        connectionManager.reconnect(laptopHost: serverHost, port: serverPort, token: token) { success, error in
            if success {
                statusMessage = "Connected"
                showReconnectAlert = false
                reconnectError = nil
                wasConnected = true
                isReconnecting = false
            } else {
                reconnectError = error ?? "Reconnection failed. Please check your network and server settings."
                showReconnectAlert = true
                isReconnecting = false
            }
        }
    }

    private func handleBack() {
        if scanController.isScanning {
            showExitConfirmation = true
        } else {
            cleanupAndDismiss()
        }
    }
    
    private func cleanup() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true
        
        if scanController.isScanning {
            scanController.stopScan()
        }
        
        connectionManager.disconnect()
    }
    
    private func cleanupAndDismiss() {
        cleanup()
        dismiss()
    }
    
    private func updateStatus() {
        if scanController.isScanning {
            statusMessage = "Scanning"
        } else if !RoomCaptureSession.isSupported {
            statusMessage = "RoomPlan not supported"
        } else {
            statusMessage = connectionManager.statusMessage
        }
    }
    
    private func updateConnectionState() {
        updateStatus()
        
        if connectionManager.isConnected {
            wasConnected = true
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
    
    private func handleConnectionStateChange(_ newState: ConnectionState) {
        switch newState {
        case .connected:
            wasConnected = true
            showReconnectAlert = false
            reconnectError = nil
            isReconnecting = false
            
        case .disconnected:
            if wasConnected {
                showReconnectAlert = true
                reconnectError = "Connection lost. Would you like to reconnect?"
            }
            isReconnecting = false
            
        case .connecting:
            isReconnecting = false
            
        case .reconnecting:
            isReconnecting = true
            statusMessage = "Reconnecting..."
            
        case .failed(let error):
            isReconnecting = false
            if wasConnected {
                showReconnectAlert = true
                reconnectError = error
            }
        }
    }
    
    private func startScan() {
        scanController.startScan()
        statusMessage = "Scanning"
    }
    
    private func stopScan() {
        scanController.stopScan()
        if connectionManager.isConnected {
            statusMessage = "Connected"
        } else {
            statusMessage = "Disconnected"
        }
    }
}
