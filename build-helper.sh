#!/bin/sh
# Rebuild the universal pty helper that src/main.js runs Claude Code inside.
set -e
cd "$(dirname "$0")"
mkdir -p src/bin
cc -O2 -Wall -arch arm64 -arch x86_64 -o src/bin/pty-helper native/pty-helper.c
# tinyjs signs only its own binaries; notarization needs this one signed too
# (Developer ID, hardened runtime, secure timestamp).
IDENTITY=$(sed -n 's/.*"signIdentity": *"\([^"]*\)".*/\1/p' tinyjs.json)
codesign --force --options runtime --timestamp --sign "$IDENTITY" src/bin/pty-helper
echo "built src/bin/pty-helper"
