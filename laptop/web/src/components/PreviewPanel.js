import React from 'react';
import './PreviewPanel.css';

function PreviewPanel({ image }) {
  return (
    <div className="preview-panel">
      <h2>Live Preview</h2>
      <div className="preview-container">
        {image ? (
          <img 
            src={image} 
            alt="Live preview from phone"
            className="preview-image"
          />
        ) : (
          <div className="preview-placeholder">
            <p>Waiting for preview frames...</p>
            <p className="preview-hint">Connect phone to see live preview</p>
          </div>
        )}
      </div>
    </div>
  );
}

export default PreviewPanel;
