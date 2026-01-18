@ -1,146 +0,0 @@
//
//  PairingView.swift
//  RoomScanRemote
//
//  Pairing screen with IP and token input
//

import SwiftUI

// Custom text field style for dark theme
struct DarkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(14)
            .background(Color.appPanel)
            .foregroundColor(.appText)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.appBorder.opacity(0.3), lineWidth: 1)
            )
    }
}

struct PairingView: View {
    @State private var laptopIP: String = ""
    @State private var token: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    @State private var navigateToScan: Bool = false
    @State private var showQRScanner: Bool = false
    @State private var scannedToken: String?
    @State private var scannedHost: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                // Dark background
                Color.appBackground
                    .ignoresSafeArea()
                
                VStack(spacing: 30) {
                    // Header
                    VStack(spacing: 8) {
                        Text("RoomScan Remote")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.appText)
                        
                        Text("Connect to your laptop")
                            .font(.subheadline)
                            .foregroundColor(.appTextSecondary)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 20)
                    
                    // Input fields
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Laptop IP Address")
                                .font(.headline)
                                .foregroundColor(.appText)
                            TextField("e.g., 192.168.1.100 or localhost", text: $laptopIP)
                                .textFieldStyle(DarkTextFieldStyle())
                                .keyboardType(.numbersAndPunctuation)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Session Token")
                                .font(.headline)
                                .foregroundColor(.appText)
                            TextField("Enter token", text: $token)
                                .textFieldStyle(DarkTextFieldStyle())
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                    .padding(.horizontal, 24)
                    
                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.statusError)
                            Text(error)
                                .foregroundColor(.statusError)
                                .font(.caption)
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    // Buttons
                    VStack(spacing: 12) {
                        Button(action: { showQRScanner = true }) {
                            HStack(spacing: 10) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 18, weight: .medium))
                                Text("Scan QR Code")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.buttonSuccess)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        
                        Button(action: connect) {
                            HStack(spacing: 10) {
                                if isConnecting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                }
                                Text(isConnecting ? "Connecting..." : "Connect")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(isConnecting || laptopIP.isEmpty || token.isEmpty ? Color.buttonDisabled : Color.buttonPrimary)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isConnecting || laptopIP.isEmpty || token.isEmpty)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    
                    Spacer()
                }
            }
            .navigationBarHidden(true)
            .background(
                NavigationLink(
                    destination: ScanView(laptopIP: laptopIP, token: token),
                    isActive: $navigateToScan
                ) {
                    EmptyView()
                }
            )
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(scannedToken: $scannedToken, scannedHost: $scannedHost)
            }
            .onChange(of: scannedToken) { newToken in
                if let token = newToken {
                    self.token = token
                    // If host was also scanned, use it; otherwise prompt for IP
                    if let host = scannedHost {
                        self.laptopIP = host
                    }
                }
            }
        }
    }
    
    private func connect() {
        guard !laptopIP.isEmpty, !token.isEmpty else {
            errorMessage = "Please enter both IP address and token"
            return
        }
        
        isConnecting = true
        errorMessage = nil
        
        // Validate IP format (basic check)
        let ipComponents = laptopIP.split(separator: ".")
        guard ipComponents.count == 4,
              ipComponents.allSatisfy({ Int($0) != nil && (0...255).contains(Int($0)!) }) else {
            errorMessage = "Invalid IP address format"
            isConnecting = false
            return
        }
        
        // Initialize WebSocket client and attempt connection
        let wsClient = WSClient.shared
        wsClient.connect(laptopIP: laptopIP, token: token) { success, error in
            DispatchQueue.main.async {
                isConnecting = false
                if success {
                    navigateToScan = true
                } else {
                    errorMessage = error ?? "Connection failed"
                }
            }
        }
    }
}