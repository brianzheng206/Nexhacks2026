// Express + WebSocket + file storage + API server
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const unzipper = require('unzipper');
const fetch = require('node-fetch');
const { URL } = require('url');
const crypto = require('crypto');

const app = express();
const server = http.createServer(app);

const PORT = process.env.PORT || 8080;
const WORKER_URL = process.env.WORKER_URL || 'http://localhost:8090';
const DATA_DIR = path.join(__dirname, 'data');

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

// Worker health check
let workerHealthy = false;

async function checkWorkerHealth() {
  try {
    const response = await fetch(`${WORKER_URL}/health`);
    if (response.ok) {
      workerHealthy = true;
      console.log(`[SERVER] Worker is healthy at ${WORKER_URL}`);
    } else {
      workerHealthy = false;
      console.warn(`[SERVER] Worker health check failed: ${response.status}`);
    }
  } catch (error) {
    workerHealthy = false;
    console.warn(`[SERVER] Worker health check failed: ${error.message}`);
  }
}

// Check worker health on startup
checkWorkerHealth().then(() => {
  // Periodic health check every 30 seconds
  setInterval(checkWorkerHealth, 30000);
});

// Helper: Call worker endpoint
async function callWorker(endpoint, body) {
  try {
    const response = await fetch(`${WORKER_URL}${endpoint}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    
    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Worker returned ${response.status}: ${errorText}`);
    }
    
    return await response.json();
  } catch (error) {
    console.error(`[SERVER] Worker call failed (${endpoint}):`, error.message);
    throw error;
  }
}

// Middleware
app.use(cors({
  origin: process.env.CORS_ORIGIN || '*', // Allow web UI
  credentials: true
}));
app.use(express.json({ limit: '200mb' }));
app.use(express.urlencoded({ extended: true, limit: '200mb' }));

// Helper: Generate secure token
function generateToken() {
  return crypto.randomBytes(32).toString('hex');
}

// Helper: Get host URL for constructing URLs
function getHostUrl(req) {
  const protocol = req.protocol || 'http';
  const host = req.get('host') || `localhost:${PORT}`;
  return `${protocol}://${host}`;
}

// Helper: Ensure directory exists
function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

// Helper: Validate token format
function isValidToken(token) {
  return token && typeof token === 'string' && token.length === 64 && /^[a-f0-9]+$/.test(token);
}

// WebSocket server with token-based routing
const wss = new WebSocket.Server({ 
  server,
  verifyClient: (info) => {
    // Extract token from query string
    const url = new URL(info.req.url, `http://${info.req.headers.host}`);
    const token = url.searchParams.get('token');
    
    if (!token || !isValidToken(token)) {
      console.warn(`[WS] Invalid token in connection attempt: ${token}`);
      return false;
    }
    
    info.req.token = token;
    return true;
  }
});

// Track WebSocket connections by token and role
const connections = new Map(); // token -> { phones: Set<ws>, uis: Set<ws> }

// Rate limiting for chunk uploads per token
const uploadRateLimits = new Map(); // token -> { count: number, resetTime: timestamp }

function getConnections(token) {
  if (!connections.has(token)) {
    connections.set(token, { phones: new Set(), uis: new Set() });
  }
  return connections.get(token);
}

// Rate limiting: max 10 chunks per minute per token
function checkUploadRateLimit(token) {
  const now = Date.now();
  const limit = uploadRateLimits.get(token);
  
  if (!limit || now > limit.resetTime) {
    uploadRateLimits.set(token, { count: 1, resetTime: now + 60000 }); // 1 minute window
    return true;
  }
  
  if (limit.count >= 10) {
    return false; // Rate limit exceeded
  }
  
  limit.count++;
  return true;
}

