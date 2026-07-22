#!/bin/bash

# Increment build number
PLIST="${PROJECT_DIR}/${INFOPLIST_FILE}"

if [ -f "$PLIST" ]; then
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
    NEW_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
    echo "Build: $CURRENT_BUILD → $NEW_BUILD"
fi
