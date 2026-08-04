# VoiceInk Local Auto-Update Setup (MacBook Pro)

**Date:** 2026-08-04  
**Machine:** MacBook Pro (macOS, Apple Silicon)  
**Fork:** https://github.com/gadhadar/VoiceInk  
**Upstream:** https://github.com/Beingpax/VoiceInk  

This document records everything set up so this Mac can automatically pull upstream VoiceInk changes, rebuild a local ad-hoc Release app, install it to `/Applications`, and relaunch it — plus the Accessibility permission workflow that local/unsigned builds require.

Related docs:

- [`MacBook_Pro_installation.md`](../MacBook_Pro_installation.md) — original local Release install + Accessibility recipe that made the app work on this machine
- [`SELF_HOSTED_AUTO_UPDATE.md`](./SELF_HOSTED_AUTO_UPDATE.md) — runner operations / troubleshooting reference
- [`BUILDING.md`](../BUILDING.md) — upstream project build guide

---

## Goal

Keep a **local, unsigned (ad-hoc)** VoiceInk install current with upstream without an Apple Developer certificate:

1. Monitor / pull from upstream `Beingpax/VoiceInk`
2. Build successfully on this Mac
3. Install to **`/Applications/VoiceInk.app`**
4. Relaunch the app
5. Recover Accessibility permissions after each rebuild (required for ad-hoc code identity changes)

Cloud GitHub-hosted runners cannot write to this Mac’s Applications folder or restart the GUI app. A **self-hosted runner on this Mac** is required.

---

## Architecture

```text
GitHub (gadhadar/VoiceInk)
  └── workflow: Auto-update local VoiceInk
        │  triggers: manual only (workflow_dispatch)
        │  runs-on: [self-hosted, macOS, voiceink]
        ▼
Self-hosted runner on this MacBook Pro
  (~/actions-runners/voiceink, LaunchAgent service)
        │
        ▼
scripts/auto-update-local.sh
  1. fetch/merge upstream/main → main
  2. push main to origin (optional)
  3. make setup (whisper.xcframework)
  4. xcodebuild Release local (ad-hoc)
  5. install to /Applications/VoiceInk.app
  6. reset TCC + open Accessibility settings
  7. relaunch app
```

---

## Files added

| Path | Purpose |
|------|---------|
| `.github/workflows/auto-update-local.yml` | GitHub Actions workflow (self-hosted only) |
| `scripts/auto-update-local.sh` | Sync, build, install, TCC reset, relaunch |
| `docs/SELF_HOSTED_AUTO_UPDATE.md` | Runner setup and ops guide |
| `docs/LOCAL_AUTO_UPDATE_SETUP.md` | This overview of the full setup |

Existing reference used heavily:

| Path | Purpose |
|------|---------|
| `MacBook_Pro_installation.md` | Proven Release + `/tmp` derived data + Accessibility fix |
| `LocalBuild.xcconfig` | Ad-hoc / no team signing overrides |
| `VoiceInk/VoiceInk.local.entitlements` | Local entitlements (no CloudKit/keychain groups) |

---

## Self-hosted runner

### Install location

```text
~/actions-runners/voiceink
```

### Registration

- **Repo:** `https://github.com/gadhadar/VoiceInk`
- **Runner name:** `macbook-voiceink`
- **Labels:** `self-hosted`, `macOS`, `voiceink`
- **Package:** `actions-runner-osx-arm64-2.336.0`

The workflow is locked to:

```yaml
runs-on: [self-hosted, macOS, voiceink]
```

so only this machine picks up the job.

### Service

Installed as a user LaunchAgent (survives reboot, runs as the logged-in GUI user):

```bash
cd ~/actions-runners/voiceink
./svc.sh status
# ./svc.sh stop | start | uninstall
```

Plist / logs:

```text
~/Library/LaunchAgents/actions.runner.gadhadar-VoiceInk.macbook-voiceink.plist
~/Library/Logs/actions.runner.gadhadar-VoiceInk.macbook-voiceink/
```

### Host prerequisites (one-time)

```bash
brew install cmake
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain   # Xcode 26+; required by mlx-swift
make setup                                     # whisper.xcframework under ~/VoiceInk-Dependencies
```

---

## Workflow behavior

**Name:** Auto-update local VoiceInk  
**File:** `.github/workflows/auto-update-local.yml`

### Triggers

| Trigger | When |
|---------|------|
| `workflow_dispatch` | **Manual only** from the Actions tab (no cron/schedule) |

Originally this ran on a schedule (daily, then monthly). Scheduling was **removed** so updates only run after you review upstream code and manually trigger the workflow. Each rebuild still requires re-approving Accessibility for ad-hoc installs.

