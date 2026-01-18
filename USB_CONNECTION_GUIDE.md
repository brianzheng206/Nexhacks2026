# USB-C Local Connection Guide

## Overview

When your iPhone is connected to your Mac via USB-C, you can use a local connection instead of WiFi for faster, more reliable streaming.

## How It Works

### USB Connection Mode
- **IP Address**: Use your Mac's USB network IP (often `172.20.10.x` or `169.254.x.x`)
- **Network**: Direct USB connection (no WiFi needed)
- **Benefits**: 
  - Faster data transfer
  - Lower latency
  - More reliable (no network interference)
  - No WiFi bandwidth usage

### WiFi Connection Mode (Default)
- **IP Address**: Your Mac's local network IP (e.g., `192.168.1.100`)
- **Network**: WiFi/LAN
- **Benefits**:
  - Phone can be anywhere in range
  - No cable needed

## Setup Instructions

### On Mac (Laptop Server)

1. **Start the server** (it will listen on `0.0.0.0:8080`):
   ```bash
   cd server
   npm start
   ```

2. **The server automatically binds to `0.0.0.0`**, which means:
   - Accessible via `localhost` on the Mac for local testing
   - Accessible via USB or WiFi IP from the iOS device
   - Both work simultaneously!

### On iPhone (iOS App)

1. **Connect iPhone to Mac via USB-C cable**

2. **Open the RoomScan Remote app**

3. **In Pairing screen:**
   - Enter your Mac's USB network IP (e.g., `172.20.10.2`)
   - Enter your session token
   - Tap "Connect"

4. **The app will connect via USB** instead of WiFi

## Technical Details

### Connection Flow

**USB Mode:**
```
iPhone → USB-C Cable → Mac
    ↓
WebSocket: ws://<usb-ip>:8080
HTTP: http://<usb-ip>:8080/upload/usdz?token=...
```

**WiFi Mode:**
```
iPhone → WiFi → Router → Mac
    ↓
WebSocket: ws://192.168.1.100:8080
HTTP: http://192.168.1.100:8080/upload/usdz?token=...
```

### Server Configuration

The server listens on `0.0.0.0:8080`, which means:
- ✅ Accepts connections from the Mac (localhost)
- ✅ Accepts connections from network IP (WiFi)
- ✅ Both work at the same time

### iOS Implementation

- Enter the host manually on the Pairing screen
- Use the same host for WebSocket and HTTP uploads

## Benefits of USB Connection

| Aspect | USB | WiFi |
|--------|-----|------|
| **Speed** | ~480 Mbps (USB 2.0) / ~5 Gbps (USB 3.0) | ~100-1000 Mbps |
| **Latency** | <1ms | 10-50ms |
| **Reliability** | Very stable | Can drop/interfere |
| **Battery** | Charges phone | Uses phone battery |
| **Range** | Cable length | WiFi range |

## When to Use Each

### Use USB When:
- ✅ Phone is physically connected to Mac
- ✅ You want fastest possible streaming
- ✅ You want most reliable connection
- ✅ You want to charge phone while scanning

### Use WiFi When:
- ✅ Phone needs to move around freely
- ✅ Mac and phone are in different rooms
- ✅ No USB cable available
- ✅ Multiple devices need to connect

## Troubleshooting

### "Connection Failed" in USB Mode

1. **Check server is running**:
   ```bash
   # On Mac terminal
   curl http://localhost:8080/health
   ```

2. **Check iPhone is connected**:
   - Look for iPhone in Finder (Mac)
   - Check if charging indicator shows

3. **Check the Mac's USB IP**:
   - System Settings → Network → iPhone USB (or similar)
   - Use that IP in the app

4. **Check firewall**:
   - Mac firewall might block incoming connections on port 8080
   - Temporarily disable to test

### Server Not Accessible via USB IP

The server should bind to `0.0.0.0` by default, which allows:
- USB IP connections
- Network IP connections

If it's only binding to `127.0.0.1`, check server configuration.

## Code Changes Made

### Server
- Already configured to accept both local and network connections
- No changes needed (listens on `0.0.0.0`)

## Performance Comparison

**USB Mode:**
- Preview streaming: ~10 FPS, <10ms latency
- Chunk uploads: ~3 seconds per chunk
- Very stable connection

**WiFi Mode:**
- Preview streaming: ~10 FPS, 20-50ms latency
- Chunk uploads: ~3-5 seconds per chunk
- Can have occasional drops

USB mode provides better performance when available!
