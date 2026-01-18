//
//  CaptureView.swift
//  RoomSensor
//
//  Created on 2024
//

import SwiftUI
import ARKit
import SceneKit

struct CaptureView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false
    
    var body: some View {
        ZStack {
            // AR Preview
            if let arSession = appState.getARSession() {
                ARViewContainer(session: arSession)
                    .edgesIgnoringSafeArea(.all)
            }
            
            // Overlay UI
            VStack(spacing: 24) {
            // Status Section
            VStack(spacing: 12) {
                Text("Status")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(statusText)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(statusColor.opacity(0.8))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 60)
            
            // Connection Info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Laptop IP:")
                        .foregroundColor(.white)
                    Text(appState.laptopIP ?? "Unknown")
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                
                HStack {
                    Text("Token:")
                        .foregroundColor(.white)
                    Text(appState.token?.prefix(16) ?? "Unknown")
                        .fontWeight(.medium)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.6))
            .cornerRadius(10)
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Control Buttons
            VStack(spacing: 16) {
                Button(action: toggleScan) {
                    HStack {
                        Image(systemName: isScanning ? "stop.circle.fill" : "play.circle.fill")
                        Text(isScanning ? "Stop Scanning" : "Start Scanning")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isScanning ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(!appState.isConnected)
                
                Button(action: disconnect) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Disconnect")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.secondary)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                
                Button(action: resetSession) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                        Text("Reset Session")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            }
            .background(Color.black.opacity(0.3))
        }
        .navigationBarTitle("Room Sensor", displayMode: .inline)
        .onReceive(appState.$scanningState) { state in
            isScanning = (state == .scanning)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ARKitError"))) { notification in
            if let message = notification.object as? String {
                errorMessage = message
                showError = true
            }
        }
        .alert("ARKit Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - ARViewContainer

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session
        arView.automaticallyUpdatesLighting = true
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // No updates needed
    }
    
    private var statusText: String {
        switch appState.scanningState {
        case .connected:
            return "Connected"
        case .scanning:
            return "Scanning..."
        case .uploading(let chunkNumber):
            return "Uploading chunk \(chunkNumber)"
        case .disconnected:
            return "Disconnected"
        }
    }
    
    private var statusColor: Color {
        switch appState.scanningState {
        case .connected, .scanning:
            return .green
        case .uploading:
            return .orange
        case .disconnected:
            return .red
        }
    }
    
    private func toggleScan() {
        if isScanning {
            appState.stopScan()
        } else {
            appState.startScan()
        }
    }
    
    private func disconnect() {
        appState.disconnect()
    }
    
    private func resetSession() {
        appState.resetSession()
        // Show confirmation
        // In a real app, you might want to show an alert
    }
}

#Preview {
    CaptureView()
        .environmentObject(AppState())
}
