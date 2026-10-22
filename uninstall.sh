#!/bin/bash
set -u

if command -v insomnia >/dev/null 2>&1; then
  insomnia off --all 2>/dev/null || true
fi
launchctl bootout "gui/$(id -u)/com.oddproblems.insomnia.heal" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.oddproblems.insomnia.heal.plist"
pkill -x InsomniaBar 2>/dev/null || true
rm -rf "$HOME/Applications/Insomnia.app"
rm -f "$HOME/.local/bin/insomnia"
[ -L "$HOME/.claude/skills/insomnia" ] && rm -f "$HOME/.claude/skills/insomnia"
if [ -f /etc/sudoers.d/insomnia ]; then
  echo "Removing the no-password rule (asks for your password):"
  sudo rm -f /etc/sudoers.d/insomnia
fi
echo "Insomnia removed. If it is still listed under System Settings > General > Login Items, remove it there."
