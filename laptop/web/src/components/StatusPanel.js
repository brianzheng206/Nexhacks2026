import React, { useEffect, useState } from 'react';
import './StatusPanel.css';

function StatusPanel({ status, token, serverUrl }) {
  const [meshStatus, setMeshStatus] = useState(null);

  useEffect(() => {
    if (!token) return;

    const fetchMeshStatus = async () => {
      try {
        // Use debug endpoint to get mesh status
        const response = await fetch(`${serverUrl}/debug/session?token=${token}`);
        if (response.ok) {
          const data = await response.json();
          setMeshStatus({
            exists: data.meshExists,
            size: data.meshSize
          });
        }
      } catch (error) {
        // Silently fail - mesh might not exist yet
      }
    };

    fetchMeshStatus();
    const interval = setInterval(fetchMeshStatus, 2000);
    return () => clearInterval(interval);
  }, [token, serverUrl]);

  return (
    <div className="status-panel">
      <h2>Status</h2>
      <div className="status-content">
        <div className="status-item">
          <label>Last Instruction:</label>
          <div className="status-value">{status.lastInstruction || 'None'}</div>
        </div>
        <div className="status-item">
          <label>Frames Captured:</label>
          <div className="status-value status-number">{status.framesCaptured}</div>
        </div>
        <div className="status-item">
          <label>Chunks Uploaded:</label>
          <div className="status-value status-number">{status.chunksUploaded}</div>
        </div>
        <div className="status-item">
          <label>Depth OK:</label>
          <div className={`status-value status-badge ${status.depthOk ? 'status-ok' : 'status-error'}`}>
            {status.depthOk ? 'Yes' : 'No'}
          </div>
        </div>
        {meshStatus && (
          <div className="status-item">
            <label>Mesh Status:</label>
            <div className="status-value">
              {meshStatus.exists ? (
                <span className="status-ok">
                  Available
                  {meshStatus.size && ` (${(meshStatus.size / 1024).toFixed(1)} KB)`}
                </span>
              ) : (
                <span className="status-error">Not available</span>
              )}
            </div>
          </div>
        )}
        {status.lastChunkId && (
          <div className="status-item">
            <label>Last Chunk:</label>
            <div className="status-value status-number">{status.lastChunkId}</div>
          </div>
        )}
        {status.triangles && (
          <div className="status-item">
            <label>Triangles:</label>
            <div className="status-value status-number">{status.triangles.toLocaleString()}</div>
          </div>
        )}
      </div>
    </div>
  );
}

export default StatusPanel;
