# Test Phone Client

A Node.js test client that simulates the iOS phone behavior for testing the room scan system without needing a Mac or iOS device.

## Setup

```bash
cd test-phone-client
npm install
```

## Usage

1. Start the server and worker (see main README)
2. Create a new session in the web UI to get a token
3. Run the test client:

```bash
node index.js <laptopIP> <token>
```

Example:
```bash
node index.js 192.168.1.10 abc123def4567890123456789012345678901234567890123456789012345678
```

## What It Does

- Connects to WebSocket server
- Sends hello message with phone role
- Responds to start/stop control messages
- Simulates preview frames (sends dummy binary data)
- Creates and uploads test chunks every 3 seconds
- Sends status updates
- Sends ready_to_finalize when stopped

## Test Chunks

The client creates dummy test chunks with:
- 5 frames per chunk
- Dummy RGB JPEG files
- Dummy depth PNG files
- Valid metadata JSON files
- index.json with frame list

**Note:** These are dummy files and won't produce a real mesh, but they allow you to test the full pipeline including chunk upload, worker integration, and mesh finalization flow.
