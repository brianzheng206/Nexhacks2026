//
//  PairingView.swift
//  RoomSensor
//
//  Created on 2024
//

import SwiftUI

struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @State private var laptopIP: String = ""
    @State private var token: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 24) {
            Text("Room Sensor")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top, 40)
            
            Text("Connect to Laptop Server")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Laptop IP Address")
                        .font(.headline)
                    
                    TextField("e.g. 192.168.1.10", text: $laptopIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Token")
                        .font(.headline)
                    
                    TextField("Enter token", text: $token)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .padding(.horizontal, 24)
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 24)
            }
            
            Button(action: connect) {
                HStack {
                    if isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .padding(.trailing, 8)
                    }
                    Text(isConnecting ? "Connecting..." : "Connect")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(isConnecting ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isConnecting || laptopIP.isEmpty || token.isEmpty)
            .padding(.horizontal, 24)
            
            Button(action: scanQR) {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan QR Code")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.secondary.opacity(0.2))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            
            Spacer()
        }
        .navigationBarHidden(true)
    }
    
    private func connect() {
        guard !laptopIP.isEmpty, !token.isEmpty else {
            errorMessage = "Please enter both IP address and token"
            return
        }
        
        isConnecting = true
        errorMessage = nil
        
        appState.connect(laptopIP: laptopIP, token: token) { success, error in
            isConnecting = false
            if !success {
                errorMessage = error ?? "Failed to connect"
            }
        }
    }
    
    private func scanQR() {
        // Stub for QR code scanning
        // TODO: Implement QR code scanning
        errorMessage = "QR code scanning not yet implemented"
    }
}

#Preview {
    PairingView()
        .environmentObject(AppState())
}
