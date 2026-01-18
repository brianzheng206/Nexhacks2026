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
    
    @State private var isServerAddressValid: Bool = true
    @State private var isTokenValid: Bool = true
    @State private var serverAddressValidationMessage: String = ""
    @State private var tokenValidationMessage: String = ""
    @State private var hasAttemptedAutoConnect: Bool = false
    @State private var autoConnectDebounceTask: DispatchWorkItem?
    
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
                        .onChange(of: serverAddress) { _, newValue in
                            validateServerAddress(newValue)
                        }
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Session Token")
                        .font(.headline)
                    TextField("Enter token", text: $token)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: token) { _, newValue in
                            validateToken(newValue)
                        }
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
            .onChange(of: scannedToken) { _, newToken in
                applyScannedValuesDebounced()
            }
            .onChange(of: scannedHost) { _, newHost in
                applyScannedValuesDebounced()
            }
            .onChange(of: scannedPort) { _, newPort in
                applyScannedValuesDebounced()
            }
        }
    }
    
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
    
    private func validateToken(_ tokenValue: String) {
        let trimmed = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.isEmpty {
            isTokenValid = true // Don't show error for empty field
            tokenValidationMessage = ""
            return
        }
        
        if trimmed.isEmpty {
            isTokenValid = false
            tokenValidationMessage = "Session token cannot be empty or only whitespace"
            return
        }
        
        isTokenValid = true
        tokenValidationMessage = ""
    }
    
    private func checkReachability(host: String, port: Int, completion: @escaping (Bool, String?) -> Void) {
        let urlString = "http://\(host):\(port)/health"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                completion(false, "Invalid server URL")
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4.0 // 4 second timeout for reachability check
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if let urlError = error as? URLError {
                    let errorMsg: String
                    switch urlError.code {
                    case .notConnectedToInternet:
                        errorMsg = "No internet connection"
                    case .cannotConnectToHost, .timedOut:
                        errorMsg = "Cannot reach server. Check address and ensure server is running."
                    case .dnsLookupFailed:
                        errorMsg = "DNS lookup failed. Check server address."
                    default:
                        errorMsg = "Server unreachable: \(urlError.localizedDescription)"
                    }
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(false, "Reachability check failed: \(error.localizedDescription)")
                    }
                }
                return
            }
            
            // If we get any response (even 404), server is reachable
            if let httpResponse = response as? HTTPURLResponse {
                DispatchQueue.main.async {
                    completion(true, nil)
                }
            } else {
                DispatchQueue.main.async {
                    completion(true, nil) // Non-HTTP response still means server is reachable
                }
            }
        }
        
        task.resume()
    }
    
    private func connect() {
        guard !serverAddress.isEmpty, !token.isEmpty else {
            errorMessage = "Please enter both server address and token"
            isConnecting = false
            return
        }
        
        // Re-validate before connecting
        validateServerAddress(serverAddress)
        validateToken(token)
        
        guard isServerAddressValid, isTokenValid else {
            errorMessage = "Please fix validation errors before connecting"
            isConnecting = false
            return
        }
        
        guard !isConnecting else {
            return
        }
        
        isConnecting = true
        errorMessage = nil
        // Don't reset hasAttemptedAutoConnect here - it should stay true if auto-connect was triggered
        // This prevents multiple auto-connect attempts from the same QR scan
        
        guard let parsed = parseServerAddress(serverAddress) else {
            errorMessage = "Invalid server address. Use host or host:port."
            isConnecting = false
            return
        }
        serverHost = parsed.host
        serverPort = parsed.port
        
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            errorMessage = "Session token cannot be empty"
            isConnecting = false
            return
        }
        
        // Add timeout for reachability check to prevent hanging
        let reachabilityTimeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.isConnecting else { return }
            self.isConnecting = false
            self.errorMessage = "Connection timeout - server may be unreachable"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: reachabilityTimeout)
        
        checkReachability(host: parsed.host, port: parsed.port) { [weak self] reachable, error in
            reachabilityTimeout.cancel()
            
            guard let self = self else { return }
            
            if !reachable {
                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.errorMessage = error ?? "Server unreachable. Please check your network and server address."
                }
                return
            }
            
            // Add a maximum timeout to ensure isConnecting is always reset
            // This prevents getting stuck in "Connecting..." state
            let maximumTimeout = DispatchWorkItem { [weak self] in
                guard let self = self, self.isConnecting else { return }
                self.isConnecting = false
                self.errorMessage = "Connection timeout - please check your network and try again"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: maximumTimeout)
            
            let wsClient = WSClient.shared
            wsClient.connect(laptopHost: parsed.host, port: parsed.port, token: trimmedToken) { success, error in
                maximumTimeout.cancel()
                
                DispatchQueue.main.async {
                    if success {
                        self.connectionManager.connectionState = .connected
                    } else {
                        let errorMessage = error ?? "Unknown error"
                        self.connectionManager.connectionState = .failed(errorMessage)
                    }
                    
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

    private func applyScannedValuesDebounced() {
        // Cancel any pending auto-connect
        autoConnectDebounceTask?.cancel()
        
        // Apply scanned values immediately
        if let scannedTokenValue = scannedToken?.trimmingCharacters(in: .whitespacesAndNewlines), !scannedTokenValue.isEmpty {
            self.token = scannedTokenValue
            // Validate token after setting
            validateToken(scannedTokenValue)
        }
        if let host = scannedHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            let address: String
            if let port = scannedPort {
                address = "\(host):\(port)"
            } else {
                address = "\(host):\(defaultPort)"
            }
            self.serverAddress = address
            // Validate server address after setting
            validateServerAddress(address)
        }
        
        // Debounce the auto-connect to wait for all values to be set and validated
        // Use slightly longer delay to ensure validation completes
        let task = DispatchWorkItem { [self] in
            DispatchQueue.main.async {
                // Double-check that we have both values before attempting
                if !self.serverAddress.isEmpty && !self.token.isEmpty {
                    self.attemptAutoConnect()
                }
            }
        }
        autoConnectDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
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
        // Don't attempt if already connecting or navigating
        guard !isConnecting, !navigateToScan else {
            logger.debug("Skipping auto-connect: isConnecting=\(isConnecting), navigateToScan=\(navigateToScan)")
            return
        }
        
        // Require both server address and token to be filled
        guard !serverAddress.isEmpty, !token.isEmpty else {
            logger.debug("Skipping auto-connect: missing serverAddress or token")
            return
        }
        
        // Require validation to pass
        guard isServerAddressValid, isTokenValid else {
            logger.debug("Skipping auto-connect: validation failed")
            return
        }
        
        // Only attempt auto-connect once per QR scan
        guard !hasAttemptedAutoConnect else {
            logger.debug("Skipping auto-connect: already attempted")
            return
        }
        
        logger.info("========== AUTO-CONNECT TRIGGERED ==========")
        logger.info("Server: \(serverAddress), Token length: \(token.count)")
        
        hasAttemptedAutoConnect = true
        connect()
    }
}
