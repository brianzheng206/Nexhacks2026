# RoomSensor iOS App

Native Swift iOS app acting as sensor: ARKit RGB+depth+pose capture + preview stream + chunk upload.

## Setup

1. Open `RoomSensor.xcodeproj` in Xcode
2. Configure your development team and signing in the project settings
3. Connect your iOS device (iOS 17+)
4. Build and run

## Features

### Pairing Screen
- Text field for laptop IP address (e.g., 192.168.1.10)
- Token input field
- Connect button to establish WebSocket connection
- QR code scan button (stub - not yet implemented)

### Capture Screen
- Status display (connected / scanning / uploading chunk N)
- Start/Stop buttons for manual control
- Responds to control messages from laptop server
- Displays connection info (IP and token)

## WebSocket Protocol

- Connects to `ws://<laptopIP>:8080/ws?token=<token>`
- Sends hello message: `{type:"hello", role:"phone", token:"..."}`
- Receives control messages: `{type:"control", action:"start"|"stop"}`
- Sends control messages: `{type:"control", action:"start"|"stop"}`

## Permissions

The app requires:
- **Camera access** - For capturing RGB and depth images
- **Local network access** - For connecting to laptop server

These are configured in `Info.plist` with appropriate usage descriptions.

## Next Steps

- Implement ARKit RGB+depth+pose capture
- Implement preview stream (JPEG frames via WebSocket)
- Implement chunk upload functionality
