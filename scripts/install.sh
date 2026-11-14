#!/bin/sh
# Builds a Release copy and installs it to /Applications. Does NOT launch the app
# (see docs/plan/01-menu-bar-app.md, step 7, for the switch-over procedure).
set -e
cd "$(dirname "$0")/.."

APP_NAME="Claude RC Controller"
APP_ID="com.nbw.claude-rc-controller"
DEST="/Applications/$APP_NAME.app"

xcodegen generate
xcodebuild -project ClaudeRCController.xcodeproj -scheme ClaudeRCController \
  -configuration Release -derivedDataPath build build

# Quit a running copy politely, so it runs stopAll(). Never pkill it.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  osascript -e "quit app id \"$APP_ID\"" || true
  tries=0
  while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      echo "The running copy did not quit within 30 seconds. Quit it by hand and rerun." >&2
      exit 1
    fi
    sleep 1
  done
fi

rm -rf "$DEST"
ditto "build/Build/Products/Release/$APP_NAME.app" "$DEST"
echo "Installed $DEST. Not launched; use: open \"$DEST\""
