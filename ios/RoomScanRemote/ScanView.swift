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
    @State private var statusMessage: String = "Connected"
    @State private var showLocalControls: Bool = true
    
    var body: some View {
        VStack(spacing: 30) {
            Text("RoomScan Remote")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top)
            
            // Status display
            VStack(spacing: 10) {
                Text("Status")
                    .font(.headline)
                Text(statusMessage)
                    .font(.body)
                    .foregroundColor(statusColor)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
            }
            .padding(.horizontal)
            
            // Local controls (for testing)
            if showLocalControls {
                VStack(spacing: 15) {
                    Button(action: startScan) {
                        Text("Start Scan")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(scanController.isScanning)
                    
                    Button(action: stopScan) {
                        Text("Stop Scan")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(!scanController.isScanning)
                }
                .padding(.horizontal)
            }
            
            // Connection info
            VStack(alignment: .leading, spacing: 5) {
                Text("Connection Info")
                    .font(.headline)
                Text("IP: \(laptopIP)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Token: \(token)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
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
            return .green
        case "scanning":
            return .blue
        case "disconnected":
            return .red
        default:
            return .orange
        }
    }
    
    private func setupWebSocketHandlers() {
        let wsClient = WSClient.shared
        
        // Update status when connection state changes
        wsClient.onConnectionStateChanged = { isConnected in
            DispatchQueue.main.async {
                statusMessage = isConnected ? "Connected" : "Disconnected"
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
    
    private func updateStatus() {
        if scanController.isScanning {
            statusMessage = "Scanning"
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
