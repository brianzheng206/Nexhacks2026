//
//  PairingView.swift
//  RoomScanRemote
//
//  Pairing screen with IP and token input
//

import SwiftUI

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
            VStack(spacing: 20) {
                Text("RoomScan Remote")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.bottom, 40)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Laptop IP Address")
                        .font(.headline)
                    TextField("e.g., 192.168.1.100", text: $laptopIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Session Token")
                        .font(.headline)
                    TextField("Enter token", text: $token)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                Button(action: { showQRScanner = true }) {
                    HStack {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 20))
                        Text("Scan QR Code")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.top, 10)
                
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
                .padding(.top, 10)
                
                Spacer()
            }
            .padding()
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
