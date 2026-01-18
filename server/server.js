const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const QRCode = require('qrcode');
const os = require('os');
const dgram = require('dgram');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = 8080;
const UPLOADS_DIR = path.join(__dirname, 'uploads');

// Ensure uploads directory exists
if (!fs.existsSync(UPLOADS_DIR)) {
  fs.mkdirSync(UPLOADS_DIR, { recursive: true });
}

// Middleware
app.use(express.json());

// Serve static files from the UI build directory
const UI_DIST_PATH = path.join(__dirname, 'UI', 'dist');

if (process.env.NODE_ENV === 'development') {
  // In development, proxy to Vite dev server
  const { createProxyMiddleware } = require('http-proxy-middleware');
  app.use('/', createProxyMiddleware({
    target: 'http://localhost:5173',
    changeOrigin: true,
    ws: true, // Enable WebSocket proxying for HMR
  }));
} else {
  // In production, serve the built UI
  app.use(express.static(UI_DIST_PATH));
  
  // Serve index.html for all non-API routes (SPA routing)
  app.get('*', (req, res, next) => {
    // Skip API routes
    if (req.path.startsWith('/new') || 
        req.path.startsWith('/upload') || 
        req.path.startsWith('/download') || 
        req.path.startsWith('/health') ||
        req.path.startsWith('/mesh') ||
        req.path.startsWith('/pair') ||
        req.path.startsWith('/debug')) {
      return next();
    }
    
    const indexPath = path.join(UI_DIST_PATH, 'index.html');
    if (fs.existsSync(indexPath)) {
      res.sendFile(indexPath);
    } else {
      res.status(404).send('UI not built. Run: cd UI && npm run build');
    }
  });
}

// Sessions Map: token -> { phoneWs, uiWsSet, latestUsdzPath }
const sessions = new Map();

// Helper: Get or create session
function getOrCreateSession(token) {
  if (!sessions.has(token)) {
    sessions.set(token, {
      phoneWs: null,
      uiWsSet: new Set(),
      latestUsdzPath: null
    });
    console.log(`[Session] Created new session: ${token}`);
  }
  return sessions.get(token);
}

// Helper: Clean up empty session
function cleanupSession(token) {
  const session = sessions.get(token);
  if (session && !session.phoneWs && session.uiWsSet.size === 0) {
    sessions.delete(token);
    console.log(`[Session] Cleaned up empty session: ${token}`);
  }
}

// Helper: Send message to all UI clients in a session
function sendToUI(token, data) {
  const session = sessions.get(token);
  if (!session) {
    console.warn(`[Session] Attempted to send to UI for non-existent session: ${token}`);
    return;
  }

  const message = JSON.stringify(data);
  let sentCount = 0;
  session.uiWsSet.forEach((ws) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(message);
      sentCount++;
    }
  });
  if (sentCount > 0) {
    console.log(`[Relay] Sent to ${sentCount} UI client(s) in session ${token}: ${data.type}`);
  }
}

// Helper: Send message to phone client in a session
function sendToPhone(token, data) {
  const session = sessions.get(token);
  if (!session || !session.phoneWs) {
    console.warn(`[Session] Attempted to send to phone for session without phone: ${token}`);
    return;
  }

  if (session.phoneWs.readyState === WebSocket.OPEN) {
    const message = JSON.stringify(data);
    session.phoneWs.send(message);
    console.log(`[Relay] Sent to phone in session ${token}: ${data.type || data.action}`);
  }
}

// Keepalive ping/pong setup
const KEEPALIVE_INTERVAL = 20000; // 20 seconds
setInterval(() => {
  sessions.forEach((session, token) => {
    // Ping phone connection
    if (session.phoneWs && session.phoneWs.readyState === WebSocket.OPEN) {
      session.phoneWs.ping();
    }
    // Ping UI connections
    session.uiWsSet.forEach((uiWs) => {
      if (uiWs.readyState === WebSocket.OPEN) {
        uiWs.ping();
      }
    });
  });
}, KEEPALIVE_INTERVAL);

