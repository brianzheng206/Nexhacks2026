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

    @State private var connectionManager = ConnectionManager()
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
    
    // Validation states
    @State private var isServerAddressValid: Bool = true
    @State private var isTokenValid: Bool = true
    @State private var serverAddressValidationMessage: String = ""
    @State private var tokenValidationMessage: String = ""
    
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
                .disabled(isConnecting || serverAddress.isEmpty || token.isEmpty || !isServerAddressValid || !isTokenValid)
                .padding(.top, 10)
                
                Spacer()
            }
            .padding()
            .navigationTitle("RoomScan Remote")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $navigateToScan) {
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
    
    // Real-time validation for server address
    private func validateServerAddress(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            isServerAddressValid = true // Don't show error for empty field
            serverAddressValidationMessage = ""
            return
        }
        
        if let parsed = parseServerAddress(trimmed) {
            isServerAddressValid = true
            serverAddressValidationMessage = ""
        } else {
            isServerAddressValid = false
            serverAddressValidationMessage = "Invalid format. Use: hostname or hostname:port (e.g., 192.168.1.100:8080)"
        }
    }
    
    // Real-time validation for token
    private func validateToken(_ tokenValue: String) {
        let trimmed = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            isTokenValid = true // Don't show error for empty field
            tokenValidationMessage = ""
            return
        }
        
        // Token should be non-empty after trimming
        if trimmed.isEmpty {
            isTokenValid = false
            tokenValidationMessage = "Session token cannot be empty or only whitespace"
            return
        }
        
        // Optional: Add format validation if tokens have a specific format
        // For now, just check it's not empty
        isTokenValid = true
        tokenValidationMessage = ""
    }
    
    // Check server reachability before attempting WebSocket connection
    private func checkReachability(host: String, port: Int, completion: @escaping (Bool, String?) -> Void) {
        let urlString = "http://\(host):\(port)/health"
        guard let url = URL(string: urlString) else {
            completion(false, "Invalid server URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0 // 3 second timeout for reachability check
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .notConnectedToInternet:
                        completion(false, "No internet connection")
                    case .cannotConnectToHost, .timedOut:
                        completion(false, "Cannot reach server. Check address and ensure server is running.")
                    case .dnsLookupFailed:
                        completion(false, "DNS lookup failed. Check server address.")
                    default:
                        completion(false, "Server unreachable: \(urlError.localizedDescription)")
                    }
                } else {
                    completion(false, "Reachability check failed: \(error.localizedDescription)")
                }
                return
            }
            
            // If we get any response (even 404), server is reachable
            if let httpResponse = response as? HTTPURLResponse {
                completion(true, nil)
            } else {
                completion(true, nil) // Non-HTTP response still means server is reachable
            }
        }
        
        task.resume()
    }
    
    private func connect() {
        guard !serverAddress.isEmpty, !token.isEmpty else {
            errorMessage = "Please enter both server address and token"
            return
        }
        
        guard isServerAddressValid, isTokenValid else {
            errorMessage = "Please fix validation errors before connecting"
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
        
        // Normalize token trimming at entry point (before passing to WSClient)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = "Session token cannot be empty"
            isConnecting = false
            return
        }
        
        // Check server reachability first
        checkReachability(host: parsed.host, port: parsed.port) { [weak self] reachable, error in
            guard let self = self else { return }
            
            if !reachable {
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.errorMessage = error ?? "Server unreachable. Please check your network and server address."
                }
                return
            }
            
            // Server is reachable, proceed with WebSocket connection
            self.connectionManager.connect(laptopHost: parsed.host, port: parsed.port, token: trimmedToken) { success, error in
                DispatchQueue.main.async {
                    self.isConnecting = false
                    if success {
                        self.navigateToScan = true
                    } else {
                        // Provide user-friendly error messages
                        let userMessage = error ?? "Connection failed. Please check your network and server settings."
                        self.errorMessage = userMessage
                    }
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
