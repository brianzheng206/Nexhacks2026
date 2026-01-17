import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';

const PairingPage: React.FC = () => {
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [token, setToken] = useState<string | null>(null);
  const [laptopIP, setLaptopIP] = useState<string>('Loading...');
  const [status, setStatus] = useState<{ message: string; type: 'error' } | null>(null);
  const navigate = useNavigate();

  useEffect(() => {
    const loadPairingInfo = async () => {
      try {
        const response = await fetch('/new');
        if (!response.ok) {
          throw new Error('Failed to load pairing info');
        }

        const data = await response.json();
        setQrDataUrl(data.qrDataUrl);
        setToken(data.token);
        
        // Extract laptop IP from data.url (which contains the full URL with IP)
        const url = new URL(data.url);
        // Use window.location.hostname for robustness, and provide a fallback/hint
        const currentHostname = window.location.hostname;
        const ipToDisplay = currentHostname === 'localhost' || currentHostname === '127.0.0.1'
          ? `Your local IP (e.g., ${url.hostname})` // Hint with the IP from the generated URL
          : currentHostname;
        setLaptopIP(ipToDisplay);

      } catch (error: any) {
        console.error('Error loading pairing info:', error);
        setStatus({ message: 'Failed to load pairing info: ' + error.message, type: 'error' });
      }
    };

    loadPairingInfo();
  }, []);

  return (
    <div className="flex flex-col items-center justify-center min-h-screen bg-gradient-to-br from-indigo-500 to-purple-600 p-5 font-sans">
      <div className="container bg-white rounded-2xl p-10 max-w-2xl w-full shadow-2xl text-center">
        <h1 className="text-gray-800 mb-3 text-3xl font-bold">📱 Pairing</h1>
        <p className="text-gray-600 mb-8 text-base">Scan this QR code with your iOS device</p>
        
        {qrDataUrl && (
          <div className="qr-container my-6">
            <img src={qrDataUrl} alt="QR Code" className="max-w-full rounded-lg shadow-md mx-auto" />
          </div>
        )}

        <div className="info-section bg-gray-100 p-6 rounded-lg my-5 text-left">
          <h3 className="text-gray-800 mb-3 text-xl font-semibold">Connection Info</h3>
          <div className="info-item mb-2 text-gray-700">
            <strong className="text-gray-800">Laptop IP:</strong> <span className="font-mono">{laptopIP}</span>
          </div>
          <div className="info-item mb-2 text-gray-700">
            <strong className="text-gray-800">Token:</strong>
          </div>
          <div className="token-display bg-blue-50 p-4 rounded-lg my-3 break-all font-mono text-sm text-blue-800 border border-blue-200">
            {token || 'Loading...'}
          </div>
        </div>

        <button
          className="button bg-gradient-to-r from-indigo-500 to-purple-600 text-white border-none py-3 px-6 text-lg rounded-lg cursor-pointer w-full mt-5 transition transform hover:-translate-y-0.5 hover:shadow-lg"
          onClick={() => navigate('/')}
        >
          Back to Home
        </button>

        {status && (
          <div className="status mt-5 p-4 rounded-lg bg-red-100 text-red-700 border border-red-300">
            {status.message}
          </div>
        )}
      </div>
    </div>
  );
};

export default PairingPage;