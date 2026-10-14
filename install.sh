#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer requires macOS." >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_home="${TERMINAL_HOTKEY_HOME:-$HOME}"
install_dir="$install_home/Library/Application Support/TerminalHotkey"
agent_dir="$install_home/Library/LaunchAgents"
app_path="$install_dir/Terminal Hotkeys.app"
agent_path="$agent_dir/local.terminal-hotkey.plist"
label="local.terminal-hotkey"

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required to write the launch agent plist." >&2
  exit 1
fi

mkdir -p "$install_dir" "$agent_dir"
staging="$(mktemp -d "$install_dir/.setup.XXXXXX")"
backup=""
changed=0
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT
rollback() {
  if [[ "$changed" != "1" ]]; then
    return
  fi
  trap - ERR
  set +e
  if [[ "${TERMINAL_HOTKEY_SKIP_LAUNCH:-0}" != "1" ]]; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
  fi
  rm -rf "$app_path"
  if [[ -d "$staging/previous.app" ]]; then
    mv "$staging/previous.app" "$app_path"
  fi
  rm -f "$agent_path"
  if [[ -f "$staging/previous.plist" ]]; then
    cp "$staging/previous.plist" "$agent_path"
    if [[ "${TERMINAL_HOTKEY_SKIP_LAUNCH:-0}" != "1" ]]; then
      launchctl bootstrap "gui/$(id -u)" "$agent_path"
    fi
  fi
  echo "Installation failed; previous installation restored." >&2
}
trap rollback ERR

staged_app="$staging/Terminal Hotkeys.app"
mkdir -p "$staged_app/Contents/MacOS"
cp "$repo_dir/src/Info.plist" "$staged_app/Contents/Info.plist"
xcrun swiftc -O "$repo_dir/src/TerminalHotkey.swift" -o "$staged_app/Contents/MacOS/terminal-hotkey"
codesign --force --sign - --identifier local.terminal-hotkeys "$staged_app"
codesign --verify "$staged_app"
"$staged_app/Contents/MacOS/terminal-hotkey" --validate

export HOTKEY_APP_PATH="$app_path" HOTKEY_INSTALL_DIR="$install_dir" HOTKEY_STAGING="$staging"
python3 - <<'PY'
import os
import plistlib
from pathlib import Path
root = Path(os.environ['HOTKEY_INSTALL_DIR'])
agent = {
    'Label': 'local.terminal-hotkey',
    'ProgramArguments': [os.environ['HOTKEY_APP_PATH'] + '/Contents/MacOS/terminal-hotkey'],
    'RunAtLoad': True,
    'KeepAlive': True,
    'ThrottleInterval': 30,
    'LimitLoadToSessionType': 'Aqua',
    'ProcessType': 'Interactive',
    'StandardOutPath': str(root / 'stdout.log'),
    'StandardErrorPath': str(root / 'stderr.log'),
}
Path(os.environ['HOTKEY_STAGING'], 'local.terminal-hotkey.plist').write_bytes(plistlib.dumps(agent))
PY
plutil -lint "$staging/local.terminal-hotkey.plist" >/dev/null

if [[ -f "$agent_path" ]]; then
  cp "$agent_path" "$staging/previous.plist"
fi
changed=1
if [[ "${TERMINAL_HOTKEY_SKIP_LAUNCH:-0}" != "1" ]]; then
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
fi
if [[ -d "$app_path" ]]; then
  backup="$staging/previous.app"
  mv "$app_path" "$backup"
fi
mv "$staged_app" "$app_path"
cp "$staging/local.terminal-hotkey.plist" "$agent_path"
chmod 644 "$agent_path"
if [[ "${TERMINAL_HOTKEY_SKIP_LAUNCH:-0}" != "1" ]]; then
  launchctl bootstrap "gui/$(id -u)" "$agent_path"
  launchctl print "gui/$(id -u)/$label" >/dev/null
  echo "Installed and started. Press Control + Option + T to open, or Control + Option + W to close the newest Terminal window."
else
  echo "Built and installed without starting the launch agent."
fi
changed=0
