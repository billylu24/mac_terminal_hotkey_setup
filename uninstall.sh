#!/bin/bash
set -euo pipefail

install_home="${TERMINAL_HOTKEY_HOME:-$HOME}"
install_dir="$install_home/Library/Application Support/TerminalHotkey"
agent_path="$install_home/Library/LaunchAgents/local.terminal-hotkey.plist"

if [[ "${TERMINAL_HOTKEY_SKIP_LAUNCH:-0}" != "1" ]]; then
  launchctl bootout "gui/$(id -u)/local.terminal-hotkey" >/dev/null 2>&1 || true
fi
rm -f "$agent_path"
rm -rf "$install_dir/Terminal Hotkeys.app"
echo "Terminal hotkeys removed. Logs, source, and backups in $install_dir were kept."
