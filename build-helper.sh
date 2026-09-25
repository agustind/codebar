#!/bin/sh
# Rebuild the universal pty helper that src/main.js runs Claude Code inside.
set -e
cd "$(dirname "$0")"
mkdir -p src/bin
cc -O2 -Wall -arch arm64 -arch x86_64 -o src/bin/pty-helper native/pty-helper.c
echo "built src/bin/pty-helper"
