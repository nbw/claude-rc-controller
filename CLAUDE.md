# claude-rc-controller

macOS menu bar app that keeps `claude remote-control` servers running per repo.
Plan: `docs/plan/01-menu-bar-app.md` (read it before changing anything).

## Commands
- `scripts/check.sh`: format lint, RCCore tests, project generation, app build.
- `cd Packages/RCCore && swift test`: logic tests only.

## Rules
- All logic in `RCCore`, tested first. The app target holds views and system integrations only.
- No test starts the real `claude`. Use fake launchers or stub scripts.
- Do not launch the built app, and do not run `launchctl`, `kill` or `pkill` against `claude` processes, before plan step 7.
- No third-party dependencies.
