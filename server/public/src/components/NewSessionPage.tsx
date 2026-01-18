import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Terminal,
  CheckCircle,
  AlertCircle,
  Info,
  Download,
  Home,
  Smartphone,
  QrCode,
  Wifi,
  ArrowRight,
  Copy,
  Check,
  Box,
} from 'lucide-react';

const NewSessionPage: React.FC = () => {
  const [token, setToken] = useState<string | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [status, setStatus] = useState<{ message: string; type: 'info' | 'success' | 'error' } | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
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
    }
  };

  const copyToken = async () => {
    if (token) {
      await navigator.clipboard.writeText(token);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    }
  };

  const getStatusIcon = () => {
    if (!status) return null;
    switch (status.type) {
      case 'success':
        return <CheckCircle className="w-5 h-5" />;
      case 'error':
        return <AlertCircle className="w-5 h-5" />;
      case 'info':
        return <Info className="w-5 h-5" />;
    }
  };

  const steps = [
    { icon: Smartphone, text: 'Open RoomScan Remote app on your iOS device' },
    { icon: QrCode, text: 'Scan this QR code or enter the token manually' },
    { icon: Wifi, text: 'Start scanning your room with RoomPlan' },
    { icon: CheckCircle, text: 'When complete, the scan will automatically upload' },
  ];

  return (
    <div className="min-h-screen bg-animated-gradient flex items-center justify-center p-6">
      <div className="max-w-4xl w-full">
        {/* Header */}
        <div className="text-center mb-10">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-gradient-to-br from-[hsl(var(--primary))] to-[hsl(var(--accent))] mb-6">
            <Box className="w-8 h-8 text-white" />
          </div>
          <h1 className="text-4xl font-bold mb-3">
            <span className="gradient-text">New Scan Session</span>
          </h1>
          <p className="text-lg text-muted-foreground max-w-md mx-auto">
            Connect your iOS device to start scanning your room
          </p>
        </div>

        <div className="grid lg:grid-cols-2 gap-6">
          {/* QR Code Card */}
          <div className="glass-card-strong rounded-3xl p-8 flex flex-col items-center">
            <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider mb-6">
              Scan to Connect
            </h2>

            {qrDataUrl ? (
              <div className="qr-container mb-6">
                <img
                  src={qrDataUrl}
                  alt="QR Code"
                  className="w-56 h-56 rounded-xl"
                />
              </div>
            ) : (
              <div className="w-56 h-56 rounded-2xl bg-secondary shimmer mb-6" />
            )}

            {/* Token Display */}
            {token && (
              <div className="w-full">
                <p className="text-xs text-muted-foreground mb-2 text-center">Session Token</p>
                <div className="glass-card rounded-xl p-4 flex items-center justify-between gap-3">
                  <code className="font-mono text-sm text-[hsl(var(--primary))] truncate flex-1">
                    {token}
                  </code>
                  <button
                    onClick={copyToken}
                    className="btn btn-ghost p-2 flex-shrink-0"
                    title="Copy token"
                  >
                    {copied ? (
                      <Check className="w-4 h-4 text-[hsl(var(--success))]" />
                    ) : (
                      <Copy className="w-4 h-4" />
                    )}
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Instructions Card */}
          <div className="glass-card-strong rounded-3xl p-8">
            <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider mb-6">
              How to Connect
            </h2>

            <div className="space-y-4 mb-8">
              {steps.map((step, index) => (
                <div key={index} className="flex items-start gap-4 group">
                  <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-[hsl(var(--primary))] to-[hsl(var(--accent))] flex items-center justify-center flex-shrink-0 opacity-80 group-hover:opacity-100 transition-opacity">
                    <span className="text-sm font-bold text-white">{index + 1}</span>
                  </div>
                  <div className="flex-1 pt-2">
                    <p className="text-foreground">{step.text}</p>
                  </div>
                </div>
              ))}
            </div>

            {/* Action Buttons */}
            <div className="space-y-3">
              <button onClick={openOperatorConsole} className="btn btn-primary w-full py-4">
                <Terminal className="w-5 h-5 mr-2" />
                Open Operator Console
                <ArrowRight className="w-4 h-4 ml-2" />
              </button>

              <button onClick={checkUpload} className="btn btn-secondary w-full py-3">
                <Info className="w-4 h-4 mr-2" />
                Check for Upload
              </button>
            </div>
          </div>
        </div>

        {/* Status Message */}
        {status && (
          <div
            className={`mt-6 glass-card rounded-2xl p-4 flex items-center gap-3 ${
              status.type === 'success'
                ? 'border-[hsl(var(--success))] bg-[hsla(var(--success),0.1)]'
                : status.type === 'info'
                ? 'border-[hsl(var(--primary))] bg-[hsla(var(--primary),0.1)]'
                : 'border-[hsl(var(--destructive))] bg-[hsla(var(--destructive),0.1)]'
            }`}
          >
            <div
              className={`${
                status.type === 'success'
                  ? 'text-[hsl(var(--success))]'
                  : status.type === 'info'
                  ? 'text-[hsl(var(--primary))]'
                  : 'text-[hsl(var(--destructive))]'
              }`}
            >
              {getStatusIcon()}
            </div>
            <p
              className={`${
                status.type === 'success'
                  ? 'text-[hsl(var(--success))]'
                  : status.type === 'info'
                  ? 'text-[hsl(var(--primary))]'
                  : 'text-[hsl(var(--destructive))]'
              }`}
            >
              {status.message}
            </p>
          </div>
        )}

        {/* Download Button */}
        {downloadUrl && (
          <a href={downloadUrl} download className="btn btn-primary w-full py-4 mt-4 glow-primary">
            <Download className="w-5 h-5 mr-2" />
            Download Room Scan
          </a>
        )}

        {/* Back Button */}
        <div className="text-center mt-8">
          <button onClick={() => navigate('/')} className="btn btn-ghost">
            <Home className="w-4 h-4 mr-2" />
            Back to Home
          </button>
        </div>
      </div>
    </div>
  );
};

export default NewSessionPage;
