#!/bin/bash
# generate_changelog.sh - Generates CHANGELOG.md from Git commit history
# Author: CajunJon
# Version: 0.1.0
# Last Modified: 2025-09-13

if [[ "$1" == "--help" ]]; then
    echo "Usage: $0"
    echo ""
    echo "Generates CHANGELOG.md from Git commit history."
    echo "No arguments required."
    exit 0
fi

CHANGELOG_FILE="CHANGELOG.md"

echo "# Changelog" > "$CHANGELOG_FILE"
echo "" >> "$CHANGELOG_FILE"
echo "Generated on $(date '+%Y-%m-%d %H:%M:%S')" >> "$CHANGELOG_FILE"
echo "" >> "$CHANGELOG_FILE"

git log --pretty=format:"- %ad: %s (%h)" --date=short >> "$CHANGELOG_FILE"

echo "CHANGELOG.md updated."
