//
//  ScanView.swift
//  RoomScanRemote
//
//  Scan screen with real-time 3D visualization and controls
//

import SwiftUI
import RoomPlan
import ARKit

// MARK: - RoomCaptureView Wrapper for SwiftUI
// Uses RoomCaptureView to display the AR session owned by ScanController.
// Enables mesh reconstruction for detailed 3D geometry capture.

struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let scanController: ScanController
    
    func makeUIView(context: Context) -> RoomCaptureView {
        // Create the view - RoomCaptureView has its own internal session
        let roomCaptureView = RoomCaptureView(frame: .zero)
        
        // Connect ScanController to the view's session
        if let session = roomCaptureView.captureSession {
            // Set ScanController as delegate to receive scanning updates and mesh anchors
            session.delegate = scanController
            session.arSession.delegate = scanController
            
            // Store reference in ScanController so it can control the session
            scanController.roomCaptureSession = session
            
            // Try to enable mesh reconstruction on the ARSession
            // Note: This may not work if the session is already running with a different configuration
            enableMeshReconstruction(on: session.arSession)
        }
        
        return roomCaptureView
    }
    
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {
        // Ensure the session is still connected
        if let session = uiView.captureSession, session.delegate !== scanController {
            session.delegate = scanController
            session.arSession.delegate = scanController
            scanController.roomCaptureSession = session
        }
    }
    
    /// Attempt to enable mesh reconstruction on an existing ARSession
    private func enableMeshReconstruction(on arSession: ARSession) {
        // Check if mesh reconstruction is supported
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            // Mesh reconstruction not supported - RoomPlan will still provide parametric data
            return
        }
        
        // Note: We cannot reconfigure an ARSession that's managed by RoomCaptureView
        // The mesh reconstruction must be enabled before the session starts
        // This is a limitation when using RoomCaptureView - for full mesh control,
        // you would need to use a custom ARView with RoomCaptureSession(arSession:)
        // ARSession will receive mesh anchors if RoomPlan enables them internally
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
                // Header with status
                headerView
                    .frame(height: 60)
                    .background(Color(UIColor.systemBackground))
                
                // 3D Room Capture View - takes up most of the screen
                ZStack {
                    // Always show RoomCaptureView to display camera feed
                    // The view will show the camera feed even when not actively scanning
                    RoomCaptureViewRepresentable(scanController: scanController)
                        .ignoresSafeArea(edges: .horizontal)
                    
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
        .alert("Connection Lost", isPresented: $showReconnectAlert) {
            Button("Reconnect") {
                reconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reconnectError ?? "WebSocket connection failed. Would you like to reconnect?")
        }
        .onAppear {
            // Prevent multiple setup calls
            guard !hasAppeared else { return }
            hasAppeared = true
            
            // Set token and connection manager in scan controller
            scanController.token = token
            scanController.connectionManager = connectionManager
            
            setupWebSocketHandlers()
            updateStatus()
            
            // Verify connection is still active
            updateConnectionState()
        }
        .onDisappear {
            // Clean up resources when view disappears (handles all exit paths)
            // This ensures cleanup happens even if user swipes down or uses system gestures
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
            updateStatus() // Update status to show quality indicator
        }
        .onChange(of: scanController.isScanning) { _ in
            updateStatus()
        }
        .onChange(of: scanController.actualFPS) { _, _ in
            // Trigger view update when FPS changes
        }
    }
    
    // MARK: - Header View
    
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
            
            // Status indicator with connection state and quality
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Connection quality indicator (only show when connected)
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
    
    // MARK: - Computed Properties
    
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
    
    // MARK: - Methods
    
    private func setupWebSocketHandlers() {
        // Handle control messages from server
        connectionManager.onControlMessage = { action in
            if action == "start" {
                startScan()
            } else if action == "stop" {
                stopScan()
            }
        }
    }
    
    private func reconnect() {
        // Use reconnect method which shows reconnecting state
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
        // Check if scan is active - show confirmation if so
        if scanController.isScanning {
            showExitConfirmation = true
        } else {
            cleanupAndDismiss()
        }
    }
    
    // Cleanup resources (called on view disappear and before dismiss)
    // Ensures cleanup happens in all exit paths: back button, swipe down, system gestures
    private func cleanup() {
        // Prevent multiple cleanup calls
        guard !hasCleanedUp else { return }
        hasCleanedUp = true
        
        // Stop scanning if active
        if scanController.isScanning {
            scanController.stopScan()
        }
        
        // Disconnect WebSocket - ensures connection is closed in all exit paths
        connectionManager.disconnect()
        
        // Cleanup logged in ScanController and ConnectionManager
    }
    
    // Cleanup and dismiss (called after confirmation or when safe to leave)
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
            // Use connection state display name
            statusMessage = connectionManager.statusMessage
        }
    }
    
    private func updateConnectionState() {
        updateStatus()
        
        // Update wasConnected flag
        if connectionManager.isConnected {
            wasConnected = true
        }
    }
    
    // Format bytes for display
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
            // Show reconnect alert if we were previously connected
            if wasConnected {
                showReconnectAlert = true
                reconnectError = "Connection lost. Would you like to reconnect?"
            }
            isReconnecting = false
            
        case .connecting:
            isReconnecting = false
            
        case .reconnecting:
            isReconnecting = true
            // Show reconnection attempt in UI
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
