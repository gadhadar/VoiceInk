# VoiceInk — MacBook Pro Local Installation Notes

**Date:** 2026-08-02  
**Machine:** MacBook Pro (macOS, Apple Silicon)  
**Goal:** Build and install VoiceInk for local use without an Apple Developer certificate, place it in `/Applications`, and enable Accessibility permissions.

This document records the steps and fixes that were required on this machine beyond a clean `make local` run described in `BUILDING.md`.

---

## Summary

VoiceInk was built from source as an **unsigned / ad-hoc signed local Release build**, installed to **`/Applications/VoiceInk.app`**, and prepared for Accessibility (and related) privacy permissions.

Key deviations from a simple `make local`:

1. Missing **CMake**
2. **xcode-select** pointed at Command Line Tools instead of full Xcode
3. **Extended attributes / resource forks** under `Documents` broke codesigning
4. Initial **Debug** local build was unsuitable for Accessibility after moving to Applications
5. A proper **Release** local rebuild + clean install + TCC reset fixed Accessibility readiness

---

## Prerequisites verified / fixed

### 1. CMake (required by whisper.cpp)

`make local` failed while building `whisper.xcframework` because CMake was missing.

```bash
brew install cmake
```

Installed version on this machine: **cmake 4.4.2** (Homebrew).

### 2. Full Xcode as active developer directory

`xcode-select -p` initially returned:

```text
/Library/Developer/CommandLineTools
```

That is not enough for `xcodebuild` / multi-SDK XCFramework builds. Full Xcode was already installed at `/Applications/Xcode.app`, so the active path was switched:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcode-select -p
xcodebuild -version
```

Result on this machine:

- Developer dir: `/Applications/Xcode.app/Contents/Developer`
- Xcode version: **26.6**
- SDKs (macOS, iOS, simulator, etc.) available after the switch

### 3. whisper.cpp XCFramework

The Makefile clones/builds whisper under:

```text
~/VoiceInk-Dependencies/whisper.cpp
```

Framework path:

```text
~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework
```

This step succeeded after CMake + Xcode path fixes.

---

## Build issues and resolutions

### Issue A — `make local` failed on codesign (“resource fork / Finder information”)

Even with ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), Xcode failed signing SPM resource bundles and later the app with:

```text
resource fork, Finder information, or similar detritus not allowed
```

Likely cause: building with derived data under the project path inside **Documents** (`GitHub.nosync` / iCloud-related layout), which can attach extended attributes that codesign rejects.

**Workaround used successfully:**

- Set `COPYFILE_DISABLE=1`
- Use derived data under `/tmp` instead of the project’s `.local-build`
- Strip xattrs on the product
- Copy with `ditto` to the install location
- Ad-hoc resign if needed

Example pattern:

```bash
export COPYFILE_DISABLE=1
rm -rf /tmp/VoiceInk-dd

xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
  -derivedDataPath /tmp/VoiceInk-dd \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  build

APP_SRC="/tmp/VoiceInk-dd/Build/Products/Release/VoiceInk.app"
xattr -cr "$APP_SRC"
rm -rf /Applications/VoiceInk.app
ditto "$APP_SRC" /Applications/VoiceInk.app
xattr -cr /Applications/VoiceInk.app
xattr -d com.apple.quarantine /Applications/VoiceInk.app 2>/dev/null || true
codesign --force --deep --sign - \
  --entitlements "$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  /Applications/VoiceInk.app
```

Local build config files used:

- `LocalBuild.xcconfig`
- `VoiceInk/VoiceInk.local.entitlements`
- `LOCAL_BUILD` Swift compilation flag

### Issue B — First successful build was Debug and Accessibility was difficult

First successful product was a **Debug** local build (initially to `~/Downloads/VoiceInk.app`, then moved to `/Applications`).

Debug layout included:

- thin `VoiceInk` launcher
- large `VoiceInk.debug.dylib`

Observations:

- `codesign` showed **adhoc** signature, no Team ID
- `spctl -a -vv /Applications/VoiceInk.app` reported **rejected**
- Moving the app after first launch confuses macOS privacy bindings (path/signature identity)
- Accessibility permission could not be granted reliably

**Fix:** rebuild as **Release** local (ad-hoc), reinstall cleanly to `/Applications` only, reset TCC entries, relaunch from `/Applications`.

Release binary characteristics after fix:

- Single Mach-O arm64 executable at  
  `/Applications/VoiceInk.app/Contents/MacOS/VoiceInk`
- Size roughly **~53 MB**
- Signature: **adhoc**
- Bundle ID: `com.prakashjoshipax.VoiceInk`

---

## Final install location

| Item | Path |
|------|------|
| App | `/Applications/VoiceInk.app` |
| Bundle ID | `com.prakashjoshipax.VoiceInk` |
| Whisper deps | `~/VoiceInk-Dependencies/` |
| Build derived data (successful builds) | `/tmp/VoiceInk-dd` |

Launch with:

```bash
open -a VoiceInk
# or
open /Applications/VoiceInk.app
```

---

## Accessibility and related permissions

### What was done on the machine

1. Quit any running VoiceInk instance.
2. Ensured only one install path: **`/Applications/VoiceInk.app`** (no lingering Downloads copy).
3. Reset privacy approvals for the bundle ID:

```bash
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk
```

4. Opened System Settings Accessibility pane and launched the app:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open -a VoiceInk
```

