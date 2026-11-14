# Plan 01: claude-rc-controller menu bar app

## Goal

A small macOS menu bar app that keeps a Claude Code Remote Control server
(`claude remote-control`) running in each repo on a user-editable list, starts
at login, and replaces the current launchd script.

Single user, built and run locally. No distribution, notarization or App Store.

## Background: what exists today

A launchd agent does this job now. The app replaces it (step 7).

- `~/Library/LaunchAgents/com.claude.remote-control.plist` runs
  `/bin/zsh -ilc 'exec "$HOME/.claude/remote-control/start.sh"'` at login. It
  has `RunAtLoad` and `KeepAlive`, so it comes back at every login until the
  plist is moved away.
- `~/.claude/remote-control/start.sh` reads `dirs.txt` (one directory per line,
  `#` comments, `~` allowed) and loops `claude remote-control` in each
  directory, restarting 30 seconds after an exit.
- `~/.claude/remote-control/dirs.txt` currently lists
  `~/github.com/nbw/q` and `~/github.com/nbw/slice_osx/stitch`.

**These servers are live and in use while you implement this plan. Do not
stop, restart or duplicate them before step 7.**

## Verified facts about `claude remote-control`

Observed on this machine with Claude Code 2.1.325, macOS 26.5. Build on these;
do not re-derive them, and do not start a real server to check them.

- **Runs without a terminal.** With stdin from `/dev/null` and output to a
  file it connects and stays up.
- **Binary path.** Use `$HOME/.local/bin/claude` (a symlink to the installed
  version). Do not rely on `claude` from `PATH`: in an interactive zsh it
  resolves to a mise shim (`~/.local/share/mise/shims/claude`), which may not
  be the process that ends up running.
- **Needs the user's interactive shell environment.** `PATH` for tools is set
  in `~/.zshrc`, so launch through `/bin/zsh -ilc`. That shell prints noise
  on stderr on this machine, for example `(eval):1: can't change option: zle`
  and `mise WARN  missing: rust@stable`.
- **Status output.** It prints `Connecting · q · main`, then a block that it
  re-prints every few seconds using ANSI cursor codes (`ESC[1A`, `ESC[7A`,
  `ESC[J`) and OSC 8 hyperlinks:

  ```
  ·✔︎· Connected · q · main
      Capacity: 1/32 · New sessions will be created in the current directory
  Continue coding in the Claude mobile app or https://claude.ai/code?environment=env_01AYJsf2oB2Mja4hXbJnT6TD
  ```

  Which of stdout or stderr carries the block was not checked, so read both
  merged. It may also print a one-off `[bridge] …` warning line first.
- **`Capacity: N/32`** is the number of live sessions under the server. A
  fresh server pre-creates one session, so it shows `0/32` for a moment and
  then `1/32` while idle. N is therefore not "sessions the user is using".
- **Untrusted folder.** Exits at once with code 1 and, on stderr:
  `Error: Workspace not trusted. Please run `claude` in <path> first to review and accept the workspace trust dialog.`
  Retrying cannot fix this; the user must run `claude` in the folder once.
- **Duplicate server.** A second server in a folder that already has one
  prints, on stderr,
  `Error: This folder is already served by a terminal `claude remote-control` on this device. Stop it first.`
  then `Exiting in about 70 seconds.` and exits after that delay.
- **Shutdown.** SIGTERM stops the server within 3 seconds.
- **Sessions are child processes** of the server (their command line contains
  `--sdk-url`). Stopping a server ends its sessions.
- **Exit code 69** was seen once from a healthy server; a plain restart
  recovered. Treat unknown non-zero exits as retryable.
- **Exit code 127** from `zsh -c` means the binary was not found.
- **Flags used here:** `--spawn worktree` (each new session gets its own git
  worktree; default is `same-dir`). Nothing else is needed.

Not verified: behaviour across sleep/wake and network loss. The restart loop
is the safety net; do not add special handling.

### Captured fixtures (already in the repo)

Real output, with the escape bytes, is in
`Packages/RCCore/Tests/RCCoreTests/Fixtures/`:

- `connected.txt`: a server starting in `q`: bridge warning, `Connecting`,
  `Connected`, `Capacity: 0/32` then `1/32`, the environment URL, OSC 8
  session links, repeated repaints.
