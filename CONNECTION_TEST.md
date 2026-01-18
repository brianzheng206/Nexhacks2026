# Connection Testing Guide

## How to Verify iOS App Connects to Server

### 1. Start the Server

```bash
cd server
npm start
```

You should see:
```
[Server] RoomScan Remote server running on http://localhost:8080
[Server] WebSocket server ready on ws://localhost:8080
```

### 2. Get a Session Token

Open in browser: `http://localhost:8080`

Click "Start Scanning" - this creates a new session and shows you:
- **Token**: The session token (e.g., `abc123xyz`)
- **IP Address**: Your laptop's IP (e.g., `192.168.1.100`)

### 3. Check Server Logs

When the iOS app connects, you should see in the server logs:

```
[WebSocket] New client connecting...
[WebSocket] Hello from phone: token="abc123xyz" (length=20)
[Session] Phone connected: abc123xyz
[Relay] Sent to 1 UI client(s) in session abc123xyz: status
```

### 4. Debug Endpoint

Check active sessions:
```bash
curl http://localhost:8080/debug/sessions
```

Expected output when connected:
```json
{
  "timestamp": "...",
  "totalSessions": 1,
  "sessions": [
    {
      "token": "abc123xyz",
      "tokenTruncated": "abc123xy...",
      "phoneConnected": true,
      "phoneReadyState": 1,
      "uiClientsCount": 1,
      "hasUsdzFile": false
    }
  ]
}
```

### 5. iOS App Connection Steps

1. Open the iOS app
2. Enter the **exact same token** from the website
3. Enter the **IP address** shown on the website
4. Tap "Connect"

### 6. Verify Connection on iOS

**Success indicators:**
- Status shows "Connected" (green)
- No error messages
- Can tap "Start Scan" button

**Failure indicators:**
- Status shows "Disconnected" (red)
- Error message appears
- "Connect" button remains disabled

### 7. Common Issues

#### Issue: "Connection timeout"
- **Cause**: Server not running, wrong IP, or firewall blocking
- **Fix**: 
  - Verify server is running: `curl http://localhost:8080/health`
  - Check IP address matches server's IP
  - Ensure both devices on same network
  - Check firewall allows port 8080

#### Issue: "Cannot connect to server"
- **Cause**: Wrong IP address or server unreachable
- **Fix**: 
  - Get correct IP: Check server logs or use `ip addr` on Linux
  - For USB-C, use the Mac's USB network IP (not `localhost`)
  - Verify server is listening on `0.0.0.0:8080` (not just `127.0.0.1`)

#### Issue: "Device not showing as connected" on website
- **Cause**: Token mismatch or connection not established
- **Fix**:
  - Verify tokens match exactly (no extra spaces)
  - Check server logs for connection errors
  - Use `/debug/sessions` endpoint to see connection state
  - Try disconnecting and reconnecting

#### Issue: Messages not being relayed
- **Cause**: Connection established but messages not reaching UI
- **Fix**:
  - Check server logs for `[Relay]` messages
  - Verify UI is connected (check `/debug/sessions`)
  - Ensure message types match: `room_update`, `mesh_update`, `instruction`, `status`

### 8. Testing the Full Flow

1. **Server running** ✓
2. **Website open with token** ✓
3. **iOS app connected** ✓
4. **Click "Start Scan" on website** → Should trigger scan on iOS
5. **Start scanning on iOS** → Should see mesh updates on website
6. **Stop scanning** → Should see export ready message

### 9. Network Debugging

**Check if server is accessible from iOS device:**
```bash
# On iOS device (via SSH or terminal app), test:
curl http://<laptop-ip>:8080/health
```

**Check WebSocket connection:**
```bash
# Use wscat or similar tool
wscat -c ws://<laptop-ip>:8080
# Then send: {"type":"hello","role":"phone","token":"test123"}
```

### 10. Server Logging

The server logs all important events:
- `[WebSocket] New client connecting...` - New connection attempt
- `[WebSocket] Hello from phone: token="..."` - Phone authenticated
- `[Session] Phone connected: ...` - Phone registered in session
- `[Relay] Phone -> UI (...)` - Message relayed to UI
- `[Session] Phone disconnected: ...` - Phone disconnected

Watch these logs to diagnose connection issues.
