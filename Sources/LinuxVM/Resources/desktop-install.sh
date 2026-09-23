#!/bin/bash
# Installs the "Desktop" tab's guest side: a lean XFCE session served by
# TigerVNC. Run by the app over SSH as the `ubuntu` user (piped in, so the
# app bundle is the single source of truth). Safe to re-run.
#
# Tuned for running under QEMU TCG on a phone:
#   --no-install-recommends  keeps it to ~250 MB of packages instead of ~1 GB
#   no compositor            xfwm4 compositing is pure CPU cost under TCG
#   Xft DPI 120              readable text on a ~6.7" screen at the geometry
#                            the app asks for (see DesktopProfile.swift)
#   no screensaver/locker    nothing to wake up for inside a VM
set -euo pipefail
# Passed through sudo explicitly: sudo's env_reset drops an exported one,
# and debconf then tries to prompt on a terminal that isn't there.

echo "==> apt-get update"
sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update -q

echo "==> Installing XFCE + TigerVNC (the slow part under emulation)"
sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends \
    xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings xfconf \
    xfce4-terminal thunar mousepad \
    tigervnc-standalone-server tigervnc-tools \
    dbus-x11 at-spi2-core xfonts-base fonts-dejavu-core \
    adwaita-icon-theme gnome-themes-extra

echo "==> Session script"
sudo -n tee /usr/local/bin/ios-desktop-session >/dev/null <<'SESSION'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
exec dbus-launch --exit-with-session startxfce4
SESSION
sudo -n chmod 755 /usr/local/bin/ios-desktop-session

echo "==> XFCE settings for a phone screen and an emulated CPU"
conf="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$conf"
cat > "$conf/xfwm4.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Default-xhdpi"/>
    <property name="title_font" type="string" value="DejaVu Sans Bold 10"/>
    <property name="box_move" type="bool" value="true"/>
    <property name="box_resize" type="bool" value="true"/>
  </property>
</channel>
XML
cat > "$conf/xsettings.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita-dark"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="120"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="none"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="DejaVu Sans 10"/>
    <property name="CursorThemeSize" type="int" value="32"/>
  </property>
</channel>
XML
touch "$HOME/.ios-desktop-installed"
echo "==> Desktop installed"
