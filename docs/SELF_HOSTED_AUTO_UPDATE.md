# Self-hosted auto-update (GitHub Actions)

This fork can keep **`/Applications/VoiceInk.app`** current with upstream
[`Beingpax/VoiceInk`](https://github.com/Beingpax/VoiceInk) by running a
**self-hosted** GitHub Actions runner on this Mac.

Cloud runners cannot install into your Applications folder or restart the app
on your machine. The workflow is intentionally locked to labels:

```text
runs-on: [self-hosted, macOS, voiceink]
```

## What the workflow does

File: [`.github/workflows/auto-update-local.yml`](../.github/workflows/auto-update-local.yml)

Script: [`scripts/auto-update-local.sh`](../scripts/auto-update-local.sh)

1. **Trigger** only via **Run workflow** manually (no schedule — review upstream first).
2. Fetch/merge **`upstream/main`** into **`main`**.
3. If there are new commits (or you force a rebuild), push `main` to **origin**.
4. Build an **ad-hoc local Release** (same recipe as `MacBook_Pro_installation.md`):
   - `COPYFILE_DISABLE=1`
   - derived data under `/tmp/VoiceInk-dd`
   - `LocalBuild.xcconfig` + `VoiceInk.local.entitlements` + `LOCAL_BUILD`
5. Quit VoiceInk, replace **`/Applications/VoiceInk.app`**, ad-hoc codesign, relaunch.

If upstream has no new commits, the job exits successfully without rebuilding
(unless **force_build** is enabled on a manual run).

## One-time host prerequisites

These match what already worked on this MacBook Pro:

```bash
brew install cmake
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcode-select -p
xcodebuild -version
make setup   # builds ~/VoiceInk-Dependencies/whisper.cpp if needed
xcodebuild -downloadComponent MetalToolchain   # required by mlx-swift on Xcode 26+
```

Confirm the app recipe once by hand (optional):

```bash
FORCE_BUILD=1 SKIP_SYNC=1 ./scripts/auto-update-local.sh
```

## Install the self-hosted runner

1. Open your fork on GitHub: **Settings → Actions → Runners → New self-hosted runner**.
2. Choose **macOS** and follow GitHub’s download/config commands (they include a unique token).
3. When `./config.sh` asks for labels, include at least:

   ```text
   self-hosted,macOS,voiceink
   ```

   (`self-hosted` and `macOS` are usually added automatically; add **`voiceink`** so only this machine picks up the job.)

4. Recommended install location (example):

   ```text
   ~/actions-runners/voiceink
   ```

5. Install and start as a **LaunchAgent** so it survives reboots and runs as **your user**
   (needed to write `/Applications` if you own that app bundle, and to `open` the GUI app):

   ```bash
   cd ~/actions-runners/voiceink
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status
   ```

6. Confirm the runner shows **Idle** (green) under the repo’s Runners page.

### PATH for GUI/LaunchAgent runners

LaunchAgents often get a minimal `PATH` and may miss Homebrew. If the job fails
to find `cmake`, either:

- ensure `/opt/homebrew/bin` is on the runner service path, or
- symlink: `sudo ln -sf /opt/homebrew/bin/cmake /usr/local/bin/cmake`

The workflow also appends Homebrew’s bin dir to `GITHUB_PATH` when present.

### Git push credentials

After a successful upstream merge the script runs `git push origin main`.

The runner must be able to push to `https://github.com/gadhadar/VoiceInk.git`:

- Prefer a **fine-grained PAT** or classic PAT with `repo` scope stored in the
  runner’s git credential helper / macOS Keychain for that host, **or**
- Configure the checkout remote to use SSH with a key loaded for the runner user.

If you only want local merges without pushing, run the workflow manually with
**push_origin = false**, or set `PUSH_ORIGIN=0` when invoking the script.

### Working directory vs permanent clone

GitHub Actions checks out the repo into the runner’s `_work` directory for each
job. That is fine: builds use `/tmp/VoiceInk-dd`, whisper stays in
`~/VoiceInk-Dependencies`, and the installed app is always
`/Applications/VoiceInk.app`.

If you prefer the job to operate on a fixed clone (e.g.
`~/Documents/Github/VoiceInk`), you can change the workflow later to `cd` there
instead of using `actions/checkout`. The default checkout approach is simpler
and avoids dirty-tree surprises in your interactive clone.

## Manual runs

**Actions → Auto-update local VoiceInk → Run workflow**

| Input | Meaning |
|-------|---------|
| `force_build` | Rebuild/install even when upstream is unchanged |
| `skip_sync` | Do not fetch/merge; build current tree only |
| `push_origin` | After merge, push `main` to your fork (default on) |

## CLI equivalent (no Actions)

From any up-to-date clone with `upstream` configured:

```bash
# Normal: sync upstream, build if changed, install, relaunch
./scripts/auto-update-local.sh

# Force rebuild of current tree without git sync
SKIP_SYNC=1 FORCE_BUILD=1 ./scripts/auto-update-local.sh
```

Environment knobs:

| Variable | Default | Purpose |
|----------|---------|---------|
| `UPSTREAM_REMOTE` | `upstream` | Remote name for Beingpax/VoiceInk |
| `ORIGIN_REMOTE` | `origin` | Your fork |
| `ORIGIN_BRANCH` | `main` | Branch to update |
| `FORCE_BUILD` | `0` | Rebuild when already up to date |
| `SKIP_SYNC` | `0` | Skip fetch/merge |
| `PUSH_ORIGIN` | `1` | Push after merge |
| `RELAUNCH` | `1` | `open` the app after install |
| `RESET_TCC` | `1` | Reset Accessibility/related TCC after install |
| `INSTALL_PATH` | `/Applications/VoiceInk.app` | Install location |
| `DERIVED_DATA` | `/tmp/VoiceInk-dd` | xcodebuild derived data |

## Accessibility after updates

Ad-hoc resigning changes the app's code identity, so macOS often drops or
blocks previous Accessibility grants after each reinstall.

`scripts/auto-update-local.sh` now resets TCC for the VoiceInk bundle ID after
install (`RESET_TCC=1` by default) and opens **Privacy & Security → Accessibility**.

After each automated update:

1. Turn **ON** VoiceInk under **Accessibility**
2. Also enable **Microphone** / **Input Monitoring** if prompted
3. If the toggle does not stick, **quit VoiceInk fully and open it again** from `/Applications` only
4. Keep a single install path: `/Applications/VoiceInk.app` (no Downloads copy)

Manual recovery (same as `MacBook_Pro_installation.md`):

```bash
pkill -x VoiceInk 2>/dev/null || true
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset Microphone com.prakashjoshipax.VoiceInk
tccutil reset ScreenCapture com.prakashjoshipax.VoiceInk
tccutil reset AppleEvents com.prakashjoshipax.VoiceInk
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open /Applications/VoiceInk.app
```

Set `RESET_TCC=0` only if you intentionally want to skip the reset.

## Security notes

- Only enable this workflow on **your fork**, with a runner you control.
- The job can modify git state, push to origin, replace `/Applications/VoiceInk.app`,
  and start GUI apps as your user.
- Do not add untrusted `workflow_dispatch` inputs that execute arbitrary shell.
- Keep the runner offline (stop the service) when you do not want automated builds.

## Troubleshooting

| Symptom | Check |
|---------|--------|
| Job stuck “Waiting for a runner” | Runner online? Labels include `voiceink`? |
| `cmake: command not found` | Homebrew PATH / symlink (above) |
| xcode-select points at CLT | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| codesign resource fork errors | Script already uses `/tmp` + `COPYFILE_DISABLE=1` |
| mlx-swift `CudaBuild` plugin validation fails | Script passes `-skipPackagePluginValidation` / `-skipMacroValidation` |
| missing `metal` / Metal Toolchain | Script auto-runs `xcodebuild -downloadComponent MetalToolchain` |
| `git push` rejected | PAT/SSH credentials for the runner user |
| Merge conflict | Resolve once in a normal clone; next schedule should be clean |
| App does not appear | Runner must run as a logged-in GUI user, not a headless SSH-only session |
