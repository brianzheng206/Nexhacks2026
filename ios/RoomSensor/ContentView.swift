//
//  ContentView.swift
//  RoomSensor
//
//  Created on 2024
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        NavigationView {
            if appState.isConnected {
                CaptureView()
                    .environmentObject(appState)
            } else {
                PairingView()
                    .environmentObject(appState)
            }
        }
    }
}

#Preview {
    ContentView()
}
