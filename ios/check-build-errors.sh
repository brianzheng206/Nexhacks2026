#!/bin/bash

# Script to check Swift build errors
# Supports both xcodebuild (macOS) and swiftc (Linux/macOS)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project directory
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_DIR="${IOS_DIR}/RoomScanRemote"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}=== Swift Build Error Checker ===${NC}"
echo "Checking Swift files in: ${SWIFT_DIR}"
echo ""

# Find all Swift files
SWIFT_FILES=$(find "${SWIFT_DIR}" -name "*.swift" -type f | sort)

if [ -z "$SWIFT_FILES" ]; then
    echo -e "${RED}❌ No Swift files found in ${SWIFT_DIR}${NC}"
    exit 1
fi

echo -e "${BLUE}Found Swift files:${NC}"
echo "$SWIFT_FILES" | while read -r file; do
    echo "  - $(basename "$file")"
done
echo ""

ERROR_COUNT=0
WARNING_COUNT=0
CHECKED_FILES=0

# Function to check with swiftc (works on Linux and macOS)
check_with_swiftc() {
    local file="$1"
    local errors=0
    local warnings=0
    
    # Try to compile the file (syntax check only)
    # Note: This won't catch all errors without a proper module context,
    # but it will catch syntax errors and basic type errors
    if command -v swiftc &> /dev/null; then
        # Create a temporary file to check syntax
        # We use -typecheck to avoid generating output
        local output
        output=$(swiftc -typecheck -sdk "$(xcrun --show-sdk-path --sdk iphoneos 2>/dev/null || echo '')" \
            -target arm64-apple-ios17.0 \
            -import-objc-header "${SWIFT_DIR}/RoomScanRemote-Bridging-Header.h" 2>&1 || true)
        
        # If SDK path failed, try without SDK (for Linux)
        if [ $? -ne 0 ] || [ -z "$output" ]; then
            output=$(swiftc -typecheck "$file" 2>&1 || true)
        fi
        
        # Count errors and warnings
        local file_errors=$(echo "$output" | grep -c "error:" || true)
        local file_warnings=$(echo "$output" | grep -c "warning:" || true)
        
        if [ "$file_errors" -gt 0 ] || [ "$file_warnings" -gt 0 ]; then
            echo -e "${YELLOW}Checking: $(basename "$file")${NC}"
            echo "$output" | grep -E "(error|warning):" | head -20
            errors=$((errors + file_errors))
            warnings=$((warnings + file_warnings))
        fi
    fi
    
    echo "$errors $warnings"
}

# Function to check with xcodebuild (macOS only)
check_with_xcodebuild() {
    local project_file="$1"
    local scheme="$2"
    
    if [ ! -d "$project_file" ]; then
        return 1
    fi
    
    echo -e "${BLUE}Using xcodebuild to check for errors...${NC}"
    
    # Try to build and capture errors
    local build_output
    build_output=$(xcodebuild -project "$project_file" \
        -scheme "$scheme" \
        -sdk iphonesimulator \
        -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
        clean build \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO 2>&1 || true)
    
    # Extract errors
    local errors=$(echo "$build_output" | grep -E "error:" | wc -l | tr -d ' ')
    local warnings=$(echo "$build_output" | grep -E "warning:" | wc -l | tr -d ' ')
    
    if [ "$errors" -gt 0 ] || [ "$warnings" -gt 0 ]; then
        echo -e "${RED}Build Errors Found:${NC}"
        echo "$build_output" | grep -E "(error|warning):" | head -50
    fi
    
    echo "$errors $warnings"
}

# Function to do basic syntax check using Swift's frontend
check_syntax_basic() {
    local file="$1"
    local errors=0
    
    # Try to parse the file for basic syntax errors
    if command -v swift &> /dev/null; then
        # Use swift -frontend -parse for syntax checking
        local output
        output=$(swift -frontend -parse "$file" 2>&1 || true)
        
        local file_errors=$(echo "$output" | grep -c "error:" || true)
        
        if [ "$file_errors" -gt 0 ]; then
            echo -e "${YELLOW}Syntax errors in: $(basename "$file")${NC}"
            echo "$output" | grep "error:" | head -10
            errors=$file_errors
        fi
    fi
    
    echo "$errors"
}

