#!/bin/sh
# Runs from anywhere; always works from the repo root. Stops on first failure.
set -e
cd "$(dirname "$0")/.."
swiftformat --lint .
(cd Packages/RCCore && swift test)
xcodegen generate
xcodebuild -project ClaudeRCController.xcodeproj -scheme ClaudeRCController \
  -configuration Debug -derivedDataPath build build
