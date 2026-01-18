# Quick Start Guide

## Step 1: Start Python Worker

Open a terminal and run:
```bash
cd ~/phone-mesh/worker
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python -m uvicorn app:app --host 0.0.0.0 --port 8090
```

Keep this terminal open.

## Step 2: Start Node Server

Open a **new terminal** and run:
```bash
cd ~/phone-mesh/laptop/server
npm install
npm start
```

Keep this terminal open.

## Step 3: Start React Web UI

Open a **new terminal** and run:
```bash
cd ~/phone-mesh/laptop/web
npm install
npm start
```

This will open the browser automatically at `http://localhost:3000`

## Step 4: Get a Token

1. In the browser, click **"Create New Session"**
2. Copy the token that appears (long hex string)

## Step 5: Run Test Phone Client

Open a **new terminal** and run:
```bash
cd ~/phone-mesh/test-phone-client
node index.js localhost <paste-your-token-here>
```

Example:
```bash
node index.js localhost abc123def4567890123456789012345678901234567890123456789012345678
```

## Step 6: Test the Flow

1. In the web UI, click **"Start"** - test client will begin uploading chunks
2. Watch preview frames and chunks arrive
3. Click **"Stop"** - test client will finish
4. Click **"Finalize"** - worker will create mesh

## All Commands in One Place

```bash
# Terminal 1: Worker
cd ~/phone-mesh/worker && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt && python -m uvicorn app:app --host 0.0.0.0 --port 8090

# Terminal 2: Server
cd ~/phone-mesh/laptop/server && npm install && npm start

# Terminal 3: Web UI
cd ~/phone-mesh/laptop/web && npm install && npm start

# Terminal 4: Test Client (after getting token from web UI)
cd ~/phone-mesh/test-phone-client && node index.js localhost YOUR_TOKEN_HERE
```