// WebSocket connection handling
wss.on('connection', (ws, req) => {
  let token = null;
  let role = null;
  let session = null;

  const clientIP = req.socket.remoteAddress || 'unknown';
  console.log(`[WebSocket] New client connecting from ${clientIP}...`);
  
  // Handle pong responses
  ws.on('pong', () => {
    // Client responded to ping, connection is alive
  });

  // Handle incoming messages
  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      // Binary JPEG frame from phone - relay to all UI clients
      if (role === 'phone' && token && session) {
        let sentCount = 0;
        session.uiWsSet.forEach((uiWs) => {
          if (uiWs.readyState === WebSocket.OPEN) {
            uiWs.send(data);
            sentCount++;
          }
        });
        if (sentCount > 0) {
          console.log(`[Relay] Forwarded JPEG frame to ${sentCount} UI client(s) in session ${token}`);
        }
      } else {
        console.warn(`[WebSocket] Received binary data from unauthenticated client or non-phone role`);
      }
    } else {
      // Text message - handle protocol messages
      try {
        const message = JSON.parse(data.toString());

        // Handle hello handshake
        if (message.type === 'hello') {
          // Validation
          if (!message.token || typeof message.token !== 'string') {
            console.error('[WebSocket] Invalid hello: missing or invalid token');
            ws.close(1008, 'Invalid token');
            return;
          }

          if (!message.role || (message.role !== 'phone' && message.role !== 'ui')) {
            console.error('[WebSocket] Invalid hello: invalid role', message.role);
            ws.close(1008, 'Invalid role');
            return;
          }

          // Trim whitespace from token to handle copy-paste issues
          token = message.token.trim();
          role = message.role;
          session = getOrCreateSession(token);
          
          console.log(`[WebSocket] Hello from ${role}: token="${token}" (length: ${token.length})`);

          if (role === 'phone') {
            // Only one phone connection per session
            if (session.phoneWs && session.phoneWs.readyState === WebSocket.OPEN) {
              console.warn(`[Session] Phone already connected for ${token}, closing old connection`);
              session.phoneWs.close(1000, 'New phone connection');
            }
            session.phoneWs = ws;
            console.log(`[Session] Phone connected: ${token}`);
            // Notify UI clients that phone connected
            sendToUI(token, { type: 'status', value: 'phone_connected', timestamp: new Date().toISOString() });
          } else if (role === 'ui') {
            session.uiWsSet.add(ws);
            console.log(`[Session] UI client connected: ${token} (${session.uiWsSet.size} UI client(s))`);
          }

          // Send confirmation
          ws.send(JSON.stringify({ type: 'hello_ack', token, role }));
        } else if (!token || !role) {
          // Reject messages from unauthenticated clients
          console.warn('[WebSocket] Message from unauthenticated client');
          ws.close(1008, 'Not authenticated');
          return;
        } else if (role === 'phone') {
          // Messages from phone to UI
          const allowedTypes = ['room_update', 'instruction', 'status', 'mesh_update'];
          if (allowedTypes.includes(message.type)) {
            console.log(`[Relay] Phone -> UI (${message.type}) in session ${token}`);
            sendToUI(token, message);
          } else {
            console.warn(`[WebSocket] Unknown message type from phone: ${message.type}`);
          }
        } else if (role === 'ui') {
          // Messages from UI to phone
          if (message.type === 'control' && (message.action === 'start' || message.action === 'stop')) {
            console.log(`[Relay] UI -> Phone (control: ${message.action}) in session ${token}`);
            sendToPhone(token, { type: 'control', action: message.action });
          } else {
            console.warn(`[WebSocket] Unknown message type from UI: ${message.type}`);
          }
        }
      } catch (error) {
        console.error('[WebSocket] Error parsing message:', error);
      }
    }
  });

  // Handle connection close
  ws.on('close', (code, reason) => {
    const reasonStr = reason ? reason.toString() : 'no reason';
    if (token && role && session) {
      if (role === 'phone') {
        session.phoneWs = null;
        console.log(`[Session] Phone disconnected: ${token} from ${clientIP} (code: ${code}, reason: ${reasonStr})`);
        // Notify UI clients that phone disconnected
        sendToUI(token, { type: 'status', value: 'phone_disconnected', timestamp: new Date().toISOString() });
      } else if (role === 'ui') {
        session.uiWsSet.delete(ws);
        console.log(`[Session] UI client disconnected: ${token} from ${clientIP} (${session.uiWsSet.size} UI client(s) remaining, code: ${code})`);
      }
      cleanupSession(token);
    } else {
      console.log(`[WebSocket] Unauthenticated client disconnected from ${clientIP} (code: ${code}, reason: ${reasonStr})`);
    }
  });

  // Handle errors
  ws.on('error', (error) => {
    console.error(`[WebSocket] Error from ${clientIP} (role: ${role || 'unknown'}, token: ${token || 'none'}):`, error.message || error);
  });
});