### Manual inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `force_build` | `false` | Rebuild/install even if upstream has no new commits |
| `skip_sync` | `false` | Skip git fetch/merge; build current tree only |
| `push_origin` | `true` | After merge, push `main` to the fork |

### Job steps (summary)

1. Checkout repo (full history)
2. Ensure `upstream` remote → `Beingpax/VoiceInk`
3. Configure git identity for merge commits
4. Verify host tools (`cmake`, `xcodebuild`, Xcode path, Homebrew PATH)
5. Run `scripts/auto-update-local.sh`
6. Verify `/Applications/VoiceInk.app` exists and is signed

---

## Build and install recipe

Stock `make local` builds **Debug** into `~/Downloads/VoiceInk.app`. On this MacBook Pro that path was a poor fit for Accessibility.

The automation uses the **proven recipe** from `MacBook_Pro_installation.md`:

- Configuration: **Release**
- Signing: ad-hoc (`CODE_SIGN_IDENTITY=-`)
- Entitlements: `VoiceInk/VoiceInk.local.entitlements`
- Flag: `LOCAL_BUILD`
- Derived data: `/tmp/VoiceInk-dd` (avoids Documents/xattr codesign failures)
- `COPYFILE_DISABLE=1`
- Install target: **`/Applications/VoiceInk.app` only**
- Extra xcodebuild flags for CI:
  - `-skipPackagePluginValidation` (mlx-swift `CudaBuild` plugin)
  - `-skipMacroValidation`

### Script environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `UPSTREAM_REMOTE` | `upstream` | Beingpax remote |
| `ORIGIN_REMOTE` | `origin` | Fork remote |
| `ORIGIN_BRANCH` | `main` | Branch to update |
| `FORCE_BUILD` | `0` | Rebuild when already up to date |
| `SKIP_SYNC` | `0` | Skip fetch/merge |
| `PUSH_ORIGIN` | `1` | Push after merge |
| `RELAUNCH` | `1` | Open app after install |
| `RESET_TCC` | `1` | Reset Accessibility-related TCC after install |
| `INSTALL_PATH` | `/Applications/VoiceInk.app` | Install location |
| `DERIVED_DATA` | `/tmp/VoiceInk-dd` | xcodebuild derived data |
| `APP_BUNDLE_ID` | `com.prakashjoshipax.VoiceInk` | Bundle ID for TCC reset |

### CLI usage (without Actions)

```bash
# Normal: sync upstream, build if changed, install, TCC reset, relaunch
./scripts/auto-update-local.sh

# Force rebuild of current tree without git sync
SKIP_SYNC=1 FORCE_BUILD=1 ./scripts/auto-update-local.sh
```

---

## Accessibility permissions (critical for local builds)

### Why this breaks after every rebuild

Local installs are **ad-hoc signed** (no Team ID). Each reinstall/re-sign changes the app’s code identity. macOS TCC (Transparency, Consent, and Control) binds Accessibility approval to that identity, so:

- Old Accessibility rows become stale or blocked
- The toggle may not appear, may not stick, or may look enabled but not work
- Moving the app between `Downloads` and `Applications` makes this worse

This is expected for unsigned local builds. It is **not** fixed by Gatekeeper approval alone (`spctl` still reports `rejected` for ad-hoc apps even when they run).

### What worked on this machine (2026-08-04)

After the first successful auto-update install, Accessibility could not be granted until the documented recovery was applied:

```bash
pkill -x VoiceInk 2>/dev/null || true
# ensure only /Applications/VoiceInk.app exists
xattr -cr /Applications/VoiceInk.app
codesign --force --deep --sign - \
  --entitlements VoiceInk/VoiceInk.local.entitlements \
  /Applications/VoiceInk.app

tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk
tccutil reset ListenEvent com.prakashjoshipax.VoiceInk 2>/dev/null || true
tccutil reset PostEvent com.prakashjoshipax.VoiceInk 2>/dev/null || true

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open /Applications/VoiceInk.app
```

Then in System Settings:

1. Turn **ON** VoiceInk under **Accessibility**
2. Enable **Microphone** / **Input Monitoring** if prompted
3. If the toggle does not stick, **quit VoiceInk fully and open it again** from `/Applications` only

### Automation behavior now

`scripts/auto-update-local.sh` with `RESET_TCC=1` (default):

1. Resets the TCC services above after install
2. Opens the Accessibility settings pane
3. Relaunches VoiceInk

You still must flip the System Settings toggles yourself (macOS does not allow scripts to grant Accessibility silently). After enabling, one quit/reopen is often required.

### Practical rules

- Always launch from **`/Applications/VoiceInk.app`**
- Do **not** keep a second copy in Downloads
- Prefer infrequent **manual** updates so you are not re-approving permissions often
- After an update: enable Accessibility → quit app → reopen once if needed