- `untrusted.txt`: the "Workspace not trusted" error.
- `already-served.txt`: the duplicate-server error.

Use these in parser tests. Do not regenerate them.

## Toolchain

- Xcode 26.5, Swift 6.3, `xcodegen` and `swiftformat` are installed
  (Homebrew). `swiftlint` is not installed; do not add it.
- Deployment target macOS 14. Swift language mode 5 for every target.
- Tests use XCTest.
- The Xcode project is generated from `project.yml` by `xcodegen` and is not
  committed.
- Ad-hoc code signing, no sandbox, hardened runtime off.
- No third-party dependencies.

## Layout

```
claude-rc-controller/
  CLAUDE.md                    short: what this is, commands, the rules below
  .gitignore                   build/, .build/, *.xcodeproj, .DS_Store
  .swiftformat
  project.yml
  Packages/RCCore/             local Swift package, no UI imports
    Package.swift
    Sources/RCCore/
    Tests/RCCoreTests/
      Fixtures/                (exists)
  App/                         SwiftUI app target (thin)
    ClaudeRCControllerApp.swift
    AppDelegate.swift
    Views/
  scripts/
    check.sh
    install.sh
  docs/plan/
```

All logic lives in `RCCore` and is tested with `swift test`. The app target
holds views and the three system integrations (login item, notifications,
folder picker) and has no tests of its own.

### File contents to use

`Packages/RCCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RCCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "RCCore", targets: ["RCCore"])],
    targets: [
        .target(name: "RCCore"),
        .testTarget(
            name: "RCCoreTests",
            dependencies: ["RCCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
```

`project.yml`:

```yaml
name: ClaudeRCController
options:
  bundleIdPrefix: com.nbw
  deploymentTarget:
    macOS: "14.0"
packages:
  RCCore:
    path: Packages/RCCore
targets:
  ClaudeRCController:
    type: application
    platform: macOS
    sources: [App]
    dependencies:
      - package: RCCore
    scheme: {}
    settings:
      base:
        PRODUCT_NAME: Claude RC Controller
        PRODUCT_BUNDLE_IDENTIFIER: com.nbw.claude-rc-controller
        SWIFT_VERSION: "5"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        ENABLE_HARDENED_RUNTIME: NO
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
```

There is no hand-written `Info.plist`.

`.swiftformat`:

```
--swiftversion 5
--exclude build,.build,**/.build
```

`scripts/check.sh` runs, from the repo root, stopping on the first failure:

```sh
swiftformat --lint .
(cd Packages/RCCore && swift test)
xcodegen generate
xcodebuild -project ClaudeRCController.xcodeproj -scheme ClaudeRCController \
  -configuration Debug -derivedDataPath build build
```

If `xcodebuild` cannot find the scheme, fix `project.yml` (do not hand-edit
the generated project).

## Rules

- Tests first for everything in `RCCore`. `scripts/check.sh` must pass before a
  step is done. Commit after each step.
- No test starts the real `claude`. Tests use a fake launcher or a stub shell
  script.
- **Steps 1 to 6 build only. Never launch the built app before step 7.** A
  launched copy would import `dirs.txt` and start servers that collide with
  the running launchd ones.
- Never run `launchctl`, `kill` or `pkill` against `claude` processes or the
  `com.claude.remote-control` job before step 7.

## RCCore design

### Model

```swift
struct Repo: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String          // absolute, tilde expanded, no trailing slash
    var enabled: Bool         // false = listed but not served
    var worktreeMode: Bool    // true adds `--spawn worktree`
}

enum ServerStatus: Equatable {
    case stopped                               // not running, not wanted
    case starting                              // process up, not yet connected
    case connected(sessions: Int, url: URL?)   // from Capacity and environment URL
    case stopping                              // SIGTERM sent, waiting for exit
    case retrying(attempt: Int, at: Date, lastError: String)
    case untrusted                             // will not retry by itself
}
```

`untrusted` is the only state that does not retry. A missing directory, a
missing binary and a duplicate server all go to `retrying` with a clear
`lastError`, because each can fix itself (a volume mounts, the other server
stops).

### RepoStore

