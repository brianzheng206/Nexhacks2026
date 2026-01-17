import React, { useState, useEffect, useRef, useCallback } from 'react';
import { useSearchParams, useNavigate } from 'react-router-dom';

const MAX_RECONNECT_ATTEMPTS = 10;
const RECONNECT_DELAY = 3000;

const MainPage: React.FC = () => {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();

  const [token, setToken] = useState<string | null>(searchParams.get('token'));
  const [isConnected, setIsConnected] = useState<boolean>(false);
  const [phoneConnected, setPhoneConnected] = useState<boolean>(false);
  const [logContent, setLogContent] = useState<string>('No data received yet...');
  const [previewImageSrc, setPreviewImageSrc] = useState<string | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [floorplanData, setFloorplanData] = useState<any[]>([]); // To store wall data for canvas
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
  }, []);

  const showDownloadLink = useCallback((url: string) => {
    setDownloadUrl(url);
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
      // Hide canvas if no data
      if (canvas) canvas.style.display = 'none';
      return;
    }

    // Show canvas, hide image preview and placeholder
    if (canvas) canvas.style.display = 'block';
    if (previewImageRef.current) previewImageRef.current.style.display = 'none';

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    let minX = Infinity, maxX = -Infinity;
    let minZ = Infinity, maxZ = -Infinity;
    const wallSegments: { x1: number; z1: number; x2: number; z2: number }[] = [];

    for (const wall of floorplanData) {
      if (!wall.transform || !Array.isArray(wall.transform) || wall.transform.length !== 16) {
        continue;
      }

      const m = wall.transform;
      const x = m[12];
      const z = m[14];
      const width = wall.dimensions?.width || 0;
      const length = wall.dimensions?.length || 0;

      const m00 = m[0], m02 = m[8];
      const angle = Math.atan2(m02, m00);

      const halfLength = length / 2;
      const cosA = Math.cos(angle);
      const sinA = Math.sin(angle);

      const end1X = x - halfLength * cosA;
      const end1Z = z - halfLength * sinA;
      const end2X = x + halfLength * cosA;
      const end2Z = z + halfLength * sinA;

      wallSegments.push({ x1: end1X, z1: end1Z, x2: end2X, z2: end2Z });

      minX = Math.min(minX, end1X, end2X);
      maxX = Math.max(maxX, end1X, end2X);
      minZ = Math.min(minZ, end1Z, end2Z);
      maxZ = Math.max(maxZ, end1Z, end2Z);
    }

    if (minX === Infinity || wallSegments.length === 0) return;

    const rangeX = maxX - minX || 1;
    const rangeZ = maxZ - minZ || 1;
    const padding = 40;
    const scale = Math.min(
      (canvas.width - padding * 2) / rangeX,
      (canvas.height - padding * 2) / rangeZ
    );

    const centerX = (minX + maxX) / 2;
    const centerZ = (minZ + maxZ) / 2;
    const offsetX = canvas.width / 2 - centerX * scale;
    const offsetZ = canvas.height / 2 - centerZ * scale;

    ctx.strokeStyle = '#667eea'; // Tailwind indigo-500
    ctx.lineWidth = 4;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';

    for (const wall of wallSegments) {
      const x1 = wall.x1 * scale + offsetX;
      const z1 = wall.z1 * scale + offsetZ;
      const x2 = wall.x2 * scale + offsetX;
      const z2 = wall.z2 * scale + offsetZ;

      ctx.beginPath();
      ctx.moveTo(x1, z1);
      ctx.lineTo(x2, z2);
      ctx.stroke();
    }
  }, [floorplanData]);

  useEffect(() => {
    initFloorplanCanvas();
    drawFloorplan(); // Initial draw

    window.addEventListener('resize', initFloorplanCanvas);
    return () => window.removeEventListener('resize', initFloorplanCanvas);
  }, [initFloorplanCanvas, drawFloorplan]);


  const connectWebSocket = useCallback(() => {
    if (!token) {
      updateStatusIndicator(false);
      return;
    }

    if (wsRef.current && (wsRef.current.readyState === WebSocket.OPEN || wsRef.current.readyState === WebSocket.CONNECTING)) {
      return;
    }

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}`;

    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => {
      console.log('WebSocket connected');
      updateStatusIndicator(true);
      reconnectAttemptsRef.current = 0;
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
        reconnectTimeoutRef.current = null;
      }

      ws.send(JSON.stringify({
        type: 'hello',
        role: 'ui',
        token: token
      }));
    };

    ws.onmessage = (event) => {
      if (event.data instanceof Blob || event.data instanceof ArrayBuffer) {
        try {
          const blob = new Blob([event.data], { type: 'image/jpeg' });
          const url = URL.createObjectURL(blob);
          setPreviewImageSrc(prevUrl => {
            if (prevUrl) URL.revokeObjectURL(prevUrl); // Revoke old URL
            return url;
          });
          // Show image, hide canvas and placeholder
          if (previewImageRef.current) previewImageRef.current.style.display = 'block';
          if (floorplanCanvasRef.current) floorplanCanvasRef.current.style.display = 'none';

        } catch (error) {
          console.error('Error handling binary frame:', error);
        }
      } else {
        try {
          const data = JSON.parse(event.data);
          if (data.type === 'hello_ack') {
            console.log('WebSocket authenticated');
          } else if (data.type === 'room_update') {
            updateLog(data);
            if (data.walls && Array.isArray(data.walls)) {
              setFloorplanData(data.walls);
            }
          } else if (data.type === 'status') {
            if (data.value === 'phone_connected') {
              updatePhoneStatus(true);
            } else if (data.value === 'phone_disconnected') {
              updatePhoneStatus(false);
            }
          } else if (data.type === 'export_ready') {
            showDownloadLink(data.downloadUrl);
          }
        } catch (error) {
          console.error('Error parsing WebSocket message:', error);
        }
      }
    };

    ws.onerror = (error) => {
      console.error('WebSocket error:', error);
      updateStatusIndicator(false);
    };

    ws.onclose = () => {
      console.log('WebSocket disconnected');
      updateStatusIndicator(false);

      if (reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
        reconnectAttemptsRef.current++;
        reconnectTimeoutRef.current = setTimeout(() => {
          console.log(`Reconnecting... (attempt ${reconnectAttemptsRef.current})`);
          connectWebSocket();
        }, RECONNECT_DELAY);
      } else {
        console.error('Max reconnection attempts reached');
      }
    };
  }, [token, updateStatusIndicator, updatePhoneStatus, updateLog, showDownloadLink]);

  useEffect(() => {
    if (token) {
      connectWebSocket();
    }

    return () => {
      if (reconnectTimeoutRef.current) {
        clearTimeout(reconnectTimeoutRef.current);
      }
      if (wsRef.current) {
        wsRef.current.close();
      }
      if (previewImageSrc) {
        URL.revokeObjectURL(previewImageSrc);
      }
    };
  }, [token, connectWebSocket, previewImageSrc]);

  const createSession = async () => {
    try {
      const response = await fetch('/new');
      if (!response.ok) {
        throw new Error('Failed to create session');
      }
      const data = await response.json();
      setToken(data.token);
      navigate(`/?token=${data.token}`); // Update URL
    } catch (error) {
      console.error('Error creating session:', error);
      alert('Failed to create session: ' + error);
    }
  };

  const startScan = () => {
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN && token) {
      wsRef.current.send(JSON.stringify({
        type: 'control',
        token: token,
        action: 'start'
      }));
      console.log('Start scan command sent');
    }
  };

  const stopScan = () => {
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN && token) {
      wsRef.current.send(JSON.stringify({
        type: 'control',
        token: token,
        action: 'stop'
      }));
      console.log('Stop scan command sent');
    }
  };

  return (
    <div className="flex flex-col h-screen bg-gray-900 text-gray-200 font-sans">
      <header className="bg-gray-800 p-4 border-b-2 border-indigo-500 flex justify-between items-center">
        <h1 className="text-xl font-bold text-white">🏠 RoomScan Remote - Operator Console</h1>
        <div className="flex items-center space-x-4">
          <div className="font-mono bg-gray-900 px-3 py-1 rounded-md border border-indigo-500 text-indigo-400 text-sm flex items-center">
            <span className={`w-2.5 h-2.5 rounded-full mr-2 ${isConnected ? 'bg-green-500 shadow-lg shadow-green-500/50' : 'bg-red-500 shadow-lg shadow-red-500/50'}`}></span>
            <span>{token ? `Token: ${token}` : 'No session token'}</span>
          </div>
          {token && (
            <div className={`text-sm ${phoneConnected ? 'text-green-400' : 'text-red-400'}`}>
              Phone: {phoneConnected ? 'Connected' : 'Disconnected'}
            </div>
          )}
        </div>
      </header>

      <div className="flex flex-1 overflow-hidden">
        <div className="flex-1 bg-black flex items-center justify-center relative border-r-2 border-gray-700">
          {previewImageSrc && (
            <img ref={previewImageRef} src={previewImageSrc} alt="Live Preview" className="max-w-full max-h-full object-contain" />
          )}
          <canvas ref={floorplanCanvasRef} className="w-full h-full bg-black" style={{ display: (previewImageSrc || floorplanData.length > 0) ? 'block' : 'none' }}></canvas>
          {!previewImageSrc && floorplanData.length === 0 && (
            <div className="text-gray-500 text-lg text-center absolute">
              Waiting for scan preview...
            </div>
          )}
        </div>

        <div className="w-96 bg-gray-800 flex flex-col p-5 overflow-y-auto">
          <div className="bg-gray-900 p-4 rounded-lg mb-5 border-l-4 border-indigo-500">
            <h3 className="text-white mb-2 text-base font-semibold">Getting Started</h3>
            {!token ? (
              <p className="text-gray-400 text-sm leading-relaxed">
                To start scanning, you need a session token. Click the button below to create a new session, or visit{' '}
                <a href="/new" className="text-indigo-400 hover:underline">/new</a>.
              </p>
            ) : (
              <p className="text-gray-400 text-sm leading-relaxed">
                Scan session active. Use buttons below to control.
              </p>
            )}
          </div>

          {!token && (
            <div className="flex mb-5">
              <button
                className="flex-1 py-3 px-5 text-base font-semibold rounded-lg cursor-pointer transition-all bg-green-500 text-white hover:bg-green-600 shadow-md hover:shadow-lg"
                onClick={createSession}
              >
                Create New Session
              </button>
            </div>
          )}

          {token && (
            <div className="flex gap-2 mb-5">
              <button
                className="flex-1 py-3 px-5 text-base font-semibold rounded-lg cursor-pointer transition-all bg-green-500 text-white hover:bg-green-600 shadow-md hover:shadow-lg disabled:opacity-50 disabled:cursor-not-allowed"
                onClick={startScan}
                disabled={!isConnected || !phoneConnected}
              >
                Start Scan
              </button>
              <button
                className="flex-1 py-3 px-5 text-base font-semibold rounded-lg cursor-pointer transition-all bg-red-500 text-white hover:bg-red-600 shadow-md hover:shadow-lg disabled:opacity-50 disabled:cursor-not-allowed"
                onClick={stopScan}
                disabled={!isConnected || !phoneConnected}
              >
                Stop Scan
              </button>
            </div>
          )}

          <div className="bg-gray-900 rounded-lg p-4 flex-1 overflow-y-auto font-mono text-xs">
            <h3 className="text-white mb-2 text-base font-semibold">Room Stats</h3>
            <pre className="text-gray-400 whitespace-pre-wrap break-words">
              {logContent}
            </pre>
          </div>

          {downloadUrl && (
            <a
              className="mt-4 py-3 px-5 bg-indigo-500 text-white text-center no-underline rounded-lg font-semibold transition-all hover:bg-indigo-600 shadow-md hover:shadow-lg"
              href={downloadUrl}
              download
            >
              Download USDZ
            </a>
          )}
        </div>
      </div>
    </div>
  );
};

export default MainPage;