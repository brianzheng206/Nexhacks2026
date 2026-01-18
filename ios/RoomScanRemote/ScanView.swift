//
//  ScanView.swift
//  RoomScanRemote
//
//  Scan screen with real-time 3D visualization and controls
//

import SwiftUI
import RoomPlan

// MARK: - RoomCaptureView Wrapper for SwiftUI
// Uses RoomCaptureView to show live RoomPlan reconstruction.

struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let scanController: ScanController
    
    func makeUIView(context: Context) -> RoomCaptureView {
        let roomCaptureView = RoomCaptureView(frame: .zero)
        // RoomCaptureView has its own read-only captureSession
        // We configure the view's session to use our delegate
        roomCaptureView.captureSession.delegate = scanController
        // Store reference to the view's session in the controller
        scanController.setRoomCaptureSession(roomCaptureView.captureSession)
        return roomCaptureView
    }
    
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Ensure delegate is set
        uiView.captureSession.delegate = scanController
    }
}

// MARK: - Placeholder View when not scanning

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

// MARK: - Main ScanView

struct ScanView: View {
    let serverHost: String
    let serverPort: Int
    let token: String
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanController = ScanController()
    
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
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header with status
                headerView
                    .frame(height: 60)
                    .background(Color(UIColor.systemBackground))
                
                // 3D Room Capture View - takes up most of the screen
                ZStack {
                    if scanController.isScanning {
                        // Show the RoomPlan live reconstruction view.
                        RoomCaptureViewRepresentable(scanController: scanController)
                            .ignoresSafeArea(edges: .horizontal)
                    } else {
                        // Placeholder when not scanning
                        ScanPlaceholderView()
                    }
                    
                    // Overlay status indicator
                    VStack {
                        Spacer()
                        statusOverlay
                            .padding(.bottom, 8)
                    }
                }
                .frame(height: geometry.size.height * 0.55) // 55% of screen for 3D view
                
                // Controls panel at bottom
                controlsPanel
                    .frame(maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(true)
        .alert("Connection Lost", isPresented: $showReconnectAlert) {
            Button("Reconnect") {
                reconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reconnectError ?? "WebSocket connection failed. Would you like to reconnect?")
        }
        .onAppear {
            // Set token in scan controller
            scanController.token = token
            
            setupWebSocketHandlers()
            updateStatus()
            
            // Verify connection is still active
            if !WSClient.shared.isConnected {
                statusMessage = "Disconnected - please reconnect"
            }
        }
        .onChange(of: scanController.isScanning) { _ in
            updateStatus()
        }
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        HStack {
            Button(action: handleBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Back")
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
            
            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(12)
        }
        .padding(.horizontal)
    }
    
    // MARK: - Status Overlay (shown on top of 3D view)
    
    private var statusOverlay: some View {
        HStack(spacing: 12) {
            if scanController.isScanning {
                // Recording indicator
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
    
    // MARK: - Controls Panel
    
    private var controlsPanel: some View {
        VStack(spacing: 16) {
            // Scan controls
            HStack(spacing: 12) {
                Button(action: startScan) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Scan")
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(scanController.isScanning || !WSClient.shared.isConnected || !RoomCaptureSession.isSupported ? Color.gray : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(scanController.isScanning || !WSClient.shared.isConnected || !RoomCaptureSession.isSupported)
                
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
            
            // Connection info (compact)
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
                Text("Token: \(String(token.prefix(8)))...")
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
    
    // MARK: - Computed Properties
    
    private var statusColor: Color {
        switch statusMessage.lowercased() {
        case "connected":
            return .green
        case "scanning":
            return .blue
        case "disconnected", "disconnected - please reconnect":
            return .red
        default:
            return .orange
        }
    }
    
    // MARK: - Methods
    
    private func setupWebSocketHandlers() {
        let wsClient = WSClient.shared
        
        // Update status when connection state changes
        wsClient.onConnectionStateChanged = { isConnected in
            DispatchQueue.main.async {
                if isConnected {
                    statusMessage = "Connected"
                    wasConnected = true
                } else {
                    statusMessage = "Disconnected"
                    // Show reconnect alert if we were previously connected
                    if wasConnected {
                        showReconnectAlert = true
                        reconnectError = "Connection lost. Please reconnect."
                    }
                }
            }
        }
        
        // Handle control messages from server
        wsClient.onControlMessage = { action in
            DispatchQueue.main.async {
                if action == "start" {
                    startScan()
                } else if action == "stop" {
                    stopScan()
                }
            }
        }
    }
    
    private func reconnect() {
        let wsClient = WSClient.shared
        wsClient.connect(laptopHost: serverHost, port: serverPort, token: token) { success, error in
            DispatchQueue.main.async {
                if success {
                    statusMessage = "Connected"
                    showReconnectAlert = false
                    reconnectError = nil
                    wasConnected = true
                } else {
                    reconnectError = error ?? "Reconnection failed"
                    showReconnectAlert = true
                }
            }
        }
    }

    private func handleBack() {
        scanController.stopScan()
        WSClient.shared.disconnect()
        dismiss()
    }
    
    private func updateStatus() {
        if scanController.isScanning {
            statusMessage = "Scanning"
        } else if !RoomCaptureSession.isSupported {
            statusMessage = "RoomPlan not supported"
        } else if WSClient.shared.isConnected {
            statusMessage = "Connected"
        } else {
            statusMessage = "Disconnected"
        }
    }
    
    private func startScan() {
        scanController.startScan()
        statusMessage = "Scanning"
    }
    
    private func stopScan() {
        scanController.stopScan()
        if WSClient.shared.isConnected {
            statusMessage = "Connected"
        } else {
            statusMessage = "Disconnected"
        }
    }
}