- Reads and writes `~/Library/Application Support/claude-rc-controller/repos.json`
  (file URL injected for tests). Atomic writes. Creates the directory.
- `add(path:)` normalizes the path (expand `~`, standardize, strip trailing
  slash) and rejects a path already in the list or one that is not a
  directory. New repos are `enabled: true, worktreeMode: false`.
- `remove(id:)`, `setEnabled(id:_:)`, `setWorktreeMode(id:_:)`.
- First run only (no `repos.json`): import from
  `~/.claude/remote-control/dirs.txt` if it exists (path injected for tests),
  with the same parsing as `start.sh`: strip `#` comments and surrounding
  whitespace, skip blanks, expand `~`. Then write `repos.json` at once, even
  if the result is empty, so the import never runs twice.
- A corrupt `repos.json` is moved aside to `repos.json.corrupt-<timestamp>`
  and the store starts empty; never crash on it.

### OutputParser

A small stateful type fed raw `Data` chunks; returns events.

- Buffer raw bytes and split on `\n` or `\r`. Decode each complete line as
  UTF-8 (lossy). Never decode a partial chunk: multi-byte characters such as
  `✔︎` can be split across chunks.
- Strip escapes before matching: CSI sequences (`ESC [ … final letter`) and
  OSC sequences (`ESC ] …` ended by BEL `\u{07}` or `ESC \`). Remove the whole
  OSC sequence including its URL parameter, so a session link is not mistaken
  for the environment URL.
- Events, matched on the stripped line:
  - `connecting`: contains `Connecting ·`
  - `connected`: contains `Connected ·`
  - `sessions(Int)`: from `Capacity: N/`
  - `environmentURL(URL)`: `https://claude.ai/code?environment=` followed by
    non-space characters
  - `untrustedWorkspace`: contains `Workspace not trusted`
  - `alreadyServed`: contains `already served by`
  - `other(String)`: any other non-empty line (used for `lastError` and the
    log)
- Tests: the three fixtures; a fixture fed one byte at a time gives the same
  events as fed whole; the zsh noise lines above come out as `other`.

### ProcessLauncher

```swift
protocol ProcessLauncher {
    /// Callbacks are delivered on the main queue, in order, and `onExit`
    /// always comes after the last `onOutput`.
    func launch(repo: Repo,
                onOutput: @escaping (Data) -> Void,
                onExit: @escaping (Int32) -> Void) throws -> RunningProcess
}
protocol RunningProcess: AnyObject {
    var pid: Int32 { get }
    func terminate()   // SIGTERM; no-op if already exited
    func kill()        // SIGKILL; no-op if already exited
}
```

Real implementation, `ShellProcessLauncher`, using Foundation `Process`:

- Defaults: executable `/bin/zsh`, arguments
  `["-ilc", "exec \"$HOME/.local/bin/claude\" remote-control"]`, with
  ` --spawn worktree` appended inside the command string when `worktreeMode`
  is on. `exec` makes the process ID the server itself, so SIGTERM reaches
  it. Executable, shell flags and command string are all injectable so tests
  can use `/bin/sh -c` and a stub script.
- `currentDirectoryURL` = repo path. `standardInput = FileHandle.nullDevice`.
  stdout and stderr share one `Pipe`.
- Threading. `readabilityHandler` and `terminationHandler` fire on arbitrary
  background queues. Funnel both through one private serial `DispatchQueue`,
  and from there `DispatchQueue.main.async` to the callbacks.
- Ordering. Deliver `onExit` only after the pipe reaches end of file (the
  handler is called with empty `Data`) or 1 second after termination,
  whichever comes first. Do not use `readDataToEndOfFile`: a surviving child
  can hold the pipe open forever. Without this rule the "Workspace not
  trusted" text can arrive after the exit and be missed.
- Set `readabilityHandler = nil` at end of file, otherwise it spins.
- Keep a strong reference to the `Process` until `onExit` has been delivered.
- `terminate()` and `kill()` check `isRunning` first.
- `Process.run()` throws when the working directory is missing; let that
  propagate.

### ServerSupervisor

`@MainActor final class`, `ObservableObject` with
`@Published private(set) var statuses: [UUID: ServerStatus]`. Launcher, clock
(now + schedule-after) and process inspector are injected. All state changes
happen on the main actor.

Every launch gets a generation number per repo. Callbacks carrying an old
generation are ignored.

**Start** (repo enabled and currently `stopped`, `retrying` or `untrusted`):

- Launch. If `launch` throws → `retrying` with `lastError` "Cannot start:
  <error>". Otherwise → `starting`.
- Parser events while running:
  - `connected` → `connected(sessions:url:)`, keeping the latest known
    `sessions` (default 0) and `url`.
  - `sessions`, `environmentURL` → update the stored values and the status if
    connected.
  - `connecting` after `connected` (a reconnect) → back to `starting`. Not a
    failure; the stability timer restarts.
  - `alreadyServed` → remember it as the error, send SIGTERM now (do not wait
    out the 70 seconds). The exit then goes to `retrying`.
  - `untrustedWorkspace` → remember it.
  - `other(line)` → remember as the last output line; pass to the event log.

**Exit, not requested:**

- Untrusted seen → `untrusted`. No retry.
- Otherwise → `retrying`. `lastError` is, in order of preference: "Already
  served by another process"; "claude not found at ~/.local/bin/claude" for
  exit 127; else the last output line plus "(exit N)".
- Delay: 5 seconds for the first attempt of a streak, 30 seconds for every
  later one. A streak ends, and the attempt counter resets to 0, when the
  repo has stayed `connected` for 60 seconds.

**Stop** (disable, remove, quit, or worktree change):

- From `starting` or `connected`: SIGTERM → `stopping`. When the exit
  arrives → `stopped`. If no exit within 5 seconds, SIGKILL.
- From `retrying`: cancel the timer → `stopped`.
- An exit in `stopping` is never a failure.

**Start requested while `stopping`** (toggle off then on, or worktree mode
change): record a pending start and run it when the exit arrives. Never
launch a second server for a folder while the first is still alive; it would
hit the duplicate error.

**Retry now:** on `retrying` or `untrusted`; cancel any timer, start at once,
reset the attempt counter.

**Remove:** stop as above; the repo's entry disappears from `statuses` once
it reaches `stopped`.

**`stopAll()`** for app quit. Synchronous, and must not wait for main-queue
callbacks (it runs on the main thread, so that would deadlock): send SIGTERM
to every live pid, then poll `kill(pid, 0)` every 100 ms for up to 3 seconds,
then SIGKILL any survivor.

**Orphans.** If the app crashes, its servers keep running, and the next
launch would hit the duplicate error for ever. So:

- `~/Library/Application Support/claude-rc-controller/pids.json` holds
  `[{ "pid": 123, "path": "/abs/repo" }]`, rewritten on every launch and
  every exit.
- At app start, before starting anything: for each recorded pid where
  `kill(pid, 0)` succeeds and `/bin/ps -o command= -p <pid>` contains both
  `claude` and `remote-control`, send SIGTERM and wait up to 3 seconds
  (SIGKILL after). Then empty the file.
- A server the app did not start (for example one run by hand in a terminal)
  is never killed. That repo sits in `retrying` with "Already served by
  another process" until the other server stops.
- `kill(pid, 0)`, the `ps` lookup and signal sending sit behind a
  `ProcessInspector` protocol so tests can fake them.

Supervisor tests (fake launcher, fake clock) must cover: connect; untrusted;
already served; unknown exit and both retry delays; streak reset after 60
seconds; stop from each state; off-then-on while stopping; worktree change;
stale-generation callbacks ignored; orphan cleanup kills only matching pids.

One integration test runs `ShellProcessLauncher` with `/bin/sh -c` against a
stub script that prints the `connected.txt` fixture and then `exec sleep 60`
(`exec`, so no orphaned `sleep` holds the pipe). It checks that output
arrives, `terminate()` ends it, and `onExit` follows the output.

### EventLog

Appends timestamped lines for start, exit (with code), status changes and
`other` output lines (skip a line identical to the previous one for that
repo) to `~/Library/Logs/claude-rc-controller/controller.log`. When the file
passes 1 MB, keep the last 500 lines.

### NotificationText

Pure functions that build notification titles and bodies (see App design),
tested in `RCCore`.

## App design

### Wiring

- `@main struct ClaudeRCControllerApp: App` with
  `@NSApplicationDelegateAdaptor(AppDelegate.self)`.
- `AppDelegate` owns the `RepoStore`, `ServerSupervisor` and notifier.
  `MenuBarExtra` content is created lazily, so nothing may depend on the
  panel being opened.
  - `applicationDidFinishLaunching`: single-instance guard, orphan cleanup,
    load store, start enabled repos, request notification permission.
  - `applicationWillTerminate`: `supervisor.stopAll()`.
- **Single-instance guard:** if
  `NSRunningApplication.runningApplications(withBundleIdentifier:)` returns
  another process, call `NSApp.terminate(nil)` before doing anything else.
  Two copies would kill each other's servers as orphans.
- `MenuBarExtra { PanelView() } label: { Image(systemName: …) }` with
  `.menuBarExtraStyle(.window)`. Views observe the supervisor and store with
  `@ObservedObject`.

### Panel

- **Menu bar icon:** SF Symbol `antenna.radiowaves.left.and.right`; switch to
  `exclamationmark.triangle` when any enabled repo is `untrusted` or is
  `retrying` with attempt ≥ 3.
- About 340 pt wide.
- One row per repo: status dot, folder name, path in secondary text, and a
  status line:
  - `stopped`: grey, "Off"
  - `starting`: yellow, "Starting…"; after 30 seconds in this state show
    "Starting (no status yet)". This is view text only, not a model state.
  - `connected`: green, "Connected · N session(s)"
  - `stopping`: grey, "Stopping…"
  - `retrying`: yellow, "Retrying in N s: <lastError>" (use `TimelineView`
    for the countdown)
  - `untrusted`: red, "Not trusted: run `claude` in this folder once"
- Row controls: enabled toggle, and a `…` `Menu` with "Open on claude.ai"
  (only when a URL is known), "Reveal in Finder", "Open Terminal here"
  (`/usr/bin/open -a Terminal <path>`), "New sessions in worktrees"
  (checkmark toggle), "Retry now" (when `retrying` or `untrusted`),
  "Remove".
- **Confirmation.** Turning a repo off, removing it, or changing worktree
  mode while its status is `starting` or `connected` ends its sessions. Ask
  first, inline in the row: "Stop this server? Its sessions will end." with
  Cancel and Stop buttons. Do not use `.alert` or `.confirmationDialog`; they
  misbehave inside a `MenuBarExtra` window. The toggle needs a custom
  `Binding` whose setter opens the confirmation instead of changing the
  value. No confirmation in other states. Do not base this on the session
  count (an idle server already reports 1).
- Footer: "Add repo…", "Launch at login" checkbox, "Open log", "Quit".
- Empty state: one line of text and the "Add repo…" button.

### Add repo

`NSApp.activate(ignoringOtherApps: true)`, then `NSOpenPanel` with
`canChooseDirectories = true`, `canChooseFiles = false`,
`allowsMultipleSelection = true`, run with `runModal()`. Show store errors
(duplicate, not a directory) inline under the footer.

### Launch at login

`SMAppService.mainApp.register()` / `unregister()`; the checkbox reflects
`SMAppService.mainApp.status == .enabled`. If it throws, show the error text
under the checkbox. There is no fallback mechanism: if it does not work in
step 7, stop and report to the user.

### Notifications

`UNUserNotificationCenter`. Request authorization at launch; if denied, carry
on without notifications. Set a `UNUserNotificationCenterDelegate` whose
`willPresent` returns `[.banner]`, or nothing shows while the app is active.

- **Startup summary:** once per app launch, when every enabled repo has
  reached `connected` or `untrusted`, or 60 seconds after launch, whichever
  comes first. Examples: "Remote Control up: q, stitch"; "Remote Control: 1
  of 2 up. stitch: not trusted". Nothing if the list is empty.
- **Failure:** when a repo becomes `untrusted`, or reaches attempt 3 of a
  retry streak. At most one per streak.

## Steps

1. **Scaffold.** `CLAUDE.md`, `.gitignore`, `.swiftformat`, `project.yml`,
   the `RCCore` package with one trivial test, an app that shows an empty
   `MenuBarExtra`, `scripts/check.sh`. Commit the existing fixtures.
2. **Model and RepoStore**, including the `dirs.txt` import and corrupt-file
   handling.
3. **OutputParser.**
4. **ShellProcessLauncher and ServerSupervisor**, without orphan handling.
5. **Orphan handling, EventLog, NotificationText.**
6. **App:** wiring, panel, add and remove, confirmation, launch at login,
   notifications, `scripts/install.sh`.
7. **Install and switch over** (below). Stop here and hand over to the user;
   do not run step 7 without their go-ahead.

## Step 7: install and switch over

Only one thing may serve a folder, so the launchd agent must be stopped
before the app first runs. Stopping it ends every Remote Control session on
this machine.

**Preconditions. Check all three, and tell the user the results before going
on:**

- This step is being run from a local terminal session, not from a Remote
  Control session (which would kill itself part-way). Check that no ancestor
  of the current shell is a `claude remote-control` process.
- List what will be stopped: `pgrep -fl "claude remote-control"` (servers) and
  `pgrep -fl -- "--sdk-url"` (their sessions).
- The user has confirmed.

Then:

1. `scripts/install.sh`:
   - `xcodegen generate`, then `xcodebuild -project ClaudeRCController.xcodeproj
     -scheme ClaudeRCController -configuration Release -derivedDataPath build build`.
   - Quit a running copy with
     `osascript -e 'quit app id "com.nbw.claude-rc-controller"'` and wait
     until it has exited. Never `pkill` it: that skips `stopAll()`.
   - `rm -rf "/Applications/Claude RC Controller.app"`, then
     `ditto "build/Build/Products/Release/Claude RC Controller.app" "/Applications/Claude RC Controller.app"`.
   - The script does not launch the app.
2. Stop the old setup:
   - `launchctl bootout gui/$(id -u)/com.claude.remote-control`
   - `mv ~/Library/LaunchAgents/com.claude.remote-control.plist ~/.claude/remote-control/`
     (so it does not come back at the next login).
   - Confirm nothing is left with both `pgrep` commands above. If something
     remains, `pkill -TERM -f "claude remote-control"`, check again, and
     report to the user if it is still there.
3. Launch with `open "/Applications/Claude RC Controller.app"`. Always use
   `open`, never the binary directly, so the current shell's environment does
   not leak into the servers. The app imports `dirs.txt` on first run. Check
   both repos turn green and appear on claude.ai/code.
4. Tick "Launch at login".
5. Manual checks, with the user:
   - Add a repo, remove a repo, toggle one off and on.
   - Add an untrusted folder: red row, clear message, no retry loop.
   - Run `claude remote-control` by hand in a third trusted folder, then add
     that folder: row shows "Already served", and recovers after the manual
     one is stopped.
   - `kill -9` the app, relaunch: no duplicate-server errors.
   - Quit the app: both `pgrep` commands show nothing.
   - Log out and in (or restart): the app starts, servers come up, the
     summary notification appears, and nothing from the old setup is running.
6. Once the restart check passes, delete `~/.claude/remote-control/`.

**Rollback**, any time before 6: quit the app, untick its login item, then
`mv ~/.claude/remote-control/com.claude.remote-control.plist ~/Library/LaunchAgents/`
and `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.remote-control.plist`.

## Risks

- **Ad-hoc signing with `SMAppService` and notifications.** Expected to work
  for a locally built app in `/Applications`, but not verified. Each rebuild
  changes the ad-hoc signature, so macOS may ask again for notification
  permission, drop the login item, or re-ask for folder access that sessions
  need (the app is the responsible process for its servers). Re-tick "Launch
  at login" after reinstalling.
- **Status parsing depends on CLI text** that can change between Claude Code
  versions. If it changes, rows stay on "Starting (no status yet)" while the
  servers still work; update the parser.
- **App Nap** may delay retry timers for a background app. Acceptable.

## Out of scope

- Listing, opening or stopping individual sessions.
- Per-repo permission mode, capacity, session names or other
  `claude remote-control` flags.
- The `remoteControlAtStartup` setting in `~/.claude/settings.json` (already
  on; unrelated to this app).
- Auto-update, notarization, distribution to other machines.
