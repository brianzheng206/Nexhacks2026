# RoomScan Remote

A Week-1 MVP project that enables remote room scanning using Apple's RoomPlan framework. The iOS app scans rooms and streams the results to a Node.js server, which serves a web UI for viewing and downloading scans.

## Project Structure

```
room-reconstruction/
├── server/          # Node.js server + web UI
│   ├── server.js    # Express + WebSocket server
│   ├── public/      # Static web UI
│   └── uploads/     # Uploaded USDZ files (created automatically)
└── ios/             # Swift iOS app (to be implemented)
```

## Server Setup

### Prerequisites

- Node.js (v14 or higher)
- npm

### Installation

1. Navigate to the server directory:
```bash
cd server
```

2. Install dependencies:
```bash
npm install
```

### Running the Server

Start the server:
```bash
npm start
```

The server will start on `http://localhost:8080`

### Server Endpoints

- `GET /` - Main web UI
- `GET /new` - Generate new scan session (returns JSON with token, url, qrDataUrl)
- `GET /new.html?token=...&url=...&qr=...` - Session page with QR code
- `POST /upload/usdz` - Upload USDZ file (multipart/form-data, requires `token` and `file`)
- `GET /download/:token/room.usdz` - Download uploaded USDZ file
- `GET /health` - Health check endpoint

### WebSocket

The server also runs a WebSocket server on the same port. Clients connected via WebSocket will receive notifications when files are uploaded:
```json
{
  "type": "upload",
  "token": "session_token",
  "message": "Room scan uploaded successfully",
  "timestamp": "2024-01-01T00:00:00.000Z"
}
```

## Usage

1. Start the server: `cd server && npm start`
2. Open `http://localhost:8080` in your browser
3. Click "Create New Scan Session" to generate a token and QR code
4. Use the iOS app to scan the QR code and upload room scans
5. The web UI will automatically notify you when a scan is uploaded
6. Download the USDZ file using the download link

## iOS App (To Be Implemented)

The iOS app will:
- Use RoomPlan framework to scan rooms
- Connect to the server using the session token
- Upload USDZ files to `/upload/usdz` endpoint
- Stream scan progress to the server

## Development

The server is designed to work independently without the iOS app. You can test the upload endpoint using curl:

```bash
curl -X POST http://localhost:8080/upload/usdz \
  -F "token=YOUR_TOKEN" \
  -F "file=@path/to/room.usdz"
```

## License

ISC
