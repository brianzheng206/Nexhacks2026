# room-scan-tsdf

Monorepo for room scanning with TSDF fusion.

## Structure

- `/laptop/server` - Node.js Express + WebSocket + file storage + API
- `/laptop/web` - React web UI operator console
- `/worker` - Python FastAPI service doing TSDF fusion with Open3D
- `/ios` - Native Swift iOS app (ARKit RGB+depth+pose capture + preview stream + chunk upload)

## Setup and Run (Windows)

### Prerequisites

- Node.js and npm installed
- Python 3.8+ installed
- iOS development environment (Xcode) for iOS app

### Network Setup

#### Find Your Laptop IP Address

1. Open Command Prompt or PowerShell
2. Run: `ipconfig`
3. Look for your active network adapter (usually "Wireless LAN adapter Wi-Fi" or "Ethernet adapter")
4. Find the "IPv4 Address" - this is your laptop IP (e.g., `192.168.1.10`)

#### Recommended Network Configuration

**Option 1: Laptop Mobile Hotspot (Recommended)**
1. On Windows: Settings → Network & Internet → Mobile hotspot
2. Turn on "Mobile hotspot"
3. Note the network name and password
4. Connect your iPhone to this hotspot
5. Use the laptop's hotspot IP address (usually `192.168.137.1` or check with `ipconfig`)

**Option 2: Same Wi-Fi Network**
1. Ensure both laptop and iPhone are on the same Wi-Fi network
2. Use the laptop's IP address from `ipconfig`

#### Windows Firewall Configuration

You need to allow inbound connections on the server ports:

1. Open Windows Defender Firewall (search "Firewall" in Start menu)
2. Click "Advanced settings"
3. Click "Inbound Rules" → "New Rule"
4. Select "Port" → Next
5. Select "TCP" and enter port `8080` → Next
6. Select "Allow the connection" → Next
7. Check all profiles (Domain, Private, Public) → Next
8. Name it "Room Scan Server" → Finish

**For React Development (if using Vite on port 5173):**
- Repeat steps 3-8 for port `5173` (or your dev server port)

### 1. Start Python Worker

```bash
cd worker
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8090
```

**Note:** The worker must be running before starting the Node server, as the server checks worker health on startup.

### 2. Start Node Server

```bash
cd laptop\server
npm install
npm start
```

### 3. Start React Web UI

```bash
cd laptop\web
npm install
npm start
```

### 4. Open UI in Browser

The React app should automatically open in your browser, typically at `http://localhost:3000`

### 5. Run iOS App on Device (or Test Client)

**Option A: iOS App (requires Mac/Xcode)**
1. Open the iOS project in Xcode
2. Connect your iOS device
3. Configure the app to connect using your laptop's IP address and token
4. Build and run on device

**Option B: Test Phone Client (no Mac required)**
1. Install dependencies:
   ```bash
   cd test-phone-client
   npm install
   ```
2. Get a token from the web UI (click "Create New Session")
3. Run the test client:
   ```bash
   node index.js <laptopIP> <token>
   ```
   Example:
   ```bash
   node index.js 192.168.1.10 abc123def4567890123456789012345678901234567890123456789012345678
   ```

The test client simulates phone behavior:
- Connects via WebSocket
- Responds to start/stop controls
- Sends preview frames
- Uploads test chunks
- Sends status updates

**Note:** Test chunks contain dummy data and won't produce a real mesh, but allow you to test the full pipeline.

## Development

Each service runs independently:
- Worker: `http://localhost:8090`
- Server: `http://localhost:8080`
- Web UI: Typically `http://localhost:3000` (CRA) or `http://localhost:5173` (Vite)

## Debugging

### Debug Endpoint

Check session status:
```
GET http://localhost:8080/debug/session?token=<your-token>
```

Returns:
- `uiClients`: Number of UI WebSocket connections
- `phoneConnected`: Whether phone is connected
- `chunksReceived`: Number of chunks received
- `meshExists`: Whether mesh file exists
- `meshSize`: Size of mesh file in bytes

## Troubleshooting

### iOS App Issues

**"Depth sensing not available" error:**
- ARKit depth requires iPhone with LiDAR (iPhone 12 Pro and later) or newer models
- Some features may work without depth, but mesh quality will be reduced

**Chunks not uploading:**
- Check network connection
- Verify laptop IP address is correct
- Ensure Windows Firewall allows port 8080
- Check server logs for rate limiting messages (max 10 chunks/minute)

**Reset Session:**
- Use "Reset Session" button in iOS app to clear all local data
- This wipes cached chunks and resets the session state
