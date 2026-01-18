//
//  QRCodeScannerModule.swift
//  RoomScanRemote
//
//  React Native module for QR code scanning
//

import Foundation
import React
import AVFoundation

@objc(QRCodeScannerModule)
class QRCodeScannerModule: NSObject {
  
  @objc
  func scan(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    // This will be implemented with a view controller
    // For now, return placeholder
    reject("NOT_IMPLEMENTED", "QR scanner view controller needed", nil)
  }
  
  @objc
  static func requiresMainQueueSetup() -> Bool {
    return false
  }
}
