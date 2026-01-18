import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  ArrowLeft,
  Copy,
  Check,
  Wifi,
  Server,
  Key,
  AlertCircle,
  Smartphone,
} from 'lucide-react';

const PairingPage: React.FC = () => {
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [token, setToken] = useState<string | null>(null);
  const [laptopIP, setLaptopIP] = useState<string>('Loading...');
  const [status, setStatus] = useState<{ message: string; type: 'error' } | null>(null);
  const [copiedToken, setCopiedToken] = useState(false);
  const [copiedIP, setCopiedIP] = useState(false);
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

        const url = new URL(data.url);
        const currentHostname = window.location.hostname;
        const ipToDisplay =
          currentHostname === 'localhost' || currentHostname === '127.0.0.1'
            ? url.hostname
            : currentHostname;
        setLaptopIP(ipToDisplay);
      } catch (error: any) {
        console.error('Error loading pairing info:', error);
        setStatus({ message: 'Failed to load pairing info: ' + error.message, type: 'error' });
      }
    };

    loadPairingInfo();
  }, []);

  const copyToClipboard = async (text: string, type: 'token' | 'ip') => {
    await navigator.clipboard.writeText(text);
    if (type === 'token') {
      setCopiedToken(true);
      setTimeout(() => setCopiedToken(false), 2000);
    } else {
      setCopiedIP(true);
      setTimeout(() => setCopiedIP(false), 2000);
    }
  };

  return (
    <div className="min-h-screen bg-animated-gradient flex items-center justify-center p-6">
      <div className="max-w-2xl w-full">
        {/* Header */}
        <div className="text-center mb-10">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-gradient-to-br from-[hsl(var(--primary))] to-[hsl(var(--accent))] mb-6">
            <Smartphone className="w-8 h-8 text-white" />
          </div>
          <h1 className="text-4xl font-bold mb-3">
            <span className="gradient-text">Device Pairing</span>
          </h1>
          <p className="text-lg text-muted-foreground max-w-md mx-auto">
            Connect your iOS device using QR code or manual entry
          </p>
        </div>

        {/* Main Card */}
        <div className="glass-card-strong rounded-3xl p-8">
          {/* QR Code Section */}
          <div className="flex flex-col items-center mb-8">
            <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider mb-6">
              Scan QR Code
            </h2>
            {qrDataUrl ? (
              <div className="qr-container pulse-glow">
                <img src={qrDataUrl} alt="QR Code" className="w-52 h-52 rounded-xl" />
              </div>
            ) : (
              <div className="w-52 h-52 rounded-2xl bg-secondary shimmer" />
            )}
          </div>

          {/* Divider */}
          <div className="flex items-center gap-4 mb-8">
            <div className="flex-1 h-px bg-border" />
            <span className="text-sm text-muted-foreground">or enter manually</span>
            <div className="flex-1 h-px bg-border" />
          </div>

          {/* Connection Info */}
          <div className="space-y-4">
            {/* Server IP */}
            <div className="glass-card rounded-2xl p-5 transition-smooth hover:border-[hsla(var(--primary),0.3)]">
              <div className="flex items-center gap-3 mb-3">
                <div className="w-10 h-10 rounded-xl bg-[hsla(var(--primary),0.15)] flex items-center justify-center">
                  <Server className="w-5 h-5 text-[hsl(var(--primary))]" />
                </div>
                <div>
                  <p className="text-xs text-muted-foreground uppercase tracking-wider">Server Address</p>
                  <p className="text-sm text-foreground">Enter this in your iOS app</p>
                </div>
              </div>
              <div className="flex items-center justify-between gap-3 bg-secondary rounded-xl px-4 py-3">
                <code className="font-mono text-lg text-[hsl(var(--primary))]">{laptopIP}:8080</code>
                <button
                  onClick={() => copyToClipboard(`${laptopIP}:8080`, 'ip')}
                  className="btn btn-ghost p-2"
                  title="Copy IP address"
                >
                  {copiedIP ? (
                    <Check className="w-4 h-4 text-[hsl(var(--success))]" />
                  ) : (
                    <Copy className="w-4 h-4" />
                  )}
                </button>
              </div>
            </div>

            {/* Session Token */}
            <div className="glass-card rounded-2xl p-5 transition-smooth hover:border-[hsla(var(--accent),0.3)]">
              <div className="flex items-center gap-3 mb-3">
                <div className="w-10 h-10 rounded-xl bg-[hsla(var(--accent),0.15)] flex items-center justify-center">
                  <Key className="w-5 h-5 text-[hsl(var(--accent))]" />
                </div>
                <div>
                  <p className="text-xs text-muted-foreground uppercase tracking-wider">Session Token</p>
                  <p className="text-sm text-foreground">Unique identifier for this session</p>
                </div>
              </div>
              <div className="flex items-center justify-between gap-3 bg-secondary rounded-xl px-4 py-3">
                <code className="font-mono text-sm text-[hsl(var(--accent))] truncate">
                  {token || 'Loading...'}
                </code>
                {token && (
                  <button
                    onClick={() => copyToClipboard(token, 'token')}
                    className="btn btn-ghost p-2 flex-shrink-0"
                    title="Copy token"
                  >
                    {copiedToken ? (
                      <Check className="w-4 h-4 text-[hsl(var(--success))]" />
                    ) : (
                      <Copy className="w-4 h-4" />
                    )}
                  </button>
                )}
              </div>
            </div>
          </div>

          {/* Tips */}
          <div className="mt-6 p-4 rounded-xl bg-[hsla(var(--primary),0.05)] border border-[hsla(var(--primary),0.1)]">
            <div className="flex items-start gap-3">
              <Wifi className="w-5 h-5 text-[hsl(var(--primary))] mt-0.5 flex-shrink-0" />
              <p className="text-sm text-muted-foreground">
                Make sure your iOS device and this computer are connected to the same Wi-Fi network for the connection to work.
              </p>
            </div>
          </div>
        </div>

        {/* Error Status */}
        {status && (
          <div className="mt-6 glass-card rounded-2xl p-4 flex items-center gap-3 border-[hsl(var(--destructive))] bg-[hsla(var(--destructive),0.1)]">
            <AlertCircle className="w-5 h-5 text-[hsl(var(--destructive))]" />
            <p className="text-[hsl(var(--destructive))]">{status.message}</p>
          </div>
        )}

        {/* Back Button */}
        <div className="text-center mt-8">
          <button onClick={() => navigate('/')} className="btn btn-secondary">
            <ArrowLeft className="w-4 h-4 mr-2" />
            Back to Dashboard
          </button>
        </div>
      </div>
    </div>
  );
};

export default PairingPage;
