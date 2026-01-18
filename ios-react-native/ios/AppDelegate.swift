//
//  AppDelegate.swift
//  RoomScanRemote
//
//  React Native App Delegate
//

import UIKit
import React

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    
    // For development: connect to Metro bundler
    // For production: use bundled JS
    #if DEBUG
    let jsCodeLocation = URL(string: "http://localhost:8081/index.bundle?platform=ios")!
    #else
    let jsCodeLocation = Bundle.main.url(forResource: "main", withExtension: "jsbundle")!
    #endif
    
    let rootView = RCTRootView(
      bundleURL: jsCodeLocation,
      moduleName: "RoomScanRemote",
      initialProperties: nil,
      launchOptions: launchOptions
    )
    
    let rootViewController = UIViewController()
    rootViewController.view = rootView
    
    self.window = UIWindow(frame: UIScreen.main.bounds)
    self.window?.rootViewController = rootViewController
    self.window?.makeKeyAndVisible()
    
    return true
  }
}
