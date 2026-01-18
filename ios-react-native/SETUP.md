# React Native Setup Guide

## Overview

This React Native version allows you to:
- **Develop on Windows**: Write TypeScript/JavaScript code
- **Deploy on Mac**: Build and test on iOS device/simulator

## Project Structure

```
ios-react-native/
├── src/                    # React Native TypeScript code
│   ├── screens/           # UI screens
│   ├── components/        # Reusable components
│   ├── services/          # Business logic
│   └── native/            # Native module TypeScript interfaces
├── ios/                   # Native iOS Swift code
│   └── RoomScanRemote/    # Native modules
└── package.json
```

## Initial Setup (Mac Required)

### 1. Install Dependencies

```bash
cd ios-react-native
npm install
```

### 2. Install React Navigation

```bash
npm install @react-navigation/native @react-navigation/native-stack
npm install react-native-screens react-native-safe-area-context
```

### 3. Create Xcode Project

You'll need to create an Xcode project that links the native modules:

1. Open Xcode
2. Create new iOS App project: "RoomScanRemote"
3. Set iOS deployment target to 17.0
4. Add the Swift files from `ios/RoomScanRemote/` to the project
5. Configure bridging header (see below)

### 4. Configure Bridging Header

In Xcode:
1. Go to Build Settings → Swift Compiler - General
2. Set "Objective-C Bridging Header" to: `RoomScanRemote/RoomScanRemote-Bridging-Header.h`

### 5. Link React Native

Add React Native via CocoaPods:

```bash
cd ios
pod init
```

Edit `Podfile`:
```ruby
platform :ios, '17.0'
use_frameworks!

target 'RoomScanRemote' do
  pod 'React', :path => '../node_modules/react-native'
  pod 'React-Core', :path => '../node_modules/react-native'
  pod 'React-RCTAppDelegate', :path => '../node_modules/react-native'
  pod 'React-CoreModules', :path => '../node_modules/react-native'
end
```

```bash
pod install
```

### 6. Update AppDelegate

In `AppDelegate.swift`:
```swift
import UIKit
import React

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let jsCodeLocation = URL(string: "http://localhost:8081/index.bundle?platform=ios")!
    
    let rootView = RCTRootView(bundleURL: jsCodeLocation, moduleName: "RoomScanRemote", initialProperties: nil, launchOptions: launchOptions)
    
    self.window = UIWindow(frame: UIScreen.main.bounds)
    let rootViewController = UIViewController()
    rootViewController.view = rootView
    self.window?.rootViewController = rootViewController
    self.window?.makeKeyAndVisible()
    
    return true
  }
}
```

## Development Workflow

### On Windows (Development)

1. Edit TypeScript files in `src/`
2. Check for syntax errors: `npm start` (Metro bundler)
3. Can't test RoomPlan without Mac/device

### On Mac (Testing)

1. Start Metro bundler: `npm start`
2. In another terminal: `npm run ios`
3. Or open Xcode and run the project

## Native Modules

The app uses three native modules:

1. **WebSocketModule**: WebSocket client
2. **RoomPlanModule**: RoomPlan scanning
3. **QRCodeScannerModule**: QR code scanning (needs implementation)

## Notes

- RoomPlan requires iOS 17+ and a device (not simulator)
- Final build/deployment needs Mac
- Server code is unchanged (works with any client)
