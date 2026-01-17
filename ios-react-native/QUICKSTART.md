# Quick Start Guide

## ✅ What's Already Done

- ✅ npm dependencies installed
- ✅ Project structure created
- ✅ Native modules written
- ✅ React Native components created
- ✅ Configuration files set up

## 🚀 Next Steps (On Mac)

### 1. Install CocoaPods (if not already installed)

```bash
sudo gem install cocoapods
```

### 2. Install iOS Dependencies

```bash
cd ios-react-native/ios
pod install
cd ..
```

### 3. Create Xcode Project

**Option A: Use React Native CLI (Easiest)**

```bash
# On Mac, create a fresh React Native project
npx react-native init RoomScanRemoteTemp --template react-native-template-typescript

# Copy the generated ios/ folder structure
# Then copy our native modules into it:
# - Copy ios-react-native/ios/RoomScanRemote/*.swift files
# - Copy ios-react-native/ios/RoomScanRemote/*.h files
# - Update AppDelegate.swift with our version
# - Update Info.plist with our version
```

**Option B: Manual Xcode Setup**

1. Open Xcode → New Project → iOS App
2. Name: `RoomScanRemote`, Language: Swift, iOS 17.0+
3. Add all Swift files from `ios/RoomScanRemote/`
4. Configure bridging header (see BUILD.md)
5. Copy `AppDelegate.swift` and `Info.plist` from our `ios/` folder

### 4. Build and Run

```bash
# Start Metro bundler
npm start

# In another terminal (or Xcode)
npm run ios
```

## 📱 Testing

1. **Start the server** (from project root):
   ```bash
   cd server
   npm start
   ```

2. **Open pairing page** in browser:
   ```
   http://<your-laptop-ip>:8080/new
   ```

3. **Run the app** on iPhone (iOS 17+ required for RoomPlan)

4. **Connect** using the token from the pairing page

## 🔧 Troubleshooting

### Metro bundler won't start
```bash
npm start -- --reset-cache
```

### Pod install fails
```bash
cd ios
pod deintegrate
pod install
cd ..
```

### Native module not found
- Check that all Swift files are added to Xcode project
- Verify bridging header path in Build Settings
- Clean build folder (Cmd+Shift+K in Xcode)

### RoomPlan not working
- Requires iOS 17+ on physical device (not simulator)
- Check `RoomCaptureSession.isSupported` returns true

## 📝 Notes

- Development can happen on Windows (edit TypeScript files)
- Building requires Mac with Xcode
- RoomPlan requires physical iOS device (not simulator)
- Server works with both native Swift and React Native versions