// Generate session token
function generateToken() {
  return Math.random().toString(36).substring(2, 15) + 
         Math.random().toString(36).substring(2, 15);
}

// Configure multer for file uploads
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const token = req.query.token;
    if (!token) {
      return cb(new Error('Token is required'));
    }
    const tokenDir = path.join(UPLOADS_DIR, token);
    if (!fs.existsSync(tokenDir)) {
      fs.mkdirSync(tokenDir, { recursive: true });
    }
    cb(null, tokenDir);
  },
  filename: (req, file, cb) => {
    cb(null, 'room.usdz');
  }
});

const upload = multer({ 
  storage: storage,
  limits: { fileSize: 100 * 1024 * 1024 } // 100MB limit
});

// HTTP Routes

// Helper: Get all local IPv4 addresses
function getAllLocalIPs() {
  const interfaces = os.networkInterfaces();
  const ips = [];
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        ips.push(iface.address);
      }
    }
  }
  return ips;
}

// Helper: Get local IP address (best effort)
function getLocalIP() {
  const ips = getAllLocalIPs();
  return ips[0] || 'localhost';
}

function getRequestHost(req) {
  const host = (req.hostname || '').trim();
  if (!host || host === 'localhost' || host === '127.0.0.1') {
    return null;
  }
  return host;
}

function getDefaultRouteIP(timeoutMs = 200) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket('udp4');
    let settled = false;

    const finish = (ip) => {
      if (settled) return;
      settled = true;
      try {
        socket.close();
      } catch {}
      resolve(ip || null);
    };

    const timer = setTimeout(() => finish(null), timeoutMs);

    socket.on('error', () => {
      clearTimeout(timer);
      finish(null);
    });

    socket.connect(80, '8.8.8.8', () => {
      clearTimeout(timer);
      const address = socket.address();
      finish(address && address.address ? address.address : null);
    });
  });
}

// GET /new - Generate new session token
app.get('/new', async (req, res) => {
  try {
    const requestedToken = typeof req.query.token === 'string' ? req.query.token.trim() : '';
    const token = requestedToken || generateToken();
    const requestHost = getRequestHost(req);
    const routeIP = await getDefaultRouteIP();
    const localIP = requestHost || routeIP || getLocalIP();
    const availableIPs = Array.from(new Set(getAllLocalIPs()));
    const url = `http://${localIP}:${PORT}/download/${token}/room.usdz`;
    
    // Create pairing URL with token and host
    const pairingUrl = `roomscan://pair?token=${token}&host=${localIP}&port=${PORT}`;
    
    // Generate QR code as data URL (use pairing URL for easier parsing)
    const qrDataUrl = await QRCode.toDataURL(pairingUrl, {
      width: 300,
      margin: 2
    });

    console.log(`[HTTP] Generated new session: ${token} (IP: ${localIP})`);

    res.json({
      token,
      url,
      qrDataUrl,
      laptopIP: localIP,
      availableIPs,
      pairingUrl: pairingUrl
    });
  } catch (error) {
    console.error('[HTTP] Error generating session:', error);
    res.status(500).json({ error: 'Failed to generate session' });
  }
});