wss.on('connection', (ws, req) => {
  const token = req.token;
  console.log(`[WS] Client connected with token: ${token.substring(0, 8)}...`);
  
  let clientRole = null;
  let isAuthenticated = false;
  let keepaliveInterval = null;
  
  // WebSocket keepalive ping every 20 seconds
  keepaliveInterval = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.ping();
    }
  }, 20000);
  
  ws.on('message', async (message) => {
    try {
      // First message must be hello
      if (!isAuthenticated) {
        const hello = JSON.parse(message.toString());
        
        if (hello.type !== 'hello') {
          console.warn(`[WS] Expected hello message, got: ${hello.type}`);
          ws.close(1008, 'Expected hello message');
          return;
        }
        
        if (hello.token !== token) {
          console.warn(`[WS] Token mismatch in hello: expected ${token.substring(0, 8)}..., got ${hello.token?.substring(0, 8)}...`);
          ws.close(1008, 'Token mismatch');
          return;
        }
        
        if (hello.role !== 'phone' && hello.role !== 'ui') {
          console.warn(`[WS] Invalid role: ${hello.role}`);
          ws.close(1008, 'Invalid role');
          return;
        }
        
        clientRole = hello.role;
        const conns = getConnections(token);
        
        if (clientRole === 'phone') {
          conns.phones.add(ws);
          console.log(`[WS] Phone authenticated for token: ${token.substring(0, 8)}...`);
          
          // Notify UI clients that phone connected
          const statusMsg = JSON.stringify({
            type: 'phone_status',
            connected: true,
            token: token
          });
          conns.uis.forEach(uiWs => {
            if (uiWs.readyState === WebSocket.OPEN) {
              uiWs.send(statusMsg);
            }
          });
        } else {
          conns.uis.add(ws);
          console.log(`[WS] UI authenticated for token: ${token.substring(0, 8)}...`);
          
          // Send current phone connection status to new UI client
          const phoneConnected = conns.phones.size > 0;
          const statusMsg = JSON.stringify({
            type: 'phone_status',
            connected: phoneConnected,
            token: token
          });
          ws.send(statusMsg);
        }
        
        isAuthenticated = true;
        ws.send(JSON.stringify({ type: 'hello_ack', role: clientRole, token }));
        return;
      }
      
      // After authentication, handle messages based on role
      if (clientRole === 'phone') {
        const conns = getConnections(token);
        
        // Check if message is binary (JPEG preview frame)
        if (Buffer.isBuffer(message)) {
          // Relay binary frame to all UI clients
          console.log(`[WS] Relaying JPEG frame (${message.length} bytes) to ${conns.uis.size} UI client(s)`);
          conns.uis.forEach(uiWs => {
            if (uiWs.readyState === WebSocket.OPEN) {
              uiWs.send(message, { binary: true });
            }
          });
        } else {
          // JSON message (status/instruction/counters)
          try {
            const data = JSON.parse(message.toString());
            console.log(`[WS] Broadcasting JSON from phone:`, data);
            
            // Broadcast to all UI clients
            const broadcast = JSON.stringify(data);
            conns.uis.forEach(uiWs => {
              if (uiWs.readyState === WebSocket.OPEN) {
                uiWs.send(broadcast);
              }
            });
          } catch (err) {
            console.error(`[WS] Failed to parse JSON from phone:`, err.message);
          }
        }
      } else {
        // UI client messages - forward control messages to phone
        try {
          const data = JSON.parse(message.toString());
          
          if (data.type === 'control' && data.action) {
            const conns = getConnections(token);
            console.log(`[WS] Forwarding control message "${data.action}" from UI to ${conns.phones.size} phone(s)`);
            
            // Forward to all phone clients for this token
            const controlMessage = JSON.stringify(data);
            conns.phones.forEach(phoneWs => {
              if (phoneWs.readyState === WebSocket.OPEN) {
                phoneWs.send(controlMessage);
              }
            });
          } else {
            console.log(`[WS] Received message from UI:`, message.toString().substring(0, 100));
          }
        } catch (err) {
          console.error(`[WS] Failed to parse UI message:`, err.message);
        }
      }
    } catch (err) {
      console.error(`[WS] Error handling message:`, err.message);
    }
  });
  
  ws.on('close', () => {
    // Clear keepalive interval
    if (keepaliveInterval) {
      clearInterval(keepaliveInterval);
      keepaliveInterval = null;
    }
    
    if (isAuthenticated && clientRole) {
      const conns = getConnections(token);
      if (clientRole === 'phone') {
        conns.phones.delete(ws);
        console.log(`[WS] Phone disconnected for token: ${token.substring(0, 8)}...`);
        
        // Notify UI clients that phone disconnected
        const statusMsg = JSON.stringify({
          type: 'phone_status',
          connected: false,
          token: token
        });
        conns.uis.forEach(uiWs => {
          if (uiWs.readyState === WebSocket.OPEN) {
            uiWs.send(statusMsg);
          }
        });
      } else {
        conns.uis.delete(ws);
        console.log(`[WS] UI disconnected for token: ${token.substring(0, 8)}...`);
      }
      
      // Clean up if no connections left
      if (conns.phones.size === 0 && conns.uis.size === 0) {
        connections.delete(token);
      }
    }
  });
  
  ws.on('error', (err) => {
    console.error(`[WS] WebSocket error:`, err.message);
  });
});