---

## Problems hit during setup and fixes

| Issue | Symptom | Fix |
|-------|---------|-----|
| Cloud Actions cannot install locally | Would build in the cloud only | Self-hosted runner on this Mac with label `voiceink` |
| OAuth token missing `workflow` scope | `git push` rejected for workflow YAML | `gh auth refresh -h github.com -s workflow,repo` |
| mlx-swift `CudaBuild` plugin validation | `Validate plug-in "CudaBuild"` / exit 65 | `-skipPackagePluginValidation` and `-skipMacroValidation` |
| Missing Metal toolchain (Xcode 26) | `cannot execute tool 'metal'` | `xcodebuild -downloadComponent MetalToolchain` (+ auto-check in script) |
| Documents/xattr codesign failures | resource fork / Finder information | `/tmp` derived data + `COPYFILE_DISABLE=1` |
| Debug local build + moved app | Accessibility could not be granted | Release local build, single `/Applications` path |
| Post-install Accessibility broken | Toggle missing/stuck after auto-update | TCC reset + reopen; baked into script as `RESET_TCC=1` |
| Scheduled rebuilds too disruptive / less review | Auto-ran untrusted upstream on a timer | Schedule **removed** — manual trigger only after review |

---

## Git history of this work (fork)

| Commit | Summary |
|--------|---------|
| `f6aa286` | Add self-hosted auto-update workflow, script, and docs |
| `dc2ba7c` | Skip mlx-swift package plugin validation |
| `cc5e298` | Ensure Metal toolchain is present before builds |
| `7ca4065` | Reset TCC after install for Accessibility recovery |
| `1e8dce0` | Run schedule monthly instead of daily |
| *(this change)* | Remove schedule entirely — manual `workflow_dispatch` only |

(Plus earlier `f4690eb` — MacBook Pro local install notes.)

---

## Successful verification (2026-08-04)

First fully successful Actions run after Metal + plugin fixes:

- Run: https://github.com/gadhadar/VoiceInk/actions/runs/30927482054
- Result: **success**
- App: `/Applications/VoiceInk.app`
- Executable: arm64 Mach-O ~52–54 MB
- Signature: **adhoc**, bundle ID `com.prakashjoshipax.VoiceInk`
- Process path when running: `/Applications/VoiceInk.app/Contents/MacOS/VoiceInk`

Accessibility was restored afterward with TCC reset + enable in System Settings + one app restart.

---

## Day-to-day usage

### Automatic schedule

**None.** There is no cron trigger. The runner can stay online, but nothing runs until you start a workflow.

### Manual update (only path)

GitHub → **Actions** → **Auto-update local VoiceInk** → **Run workflow**

Suggested inputs when you intentionally want a refresh:

- `force_build`: true (if you want rebuild even with no upstream delta)
- `skip_sync`: false
- `push_origin`: true

### Check runner health

```bash
cd ~/actions-runners/voiceink && ./svc.sh status
# GitHub → Settings → Actions → Runners → macbook-voiceink should show Idle/Online
```

### Stop automation temporarily

```bash
cd ~/actions-runners/voiceink
./svc.sh stop
```

---

## Security notes

- Runner runs as your user and can modify git state, push to the fork, replace `/Applications/VoiceInk.app`, reset TCC for the app bundle ID, and launch GUI apps
- Only enable this on **your fork**, with a runner you control
- Do not commit secrets (e.g. `.webui_secret_key` is local/untracked)
- Registration tokens from GitHub’s “New runner” page are single-use; they are not stored in the repo

---

## Quick recovery cheat sheet

```bash
# App broken / Accessibility stuck after an update
pkill -x VoiceInk 2>/dev/null || true
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open /Applications/VoiceInk.app
# Enable VoiceInk in Accessibility, then quit and reopen once if needed

# Force local rebuild + install without waiting for Actions
cd ~/Documents/Github/VoiceInk   # or your clone path
SKIP_SYNC=1 FORCE_BUILD=1 ./scripts/auto-update-local.sh
```

---

## Expected healthy install signals

```bash
ls -la /Applications/VoiceInk.app/Contents/MacOS/VoiceInk
file /Applications/VoiceInk.app/Contents/MacOS/VoiceInk
codesign -dv --verbose=2 /Applications/VoiceInk.app
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  /Applications/VoiceInk.app/Contents/Info.plist
pgrep -lf VoiceInk
```

Healthy signals:

- Single arm64 Mach-O executable under `/Applications/.../MacOS/VoiceInk`
- `Signature=adhoc`
- Process path under `/Applications/VoiceInk.app`
- Accessibility toggle can be enabled for **VoiceInk** and works after one relaunch if needed
