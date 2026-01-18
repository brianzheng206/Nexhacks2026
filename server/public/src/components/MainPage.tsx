import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';
import {
  Play,
  Square,
  Download,
  Wifi,
  WifiOff,
  Plus,
  Activity,
  Box,
  Scan,
  Layers,
  Maximize2,
  ZoomIn,
} from 'lucide-react';

const MAX_RECONNECT_ATTEMPTS = 10;
const RECONNECT_DELAY = 3000;

const MainPage: React.FC = () => {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();

  const [token, setToken] = useState<string | null>(searchParams.get('token'));
  const [isConnected, setIsConnected] = useState<boolean>(false);
  const [phoneConnected, setPhoneConnected] = useState<boolean>(false);
  const [logContent, setLogContent] = useState<string>('Waiting for room data...');
  const [previewImageSrc, setPreviewImageSrc] = useState<string | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [floorplanData, setFloorplanData] = useState<any[]>([]);
  const [isScanning, setIsScanning] = useState<boolean>(false);
  const [roomStats, setRoomStats] = useState<any>(null);

  const wsRef = useRef<WebSocket | null>(null);
  const reconnectAttemptsRef = useRef<number>(0);
  const reconnectTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const previewImageRef = useRef<HTMLImageElement>(null);
  const floorplanCanvasRef = useRef<HTMLCanvasElement>(null);
  const floorplanCtxRef = useRef<CanvasRenderingContext2D | null>(null);

  const updateStatusIndicator = useCallback((connected: boolean) => {
    setIsConnected(connected);
  }, []);

  const updatePhoneStatus = useCallback((connected: boolean) => {
    setPhoneConnected(connected);
  }, []);

  const updateLog = useCallback((data: any) => {
    const logData = data.stats || data.room || data;
    setLogContent(JSON.stringify(logData, null, 2));
    if (data.stats) {
      setRoomStats(data.stats);
    }
  }, []);

  const showDownloadLink = useCallback((url: string) => {
    setDownloadUrl(url);
    setIsScanning(false);
  }, []);

  const initFloorplanCanvas = useCallback(() => {
    const canvas = floorplanCanvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    floorplanCtxRef.current = ctx;
    const container = canvas.parentElement;
    if (container) {
      canvas.width = container.clientWidth;
      canvas.height = container.clientHeight;
    }
  }, []);

  const drawFloorplan = useCallback(() => {
    const ctx = floorplanCtxRef.current;
    const canvas = floorplanCanvasRef.current;

    if (!ctx || !canvas || !floorplanData || floorplanData.length === 0) {
      if (canvas) canvas.style.display = 'none';
      return;
    }

    if (canvas) canvas.style.display = 'block';
    if (previewImageRef.current) previewImageRef.current.style.display = 'none';

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    let minX = Infinity,
      maxX = -Infinity;
    let minZ = Infinity,
      maxZ = -Infinity;
    const wallSegments: { x1: number; z1: number; x2: number; z2: number }[] = [];

    for (const wall of floorplanData) {
      if (!wall.transform || !Array.isArray(wall.transform) || wall.transform.length !== 16) continue;

      const m = wall.transform;
      const x = m[12],
        z = m[14];
      const length = wall.dimensions?.length || 0;
      const angle = Math.atan2(m[8], m[0]);
      const halfLength = length / 2;
      const cosA = Math.cos(angle),
        sinA = Math.sin(angle);

      const end1X = x - halfLength * cosA,
        end1Z = z - halfLength * sinA;
      const end2X = x + halfLength * cosA,
        end2Z = z + halfLength * sinA;

      wallSegments.push({ x1: end1X, z1: end1Z, x2: end2X, z2: end2Z });
      minX = Math.min(minX, end1X, end2X);
      maxX = Math.max(maxX, end1X, end2X);
      minZ = Math.min(minZ, end1Z, end2Z);
      maxZ = Math.max(maxZ, end1Z, end2Z);
    }

    if (minX === Infinity || wallSegments.length === 0) return;

    const rangeX = maxX - minX || 1;
    const rangeZ = maxZ - minZ || 1;
    const padding = 60;
    const scale = Math.min((canvas.width - padding * 2) / rangeX, (canvas.height - padding * 2) / rangeZ);

    const centerX = (minX + maxX) / 2,
      centerZ = (minZ + maxZ) / 2;
    const offsetX = canvas.width / 2 - centerX * scale,
      offsetZ = canvas.height / 2 - centerZ * scale;

    // Draw with gradient stroke
    const gradient = ctx.createLinearGradient(0, 0, canvas.width, canvas.height);
    gradient.addColorStop(0, '#0ea5e9');
    gradient.addColorStop(1, '#8b5cf6');

    ctx.strokeStyle = gradient;
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.shadowColor = '#0ea5e9';
    ctx.shadowBlur = 10;

    for (const wall of wallSegments) {
      ctx.beginPath();
      ctx.moveTo(wall.x1 * scale + offsetX, wall.z1 * scale + offsetZ);
      ctx.lineTo(wall.x2 * scale + offsetX, wall.z2 * scale + offsetZ);
      ctx.stroke();
    }

    // Draw corner points
    ctx.shadowBlur = 0;
    ctx.fillStyle = '#0ea5e9';
    for (const wall of wallSegments) {
      ctx.beginPath();
      ctx.arc(wall.x1 * scale + offsetX, wall.z1 * scale + offsetZ, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(wall.x2 * scale + offsetX, wall.z2 * scale + offsetZ, 4, 0, Math.PI * 2);
      ctx.fill();
    }
  }, [floorplanData]);

  useEffect(() => {
    initFloorplanCanvas();
    drawFloorplan();
    window.addEventListener('resize', initFloorplanCanvas);
    return () => window.removeEventListener('resize', initFloorplanCanvas);
  }, [initFloorplanCanvas, drawFloorplan]);

  const connectWebSocket = useCallback(() => {
    if (
      !token ||
      (wsRef.current && (wsRef.current.readyState === WebSocket.OPEN || wsRef.current.readyState === WebSocket.CONNECTING))
    )
      return;

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${protocol}//${window.location.host}`);
    wsRef.current = ws;

    ws.onopen = () => {
      updateStatusIndicator(true);
      reconnectAttemptsRef.current = 0;
      if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current);
      ws.send(JSON.stringify({ type: 'hello', role: 'ui', token }));
    };

    ws.onmessage = (event) => {
      if (event.data instanceof Blob || event.data instanceof ArrayBuffer) {
        const blob = new Blob([event.data], { type: 'image/jpeg' });
        const url = URL.createObjectURL(blob);
        setPreviewImageSrc((prev) => {
          if (prev) URL.revokeObjectURL(prev);
          return url;
        });
        if (previewImageRef.current) previewImageRef.current.style.display = 'block';
        if (floorplanCanvasRef.current) floorplanCanvasRef.current.style.display = 'none';
      } else {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'room_update') {
            updateLog(data);
            if (data.walls && Array.isArray(data.walls)) setFloorplanData(data.walls);
          } else if (data.type === 'status') {
            if (data.value === 'phone_connected') updatePhoneStatus(true);
            else if (data.value === 'phone_disconnected') updatePhoneStatus(false);
          } else if (data.type === 'export_ready') showDownloadLink(data.downloadUrl);
        } catch (error) {
          console.error('Error parsing WebSocket message:', error);
        }
      }
    };

    ws.onerror = (error) => console.error('WebSocket error:', error);
    ws.onclose = () => {
      updateStatusIndicator(false);
      if (reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
        reconnectAttemptsRef.current++;
        reconnectTimeoutRef.current = setTimeout(() => connectWebSocket(), RECONNECT_DELAY);
      }
    };
  }, [token, updateStatusIndicator, updatePhoneStatus, updateLog, showDownloadLink]);

  useEffect(() => {
    if (token) connectWebSocket();
    return () => {
      if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current);
      if (wsRef.current) wsRef.current.close();
      if (previewImageSrc) URL.revokeObjectURL(previewImageSrc);
    };
  }, [token, connectWebSocket, previewImageSrc]);

  const createSession = async () => {
    try {
      const response = await fetch('/new');
      if (!response.ok) throw new Error('Failed to create session');
      const data = await response.json();
      setToken(data.token);
      navigate(`/?token=${data.token}`);
    } catch (error) {
      console.error('Error creating session:', error);
    }
  };

  const sendControl = (action: 'start' | 'stop') => {
    if (wsRef.current?.readyState === WebSocket.OPEN && token) {
      wsRef.current.send(JSON.stringify({ type: 'control', token, action }));
      setIsScanning(action === 'start');
    }
  };

  // Landing page when no session
  if (!token) {
    return (
      <div className="min-h-screen bg-animated-gradient flex items-center justify-center p-6">
        <div className="max-w-2xl w-full text-center">
          {/* Hero Section */}
          <div className="hero-glow mb-12">
            <div className="inline-flex items-center justify-center w-24 h-24 rounded-3xl bg-gradient-to-br from-[hsl(var(--primary))] to-[hsl(var(--accent))] mb-8 float">
              <Box className="w-12 h-12 text-white" />
            </div>
            <h1 className="text-5xl font-bold mb-4">
              <span className="gradient-text">RoomScan</span>
              <span className="text-foreground"> Remote</span>
            </h1>
            <p className="text-xl text-muted-foreground max-w-md mx-auto leading-relaxed">
              Transform your space with AI-powered room scanning and intelligent furniture suggestions
            </p>
          </div>

          {/* Features Grid */}
          <div className="grid grid-cols-3 gap-4 mb-12">
            <div className="glass-card rounded-2xl p-6 transition-smooth hover:scale-[1.02]">
              <Scan className="w-8 h-8 text-[hsl(var(--primary))] mb-3 mx-auto" />
              <h3 className="font-semibold text-foreground mb-1">3D Scanning</h3>
              <p className="text-sm text-muted-foreground">Capture rooms with RoomPlan</p>
            </div>
            <div className="glass-card rounded-2xl p-6 transition-smooth hover:scale-[1.02]">
              <Layers className="w-8 h-8 text-[hsl(var(--accent))] mb-3 mx-auto" />
              <h3 className="font-semibold text-foreground mb-1">Live Preview</h3>
              <p className="text-sm text-muted-foreground">Real-time visualization</p>
            </div>
            <div className="glass-card rounded-2xl p-6 transition-smooth hover:scale-[1.02]">
              <ZoomIn className="w-8 h-8 text-[hsl(var(--success))] mb-3 mx-auto" />
              <h3 className="font-semibold text-foreground mb-1">AI Analysis</h3>
              <p className="text-sm text-muted-foreground">Smart suggestions</p>
            </div>
          </div>

          {/* CTA Buttons */}
          <div className="flex flex-col sm:flex-row gap-4 justify-center">
            <button onClick={createSession} className="btn btn-primary text-lg px-8 py-4 glow-primary">
              <Plus className="w-5 h-5 mr-2" />
              Start New Session
            </button>
            <button onClick={() => navigate('/new')} className="btn btn-secondary text-lg px-8 py-4">
              <Scan className="w-5 h-5 mr-2" />
              View QR Setup
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Dashboard when session is active
  return (
    <div className="flex flex-col h-screen w-screen bg-animated-gradient text-foreground">
      {/* Header */}
      <header className="glass-card border-0 border-b border-border px-6 py-4 flex justify-between items-center z-10">
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-[hsl(var(--primary))] to-[hsl(var(--accent))] flex items-center justify-center">
              <Box className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold gradient-text">RoomScan Remote</h1>
              <p className="text-xs text-muted-foreground">Operator Console</p>
            </div>
          </div>
        </div>

        <div className="flex items-center gap-4">
          {/* Connection Status */}
          <div className="flex items-center gap-3">
            <div
              className={`badge ${isConnected ? 'badge-success' : 'badge-danger'} ${isConnected ? 'status-pulse' : ''}`}
            >
              <span className={`w-2 h-2 rounded-full mr-2 ${isConnected ? 'bg-[hsl(var(--success))]' : 'bg-[hsl(var(--destructive))]'}`} />
              {isConnected ? 'Connected' : 'Disconnected'}
            </div>

            <div className={`badge ${phoneConnected ? 'badge-success' : 'badge-warning'}`}>
              {phoneConnected ? <Wifi className="w-3.5 h-3.5 mr-1.5" /> : <WifiOff className="w-3.5 h-3.5 mr-1.5" />}
              Phone
            </div>
          </div>

          {/* Token Display */}
          <div className="glass-card rounded-xl px-4 py-2 font-mono text-sm">
            <span className="text-muted-foreground mr-2">Session:</span>
            <span className="text-[hsl(var(--primary))]">{token.substring(0, 8)}...</span>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <div className="flex flex-1 overflow-hidden">
        {/* Preview Panel */}
        <div className="flex-1 relative p-4">
          <div className="glass-card-strong rounded-2xl w-full h-full overflow-hidden relative">
            {/* Preview Area */}
            <div className="absolute inset-0 flex items-center justify-center bg-[hsl(var(--background))]">
              {previewImageSrc && (
                <img
                  ref={previewImageRef}
                  src={previewImageSrc}
                  alt="Live Preview"
                  className="max-w-full max-h-full object-contain"
                />
              )}
              <canvas ref={floorplanCanvasRef} className="w-full h-full" />

              {!previewImageSrc && floorplanData.length === 0 && (
                <div className="text-center">
                  <div className="w-20 h-20 rounded-2xl bg-secondary flex items-center justify-center mx-auto mb-4">
                    <Scan className="w-10 h-10 text-muted-foreground" />
                  </div>
                  <p className="text-muted-foreground text-lg">Waiting for scan preview...</p>
                  <p className="text-muted-foreground/60 text-sm mt-2">Connect your iOS device and start scanning</p>
                </div>
              )}
            </div>

            {/* Scanning Indicator */}
            {isScanning && (
              <div className="absolute top-4 left-4 badge badge-info status-pulse">
                <Activity className="w-3.5 h-3.5 mr-1.5 animate-pulse" />
                Scanning...
              </div>
            )}

            {/* Fullscreen Button */}
            <button className="absolute top-4 right-4 btn btn-ghost p-2 glass-card">
              <Maximize2 className="w-5 h-5" />
            </button>
          </div>
        </div>

        {/* Control Sidebar */}
        <div className="w-96 p-4 flex flex-col gap-4 overflow-y-auto">
          {/* Scan Controls */}
          <div className="glass-card-strong rounded-2xl p-5">
            <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider mb-4">
              Scan Controls
            </h2>
            <div className="grid grid-cols-2 gap-3">
              <button
                onClick={() => sendControl('start')}
                disabled={!isConnected || !phoneConnected || isScanning}
                className="btn btn-success py-4"
              >
                <Play className="w-5 h-5 mr-2" />
                Start
              </button>
              <button
                onClick={() => sendControl('stop')}
                disabled={!isConnected || !phoneConnected || !isScanning}
                className="btn btn-danger py-4"
              >
                <Square className="w-5 h-5 mr-2" />
                Stop
              </button>
            </div>

            {!phoneConnected && isConnected && (
              <div className="mt-4 p-3 rounded-xl bg-[hsla(var(--warning),0.1)] border border-[hsla(var(--warning),0.3)]">
                <p className="text-sm text-[hsl(var(--warning))]">
                  Waiting for iOS device to connect...
                </p>
              </div>
            )}
          </div>

          {/* Room Stats */}
          <div className="glass-card-strong rounded-2xl p-5 flex-1 flex flex-col">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider">
                Room Data
              </h2>
              <Activity className="w-4 h-4 text-muted-foreground" />
            </div>

            {/* Stats Summary */}
            {roomStats && (
              <div className="grid grid-cols-2 gap-3 mb-4">
                <div className="stats-card glass-card rounded-xl p-3">
                  <p className="text-xs text-muted-foreground">Walls</p>
                  <p className="text-xl font-bold text-[hsl(var(--primary))]">{roomStats.wallCount || floorplanData.length || 0}</p>
                </div>
                <div className="stats-card glass-card rounded-xl p-3">
                  <p className="text-xs text-muted-foreground">Doors</p>
                  <p className="text-xl font-bold text-[hsl(var(--accent))]">{roomStats.doorCount || 0}</p>
                </div>
                <div className="stats-card glass-card rounded-xl p-3">
                  <p className="text-xs text-muted-foreground">Windows</p>
                  <p className="text-xl font-bold text-[hsl(var(--success))]">{roomStats.windowCount || 0}</p>
                </div>
                <div className="stats-card glass-card rounded-xl p-3">
                  <p className="text-xs text-muted-foreground">Objects</p>
                  <p className="text-xl font-bold text-[hsl(var(--warning))]">{roomStats.objectCount || 0}</p>
                </div>
              </div>
            )}

            {/* Raw Data */}
            <div className="flex-1 overflow-hidden flex flex-col min-h-0">
              <p className="text-xs text-muted-foreground mb-2">Raw JSON</p>
              <div className="code-display flex-1 overflow-y-auto text-xs">
                <pre className="text-muted-foreground whitespace-pre-wrap break-words">{logContent}</pre>
              </div>
            </div>
          </div>

          {/* Download Section */}
          {downloadUrl && (
            <a
              href={downloadUrl}
              download
              className="btn btn-primary w-full py-4 glow-primary"
            >
              <Download className="w-5 h-5 mr-2" />
              Download USDZ Model
            </a>
          )}
        </div>
      </div>
    </div>
  );
};

export default MainPage;
