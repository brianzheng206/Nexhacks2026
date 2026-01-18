import { useState, useEffect, useRef, useCallback } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';
import {
  ArrowLeft, Play, Square, Download, Wifi, WifiOff, Plus, Activity,
  Box, Scan, Layers, Sparkles,
} from 'lucide-react';
import Mesh3DViewer from './Mesh3DViewer';
import RoomPlanViewer from './RoomPlanViewer';

const MAX_RECONNECT_ATTEMPTS = 10;
const RECONNECT_DELAY = 3000;

// Animated background component
function AnimatedBackground() {
  return (
    <>
      {/* Gradient orbs */}
      <div className="orb orb-1" />
      <div className="orb orb-2" />
      <div className="orb orb-3" />
      {/* Grid overlay */}
      <div className="grid-overlay" />
      {/* Noise texture */}
      <div className="noise-overlay" />
      {/* Floating particles */}
      <div className="particles">
        {[...Array(12)].map((_, i) => <div key={i} className="particle" />)}
      </div>
    </>
  );
}

export default function MainPage() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();

  const [token, setToken] = useState<string | null>(searchParams.get('token'));
  const [isConnected, setIsConnected] = useState(false);
  const [phoneConnected, setPhoneConnected] = useState(false);
  const [logContent, setLogContent] = useState('Waiting for data...');
  const [previewImageSrc, setPreviewImageSrc] = useState<string | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [floorplanData, setFloorplanData] = useState<any[]>([]);
  const [isScanning, setIsScanning] = useState(false);
  const [roomStats, setRoomStats] = useState<any>(null);
  const [meshData, setMeshData] = useState<Map<string, any>>(new Map()); // Store mesh anchors by ID
  const [laptopIP, setLaptopIP] = useState<string | null>(null);
  const [availableIPs, setAvailableIPs] = useState<string[]>([]);
  const copyText = (text: string) => navigator.clipboard.writeText(text);
  const ipCandidates = [laptopIP, ...availableIPs].filter(Boolean) as string[];
  const uniqueIPs = Array.from(new Set(ipCandidates.filter(ip => ip !== 'localhost' && ip !== '127.0.0.1')));
  const primaryIP = uniqueIPs[0] || window.location.hostname;
  const isLoopback = primaryIP === 'localhost' || primaryIP === '127.0.0.1';

  const wsRef = useRef<WebSocket | null>(null);
  const reconnectAttemptsRef = useRef(0);
  const reconnectTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const previewImageRef = useRef<HTMLImageElement>(null);
  const floorplanCanvasRef = useRef<HTMLCanvasElement>(null);
  const floorplanCtxRef = useRef<CanvasRenderingContext2D | null>(null);

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
    if (!ctx || !canvas || !floorplanData?.length) {
      if (canvas) canvas.style.display = 'none';
      return;
    }
    canvas.style.display = 'block';
    if (previewImageRef.current) previewImageRef.current.style.display = 'none';
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
    const walls: { x1: number; z1: number; x2: number; z2: number }[] = [];

    for (const wall of floorplanData) {
      if (!wall.transform?.length || wall.transform.length !== 16) continue;
      const m = wall.transform;
      const x = m[12], z = m[14], len = wall.dimensions?.length || 0;
      const angle = Math.atan2(m[8], m[0]), half = len / 2;
      const cos = Math.cos(angle), sin = Math.sin(angle);
      const x1 = x - half * cos, z1 = z - half * sin;
      const x2 = x + half * cos, z2 = z + half * sin;
      walls.push({ x1, z1, x2, z2 });
      minX = Math.min(minX, x1, x2); maxX = Math.max(maxX, x1, x2);
      minZ = Math.min(minZ, z1, z2); maxZ = Math.max(maxZ, z1, z2);
    }

    if (!walls.length) return;
    const pad = 60;
    const scale = Math.min((canvas.width - pad * 2) / (maxX - minX || 1), (canvas.height - pad * 2) / (maxZ - minZ || 1));
    const offX = canvas.width / 2 - ((minX + maxX) / 2) * scale;
    const offZ = canvas.height / 2 - ((minZ + maxZ) / 2) * scale;

    ctx.strokeStyle = 'rgba(255,255,255,0.8)';
    ctx.lineWidth = 2;
    ctx.lineCap = 'round';
    ctx.shadowColor = 'rgba(255,255,255,0.3)';
    ctx.shadowBlur = 8;
    walls.forEach(w => {
      ctx.beginPath();
      ctx.moveTo(w.x1 * scale + offX, w.z1 * scale + offZ);
      ctx.lineTo(w.x2 * scale + offX, w.z2 * scale + offZ);
      ctx.stroke();
    });
    ctx.shadowBlur = 0;
    ctx.fillStyle = 'rgba(255,255,255,0.9)';
    walls.forEach(w => {
      [{ x: w.x1, z: w.z1 }, { x: w.x2, z: w.z2 }].forEach(p => {
        ctx.beginPath();
        ctx.arc(p.x * scale + offX, p.z * scale + offZ, 3, 0, Math.PI * 2);
        ctx.fill();
      });
    });
  }, [floorplanData]);

  useEffect(() => {
    initFloorplanCanvas();
    drawFloorplan();
    window.addEventListener('resize', initFloorplanCanvas);
    return () => window.removeEventListener('resize', initFloorplanCanvas);
  }, [initFloorplanCanvas, drawFloorplan]);

  const connectWebSocket = useCallback(() => {
    if (!token || wsRef.current?.readyState === WebSocket.OPEN || wsRef.current?.readyState === WebSocket.CONNECTING) return;
    const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}`);
    wsRef.current = ws;

    ws.onopen = () => {
      setIsConnected(true);
      reconnectAttemptsRef.current = 0;
      if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current);
      ws.send(JSON.stringify({ type: 'hello', role: 'ui', token }));
    };

    ws.onmessage = (e) => {
      if (e.data instanceof Blob || e.data instanceof ArrayBuffer) {
        const url = URL.createObjectURL(new Blob([e.data], { type: 'image/jpeg' }));
        setPreviewImageSrc(prev => { if (prev) URL.revokeObjectURL(prev); return url; });
        if (previewImageRef.current) previewImageRef.current.style.display = 'block';
        if (floorplanCanvasRef.current) floorplanCanvasRef.current.style.display = 'none';
      } else {
        try {
          const d = JSON.parse(e.data);
          if (d.type === 'room_update') {
            setLogContent(JSON.stringify(d.stats || d.room || d, null, 2));
            // iOS sends: { walls: count, doors: count, windows: count, objects: count }
            // Map to frontend format for compatibility
            if (d.stats) {
              setRoomStats({
                wallCount: d.stats.walls || 0,
                doorCount: d.stats.doors || 0,
                windowCount: d.stats.windows || 0,
                objectCount: d.stats.objects || 0,
                // Also keep original for JSON display
                ...d.stats
              });
            } else if (Array.isArray(d.walls)) {
              setRoomStats({
                wallCount: d.walls.length,
                doorCount: Array.isArray(d.doors) ? d.doors.length : 0,
                windowCount: Array.isArray(d.windows) ? d.windows.length : 0,
                objectCount: Array.isArray(d.objects) ? d.objects.length : 0,
              });
            }
            // Update floorplan with walls data (real-time 3D visualization)
            if (d.walls?.length) {
              setFloorplanData(d.walls);
              setIsScanning(true); // Show scanning indicator when walls are being detected
            }
          } else if (d.type === 'mesh_update') {
            // Handle detailed 3D mesh with colors
            if (d.anchorId && d.vertices && d.faces && d.colors) {
              console.log('[MainPage] Received mesh_update:', {
                anchorId: d.anchorId,
                vertexCount: d.vertices?.length || 0,
                faceCount: d.faces?.length || 0,
                colorCount: d.colors?.length || 0
              });
              setMeshData(prev => {
                const updated = new Map(prev);
                updated.set(d.anchorId, {
                  vertices: d.vertices,
                  faces: d.faces,
                  colors: d.colors,
                  transform: d.transform,
                  timestamp: d.t
                });
                return updated;
              });
              setIsScanning(true);
              setLogContent(JSON.stringify({
                type: d.type,
                anchorId: d.anchorId,
                vertexCount: d.vertices?.length || 0,
                faceCount: d.faces?.length || 0,
                colorCount: d.colors?.length || 0
              }, null, 2));
            } else {
              console.warn('[MainPage] Invalid mesh_update message:', d);
            }
          } else if (d.type === 'status') {
            setPhoneConnected(d.value === 'phone_connected');
            if (d.value === 'phone_disconnected') {
              setIsScanning(false);
            }
            setLogContent(JSON.stringify(d, null, 2));
          } else if (d.type === 'export_ready') {
            setDownloadUrl(d.downloadUrl);
            setIsScanning(false);
            setLogContent(JSON.stringify(d, null, 2));
          }
        } catch {}
      }
    };

    ws.onerror = () => {};
    ws.onclose = () => {
      setIsConnected(false);
      if (reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
        reconnectAttemptsRef.current++;
        reconnectTimeoutRef.current = setTimeout(connectWebSocket, RECONNECT_DELAY);
      }
    };
  }, [token]);

  useEffect(() => {
    if (token) {
      connectWebSocket();
      // Fetch laptop IP if not already set
      if (!laptopIP) {
        const query = token ? `?token=${encodeURIComponent(token)}` : '';
        fetch(`/new${query}`).then(r => r.json()).then(d => {
          if (d.laptopIP) setLaptopIP(d.laptopIP);
          if (Array.isArray(d.availableIPs)) setAvailableIPs(d.availableIPs);
        }).catch(() => {});
      }
    }
    return () => {
      if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current);
      wsRef.current?.close();
      if (previewImageSrc) URL.revokeObjectURL(previewImageSrc);
    };
  }, [token, connectWebSocket, previewImageSrc, laptopIP]);

  const createSession = async () => {
    try {
      const res = await fetch('/new');
      if (!res.ok) throw new Error();
      const d = await res.json();
      setToken(d.token);
      setLaptopIP(d.laptopIP);
      if (Array.isArray(d.availableIPs)) setAvailableIPs(d.availableIPs);
      navigate(`/?token=${d.token}`);
    } catch {}
  };

  const handleBack = () => {
    if (previewImageSrc) {
      URL.revokeObjectURL(previewImageSrc);
    }
    wsRef.current?.close();
    if (reconnectTimeoutRef.current) clearTimeout(reconnectTimeoutRef.current);
    wsRef.current = null;
    reconnectTimeoutRef.current = null;
    reconnectAttemptsRef.current = 0;
    setIsConnected(false);
    setPhoneConnected(false);
    setLogContent('Waiting for data...');
    setPreviewImageSrc(null);
    setDownloadUrl(null);
    setFloorplanData([]);
    setIsScanning(false);
    setRoomStats(null);
    setMeshData(new Map());
    setLaptopIP(null);
    setAvailableIPs([]);
    setToken(null);
    navigate('/');
  };

  const sendControl = (action: 'start' | 'stop') => {
    if (wsRef.current?.readyState === WebSocket.OPEN && token) {
      wsRef.current.send(JSON.stringify({ type: 'control', token, action }));
      setIsScanning(action === 'start');
    }
  };

  // ========== LANDING PAGE ==========
  if (!token) {
    return (
      <div className="min-h-screen bg-animated-gradient flex items-center justify-center p-8 relative">
        <AnimatedBackground />

        <div className="max-w-xl w-full text-center relative z-10">
          {/* Logo */}
          <div className="hero-glow mb-12">
            <div className="animate-fade-in inline-flex items-center justify-center w-24 h-24 rounded-[28px] bg-gradient-to-b from-white/20 to-white/5 border border-white/15 mb-8 float shadow-2xl">
              <Box className="w-12 h-12 text-white" strokeWidth={1.5} />
            </div>

            {/* Animated title */}
            <h1 className="text-6xl font-bold tracking-tight mb-6 animate-fade-in delay-1">
              <span className="shimmer-text">RoomScan</span>
            </h1>

            {/* Typewriter tagline */}
            <p className="text-xl text-white/50 max-w-md mx-auto leading-relaxed animate-fade-in delay-2">
              AI-powered room scanning.
              <br />
              <span className="text-white/30">Reimagine your space.</span>
            </p>
          </div>

          {/* Feature cards */}
          <div className="grid grid-cols-3 gap-4 mb-12">
            {[
              { icon: Scan, label: '3D Capture', desc: 'LiDAR scanning', delay: 'delay-3' },
              { icon: Layers, label: 'Real-time', desc: 'Live preview', delay: 'delay-4' },
              { icon: Sparkles, label: 'AI Design', desc: 'Smart layouts', delay: 'delay-5' },
            ].map(({ icon: Icon, label, desc, delay }) => (
              <div key={label} className={`animate-fade-in ${delay} glass-card rounded-2xl p-5 transition-smooth hover:scale-105 hover:bg-white/[0.08]`}>
                <Icon className="w-7 h-7 text-white/60 mb-3 mx-auto" strokeWidth={1.5} />
                <p className="font-medium text-white/90 text-sm">{label}</p>
                <p className="text-xs text-white/40 mt-1">{desc}</p>
              </div>
            ))}
          </div>

          {/* CTA */}
          <div className="flex flex-col gap-3 max-w-xs mx-auto animate-fade-in delay-6">
            <button onClick={createSession} className="btn btn-primary py-4 text-base">
              <Plus className="w-5 h-5" strokeWidth={2} />
              Start Scanning
            </button>
            <button onClick={() => navigate('/new')} className="btn btn-secondary py-3">
              <Scan className="w-4 h-4" strokeWidth={2} />
              QR Setup
            </button>
          </div>

          {/* Subtle hint */}
          <p className="text-white/20 text-xs mt-12 animate-fade-in delay-6">
            Requires iPhone or iPad with LiDAR
          </p>
        </div>
      </div>
    );
  }

  // ========== DASHBOARD ==========
  return (
    <div className="flex flex-col h-screen w-screen bg-black text-white">
      <header className="glass border-b border-white/10 px-6 py-4 flex justify-between items-center">
        <div className="flex items-center gap-3">
          <button onClick={handleBack} className="btn btn-ghost px-3 py-2 text-xs">
            <ArrowLeft className="w-4 h-4" />
            Back
          </button>
          <div className="w-9 h-9 rounded-xl bg-gradient-to-b from-white/15 to-white/5 border border-white/10 flex items-center justify-center">
            <Box className="w-4 h-4 text-white/80" strokeWidth={1.5} />
          </div>
          <div>
            <h1 className="text-base font-semibold text-white/90">RoomScan</h1>
            <p className="text-xs text-white/40">Console</p>
          </div>
        </div>
        <div className="flex items-center gap-3">
          <div className={`badge ${isConnected ? 'badge-success' : 'badge-danger'}`}>
            <span className={`w-1.5 h-1.5 rounded-full ${isConnected ? 'bg-green-400' : 'bg-red-400'}`} />
            {isConnected ? 'Live' : 'Offline'}
          </div>
          <div className={`badge ${phoneConnected ? 'badge-success' : 'badge-warning'}`}>
            {phoneConnected ? <Wifi className="w-3 h-3" /> : <WifiOff className="w-3 h-3" />}
            {phoneConnected ? 'Device Connected' : 'No Device'}
          </div>
          <div 
            className="glass rounded-lg px-3 py-1.5 font-mono text-xs text-white/60 cursor-pointer hover:bg-white/10 transition-colors"
            onClick={() => { navigator.clipboard.writeText(token || ''); }}
            title={`Full token: ${token} (click to copy)`}
          >
            {token}
          </div>
        </div>
      </header>

      <div className="flex flex-1 overflow-hidden">
        <div className="flex-1 p-4 overflow-y-auto">
          <div className="grid gap-4 h-full grid-cols-1 xl:grid-cols-2">
            <div className="glass-card-strong rounded-2xl w-full h-full overflow-hidden relative" style={{ minHeight: '400px' }}>
              <div className="absolute top-4 left-4 badge badge-info z-10">
                <Activity className="w-3 h-3" />
                Live Preview
              </div>
              <div className="absolute inset-0 w-full h-full">
                <div className="w-full h-full flex items-center justify-center bg-black/50">
                  {previewImageSrc && <img ref={previewImageRef} src={previewImageSrc} alt="" className="max-w-full max-h-full object-contain" />}
                  <canvas ref={floorplanCanvasRef} className="w-full h-full" />
                  {!previewImageSrc && !floorplanData.length && (
                    <div className="text-center absolute">
                      <div className="w-16 h-16 rounded-2xl bg-white/5 flex items-center justify-center mx-auto mb-4">
                        <Scan className="w-8 h-8 text-white/20" strokeWidth={1.5} />
                      </div>
                      <p className="text-white/30">Awaiting scan</p>
                      <p className="text-white/15 text-sm mt-1">Connect device to begin</p>
                    </div>
                  )}
                </div>
              </div>
              {isScanning && (
                <div className="absolute bottom-4 left-4 badge badge-info status-pulse z-10">
                  Scanning
                </div>
              )}
            </div>

            <div className="glass-card-strong rounded-2xl w-full h-full overflow-hidden relative" style={{ minHeight: '400px' }}>
              <div className="absolute top-4 left-4 badge badge-info z-10">
                <Layers className="w-3 h-3" />
                3D Reconstruction
              </div>
              <div className="absolute inset-0 w-full h-full">
                {meshData.size > 0 ? (
                  <Mesh3DViewer meshData={meshData} className="w-full h-full" />
                ) : floorplanData.length > 0 ? (
                  <RoomPlanViewer walls={floorplanData} className="w-full h-full" />
                ) : (
                  <div className="w-full h-full flex items-center justify-center bg-black/50">
                    <div className="text-center">
                      <div className="w-16 h-16 rounded-2xl bg-white/5 flex items-center justify-center mx-auto mb-4">
                        <Box className="w-8 h-8 text-white/20" strokeWidth={1.5} />
                      </div>
                      <p className="text-white/30">Waiting for 3D data</p>
                      <p className="text-white/15 text-sm mt-1">Start scanning to stream 3D</p>
                    </div>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>

        <div className="w-80 p-4 flex flex-col gap-4 overflow-y-auto">
          <div className="glass-card-strong rounded-2xl p-5">
            <p className="text-xs font-medium text-white/40 uppercase tracking-wider mb-4">Controls</p>
            <div className="grid grid-cols-2 gap-2">
              <button onClick={() => sendControl('start')} disabled={!isConnected || !phoneConnected || isScanning} className="btn btn-success py-3">
                <Play className="w-4 h-4" /> Start
              </button>
              <button onClick={() => sendControl('stop')} disabled={!isConnected || !phoneConnected || !isScanning} className="btn btn-danger py-3">
                <Square className="w-4 h-4" /> Stop
              </button>
            </div>
            <button onClick={() => navigate(`/pair?token=${token}`)} className="btn btn-secondary w-full mt-3 py-2">
              <Scan className="w-4 h-4" />
              QR Setup
            </button>
            <button onClick={handleBack} className="btn btn-ghost w-full mt-3 py-2">
              <ArrowLeft className="w-4 h-4" />
              Home
            </button>
            {!phoneConnected && isConnected && (
              <div className="mt-3 p-3 rounded-lg bg-amber-500/10 border border-amber-500/20">
                <p className="text-xs text-amber-400/80 font-medium mb-2">📱 Connect Your Device</p>
                <div className="space-y-2 text-[10px] text-amber-400/70">
                  <div className="flex gap-2">
                    <span className="text-amber-400/50">IP:</span>
                    <span className="font-mono bg-black/30 px-1 rounded">{primaryIP}</span>
                    <button
                      onClick={() => copyText(primaryIP)}
                      className="text-amber-300/70 hover:text-amber-200 transition-colors"
                    >
                      Copy
                    </button>
                  </div>
                  {uniqueIPs.length > 1 && (
                    <div className="space-y-1">
                      <p className="text-[9px] text-amber-400/40 uppercase">Other IPs</p>
                      {uniqueIPs.slice(1, 4).map(ip => (
                        <div key={ip} className="flex gap-2 items-center">
                          <span className="text-amber-400/50">IP:</span>
                          <span className="font-mono bg-black/30 px-1 rounded">{ip}</span>
                          <button
                            onClick={() => copyText(ip)}
                            className="text-amber-300/70 hover:text-amber-200 transition-colors"
                          >
                            Copy
                          </button>
                        </div>
                      ))}
                    </div>
                  )}
                  <div className="flex gap-2">
                    <span className="text-amber-400/50">Token:</span>
                    <span className="font-mono bg-black/30 px-1 rounded break-all">{token}</span>
                  </div>
                </div>
                <p className="text-[9px] text-amber-400/40 mt-2">
                  Enter these on your iOS app to connect
                </p>
                {isLoopback && uniqueIPs.length === 0 && (
                  <p className="text-[9px] text-amber-400/40 mt-1">
                    Tip: open this page via your laptop's LAN IP to generate a reachable QR.
                  </p>
                )}
              </div>
            )}
          </div>

          <div className="glass-card-strong rounded-2xl p-5 flex-1 flex flex-col min-h-0">
            <p className="text-xs font-medium text-white/40 uppercase tracking-wider mb-4">Room Data</p>
            {(roomStats || floorplanData.length > 0) && (
              <div className="grid grid-cols-2 gap-2 mb-4">
                {[
                  { l: 'Walls', v: roomStats?.wallCount ?? floorplanData.length ?? 0 },
                  { l: 'Doors', v: roomStats?.doorCount ?? 0 },
                  { l: 'Windows', v: roomStats?.windowCount ?? 0 },
                  { l: 'Objects', v: roomStats?.objectCount ?? 0 },
                ].map(({ l, v }) => (
                  <div key={l} className="stats-card glass rounded-xl p-3">
                    <p className="text-[10px] text-white/40 uppercase">{l}</p>
                    <p className="text-xl font-semibold text-white/90">{v}</p>
                  </div>
                ))}
              </div>
            )}
            <div className="flex-1 overflow-hidden flex flex-col min-h-0">
              <p className="text-[10px] text-white/30 uppercase mb-2">JSON</p>
              <div className="code-display flex-1 overflow-y-auto text-xs">
                <pre className="whitespace-pre-wrap break-words">{logContent}</pre>
              </div>
            </div>
          </div>

          {downloadUrl && (
            <a href={downloadUrl} download className="btn btn-primary py-4 glow-primary">
              <Download className="w-5 h-5" /> Download USDZ
            </a>
          )}
        </div>
      </div>
    </div>
  );
}
