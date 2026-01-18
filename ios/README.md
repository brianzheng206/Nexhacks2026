@ -1,70 +0,0 @@
# RoomScanRemote iOS App

Minimal Swift iOS app for RoomScan Remote MVP.

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## Project Structure

```
RoomScanRemote/
├── RoomScanRemoteApp.swift    # App entry point
├── PairingView.swift          # Pairing screen (IP + token input)
├── ScanView.swift             # Scan screen (status + controls)
├── WSClient.swift             # WebSocket client
├── ScanController.swift       # Scan controller (stub)
└── Info.plist                 # App configuration
```

## Setup

1. Open Xcode
2. Create a new iOS App project:
   - Product Name: `RoomScanRemote`
   - Interface: SwiftUI
   - Language: Swift
   - Minimum Deployment: iOS 17.0
3. Replace the generated files with the files in this directory
4. Copy `Info.plist` keys to your project's Info.plist (or use the provided file)

## Features

### Pairing Screen
- Text field for laptop IP address
- Text field for session token
- Connect button
- Basic IP validation
- Error handling

### Scan Screen
- Status display (Connected/Scanning/Disconnected)
- Start/Stop scan buttons (for local testing)
- Connection info display
- Responds to control messages from server

### WebSocket Client
- Connects to `ws://<laptopIP>:8080`
- Sends hello message: `{type:"hello", role:"phone", token:"..."}`
- Listens for control messages: `{type:"control", action:"start"|"stop"}`
- Handles room_update, instruction, and status messages
- Auto-reconnection on disconnect

## Usage

1. Start the server on your laptop: `cd server && npm start`
2. Create a session: Visit `http://<laptop-ip>:8080/new` to get a token
3. Open the iOS app
4. Enter laptop IP and token
5. Tap "Connect"
6. Use Start/Stop buttons or wait for server control commands

## Next Steps
- Implement RoomPlan scanning in `ScanController`
- Add camera preview (optional)
- Implement USDZ export and upload
- Add error handling and retry logic
