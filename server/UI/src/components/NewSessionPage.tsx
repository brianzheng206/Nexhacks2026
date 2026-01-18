import { useState, useEffect } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import {
  Terminal,
  CheckCircle,
  AlertCircle,
  Info,
  Download,
  ArrowLeft,
  Copy,
  Check,
  Box,
} from 'lucide-react';

export default function NewSessionPage() {
  const [searchParams] = useSearchParams();
  const existingToken = searchParams.get('token');
  const [token, setToken] = useState<string | null>(null);
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null);
  const [status, setStatus] = useState<{ message: string; type: 'info' | 'success' | 'error' } | null>(null);
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const navigate = useNavigate();

  useEffect(() => {
    const query = existingToken ? `?token=${encodeURIComponent(existingToken)}` : '';
    fetch(`/new${query}`)
      .then(res => res.json())
      .then(data => {
        setToken(data.token);
        setQrDataUrl(data.qrDataUrl);
      })
      .catch(() => setStatus({ message: 'Failed to create session.', type: 'error' }));
  }, [existingToken]);

  const checkUpload = async () => {
    if (!token) return setStatus({ message: 'No token', type: 'error' });
    setStatus({ message: 'Checking...', type: 'info' });
    try {
      const res = await fetch(`/download/${token}/room.usdz`, { method: 'HEAD' });
      if (res.ok) {
        setStatus({ message: 'Scan available!', type: 'success' });
        setDownloadUrl(`/download/${token}/room.usdz`);
      } else {
        setStatus({ message: 'Not ready yet...', type: 'info' });
      }
    } catch {
      setStatus({ message: 'Not ready yet...', type: 'info' });
    }
  };

  const copyToken = async () => {
    if (token) {
      await navigator.clipboard.writeText(token);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    }
  };

  const handleBack = () => {
    navigate('/');
  };

  const steps = [
    'Open RoomScan app on iOS',
    'Scan the QR code below',
    'Start scanning your room',
    'Export when complete',
  ];

  return (
    <div className="min-h-screen bg-animated-gradient flex items-center justify-center p-6">
      <div className="max-w-3xl w-full">
        {/* Header */}
        <div className="text-center mb-12">
          <div className="inline-flex items-center justify-center w-16 h-16 rounded-2xl bg-gradient-to-b from-white/15 to-white/5 border border-white/10 mb-6">
            <Box className="w-8 h-8 text-white/80" strokeWidth={1.5} />
          </div>
          <h1 className="text-4xl font-semibold tracking-tight mb-3">
            <span className="gradient-text">New Session</span>
          </h1>
          <p className="text-lg text-white/40">
            Connect your iOS device to begin
          </p>
        </div>

        <div className="grid lg:grid-cols-2 gap-6">
          {/* QR Card */}
          <div className="glass-card-strong rounded-3xl p-8 flex flex-col items-center">
            <p className="text-xs font-medium text-white/40 uppercase tracking-wider mb-6">
              Scan to Connect
            </p>
            {qrDataUrl ? (
              <div className="qr-container mb-6">
                <img src={qrDataUrl} alt="QR" className="w-48 h-48 rounded-xl" />
              </div>
            ) : (
              <div className="w-48 h-48 rounded-2xl shimmer mb-6" />
            )}
            {token && (
              <div className="w-full">
                <p className="text-[10px] text-white/30 uppercase mb-2 text-center">Token</p>
                <div className="glass rounded-xl p-3 flex items-center justify-between gap-2">
                  <code className="font-mono text-sm text-white/70 truncate flex-1">{token}</code>
                  <button onClick={copyToken} className="btn btn-ghost p-2">
                    {copied ? <Check className="w-4 h-4 text-green-400" /> : <Copy className="w-4 h-4" />}
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Instructions */}
          <div className="glass-card-strong rounded-3xl p-8">
            <p className="text-xs font-medium text-white/40 uppercase tracking-wider mb-6">
              Instructions
            </p>
            <div className="space-y-4 mb-8">
              {steps.map((step, i) => (
                <div key={i} className="flex items-center gap-4">
                  <div className="w-8 h-8 rounded-full bg-white/10 flex items-center justify-center text-sm font-medium text-white/70">
                    {i + 1}
                  </div>
                  <p className="text-white/80">{step}</p>
                </div>
              ))}
            </div>

            <div className="space-y-3">
              <button onClick={() => token && navigate(`/?token=${token}`)} className="btn btn-primary w-full py-3.5">
                <Terminal className="w-4 h-4" />
                Open Console
              </button>
              <button onClick={checkUpload} className="btn btn-secondary w-full py-3">
                <Info className="w-4 h-4" />
                Check Upload
              </button>
            </div>
          </div>
        </div>

        {/* Status */}
        {status && (
          <div className={`mt-6 glass rounded-xl p-4 flex items-center gap-3 ${
            status.type === 'success' ? 'border border-green-500/30' :
            status.type === 'error' ? 'border border-red-500/30' : ''
          }`}>
            {status.type === 'success' && <CheckCircle className="w-5 h-5 text-green-400" />}
            {status.type === 'error' && <AlertCircle className="w-5 h-5 text-red-400" />}
            {status.type === 'info' && <Info className="w-5 h-5 text-white/50" />}
            <p className={
              status.type === 'success' ? 'text-green-400' :
              status.type === 'error' ? 'text-red-400' : 'text-white/60'
            }>{status.message}</p>
          </div>
        )}

        {downloadUrl && (
          <a href={downloadUrl} download className="btn btn-primary w-full py-4 mt-4 glow-primary">
            <Download className="w-5 h-5" />
            Download Scan
          </a>
        )}

        <div className="text-center mt-8">
          <button onClick={handleBack} className="btn btn-ghost">
            <ArrowLeft className="w-4 h-4" />
            Back
          </button>
        </div>
      </div>
    </div>
  );
}
