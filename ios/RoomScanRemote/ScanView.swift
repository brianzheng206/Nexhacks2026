@ -1,208 +0,0 @@
//
//  ScanView.swift
//  RoomScanRemote
//
//  Scan screen with status and controls
//

import SwiftUI

struct ScanView: View {
    let laptopIP: String
    let token: String
    
    @StateObject private var scanController = ScanController()
    
    init(laptopIP: String, token: String) {
        self.laptopIP = laptopIP
        self.token = token
    }
    @State private var statusMessage: String = "Connected"
    @State private var showLocalControls: Bool = true
    @State private var showReconnectAlert: Bool = false
    @State private var reconnectError: String?
    @State private var wasConnected: Bool = false
    
    var body: some View {
        ZStack {
            // Dark background
            Color.appBackground
                .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Text("RoomScan Remote")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.appText)
                        
                        // Status indicator
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(statusMessage)
                                .font(.subheadline)
                                .foregroundColor(.appTextSecondary)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    
                    // Status card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: statusIcon)
                                .foregroundColor(statusColor)
                                .font(.system(size: 20))
                            Text("Status")
                                .font(.headline)
                                .foregroundColor(.appText)
                        }
                        
                        Text(statusMessage)
                            .font(.body)
                            .foregroundColor(statusColor)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.appPanel)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal, 24)
                    
                    // Local controls (for testing)
                    if showLocalControls {
                        VStack(spacing: 12) {
                            Button(action: startScan) {
                                HStack(spacing: 10) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Start Scan")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    scanController.isScanning || !WSClient.shared.isConnected || !RoomCaptureSession.isSupported
                                    ? Color.buttonDisabled
                                    : Color.buttonSuccess
                                )
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(scanController.isScanning || !WSClient.shared.isConnected || !RoomCaptureSession.isSupported)
                            
                            Button(action: stopScan) {
                                HStack(spacing: 10) {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Stop Scan")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(!scanController.isScanning ? Color.buttonDisabled : Color.buttonDanger)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(!scanController.isScanning)
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    // Connection info card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.appAccent)
                                .font(.system(size: 18))
                            Text("Connection Info")
                                .font(.headline)
                                .foregroundColor(.appText)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("IP:")
                                    .font(.caption)
                                    .foregroundColor(.appTextSecondary)
                                Text(laptopIP)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.appText)
                            }
                            
                            HStack {
                                Text("Token:")
                                    .font(.caption)
                                    .foregroundColor(.appTextSecondary)
                                Text(token)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.appText)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.appPanel)
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 24)
                    
                    Spacer(minLength: 40)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
    
    private var statusColor: Color {
        switch statusMessage.lowercased() {
        case "connected":
            return .statusConnected
        case "scanning":
            return .statusScanning
        case "disconnected", "disconnected - please reconnect":
            return .statusError
        default:
            return .statusWarning
        }
    }
    
    private var statusIcon: String {
        switch statusMessage.lowercased() {
        case "connected":
            return "checkmark.circle.fill"
        case "scanning":
            return "waveform.circle.fill"
        case "disconnected", "disconnected - please reconnect":
            return "xmark.circle.fill"
        default:
            return "exclamationmark.triangle.fill"
        }
    }
    
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
        wsClient.connect(laptopIP: laptopIP, token: token) { success, error in
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