// Configure multer for file uploads
const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const token = req.query.token;
    if (!token || !isValidToken(token)) {
      return cb(new Error('Invalid or missing token'));
    }
    const chunkDir = path.join(DATA_DIR, token, 'chunks');
    ensureDir(chunkDir);
    cb(null, chunkDir);
  },
  filename: (req, file, cb) => {
    const chunkId = req.query.chunkId;
    if (!chunkId || typeof chunkId !== 'string') {
      return cb(new Error('Invalid or missing chunkId'));
    }
    // Sanitize chunkId to prevent path traversal
    const safeChunkId = chunkId.replace(/[^a-zA-Z0-9_-]/g, '_');
    cb(null, `${safeChunkId}.zip`);
  }
});

const upload = multer({ 
  storage,
  limits: { fileSize: 200 * 1024 * 1024 } // 200MB limit
});

// API Routes

// GET /new -> returns JSON { token, wsUrl, uploadBaseUrl }
app.get('/new', async (req, res) => {
  try {
    const token = generateToken();
    const hostUrl = getHostUrl(req);
    
    // Create token directory structure
    const tokenDir = path.join(DATA_DIR, token);
    ensureDir(tokenDir);
    ensureDir(path.join(tokenDir, 'chunks'));
    ensureDir(path.join(tokenDir, 'mesh'));
    
    // Initialize worker session
    if (workerHealthy) {
      try {
        await callWorker('/init_session', { token });
        console.log(`[API] Worker session initialized for token: ${token.substring(0, 8)}...`);
      } catch (err) {
        console.warn(`[API] Failed to initialize worker session:`, err.message);
        // Continue anyway - worker might recover
      }
    } else {
      console.warn(`[API] Worker not healthy, skipping session init`);
    }
    
    const response = {
      token,
      wsUrl: `${hostUrl.replace('http://', 'ws://').replace('https://', 'wss://')}/ws?token=${token}`,
      uploadBaseUrl: `${hostUrl}/upload/chunk?token=${token}`
    };
    
    console.log(`[API] Generated new token: ${token.substring(0, 8)}...`);
    res.json(response);
  } catch (err) {
    console.error(`[API] Error in /new:`, err);
    res.status(500).json({ error: 'Failed to generate token' });
  }
});

// POST /upload/chunk?token=...&chunkId=... -> accepts multipart file field "file" (zip)
app.post('/upload/chunk', upload.single('file'), async (req, res) => {
  try {
    const token = req.query.token;
    const chunkId = req.query.chunkId;
    
    // Validation
    if (!token || !isValidToken(token)) {
      return res.status(400).json({ error: 'Invalid or missing token' });
    }
    
    if (!chunkId || typeof chunkId !== 'string') {
      return res.status(400).json({ error: 'Invalid or missing chunkId' });
    }
    
    // Rate limiting check
    if (!checkUploadRateLimit(token)) {
      return res.status(429).json({ error: 'Rate limit exceeded. Maximum 10 chunks per minute.' });
    }
    
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }
    
    const zipPath = req.file.path;
    const safeChunkId = chunkId.replace(/[^a-zA-Z0-9_-]/g, '_');
    const extractPath = path.join(DATA_DIR, token, 'chunks', safeChunkId);
    
    console.log(`[API] Extracting chunk ${safeChunkId} for token ${token.substring(0, 8)}...`);
    
    // Extract zip file
    try {
      ensureDir(extractPath);
      await new Promise((resolve, reject) => {
        fs.createReadStream(zipPath)
          .pipe(unzipper.Extract({ path: extractPath }))
          .on('close', () => {
            console.log(`[API] Extracted chunk ${safeChunkId} to ${extractPath}`);
            resolve();
          })
          .on('error', reject);
      });
    } catch (extractErr) {
      console.error(`[API] Failed to extract chunk:`, extractErr);
      return res.status(500).json({ error: 'Failed to extract chunk', details: extractErr.message });
    }
    
    // Forward to worker - use absolute path for Windows compatibility
    const chunkPath = path.resolve(extractPath).replace(/\\/g, '/'); // Normalize to forward slashes for worker
    if (workerHealthy) {
      try {
        console.log(`[API] Forwarding chunk to worker: ${chunkPath}`);
        await callWorker('/ingest_chunk', { token, chunkPath });
        console.log(`[API] Worker acknowledged chunk ${safeChunkId}`);
      } catch (workerErr) {
        console.error(`[API] Failed to forward to worker:`, workerErr.message);
        // Don't fail the request if worker fails, just log it
      }
    } else {
      console.warn(`[API] Worker not healthy, skipping chunk ingestion`);
    }
    
    res.json({ 
      success: true,
      token,
      chunkId: safeChunkId,
      extractedPath: chunkPath
    });
  } catch (err) {
    console.error(`[API] Error in /upload/chunk:`, err);
    res.status(500).json({ error: 'Failed to process chunk upload', details: err.message });
  }
});

