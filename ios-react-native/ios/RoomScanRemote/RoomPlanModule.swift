//
//  RoomPlanModule.swift
//  RoomScanRemote
//
//  React Native module for RoomPlan scanning
//

import Foundation
import React
import RoomPlan
import ARKit

@objc(RoomPlanModule)
class RoomPlanModule: RCTEventEmitter {
  private var scanController: ScanControllerNative?
  static var sharedLaptopIP: String?
  
  @objc
  static func requiresMainQueueSetup() -> Bool {
    return false
  }
  
  @objc
  func setLaptopIP(_ laptopIP: String) {
    RoomPlanModule.sharedLaptopIP = laptopIP
  }
  
  @objc
  func isSupported(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    resolve(RoomCaptureSession.isSupported)
  }
  
  @objc
  func startScan(_ token: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        reject("ERROR", "Module deallocated", nil)
        return
      }
      
      guard RoomCaptureSession.isSupported else {
        reject("NOT_SUPPORTED", "RoomPlan is not supported", nil)
        return
      }
      
      guard let laptopIP = RoomPlanModule.sharedLaptopIP else {
        reject("ERROR", "Laptop IP not set", nil)
        return
      }
      
      self.scanController = ScanControllerNative(token: token, laptopIP: laptopIP)
      self.scanController?.delegate = self
      self.scanController?.startScan()
      resolve(nil)
    }
  }
  
  @objc
  func stopScan(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
    DispatchQueue.main.async { [weak self] in
      self?.scanController?.stopScan()
      self?.scanController = nil
      resolve(nil)
    }
  }
  
  override func supportedEvents() -> [String]! {
    return ["scanUpdate", "scanComplete", "scanError", "instruction"]
  }
}

extension RoomPlanModule: ScanControllerNativeDelegate {
  func didUpdateRoom(_ stats: [String: Any]) {
    sendEvent(withName: "scanUpdate", body: stats)
  }
  
  func didCompleteScan(_ downloadUrl: String?) {
    sendEvent(withName: "scanComplete", body: downloadUrl)
  }
  
  func didReceiveError(_ error: String) {
    sendEvent(withName: "scanError", body: error)
  }
  
  func didReceiveInstruction(_ instruction: String) {
    sendEvent(withName: "instruction", body: instruction)
  }
}
