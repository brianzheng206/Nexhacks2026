/**
 * Test Phone Client - Simulates iOS phone behavior for testing without a Mac/iOS device
 * 
 * Usage:
 *   node index.js <laptopIP> <token>
 * 
 * Example:
 *   node index.js 192.168.1.10 abc123...
 */

const WebSocket = require('ws');
const FormData = require('form-data');
const fetch = require('node-fetch');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const archiver = require('archiver');

const LAPTOP_IP = process.argv[2] || 'localhost';
const TOKEN = process.argv[3];

if (!TOKEN) {
  console.error('Usage: node index.js <laptopIP> <token>');
  console.error('Example: node index.js 192.168.1.10 abc123def456...');
  process.exit(1);
}

const SERVER_URL = `http://${LAPTOP_IP}:8080`;
const WS_URL = `ws://${LAPTOP_IP}:8080/ws?token=${TOKEN}`;

let ws = null;
let isScanning = false;
let frameCount = 0;
let keyframeCount = 0;
let chunkCounter = 0;

// Create test chunk directory structure
const TEST_CHUNK_DIR = path.join(__dirname, 'test-chunks');
if (!fs.existsSync(TEST_CHUNK_DIR)) {
  fs.mkdirSync(TEST_CHUNK_DIR, { recursive: true });
}

function createTestChunk(chunkId) {
  const chunkDir = path.join(TEST_CHUNK_DIR, `chunk_${chunkId}`);
  fs.mkdirSync(chunkDir, { recursive: true });
  fs.mkdirSync(path.join(chunkDir, 'rgb'), { recursive: true });
  fs.mkdirSync(path.join(chunkDir, 'depth'), { recursive: true });
  fs.mkdirSync(path.join(chunkDir, 'meta'), { recursive: true });
  
  // Create dummy files
  const frameIds = [];
  for (let i = 0; i < 5; i++) {
    const frameId = String(i).padStart(6, '0');
    frameIds.push(frameId);
    
    // Create dummy RGB (small JPEG)
    const rgbPath = path.join(chunkDir, 'rgb', `${frameId}.jpg`);
    fs.writeFileSync(rgbPath, Buffer.from('dummy jpeg data'));
    
    // Create dummy depth PNG
    const depthPath = path.join(chunkDir, 'depth', `${frameId}.png`);
    fs.writeFileSync(depthPath, Buffer.from('dummy png data'));
    
    // Create metadata JSON
    const metaPath = path.join(chunkDir, 'meta', `${frameId}.json`);
    const meta = {
      timestamp: Date.now() / 1000 + i * 0.1,
      K_color: [[800, 0, 320], [0, 800, 240], [0, 0, 1]],
      K_depth: [[400, 0, 160], [0, 400, 120], [0, 0, 1]],
      colorSize: [640, 480],
      depthSize: [320, 240],
      T_wc: [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, i * 0.1],
        [0, 0, 0, 1]
      ],
      depthScale: 1000.0
    };
    fs.writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  }
  
  // Create index.json
  const indexPath = path.join(chunkDir, 'index.json');
  fs.writeFileSync(indexPath, JSON.stringify({ frames: frameIds }, null, 2));
  
  return chunkDir;
}

async function zipDirectory(sourceDir, zipPath) {
  return new Promise((resolve, reject) => {
    const output = fs.createWriteStream(zipPath);
    const archive = archiver('zip', { zlib: { level: 9 } });
    
    output.on('close', () => resolve());
    archive.on('error', reject);
    
    archive.pipe(output);
    archive.directory(sourceDir, false);
    archive.finalize();
  });
}

async function uploadChunk(chunkDir, chunkId) {
  try {
    // Create zip
    const zipPath = path.join(TEST_CHUNK_DIR, `${chunkId}.zip`);
    await zipDirectory(chunkDir, zipPath);
    
    // Upload
    const form = new FormData();
    form.append('file', fs.createReadStream(zipPath));
    
    const response = await fetch(`${SERVER_URL}/upload/chunk?token=${TOKEN}&chunkId=${chunkId}`, {
      method: 'POST',
      body: form
    });
    
    if (response.ok) {
      const data = await response.json();
      console.log(`✓ Chunk ${chunkId} uploaded successfully`);
      
      // Cleanup
      fs.unlinkSync(zipPath);
      fs.rmSync(chunkDir, { recursive: true, force: true });
      
      return true;
    } else {
      const error = await response.text();
      console.error(`✗ Failed to upload chunk ${chunkId}: ${error}`);
      return false;
    }
  } catch (error) {
    console.error(`✗ Error uploading chunk ${chunkId}:`, error.message);
    return false;
  }
}

