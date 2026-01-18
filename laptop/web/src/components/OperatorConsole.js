import React, { useState, useEffect, useRef } from 'react';
import './OperatorConsole.css';
import PreviewPanel from './PreviewPanel';
import StatusPanel from './StatusPanel';
import MeshViewer from './MeshViewer';

const SERVER_URL = process.env.REACT_APP_SERVER_URL || 'http://localhost:8080';

function OperatorConsole() {
  const [token, setToken] = useState('');
  const [wsUrl, setWsUrl] = useState('');
  const [uploadBaseUrl, setUploadBaseUrl] = useState('');
  const [connectionInfo, setConnectionInfo] = useState(null);
  const [previewImage, setPreviewImage] = useState(null);
  const [status, setStatus] = useState({
    lastInstruction: '',
    framesCaptured: 0,
    chunksUploaded: 0,
    depthOk: false,
    lastChunkId: null,
    triangles: null
  });
  const [ws, setWs] = useState(null);
  const [wsConnected, setWsConnected] = useState(false);
  const [phoneConnected, setPhoneConnected] = useState(false);
  const [readyToFinalize, setReadyToFinalize] = useState(false);

  // Read token from URL on mount
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const urlToken = params.get('token');
    if (urlToken) {
      setToken(urlToken);
      connectWebSocket(urlToken);
    }
  }, []);

  // Connect WebSocket when token changes
  const connectWebSocket = (tokenToUse) => {
    if (!tokenToUse) return;

    const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsHost = SERVER_URL.replace(/^https?:\/\//, '').replace(/^wss?:\/\//, '');
    const wsUrlToConnect = `${wsProtocol}//${wsHost}/ws?token=${tokenToUse}`;

    console.log('Connecting to WebSocket:', wsUrlToConnect);

    const websocket = new WebSocket(wsUrlToConnect);

    websocket.onopen = () => {
      console.log('WebSocket connected');
      setWsConnected(true);
      // Send hello message
      websocket.send(JSON.stringify({
        type: 'hello',
        role: 'ui',
        token: tokenToUse
      }));
    };

    websocket.onmessage = (event) => {
      // Check if it's a binary message (JPEG frame)
      if (event.data instanceof Blob || event.data instanceof ArrayBuffer) {
        console.log('Received binary frame, size:', event.data instanceof Blob ? event.data.size : event.data.byteLength);
        const blob = event.data instanceof Blob ? event.data : new Blob([event.data]);
        const url = URL.createObjectURL(blob);
        // Clean up previous URL to prevent memory leaks
        setPreviewImage(prev => {
          if (prev) URL.revokeObjectURL(prev);
          return url;
        });
      } else {
        // JSON message (status/instruction/counters)
        try {
          const data = JSON.parse(event.data);
          console.log('Received status:', data);

          // Handle hello_ack
          if (data.type === 'hello_ack') {
            console.log('WebSocket authenticated');
            return;
          }

          // Handle phone connection status
          if (data.type === 'phone_status') {
            setPhoneConnected(data.connected || false);
            return;
          }

          // Handle ready_to_finalize
          if (data.type === 'status' && data.value === 'ready_to_finalize') {
            setReadyToFinalize(true);
          }

          // Handle chunk_uploaded
          if (data.type === 'chunk_uploaded') {
            setStatus(prev => ({
              ...prev,
              lastChunkId: data.chunkId,
              chunksUploaded: (prev.chunksUploaded || 0) + 1
            }));
          }

          // Update status from phone messages
          if (data.type === 'status') {
            setStatus(prev => ({
              ...prev,
              lastInstruction: data.message || data.instruction || '',
              framesCaptured: data.frames ?? data.framesCaptured ?? prev.framesCaptured,
              chunksUploaded: data.chunksUploaded ?? prev.chunksUploaded,
              depthOk: data.depthOK ?? data.depthOk ?? prev.depthOk
            }));
          } else if (data.type === 'instruction') {
            setStatus(prev => ({
              ...prev,
              lastInstruction: data.message || data.instruction || ''
            }));
          } else if (data.framesCaptured !== undefined || data.chunksUploaded !== undefined) {
            // Update counters if present
            setStatus(prev => ({
              ...prev,
              framesCaptured: data.framesCaptured ?? prev.framesCaptured,
              chunksUploaded: data.chunksUploaded ?? prev.chunksUploaded,
              depthOk: data.depthOk ?? prev.depthOk
            }));
          }
        } catch (err) {
          console.error('Failed to parse WebSocket message:', err);
        }
      }
    };

    websocket.onerror = (error) => {
      console.error('WebSocket error:', error);
      setWsConnected(false);
    };

    websocket.onclose = () => {
      console.log('WebSocket disconnected');
      setWsConnected(false);
      setWs(null);
    };

    setWs(websocket);
    setWsUrl(wsUrlToConnect);
  };

  const handleCreateNewSession = async () => {
    try {
      const response = await fetch(`${SERVER_URL}/new`);
      if (!response.ok) {
        throw new Error('Failed to create new session');
      }
      const data = await response.json();
      setToken(data.token);
      setWsUrl(data.wsUrl);
      setUploadBaseUrl(data.uploadBaseUrl);
      setConnectionInfo(data);
      connectWebSocket(data.token);
      
      // Update URL without reload
      const newUrl = new URL(window.location);
      newUrl.searchParams.set('token', data.token);
      window.history.pushState({}, '', newUrl);
    } catch (error) {
      console.error('Error creating new session:', error);
      alert('Failed to create new session: ' + error.message);
    }
  };

  const sendControl = (action) => {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      alert('WebSocket not connected');
      return;
    }
    ws.send(JSON.stringify({
      type: 'control',
      action: action
    }));
    console.log('Sent control:', action);
  };

  const handleFinalize = async () => {
    if (!token) {
      alert('No token available');
      return;
    }
    try {
      const response = await fetch(`${SERVER_URL}/finalize?token=${token}`, {
        method: 'POST'
      });
      if (!response.ok) {
        const error = await response.json();
        throw new Error(error.error || 'Failed to finalize');
      }
      const data = await response.json();
      alert(`Mesh finalized! URL: ${data.meshUrl}`);
      setReadyToFinalize(false); // Reset after finalization
      
      // Update status with mesh stats
      if (data.triangles) {
        setStatus(prev => ({
          ...prev,
          triangles: data.triangles
        }));
      }
    } catch (error) {
      console.error('Error finalizing:', error);
      alert('Failed to finalize mesh: ' + error.message);
    }
  };

  // Cleanup WebSocket on unmount
  useEffect(() => {
    return () => {
      if (ws) {
        ws.close();
      }
    };
  }, [ws]);

  return (
    <div className="operator-console">
      <header className="console-header">
        <h1>Room Scan TSDF - Operator Console</h1>
      </header>

      <div className="console-content">
        <div className="console-left">
          <div className="session-panel">
            <h2>Session</h2>
            <div className="token-input-group">
              <label>Token:</label>
              <input
                type="text"
                value={token}
                onChange={(e) => setToken(e.target.value)}
                placeholder="Enter token or create new session"
                className="token-input"
              />
            </div>
            <button 
              onClick={handleCreateNewSession}
              className="btn btn-primary"
            >
              Create New Session
            </button>
            
            {connectionInfo && (
              <div className="connection-info">
                <h3>Connection Info</h3>
                <div className="info-item">
                  <strong>Token:</strong> <code>{token.substring(0, 16)}...</code>
                </div>
                <div className="info-item">
                  <strong>WebSocket:</strong> <code>{wsUrl}</code>
                </div>
                <div className="info-item">
                  <strong>Upload URL:</strong> <code>{uploadBaseUrl}</code>
                </div>
                <div className="info-item">
                  <strong>WS Status:</strong> 
                  <span className={wsConnected ? 'status-connected' : 'status-disconnected'}>
                    {wsConnected ? 'Connected' : 'Disconnected'}
                  </span>
                </div>
                <div className="info-item">
                  <strong>Phone Status:</strong> 
                  <span className={phoneConnected ? 'status-connected' : 'status-disconnected'}>
                    {phoneConnected ? 'Connected' : 'Disconnected'}
                  </span>
                </div>
                {readyToFinalize && (
                  <div className="info-item">
                    <span className="status-ok" style={{color: '#27ae60', fontWeight: 'bold'}}>
                      ✓ Ready to finalize mesh
                    </span>
                  </div>
                )}
              </div>
            )}
          </div>

          <div className="control-panel">
            <h2>Controls</h2>
            <div className="control-buttons">
              <button 
                onClick={() => sendControl('start')}
                className="btn btn-success"
                disabled={!wsConnected}
              >
                Start
              </button>
              <button 
                onClick={() => sendControl('stop')}
                className="btn btn-danger"
                disabled={!wsConnected}
              >
                Stop
              </button>
              <button 
                onClick={handleFinalize}
                className="btn btn-warning"
                disabled={!token}
                title={!readyToFinalize ? "Click to finalize mesh (will work even if scan not complete)" : "Finalize mesh"}
              >
                Finalize
              </button>
            </div>
          </div>

          <StatusPanel status={status} token={token} serverUrl={SERVER_URL} />
        </div>

        <div className="console-right">
          <MeshViewer token={token} serverUrl={SERVER_URL} ws={ws} />
          {/* Preview panel hidden - showing mesh generation instead for smoother experience */}
          {previewImage && (
            <div style={{display: 'none'}}>
              <PreviewPanel image={previewImage} />
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

export default OperatorConsole;
