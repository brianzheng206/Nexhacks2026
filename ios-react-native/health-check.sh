#!/bin/bash
# Health check script for React Native project

echo "🔍 React Native Project Health Check"
echo "======================================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. TypeScript Compilation
echo "1️⃣  Checking TypeScript compilation..."
if npx tsc --noEmit > /dev/null 2>&1; then
    echo -e "${GREEN}✅ TypeScript: PASSED${NC}"
else
    echo -e "${RED}❌ TypeScript: FAILED${NC}"
    npx tsc --noEmit 2>&1 | head -5
    exit 1
fi

# 2. Metro Bundler
echo ""
echo "2️⃣  Checking Metro bundler..."
if curl -s http://localhost:8081/status > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Metro bundler: RUNNING${NC}"
else
    echo -e "${YELLOW}⚠️  Metro bundler: NOT RUNNING (run 'npm start' in another terminal)${NC}"
fi

# 3. Dependencies
echo ""
echo "3️⃣  Checking dependencies..."
if npm ls --depth=0 2>&1 | grep -q "UNMET"; then
    echo -e "${RED}❌ Dependencies: MISSING${NC}"
    npm ls --depth=0 2>&1 | grep "UNMET"
else
    echo -e "${GREEN}✅ Dependencies: INSTALLED${NC}"
fi

# 4. File Structure
echo ""
echo "4️⃣  Checking file structure..."
TS_FILES=$(find src -name "*.ts" -o -name "*.tsx" 2>/dev/null | wc -l)
SWIFT_FILES=$(find ios/RoomScanRemote -name "*.swift" 2>/dev/null | wc -l)

if [ "$TS_FILES" -gt 0 ]; then
    echo -e "${GREEN}✅ TypeScript files: $TS_FILES found${NC}"
else
    echo -e "${RED}❌ No TypeScript files found${NC}"
fi

if [ "$SWIFT_FILES" -gt 0 ]; then
    echo -e "${GREEN}✅ Swift files: $SWIFT_FILES found${NC}"
else
    echo -e "${YELLOW}⚠️  No Swift files found (expected if not on Mac)${NC}"
fi

# 5. Linting
echo ""
echo "5️⃣  Checking linting..."
LINT_OUTPUT=$(npm run lint 2>&1)
LINT_ERRORS=$(echo "$LINT_OUTPUT" | grep -c "error" || echo "0")
if [ "$LINT_ERRORS" -eq 0 ]; then
    echo -e "${GREEN}✅ Linting: PASSED${NC}"
else
    echo -e "${YELLOW}⚠️  Linting: $LINT_ERRORS errors found${NC}"
fi

echo ""
echo "======================================"
echo -e "${GREEN}✅ Health check complete!${NC}"
echo ""
echo "Next steps:"
echo "  • If Metro isn't running: npm start"
echo "  • To build on Mac: cd ios && pod install"
echo "  • To test bundle: npx react-native bundle --platform ios --entry-file index.js --bundle-output /tmp/test.js"
