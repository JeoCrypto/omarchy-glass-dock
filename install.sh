#!/bin/bash

# Install Glass Dock for the current user.
# Copies the dock into ~/.config/quickshell/glass-dock and creates a default
# pinned-apps list if there isn't one. Does not touch your Hyprland config;
# see README.md for autostart and blur.

set -e

src="$(cd "$(dirname "$0")" && pwd)"
dock_dir="$HOME/.config/quickshell/glass-dock"
config_dir="$HOME/.config/glass-dock"

mkdir -p "$dock_dir" "$config_dir"
cp "$src/shell.qml" "$dock_dir/shell.qml"

if [[ ! -f $config_dir/pinned ]]; then
  cat >"$config_dir/pinned" <<'EOF'
# One desktop-file id per line (the .desktop file name without the extension).
org.gnome.Nautilus
chromium
foot
EOF
fi

echo "Glass Dock installed to $dock_dir"
echo
echo "Start it now:        qs -c glass-dock &"
echo "Pinned apps:         $config_dir/pinned"
echo "Autostart and blur:  see README.md"
