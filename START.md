# How to Start the Server and UI

## Quick Start (Development Mode)

### Option 1: Two Terminal Windows (Recommended)

**Terminal 1 - Start the UI Dev Server:**
```bash
cd server/UI
npm install  # Only needed first time
npm run dev
```
This starts Vite dev server on `http://localhost:5173`

**Terminal 2 - Start the Node.js Server:**
```bash
cd server
npm install  # Only needed first time
NODE_ENV=development npm start
```
This starts the Express server on `http://localhost:8080` and proxies to the Vite dev server.

**Open in Browser:**
- Go to `http://localhost:8080`
- The UI will be served through the Node.js server

### Option 2: Production Mode (Built UI)

**Step 1 - Build the UI:**
```bash
cd server/UI
npm install  # Only needed first time
npm run build
```

**Step 2 - Start the Server:**
```bash
cd server
npm install  # Only needed first time
npm start
```

**Open in Browser:**
- Go to `http://localhost:8080`

## First Time Setup

If you haven't installed dependencies yet:

```bash
# Install server dependencies
cd server
npm install

# Install UI dependencies
cd ../UI
npm install
```

## Troubleshooting

- **Port 8080 already in use?** Change `PORT` in `server/server.js`
- **Port 5173 already in use?** Vite will automatically use the next available port
- **UI not loading?** Make sure both servers are running (check both terminals)
- **WebSocket errors?** Ensure the Node.js server is running on port 8080

## What You'll See

1. The main page at `http://localhost:8080` shows the operator console
2. You can create a new scan session to get a token
3. Connect your iOS device using the token
4. The 3D mesh viewer will appear when scanning starts
