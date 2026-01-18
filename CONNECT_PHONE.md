# How to Connect Your iOS Phone

## Quick Steps

### 1. Find Your Laptop IP Address

**On Windows:**
```bash
ipconfig
```
Look for "IPv4 Address" under your active network adapter (usually Wi-Fi or Ethernet).

**On Linux/Mac:**
```bash
ifconfig
# or
ip addr
```
Look for your network interface (usually `wlan0` or `eth0`) and find the `inet` address.

**Example:** `192.168.1.10` or `192.168.137.1` (if using mobile hotspot)

### 2. Start All Services

Make sure all services are running:
- ✅ Python Worker (port 8090)
- ✅ Node Server (port 8080)  
- ✅ React Web UI (port 3000)

### 3. Get a Token

1. Open the web UI: `http://localhost:3000`
2. Click **"Create New Session"**
3. Copy the token that appears (64-character hex string)

### 4. Build and Run iOS App

**Requirements:**
- Mac with Xcode installed
- iPhone with iOS 17+ (iPhone 12 Pro or later for depth sensing)
- USB cable to connect iPhone

**Steps:**
1. Open Xcode
2. Open project: `phone-mesh/ios/RoomSensor.xcodeproj`
3. Connect your iPhone via USB
4. Select your iPhone as the build target (top toolbar)
5. Click **Run** (▶️ button) or press `Cmd+R`
6. Wait for app to install and launch on your phone

### 5. Connect in iOS App

1. In the iOS app, you'll see the **Pairing** screen
2. Enter your **laptop IP address** (from step 1)
3. Enter the **token** (from step 3)
4. Click **"Connect"**
5. You should see "Connected" status

### 6. Start Scanning

1. In the web UI, click **"Start"**
2. The iOS app will automatically begin:
   - Capturing ARKit frames
   - Streaming preview to web UI
   - Recording keyframes
   - Uploading chunks every 3 seconds

### 7. View Results

- **Live Preview:** See real-time camera feed in web UI
- **Status Panel:** See frames captured, chunks uploaded
- **Mesh Viewer:** After clicking "Finalize", see the 3D mesh

## Network Setup Tips

### Option 1: Mobile Hotspot (Recommended)
1. Turn on mobile hotspot on your laptop
2. Connect iPhone to the hotspot
3. Use the hotspot IP (usually `192.168.137.1`)

### Option 2: Same Wi-Fi Network
1. Connect both laptop and iPhone to same Wi-Fi
2. Use laptop's Wi-Fi IP address

### Firewall Configuration

**Windows:**
- Allow port 8080 in Windows Firewall (see README.md)

**Linux:**
```bash
sudo ufw allow 8080
```

## Troubleshooting

**"Can't connect to server":**
- Check laptop IP is correct
- Ensure server is running on port 8080
- Check firewall settings
- Make sure phone and laptop are on same network

**"Depth sensing not available":**
- Requires iPhone 12 Pro or later
- Some features work without depth, but mesh quality reduced

**Preview not showing:**
- Check browser console for errors
- Verify WebSocket connection is established
- Try refreshing the web UI

**Chunks not uploading:**
- Check network connection
- Verify rate limit (max 10 chunks/minute)
- Check server logs for errors
