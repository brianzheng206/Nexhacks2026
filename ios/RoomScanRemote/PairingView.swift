//
//  PairingView.swift
//  RoomScanRemote
//
//  Pairing screen with server address and token input
//

import SwiftUI
import Foundation

struct PairingView: View {
    private let defaultPort = 8080

    @State private var serverAddress: String = ""
    @State private var serverHost: String = ""
    @State private var serverPort: Int = 8080
    @State private var token: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    @State private var navigateToScan: Bool = false
    @State private var showQRScanner: Bool = false
    @State private var scannedToken: String?
    @State private var scannedHost: String?
    @State private var scannedPort: Int?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("RoomScan Remote")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.bottom, 40)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Server Address")
                        .font(.headline)
                    TextField("e.g., 192.168.1.100:8080", text: $serverAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.URL)
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
                .disabled(isConnecting || serverAddress.isEmpty || token.isEmpty)
                .padding(.top, 10)
                
                Spacer()
            }
            .padding()
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $navigateToScan) {
                ScanView(serverHost: serverHost, serverPort: serverPort, token: token)
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(scannedToken: $scannedToken, scannedHost: $scannedHost, scannedPort: $scannedPort)
            }
            .onChange(of: scannedToken) { _ in
                applyScannedValues()
            }
            .onChange(of: scannedHost) { _ in
                applyScannedValues()
            }
            .onChange(of: scannedPort) { _ in
                applyScannedValues()
            }
        }
    }
    
    private func connect() {
        guard !serverAddress.isEmpty, !token.isEmpty else {
            errorMessage = "Please enter both server address and token"
            return
        }
        
        isConnecting = true
        errorMessage = nil
        
        guard let parsed = parseServerAddress(serverAddress) else {
            errorMessage = "Invalid server address. Use host or host:port."
            isConnecting = false
            return
        }
        serverHost = parsed.host
        serverPort = parsed.port
        
        // Initialize WebSocket client and attempt connection
        let wsClient = WSClient.shared
        wsClient.connect(laptopHost: parsed.host, port: parsed.port, token: token) { success, error in
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

    private func applyScannedValues() {
        if let token = scannedToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            self.token = token
        }
        if let host = scannedHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            if let port = scannedPort {
                serverAddress = "\(host):\(port)"
            } else {
                serverAddress = host
            }
        }
        attemptAutoConnect()
    }

    private func parseServerAddress(_ input: String) -> (host: String, port: Int)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           url.scheme == "roomscan",
           url.host == "pair" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let host = components?.queryItems?.first(where: { $0.name == "host" })?.value
            let portValue = components?.queryItems?.first(where: { $0.name == "port" })?.value
            let port = Int(portValue ?? "") ?? defaultPort
            if let host = host, !host.isEmpty {
                return (host, port)
            }
        }

        if trimmed.contains("://") || trimmed.contains("/") || trimmed.contains("?") {
            let urlString = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
            if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
                return (host, url.port ?? defaultPort)
            }
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let host = String(parts[0])
            let portValue = String(parts[1])
            guard !host.isEmpty,
                  let port = Int(portValue),
                  (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }

        return (trimmed, defaultPort)
    }

    private func attemptAutoConnect() {
        guard !isConnecting, !navigateToScan else { return }
        guard !serverAddress.isEmpty, !token.isEmpty else { return }
        connect()
    }
}
