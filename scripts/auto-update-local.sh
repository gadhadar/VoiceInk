#!/usr/bin/env bash
# Sync upstream, build ad-hoc local Release VoiceInk, install to /Applications, relaunch.
# Recipe from MacBook_Pro_installation.md (Release + /tmp derived data).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${ORIGIN_REMOTE:-origin}"
ORIGIN_BRANCH="${ORIGIN_BRANCH:-main}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.prakashjoshipax.VoiceInk}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/VoiceInk.app}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/VoiceInk-dd}"
SKIP_SYNC="${SKIP_SYNC:-0}"
FORCE_BUILD="${FORCE_BUILD:-0}"
PUSH_ORIGIN="${PUSH_ORIGIN:-1}"
RELAUNCH="${RELAUNCH:-1}"

log() { printf '[auto-update] %s\n' "$*"; }
die() { printf '[auto-update] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"
}

check_host() {
  require_cmd git
  require_cmd make
  require_cmd xcodebuild
  require_cmd ditto
  require_cmd codesign
  require_cmd cmake

  local dev_dir
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$dev_dir" != *"/Xcode.app/"* ]]; then
    die "xcode-select must point at full Xcode.app (got: ${dev_dir:-unset}). Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi

  [[ -f "$ROOT_DIR/LocalBuild.xcconfig" ]] \
    || die "LocalBuild.xcconfig missing in repo root"
  [[ -f "$ROOT_DIR/VoiceInk/VoiceInk.local.entitlements" ]] \
    || die "VoiceInk/VoiceInk.local.entitlements missing"
}

sync_upstream() {
  git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
    || die "git remote '$UPSTREAM_REMOTE' is not configured"

  log "Fetching $UPSTREAM_REMOTE and $ORIGIN_REMOTE..."
  git fetch "$UPSTREAM_REMOTE" --prune
  git fetch "$ORIGIN_REMOTE" --prune || true

  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$current_branch" != "$ORIGIN_BRANCH" ]]; then
    log "Checking out $ORIGIN_BRANCH (was on $current_branch)"
    git checkout "$ORIGIN_BRANCH"
  fi

  if git rev-parse --verify "$ORIGIN_REMOTE/$ORIGIN_BRANCH" >/dev/null 2>&1; then
    if ! git merge-base --is-ancestor "$ORIGIN_REMOTE/$ORIGIN_BRANCH" HEAD; then
      log "Fast-forwarding to $ORIGIN_REMOTE/$ORIGIN_BRANCH"
      git merge --ff-only "$ORIGIN_REMOTE/$ORIGIN_BRANCH"
    fi
  fi

  local before after
  before="$(git rev-parse HEAD)"
  log "Merging $UPSTREAM_REMOTE/$UPSTREAM_BRANCH into $ORIGIN_BRANCH"
  if ! git merge --no-edit "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
    die "Merge from $UPSTREAM_REMOTE/$UPSTREAM_BRANCH failed; resolve conflicts manually"
  fi
  after="$(git rev-parse HEAD)"

  if [[ "$before" == "$after" && "$FORCE_BUILD" != "1" ]]; then
    log "Already up to date with $UPSTREAM_REMOTE/$UPSTREAM_BRANCH (HEAD=$after); nothing to build"
    exit 0
  fi

  if [[ "$before" == "$after" ]]; then
    log "No upstream changes, but FORCE_BUILD=1 — rebuilding anyway"
  else
    log "Updated $before -> $after"
    if [[ "$PUSH_ORIGIN" == "1" ]]; then
      log "Pushing $ORIGIN_BRANCH to $ORIGIN_REMOTE"
      git push "$ORIGIN_REMOTE" "$ORIGIN_BRANCH"
    else
      log "Skipping push to origin (PUSH_ORIGIN=0)"
    fi
  fi
}

build_and_install() {
  export COPYFILE_DISABLE=1

  log "Ensuring whisper.xcframework is available..."
  make setup

  log "Quitting VoiceInk if running..."
  pkill -x VoiceInk 2>/dev/null || true
  sleep 1

  log "Cleaning derived data at $DERIVED_DATA"
  rm -rf "$DERIVED_DATA"

  log "Building local Release (ad-hoc)..."
  xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$ROOT_DIR/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    build

  local app_src="$DERIVED_DATA/Build/Products/Release/VoiceInk.app"
  [[ -d "$app_src" ]] || die "Built app not found at $app_src"

  log "Stripping xattrs from build product"
  xattr -cr "$app_src"

  log "Installing to $INSTALL_PATH"
  rm -rf "$INSTALL_PATH"
  ditto "$app_src" "$INSTALL_PATH"
  xattr -cr "$INSTALL_PATH"
  xattr -d com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

  log "Ad-hoc codesigning installed app"
  codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/VoiceInk/VoiceInk.local.entitlements" \
    "$INSTALL_PATH"

  log "Installed app signature:"
  codesign -dv --verbose=2 "$INSTALL_PATH" 2>&1 || true

  if [[ "$RELAUNCH" == "1" ]]; then
    log "Launching VoiceInk from $INSTALL_PATH"
    open "$INSTALL_PATH"
  else
    log "Skipping relaunch (RELAUNCH=0)"
  fi

  log "Done. Bundle ID: $APP_BUNDLE_ID"
  log "If Accessibility breaks after an update, run:"
  log "  tccutil reset Accessibility $APP_BUNDLE_ID"
  log "  open \"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility\""
  log "  open -a VoiceInk"
}

main() {
  check_host

  if [[ "$SKIP_SYNC" == "1" ]]; then
    log "Build-only mode (SKIP_SYNC=1)"
  else
    sync_upstream
  fi

  build_and_install
}

main "$@"