### What the user must still confirm in System Settings

Turn **ON** for VoiceInk as prompted:

- **Privacy & Security → Accessibility** (required)
- **Microphone**
- **Input Monitoring** (if shown; often needed for global hotkeys)
- **Screen & System Audio Recording** (if using context/screen features)
- **Automation** / Apple Events (if prompted)

### Practical rules for local/ad-hoc builds

- Always launch from **`/Applications/VoiceInk.app`**
- Do **not** keep multiple copies (Downloads + Applications)
- After rebuilding/reinstalling, reset TCC and re-enable toggles
- Moving a previously launched ad-hoc app often breaks or duplicates permission entries

---

## Recommended rebuild recipe (this Mac)

From the VoiceInk repo root:

```bash
# One-time / occasional host setup
brew install cmake
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Ensure whisper framework exists (Makefile target)
make setup

# Reliable local Release install (avoids Documents xattr codesign issues)
export COPYFILE_DISABLE=1
pkill -x VoiceInk 2>/dev/null || true
rm -rf /tmp/VoiceInk-dd

xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
  -derivedDataPath /tmp/VoiceInk-dd \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  build

APP_SRC="/tmp/VoiceInk-dd/Build/Products/Release/VoiceInk.app"
xattr -cr "$APP_SRC"
rm -rf /Applications/VoiceInk.app
ditto "$APP_SRC" /Applications/VoiceInk.app
xattr -cr /Applications/VoiceInk.app
xattr -d com.apple.quarantine /Applications/VoiceInk.app 2>/dev/null || true
codesign --force --deep --sign - \
  --entitlements "$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  /Applications/VoiceInk.app

tccutil reset Accessibility com.prakashjoshipax.VoiceInk
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open -a VoiceInk
```

Note: stock `make local` builds **Debug** into `~/Downloads/VoiceInk.app`. On this MacBook Pro, **Release + `/Applications` + `/tmp` derived data** was the path that worked for both install and Accessibility readiness.

---

## Local-build limitations (unchanged product behavior)

Per project docs for local/unsigned builds:

- No iCloud dictionary sync
- No automatic updates (pull new code and rebuild to update)
- No Apple Developer Team signing / notarization
- Gatekeeper may still treat the app as unsigned/ad-hoc (`spctl` can report rejected even when the app runs)

---

## Timeline of work performed (2026-08-02)

1. Read `building.md` / Makefile; started `make local`.
2. Installed **CMake** via Homebrew after whisper build failure.
3. Switched **xcode-select** from Command Line Tools to full **Xcode.app**.
4. Built **whisper.xcframework** under `~/VoiceInk-Dependencies`.
5. Hit codesign failures from **resource fork / xattr** detritus with project-local derived data.
6. Successfully built **Debug** local app using `/tmp` derived data; first install path was Downloads, then Applications.
7. Accessibility permission failed / could not be granted reliably on Debug + moved app.
8. Rebuilt **Release** local ad-hoc app; installed cleanly to **`/Applications/VoiceInk.app`**.
9. Reset Accessibility / Microphone / ScreenCapture / AppleEvents TCC entries for `com.prakashjoshipax.VoiceInk`.
10. Opened Accessibility settings and relaunched VoiceInk for manual toggle enablement.

---

## Quick verification commands

```bash
# App present
ls -la /Applications/VoiceInk.app/Contents/MacOS/VoiceInk
file /Applications/VoiceInk.app/Contents/MacOS/VoiceInk

# Signature
codesign -dv --verbose=2 /Applications/VoiceInk.app

# Bundle ID
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  /Applications/VoiceInk.app/Contents/Info.plist

# Running process path should be under /Applications
pgrep -lf VoiceInk
```

Expected healthy local install signals:

- Executable is a normal **arm64 Mach-O** under `/Applications/.../MacOS/VoiceInk`
- `codesign` shows **Signature=adhoc**
- Process path is `/Applications/VoiceInk.app/Contents/MacOS/VoiceInk`
- Accessibility toggle can be enabled for **VoiceInk** in System Settings
