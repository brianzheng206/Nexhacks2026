//
//  ScanController.swift
//  RoomScanRemote
//
//  Controller for room scanning (stub for now)
//

import Foundation
import Combine

class ScanController: ObservableObject {
    @Published var isScanning: Bool = false
    
    func startScan() {
        guard !isScanning else { return }
        
        print("[ScanController] Starting scan...")
        isScanning = true
        
        // TODO: Implement RoomPlan scanning
        // For now, just update the state
    }
    
    func stopScan() {
        guard isScanning else { return }
        
        print("[ScanController] Stopping scan...")
        isScanning = false
        
        // TODO: Implement RoomPlan stop
        // For now, just update the state
    }
}
