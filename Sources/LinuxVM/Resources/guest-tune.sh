#!/bin/bash
# Run by the app (as `ubuntu`, passwordless sudo) every time it connects.
# Idempotent and quick. Turns off stock-server background work that costs
# real CPU under emulation and gets in the way of an interactive VM:
#  - update-motd scripts: every SSH login ran update-notifier's apt-check,
#    a Python process pegging a vCPU for a minute+ under TCG
#  - apt-daily / unattended-upgrades: random apt runs that hold the dpkg
#    lock (the Desktop install would fail on it) and burn CPU/battery
# `sudo apt upgrade` by hand keeps working as usual.
sudo -n chmod -x /etc/update-motd.d/* 2>/dev/null || true
sudo -n systemctl disable --now \
    apt-daily.timer apt-daily-upgrade.timer motd-news.timer \
    unattended-upgrades.service >/dev/null 2>&1 || true
exit 0
