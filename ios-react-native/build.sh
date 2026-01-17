#!/bin/bash
# Build script for React Native iOS app
# Run this on Mac after setting up Xcode project

set -e

echo "🚀 Building RoomScan Remote (React Native)"

# Check if we're on Mac
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script must be run on macOS"
    exit 1
fi

# Check for Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode not found. Please install Xcode from the App Store"
    exit 1
fi

# Install npm dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "📦 Installing npm dependencies..."
    npm install
fi

# Install CocoaPods dependencies
if [ ! -d "ios/Pods" ]; then
    echo "📦 Installing CocoaPods dependencies..."
    cd ios
    pod install
    cd ..
fi

# Start Metro bundler in background
echo "🚇 Starting Metro bundler..."
npm start &
METRO_PID=$!

# Wait a bit for Metro to start
sleep 5

# Build and run
echo "🔨 Building iOS app..."
npm run ios

# Kill Metro when done
kill $METRO_PID 2>/dev/null || true

echo "✅ Build complete!"
