# RoomScan Remote - React Native

React Native version of RoomScan Remote iOS app. Allows development on Windows with final deployment on Mac.

## ✅ Build Status

**Windows Setup**: ✅ Complete
- npm dependencies installed
- Project structure created
- All code written

**Mac Setup**: ⏳ Pending
- Requires Xcode project creation
- See `BUILD.md` for instructions

## Quick Start

### On Windows (Development)
```bash
cd ios-react-native
npm start  # Check for syntax errors
```

### On Mac (Building)
```bash
cd ios-react-native
cd ios && pod install && cd ..
# Then follow BUILD.md to create Xcode project
npm run ios
```

## Project Structure

- `src/` - React Native TypeScript code
- `ios/RoomScanRemote/` - Native Swift modules
- `ios/` - Xcode project files (to be created on Mac)

## Documentation

- **QUICKSTART.md** - Quick setup guide
- **BUILD.md** - Detailed build instructions
- **BUILD_STATUS.md** - Current build status
- **SETUP.md** - Complete setup guide

## Features

✅ WebSocket communication
✅ RoomPlan scanning
✅ Live preview streaming
✅ USDZ upload
✅ QR code pairing (needs view controller)

## Requirements

- Node.js 18+
- Mac with Xcode 15+ (for building)
- iOS 17+ device (for RoomPlan testing)
- CocoaPods (for iOS dependencies)

## Development Workflow

1. **Windows**: Edit TypeScript files in `src/`
2. **Mac**: Build and test on device
3. **Server**: Unchanged, works with both versions
