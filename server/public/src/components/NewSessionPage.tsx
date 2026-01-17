import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';

const NewSessionPage: React.FC = () => {
  const [token, setToken] = useState<string | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [status, setStatus] = useState<{ message: string; type: 'info' | 'success' | 'error' } | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const navigate = useNavigate();

  useEffect(() => {
    const fetchNewSession = async () => {
      try {
        const response = await fetch('/new');
        const data = await response.json();
        setToken(data.token);
        setQrDataUrl(data.qrDataUrl);
      } catch (error) {
        setStatus({ message: 'Failed to create a new session.', type: 'error' });
      }
    };

    fetchNewSession();
  }, []);

  const checkUpload = async () => {
    if (!token) {
      setStatus({ message: 'No token available', type: 'error' });
      return;
    }

    try {
      setStatus({ message: 'Checking for uploaded file...', type: 'info' });
      const response = await fetch(`/download/${token}/room.usdz`, { method: 'HEAD' });

      if (response.ok) {
        setStatus({ message: 'Room scan is available!', type: 'success' });
        setDownloadUrl(`/download/${token}/room.usdz`);
      } else {
        setStatus({ message: 'No upload found yet. Waiting for scan...', type: 'info' });
      }
    } catch (error) {
      setStatus({ message: 'No upload found yet. Waiting for scan...', type: 'info' });
    }
  };

  const openOperatorConsole = () => {
    if (token) {
      navigate(`/?token=${token}`);
    } else {
      alert('No token available');
    }
  };

  return (
    <div className="container bg-white rounded-2xl p-10 max-w-3xl w-full shadow-lg text-center">
      <h1 className="text-gray-800 mb-2 text-3xl font-bold">📱 New Scan Session</h1>
      <p className="text-gray-600 mb-6 text-base">Share this QR code with your iOS device to start scanning</p>

      {token && (
        <div className="token-display bg-gray-100 p-4 rounded-lg mb-5 break-all font-mono text-sm text-left">
          <div className="token-label font-bold text-gray-800 mb-1 text-sm">Session Token:</div>
          <div>{token}</div>
        </div>
      )}

      {qrDataUrl && (
        <div className="qr-container text-center my-6">
          <img src={qrDataUrl} alt="QR Code" className="max-w-full rounded-lg shadow-md mx-auto" />
        </div>
      )}

      <div className="instructions bg-blue-100 p-5 rounded-lg my-5 border-l-4 border-blue-500 text-left">
        <h3 className="text-gray-800 mb-2 text-xl font-semibold">How to use:</h3>
        <ol className="ml-5 text-gray-700 list-decimal list-inside">
          <li>Open the RoomScan Remote app on your iOS device</li>
          <li>Scan this QR code or enter the token manually</li>
          <li>Start scanning your room with RoomPlan</li>
          <li>When complete, the scan will automatically upload</li>
        </ol>
      </div>

      <button
        className="button bg-gradient-to-r from-indigo-500 to-purple-600 text-white border-none py-3 px-6 text-lg rounded-lg cursor-pointer w-full mb-3 transition transform hover:-translate-y-0.5 hover:shadow-lg"
        onClick={openOperatorConsole}
      >
        Open Operator Console
      </button>
      <button
        className="button bg-gray-500 text-white border-none py-3 px-6 text-lg rounded-lg cursor-pointer w-full mb-3 transition transform hover:-translate-y-0.5 hover:shadow-lg"
        onClick={checkUpload}
      >
        Check for Upload
      </button>
      <button
        className="button bg-gray-500 text-white border-none py-3 px-6 text-lg rounded-lg cursor-pointer w-full mb-3 transition transform hover:-translate-y-0.5 hover:shadow-lg"
        onClick={() => navigate('/')}
      >
        Back to Home
      </button>

      {status && (
        <div
          className={`status mt-5 p-4 rounded-lg ${
            status.type === 'success' ? 'bg-green-100 text-green-700 border border-green-300' :
            status.type === 'info' ? 'bg-blue-100 text-blue-700 border border-blue-300' :
            'bg-red-100 text-red-700 border border-red-300'
          }`}
        >
          {status.message}
        </div>
      )}

      {downloadUrl && (
        <a className="download-link block mt-5 p-4 bg-gray-100 rounded-lg text-center no-underline text-indigo-500 font-bold hover:text-indigo-600" href={downloadUrl} download>
          Download Room Scan
        </a>
      )}
    </div>
  );
};

export default NewSessionPage;