// POST /finalize?token=... -> tells worker to finalize mesh
app.post('/finalize', async (req, res) => {
  try {
    const token = req.query.token;
    
    if (!token || !isValidToken(token)) {
      return res.status(400).json({ error: 'Invalid or missing token' });
    }
    
    console.log(`[API] Finalizing mesh for token: ${token.substring(0, 8)}...`);
    
    // Call worker to finalize
    if (!workerHealthy) {
      return res.status(502).json({ 
        error: 'Worker unavailable',
        details: 'Worker health check failed'
      });
    }
    
    try {
      const workerData = await callWorker('/finalize', { token });
      console.log(`[API] Worker finalized mesh:`, workerData);
      
      // Construct mesh URL
      const hostUrl = getHostUrl(req);
      const meshUrl = `${hostUrl}/mesh?token=${token}`;
      
      res.json({ 
        meshUrl,
        vertices: workerData.vertices,
        triangles: workerData.triangles,
        totalFrames: workerData.total_frames
      });
    } catch (workerErr) {
      console.error(`[API] Failed to contact worker:`, workerErr.message);
      return res.status(502).json({ 
        error: 'Worker failed to finalize mesh',
        details: workerErr.message
      });
    }
  } catch (err) {
    console.error(`[API] Error in /finalize:`, err);
    res.status(500).json({ error: 'Failed to finalize mesh', details: err.message });
  }
});

// GET /mesh?token=... -> serves the latest mesh file
app.get('/mesh', (req, res) => {
  try {
    const token = req.query.token;
    
    if (!token || !isValidToken(token)) {
      return res.status(400).json({ error: 'Invalid or missing token' });
    }
    
    const meshPath = path.join(DATA_DIR, token, 'mesh', 'latest.ply');
    
    if (!fs.existsSync(meshPath)) {
      return res.status(404).json({ error: 'Mesh not found. It may not be finalized yet.' });
    }
    
    console.log(`[API] Serving mesh for token: ${token.substring(0, 8)}...`);
    
    // Set appropriate headers for PLY file with cache control
    const stats = fs.statSync(meshPath);
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Disposition', `attachment; filename="mesh_${token.substring(0, 8)}.ply"`);
    res.setHeader('Last-Modified', stats.mtime.toUTCString());
    res.setHeader('ETag', `"${stats.mtime.getTime()}-${stats.size}"`);
    res.setHeader('Cache-Control', 'no-cache, must-revalidate'); // Force revalidation for real-time updates
    
    // Stream the file
    const fileStream = fs.createReadStream(meshPath);
    fileStream.pipe(res);
    
    fileStream.on('error', (err) => {
      console.error(`[API] Error streaming mesh:`, err);
      if (!res.headersSent) {
        res.status(500).json({ error: 'Failed to stream mesh file' });
      }
    });
  } catch (err) {
    console.error(`[API] Error in /mesh:`, err);
    res.status(500).json({ error: 'Failed to serve mesh', details: err.message });
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Debug endpoint: GET /debug/session?token=...
app.get('/debug/session', (req, res) => {
  try {
    const token = req.query.token;
    
    if (!token || !isValidToken(token)) {
      return res.status(400).json({ error: 'Invalid or missing token' });
    }
    
    const conns = getConnections(token);
    const tokenDir = path.join(DATA_DIR, token);
    const chunksDir = path.join(tokenDir, 'chunks');
    const meshPath = path.join(tokenDir, 'mesh', 'latest.ply');
    
    // Count chunks
    let chunksReceived = 0;
    if (fs.existsSync(chunksDir)) {
      const chunkDirs = fs.readdirSync(chunksDir, { withFileTypes: true })
        .filter(dirent => dirent.isDirectory())
        .length;
      chunksReceived = chunkDirs;
    }
    
    res.json({
      token: token.substring(0, 16) + '...',
      uiClients: conns.uis.size,
      phoneConnected: conns.phones.size > 0,
      chunksReceived: chunksReceived,
      meshExists: fs.existsSync(meshPath),
      meshSize: fs.existsSync(meshPath) ? fs.statSync(meshPath).size : null
    });
  } catch (err) {
    console.error(`[API] Error in /debug/session:`, err);
    res.status(500).json({ error: 'Failed to get session debug info', details: err.message });
  }
});

// Start server
// Listen on 0.0.0.0 to accept both localhost (USB) and network (WiFi) connections
server.listen(PORT, '0.0.0.0', () => {
  console.log(`[SERVER] Express server running on port ${PORT}`);
  console.log(`[SERVER] WebSocket server ready at ws://localhost:${PORT}/ws`);
  console.log(`[SERVER] Accepting connections from: localhost (USB) and network (WiFi)`);
  console.log(`[SERVER] Worker URL: ${WORKER_URL}`);
  console.log(`[SERVER] Data directory: ${DATA_DIR}`);
});
