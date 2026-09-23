#!/bin/bash
# Installs Claude Code in the guest, for the `ubuntu` user, with the
# official native installer (https://code.claude.com/docs/en/setup.md):
# a single self-updating binary at ~/.local/bin/claude, linux-arm64
# supported. No Node.js needed (jammy's Node 12 is too old for the npm
# package anyway).
#
# Started by the app in the background every time the VM becomes ready;
# a no-op once `claude` exists. Log: ~/.cache/ios-claude-install.log
set -uo pipefail
mkdir -p "$HOME/.cache"

# ~/.profile only adds ~/.local/bin to PATH if it existed at login time;
# make it unconditional for new shells.
if ! grep -q 'ios-termux-sandbox: claude' "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" <<'RC'

# ios-termux-sandbox: claude
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
if [ -t 1 ] && [ ! -e "$HOME/.cache/ios-claude-hint" ]; then
    if [ -x "$HOME/.local/bin/claude" ]; then
        echo "Claude Code is installed — type: claude"
        mkdir -p "$HOME/.cache" && touch "$HOME/.cache/ios-claude-hint"
    else
        echo "Claude Code is being installed in the background (tail -f ~/.cache/ios-claude-install.log)"
    fi
fi
RC
fi

if [ -x "$HOME/.local/bin/claude" ]; then
    echo "Claude Code already installed: $("$HOME/.local/bin/claude" --version 2>/dev/null)"
    exit 0
fi

exec 9>"$HOME/.cache/ios-claude-install.lock"
flock -n 9 || { echo "install already running"; exit 0; }

echo "==> Installing Claude Code ($(date -u))"
for attempt in 1 2 3; do
    if curl -fsSL https://claude.ai/install.sh | bash; then
        echo "==> Done: $("$HOME/.local/bin/claude" --version 2>/dev/null)"
        exit 0
    fi
    echo "attempt $attempt failed, retrying in 30s"
    sleep 30
done
echo "==> Claude Code install failed; the app retries on next start. Manual: curl -fsSL https://claude.ai/install.sh | bash"
exit 1
