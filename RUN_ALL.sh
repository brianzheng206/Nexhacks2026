#!/bin/bash
# Quick start script for room-scan-tsdf

echo "=== Room Scan TSDF - Quick Start ==="
echo ""
echo "This script will help you start all services."
echo "You'll need 4 terminal windows/tabs."
echo ""

# Check if we're in the right directory
if [ ! -d "worker" ] || [ ! -d "laptop" ]; then
    echo "Error: Please run this from the phone-mesh directory"
    exit 1
fi

echo "=== Terminal 1: Python Worker ==="
echo "Run these commands:"
echo "  cd ~/phone-mesh/worker"
echo "  source venv/bin/activate"
echo "  python -m uvicorn app:app --host 0.0.0.0 --port 8090"
echo ""

echo "=== Terminal 2: Node Server ==="
echo "Run these commands:"
echo "  cd ~/phone-mesh/laptop/server"
echo "  npm install"
echo "  npm start"
echo ""

echo "=== Terminal 3: React Web UI ==="
echo "Run these commands:"
echo "  cd ~/phone-mesh/laptop/web"
echo "  npm install"
echo "  npm start"
echo ""

echo "=== Terminal 4: Test Phone Client ==="
echo "After the web UI opens:"
echo "  1. Click 'Create New Session' to get a token"
echo "  2. Run these commands:"
echo "     cd ~/phone-mesh/test-phone-client"
echo "     node index.js localhost YOUR_TOKEN_HERE"
echo ""

echo "Press Enter when ready to continue..."
read
