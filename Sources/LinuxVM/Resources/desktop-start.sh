#!/bin/bash
# Starts (or restarts) the VNC desktop on display :1 = guest port 5901,
# which QEMU forwards to 127.0.0.1:5901 on the phone.
# Usage: desktop-start.sh <width>x<height>   (VNC password in $IOS_VNC_PASSWORD)
set -euo pipefail
geometry="$1"
mkdir -p "$HOME/.vnc"
printf '%s\n' "$IOS_VNC_PASSWORD" | vncpasswd -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"
tigervncserver -kill :1 >/dev/null 2>&1 || true
# -localhost no: connections arrive from QEMU's user-mode gateway
# (10.0.2.2), not from the guest's loopback. The port is only forwarded to
# the phone's own loopback, and VncAuth is still required.
tigervncserver :1 \
    -geometry "$geometry" -depth 24 \
    -localhost no -SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd" \
    -AlwaysShared -xstartup /usr/local/bin/ios-desktop-session
echo "==> Desktop running on :1 ($geometry)"
