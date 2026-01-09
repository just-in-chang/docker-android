#!/bin/bash
# Input password via ADB for secure screens that VNC can't capture

ADB_TARGET="${ADB_TARGET:-localhost:5555}"

# Connect to emulator if not already connected
adb connect "$ADB_TARGET" 2>/dev/null

# Check connection
if ! adb -s "$ADB_TARGET" get-state >/dev/null 2>&1; then
    echo "Error: Cannot connect to $ADB_TARGET"
    echo "Make sure the emulator is running and ADB port is exposed."
    exit 1
fi

# Prompt for password (hidden input)
echo -n "Enter password: "
read -s PASSWORD
echo ""

if [ -z "$PASSWORD" ]; then
    echo "Error: Password cannot be empty"
    exit 1
fi

# Escape special characters for shell input
# ADB input text has issues with some special chars, so we use base64 + keyevents for complex passwords
if [[ "$PASSWORD" =~ [^a-zA-Z0-9] ]]; then
    echo "Password contains special characters, using character-by-character input..."
    for (( i=0; i<${#PASSWORD}; i++ )); do
        char="${PASSWORD:$i:1}"
        # Use input text for each character
        adb -s "$ADB_TARGET" shell input text "'$char'" 2>/dev/null || \
        adb -s "$ADB_TARGET" shell input text "$char"
    done
else
    # Simple password, use direct input
    adb -s "$ADB_TARGET" shell input text "$PASSWORD"
fi

echo "Password entered."

# Ask if user wants to press Enter
echo -n "Press Enter/Submit? [Y/n]: "
read -r SUBMIT
if [[ ! "$SUBMIT" =~ ^[Nn]$ ]]; then
    adb -s "$ADB_TARGET" shell input keyevent 66
    echo "Enter pressed."
fi

echo "Done!"
