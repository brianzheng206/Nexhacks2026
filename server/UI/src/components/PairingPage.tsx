import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowLeft, Copy, Check, Wifi, Server, Key, AlertCircle, Smartphone } from 'lucide-react';

export default function PairingPage() {
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [token, setToken] = useState<string | null>(null);
  const [laptopIP, setLaptopIP] = useState('Loading...');
  const [error, setError] = useState<string | null>(null);
  const [copiedToken, setCopiedToken] = useState(false);
  const [copiedIP, setCopiedIP] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    fetch('/new')
      .then(res => {
        if (!res.ok) throw new Error('Failed');
        return res.json();
      })
      .then(data => {
        setQrDataUrl(data.qrDataUrl);
        setToken(data.token);
        const url = new URL(data.url);
        const host = window.location.hostname;
        setLaptopIP(host === 'localhost' || host === '127.0.0.1' ? url.hostname : host);
      })
      .catch(e => setError(e.message));
  }, []);

  const copy = async (text: string, type: 'token' | 'ip') => {
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
      <div className="max-w-lg w-full">
        {/* Header */}
        <div className="text-center mb-10">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-gradient-to-b from-white/15 to-white/5 border border-white/10 mb-6">
            <Smartphone className="w-8 h-8 text-white/80" strokeWidth={1.5} />
          </div>
          <h1 className="text-4xl font-semibold tracking-tight mb-3">
            <span className="gradient-text">Pairing</span>
          </h1>
          <p className="text-lg text-white/40">
            Connect via QR or manual entry
          </p>
        </div>

        {/* Main Card */}
        <div className="glass-card-strong rounded-3xl p-8">
          {/* QR */}
          <div className="flex flex-col items-center mb-8">
            <p className="text-xs font-medium text-white/40 uppercase tracking-wider mb-5">Scan QR</p>
            {qrDataUrl ? (
              <div className="qr-container">
                <img src={qrDataUrl} alt="QR" className="w-44 h-44 rounded-xl" />
              </div>
            ) : (
              <div className="w-44 h-44 rounded-2xl shimmer" />
            )}
          </div>

          {/* Divider */}
          <div className="flex items-center gap-4 mb-8">
            <div className="flex-1 h-px bg-white/10" />
            <span className="text-xs text-white/30">or manually</span>
            <div className="flex-1 h-px bg-white/10" />
          </div>

          {/* Connection Info */}
          <div className="space-y-4">
            {/* Server */}
            <div className="glass rounded-2xl p-4">
              <div className="flex items-center gap-3 mb-3">
                <div className="w-9 h-9 rounded-xl bg-white/5 flex items-center justify-center">
                  <Server className="w-4 h-4 text-white/60" />
                </div>
                <div>
                  <p className="text-[10px] text-white/30 uppercase">Server</p>
                  <p className="text-sm text-white/70">Enter in iOS app</p>
                </div>
              </div>
              <div className="flex items-center justify-between gap-2 bg-black/30 rounded-xl px-4 py-3">
                <code className="font-mono text-white/80">{laptopIP}:8080</code>
                <button onClick={() => copy(`${laptopIP}:8080`, 'ip')} className="btn btn-ghost p-2">
                  {copiedIP ? <Check className="w-4 h-4 text-green-400" /> : <Copy className="w-4 h-4" />}
                </button>
              </div>
            </div>

            {/* Token */}
            <div className="glass rounded-2xl p-4">
              <div className="flex items-center gap-3 mb-3">
                <div className="w-9 h-9 rounded-xl bg-white/5 flex items-center justify-center">
                  <Key className="w-4 h-4 text-white/60" />
                </div>
                <div>
                  <p className="text-[10px] text-white/30 uppercase">Token</p>
                  <p className="text-sm text-white/70">Session identifier</p>
                </div>
              </div>
              <div className="flex items-center justify-between gap-2 bg-black/30 rounded-xl px-4 py-3">
                <code className="font-mono text-sm text-white/80 truncate">{token || '...'}</code>
                {token && (
                  <button onClick={() => copy(token, 'token')} className="btn btn-ghost p-2">
                    {copiedToken ? <Check className="w-4 h-4 text-green-400" /> : <Copy className="w-4 h-4" />}
                  </button>
                )}
              </div>
            </div>
          </div>

          {/* Tip */}
          <div className="mt-6 p-4 rounded-xl bg-white/[0.03] border border-white/5">
            <div className="flex items-start gap-3">
              <Wifi className="w-4 h-4 text-white/40 mt-0.5" />
              <p className="text-sm text-white/40">
                Both devices must be on the same Wi-Fi network.
              </p>
            </div>
          </div>
        </div>

        {/* Error */}
        {error && (
          <div className="mt-6 glass rounded-xl p-4 flex items-center gap-3 border border-red-500/30">
            <AlertCircle className="w-5 h-5 text-red-400" />
            <p className="text-red-400">{error}</p>
          </div>
        )}

        {/* Back */}
        <div className="text-center mt-8">
          <button onClick={() => navigate('/')} className="btn btn-secondary">
            <ArrowLeft className="w-4 h-4" />
            Back
          </button>
        </div>
      </div>
    </div>
  );
}