function connectWebSocket() {
  console.log(`Connecting to ${WS_URL}...`);
  
  ws = new WebSocket(WS_URL);
  
  ws.on('open', () => {
    console.log('WebSocket connected');
    
    // Send hello message
    ws.send(JSON.stringify({
      type: 'hello',
      role: 'phone',
      token: TOKEN
    }));
  });
  
  ws.on('message', (data) => {
    try {
      const message = JSON.parse(data.toString());
      
      if (message.type === 'hello_ack') {
        console.log('✓ Authenticated with server');
      } else if (message.type === 'control') {
        console.log(`Received control: ${message.action}`);
        
        if (message.action === 'start') {
          startScanning();
        } else if (message.action === 'stop') {
          stopScanning();
        }
      }
    } catch (err) {
      // Binary message (ignored in test client)
    }
  });
  
  ws.on('error', (error) => {
    console.error('WebSocket error:', error.message);
  });
  
  ws.on('close', () => {
    console.log('WebSocket disconnected');
    // Reconnect after 2 seconds
    setTimeout(connectWebSocket, 2000);
  });
}

function startScanning() {
  if (isScanning) return;
  
  isScanning = true;
  console.log('📱 Started scanning (simulated)');
  
  // Send initial status update
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'status',
      scanning: true,
      frames: 0,
      keyframes: 0,
      depthOK: true
    }));
  }
  
  // Simulate preview frames
  let frameColor = 0;
  const previewInterval = setInterval(() => {
    if (!isScanning) {
      clearInterval(previewInterval);
      return;
    }
    
    // Create a simple colored square JPEG (64x64) that changes color
    // Using a base64-encoded valid JPEG
    const colors = [
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', // red
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', // green  
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChAGA8f9fCQAAAABJRU5ErkJggg=='  // blue
    ];
    
    // Create a proper 64x64 red JPEG (valid base64 from PIL)
    const testJpeg = Buffer.from(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/wAARCABAAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDyyiiivzo/ssKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//2Q==',
      'base64'
    );
    
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(testJpeg, { binary: true });
      if (frameCount % 50 === 0) {
        console.log(`Sent ${frameCount} preview frames`);
      }
    }
    
    frameCount++;
    
    // Send status update every 10 frames
    if (frameCount % 10 === 0 && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: 'status',
        scanning: true,
        frames: frameCount,
        keyframes: keyframeCount,
        depthOK: true
      }));
    }
  }, 100); // ~10 fps
  
  // Simulate keyframe recording and chunk uploads
  const chunkInterval = setInterval(async () => {
    if (!isScanning) {
      clearInterval(chunkInterval);
      return;
    }
    
    chunkCounter++;
    const chunkId = `chunk_${String(chunkCounter).padStart(6, '0')}`;
    
    console.log(`Creating test chunk: ${chunkId}`);
    const chunkDir = createTestChunk(chunkId);
    
    // Upload chunk
    const uploadSuccess = await uploadChunk(chunkDir, chunkId);
    
    // Send status update
    if (ws && ws.readyState === WebSocket.OPEN) {
      keyframeCount += 5; // 5 frames per chunk
      ws.send(JSON.stringify({
        type: 'chunk_uploaded',
        chunkId: chunkId,
        count: 5
      }));
      ws.send(JSON.stringify({
        type: 'status',
        scanning: true,
        frames: frameCount,
        keyframes: keyframeCount,
        depthOK: true,
        chunksUploaded: chunkCounter
      }));
    }
  }, 3000); // Upload chunk every 3 seconds
}

function stopScanning() {
  if (!isScanning) return;
  
  isScanning = false;
  console.log('📱 Stopped scanning');
  
  // Send ready_to_finalize
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'status',
      value: 'ready_to_finalize'
    }));
  }
}

// Main
console.log('Test Phone Client');
console.log('================');
console.log(`Server: ${SERVER_URL}`);
console.log(`Token: ${TOKEN.substring(0, 16)}...`);
console.log('');

connectWebSocket();

// Handle Ctrl+C
process.on('SIGINT', () => {
  console.log('\nShutting down...');
  if (ws) ws.close();
  process.exit(0);
});
