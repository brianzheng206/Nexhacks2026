#!/bin/bash

# Swift Build Error Checker
# 
# This script checks all Swift files in the RoomScanRemote directory for build errors.
# It works on both Linux/WSL and macOS.
#
# Usage:
#   ./check-swift-syntax.sh
#
# The script will:
# - Check all .swift files for syntax errors
# - Validate brace/parenthesis/bracket matching
# - Use swiftc to check compilation errors (if available)
# - Filter out expected framework import errors on Linux
# - Report real compilation errors that need fixing
#
# Exit codes:
#   0 - No errors found
#   1 - Errors found

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_DIR="${IOS_DIR}/RoomScanRemote"

echo -e "${BLUE}=== Swift Syntax Checker ===${NC}"
echo "Checking: ${SWIFT_DIR}"
echo ""

# Find all Swift files
SWIFT_FILES=$(find "${SWIFT_DIR}" -name "*.swift" -type f | sort)

if [ -z "$SWIFT_FILES" ]; then
    echo -e "${RED}❌ No Swift files found${NC}"
    exit 1
fi

ERROR_COUNT=0
WARNING_COUNT=0
TOTAL_FILES=0

# Check each Swift file
while IFS= read -r file; do
    TOTAL_FILES=$((TOTAL_FILES + 1))
    filename=$(basename "$file")
    
    echo -e "${BLUE}Checking: ${filename}${NC}"
    
    # Check 1: File is readable
    if [ ! -r "$file" ]; then
        echo -e "  ${RED}❌ Cannot read file${NC}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    
    # Check 2: Basic brace matching
    open_braces=$(grep -o "{" "$file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    close_braces=$(grep -o "}" "$file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    open_parens=$(grep -o "(" "$file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    close_parens=$(grep -o ")" "$file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    open_brackets=$(grep -o "\[" "$file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    close_brackets=$(grep -o "\]" "$file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    
    if [ "$open_braces" -ne "$close_braces" ]; then
        echo -e "  ${RED}❌ Brace mismatch: {=$open_braces }=$close_braces${NC}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    if [ "$open_parens" -ne "$close_parens" ]; then
        echo -e "  ${RED}❌ Parenthesis mismatch: (=$open_parens )=$close_parens${NC}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    if [ "$open_brackets" -ne "$close_brackets" ]; then
        echo -e "  ${RED}❌ Bracket mismatch: [=$open_brackets ]=$close_brackets${NC}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    
    # Check 3: Common Swift syntax issues
    # Check for unterminated strings (basic check)
    if grep -q '"[^"]*$' "$file" 2>/dev/null && ! grep -q '"[^"]*"[^"]*$' "$file" 2>/dev/null; then
        # This is a very basic check and may have false positives
        line_num=$(grep -n '"[^"]*$' "$file" | head -1 | cut -d: -f1 || echo "")
        if [ -n "$line_num" ]; then
            echo -e "  ${YELLOW}⚠ Possible unterminated string around line $line_num${NC}"
            WARNING_COUNT=$((WARNING_COUNT + 1))
        fi
    fi
    
    # Check 4: Try swiftc if available (best method)
    if command -v swiftc &> /dev/null; then
        # Try to type-check the file
        # Note: This may fail due to missing imports/dependencies, but will catch syntax errors
        swiftc_output=$(swiftc -typecheck "$file" 2>&1 || true)
        
        # Filter out expected errors on Linux (iOS frameworks not available)
        # These are framework import errors, not syntax errors
        real_errors=$(echo "$swiftc_output" | grep "error:" | grep -v "no such module" | \
            grep -v "is unavailable" | grep -v "has moved to" || true)
        
        # Count real syntax/logic errors (not missing framework errors)
        if [ -z "$real_errors" ]; then
            real_error_count=0
        else
            real_error_count=$(echo "$real_errors" | grep -c "error:" || echo "0")
        fi
        
        framework_error_count=$(echo "$swiftc_output" | grep "error:" | grep -E "(no such module|is unavailable|has moved to)" | wc -l | tr -d ' ' || echo "0")
        
        # Ensure counts are numeric
        real_error_count=${real_error_count:-0}
        framework_error_count=${framework_error_count:-0}
        
        if [ "$real_error_count" -gt 0 ]; then
            echo -e "  ${RED}❌ Compilation errors (excluding framework issues):${NC}"
            echo "$real_errors" | sed 's/^/    /' | head -10
            ERROR_COUNT=$((ERROR_COUNT + real_error_count))
        elif [ "$framework_error_count" -gt 0 ]; then
            # Only show framework errors as warnings on Linux
            if [[ "$OSTYPE" != "darwin"* ]]; then
                echo -e "  ${YELLOW}⚠ Framework import errors (expected on Linux): $framework_error_count${NC}"
                WARNING_COUNT=$((WARNING_COUNT + framework_error_count))
            else
                # On macOS, framework errors are real errors
                echo -e "  ${RED}❌ Framework import errors:${NC}"
                echo "$swiftc_output" | grep "error:" | grep -E "(no such module|is unavailable|has moved to)" | sed 's/^/    /' | head -5
                ERROR_COUNT=$((ERROR_COUNT + framework_error_count))
            fi
        fi
        
        if echo "$swiftc_output" | grep -q "warning:"; then
            warning_count=$(echo "$swiftc_output" | grep -c "warning:" || echo "0")
            if [ "$warning_count" -gt 0 ]; then
                echo -e "  ${YELLOW}⚠ Warnings found: $warning_count${NC}"
                WARNING_COUNT=$((WARNING_COUNT + warning_count))
            fi
        fi
    fi
    
    # If no errors found with basic checks
    if [ "$ERROR_COUNT" -eq 0 ] || [ "$TOTAL_FILES" -eq 1 ]; then
        if ! command -v swiftc &> /dev/null || ! echo "$swiftc_output" | grep -q "error:"; then
            echo -e "  ${GREEN}✓ No syntax errors detected${NC}"
        fi
    fi
    
    echo ""
done <<< "$SWIFT_FILES"

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "Files checked: ${TOTAL_FILES}"
if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}Errors: ${ERROR_COUNT}${NC}"
else
    echo -e "${GREEN}Errors: ${ERROR_COUNT}${NC}"
fi

if [ "$WARNING_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Warnings: ${WARNING_COUNT}${NC}"
else
    echo -e "${GREEN}Warnings: ${WARNING_COUNT}${NC}"
fi

echo ""

if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${RED}❌ Check failed with ${ERROR_COUNT} error(s)${NC}"
    exit 1
else
    echo -e "${GREEN}✅ All checks passed!${NC}"
    exit 0
fi