// POST /upload/usdz?token=... - Upload USDZ file
app.post('/upload/usdz', upload.single('file'), (req, res) => {
  try {
    const token = req.query.token;
    
    // Validation
    if (!token) {
      console.warn('[HTTP] Upload attempted without token');
      return res.status(400).json({ error: 'Token is required in query parameter' });
    }

    if (!req.file) {
      console.warn(`[HTTP] Upload attempted without file for token: ${token}`);
      return res.status(400).json({ error: 'No file uploaded' });
    }

    // Ensure uploads directory exists (redundant check for safety)
    const tokenDir = path.join(UPLOADS_DIR, token);
    if (!fs.existsSync(tokenDir)) {
      fs.mkdirSync(tokenDir, { recursive: true });
    }

    const filePath = req.file.path;
    const session = getOrCreateSession(token);
    session.latestUsdzPath = filePath;

    console.log(`[HTTP] File uploaded for token: ${token} (${req.file.size} bytes)`);
    
    const downloadUrl = `http://localhost:${PORT}/download/${token}/room.usdz`;
    
    // Notify UI clients
    sendToUI(token, {
      type: 'export_ready',
      downloadUrl: downloadUrl,
      token: token,
      timestamp: new Date().toISOString()
    });

    res.json({
      success: true,
      token: token,
      message: 'File uploaded successfully'
    });
  } catch (error) {
    console.error('[HTTP] Upload error:', error);
    res.status(500).json({ error: 'Upload failed', details: error.message });
  }
});

// GET /download/:token/room.usdz - Download USDZ file
app.get('/download/:token/room.usdz', (req, res) => {
  const token = req.params.token;
  const filePath = path.join(UPLOADS_DIR, token, 'room.usdz');

  // Validation
  if (!token || typeof token !== 'string') {
    return res.status(400).json({ error: 'Invalid token' });
  }

  if (!fs.existsSync(filePath)) {
    console.warn(`[HTTP] Download attempted for non-existent file: ${token}`);
    return res.status(404).json({ error: 'File not found' });
  }

  console.log(`[HTTP] Downloading file for token: ${token}`);
  res.download(filePath, 'room.usdz', (err) => {
    if (err) {
      console.error('[HTTP] Download error:', err);
      if (!res.headersSent) {
        res.status(500).json({ error: 'Download failed' });
      }
    }
  });
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'ok', 
    timestamp: new Date().toISOString(),
    activeSessions: sessions.size
  });
});

// Debug endpoint - shows all active sessions (remove in production)
app.get('/debug/sessions', (req, res) => {
  const sessionList = [];
  sessions.forEach((session, token) => {
    sessionList.push({
      token: token,
      tokenTruncated: token.substring(0, 8) + '...',
      phoneConnected: session.phoneWs !== null && session.phoneWs.readyState === 1,
      phoneReadyState: session.phoneWs?.readyState ?? 'null',
      uiClientsCount: session.uiWsSet.size,
      hasUsdzFile: session.latestUsdzPath !== null
    });
  });
  
  console.log('[Debug] Current sessions:', JSON.stringify(sessionList, null, 2));
  
  res.json({
    timestamp: new Date().toISOString(),
    totalSessions: sessions.size,
    sessions: sessionList
  });
});

// Start server
server.listen(PORT, () => {
  console.log(`[Server] RoomScan Remote server running on http://localhost:${PORT}`);
  console.log(`[Server] WebSocket server ready on ws://localhost:${PORT}`);
});