# Main checking logic
echo -e "${BLUE}Starting build error check...${NC}"
echo ""

# Method 1: Try xcodebuild if on macOS and project exists
if [[ "$OSTYPE" == "darwin"* ]]; then
    PROJECT_FILE="${IOS_DIR}/RoomScanRemote.xcodeproj"
    if [ -d "$PROJECT_FILE" ]; then
        echo -e "${GREEN}✓ Found Xcode project, using xcodebuild${NC}"
        result=$(check_with_xcodebuild "$PROJECT_FILE" "RoomScanRemote")
        xcode_errors=$(echo "$result" | awk '{print $1}')
        xcode_warnings=$(echo "$result" | awk '{print $2}')
        ERROR_COUNT=$((ERROR_COUNT + xcode_errors))
        WARNING_COUNT=$((WARNING_COUNT + xcode_warnings))
        CHECKED_FILES=1
    fi
fi

# Method 2: Check individual files with swiftc (if available)
if command -v swiftc &> /dev/null || command -v swift &> /dev/null; then
    echo -e "${GREEN}✓ Swift compiler found, checking individual files...${NC}"
    echo ""
    
    while IFS= read -r file; do
        CHECKED_FILES=$((CHECKED_FILES + 1))
        
        # Basic syntax check
        if command -v swift &> /dev/null; then
            syntax_errors=$(check_syntax_basic "$file")
            ERROR_COUNT=$((ERROR_COUNT + syntax_errors))
        fi
        
        # More detailed check with swiftc if available
        if command -v swiftc &> /dev/null; then
            result=$(check_with_swiftc "$file")
            file_errors=$(echo "$result" | awk '{print $1}')
            file_warnings=$(echo "$result" | awk '{print $2}')
            ERROR_COUNT=$((ERROR_COUNT + file_errors))
            WARNING_COUNT=$((WARNING_COUNT + file_warnings))
        fi
    done <<< "$SWIFT_FILES"
fi

# Method 3: If no compiler found, do basic file validation
if [ "$CHECKED_FILES" -eq 0 ]; then
    echo -e "${YELLOW}⚠ No Swift compiler found (swiftc or xcodebuild)${NC}"
    echo -e "${YELLOW}Performing basic file validation...${NC}"
    echo ""
    
    while IFS= read -r file; do
        CHECKED_FILES=$((CHECKED_FILES + 1))
        
        # Check if file is readable
        if [ ! -r "$file" ]; then
            echo -e "${RED}❌ Cannot read: $(basename "$file")${NC}"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        fi
        
        # Check for common Swift syntax issues (basic regex checks)
        if grep -q "func.*{$" "$file" 2>/dev/null; then
            # Check for missing closing braces (very basic)
            open_braces=$(grep -o "{" "$file" | wc -l | tr -d ' ')
            close_braces=$(grep -o "}" "$file" | wc -l | tr -d ' ')
            if [ "$open_braces" -ne "$close_braces" ]; then
                echo -e "${YELLOW}⚠ Possible brace mismatch in: $(basename "$file")${NC}"
                WARNING_COUNT=$((WARNING_COUNT + 1))
            fi
        fi
        
        echo -e "${GREEN}✓ Checked: $(basename "$file")${NC}"
    done <<< "$SWIFT_FILES"
fi

# Summary
echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "Files checked: ${CHECKED_FILES}"
if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}Errors found: ${ERROR_COUNT}${NC}"
else
    echo -e "${GREEN}Errors found: ${ERROR_COUNT}${NC}"
fi

if [ "$WARNING_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Warnings found: ${WARNING_COUNT}${NC}"
else
    echo -e "${GREEN}Warnings found: ${WARNING_COUNT}${NC}"
fi

echo ""

# Exit with appropriate code
if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}❌ Build check failed with ${ERROR_COUNT} error(s)${NC}"
    exit 1
else
    echo -e "${GREEN}✅ Build check passed!${NC}"
    exit 0
fi
