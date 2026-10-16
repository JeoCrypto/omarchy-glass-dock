# Glass Dock

A small, pixel-aligned, macOS-style dock for [Omarchy](https://omarchy.org) and Hyprland, built with [Quickshell](https://quickshell.org) (which Omarchy already ships).

![Glass Dock preview](preview.png)

- **Sharp on HiDPI.** Icons load at full device resolution. The geometry uses whole logical pixels and the border is a one-physical-pixel hairline at 2×, so nothing gets upscaled or blurred.
- **Follows your Omarchy theme.** Colours come from the active theme and update live when you switch themes.
- **Auto-hides.** It slides up when the pointer reaches the bottom edge and hides again shortly after the pointer leaves.
- **macOS-style touches:** a running-app dot under each icon, the app name above the hovered icon, and a hand-drawn app-grid button that opens Omarchy's Apps menu.
- **Click behaviour:** click opens or focuses an app, clicking again cycles through its windows, and middle-click opens a new window.

## Install

Glass Dock is an Omarchy shell plugin:

```bash
omarchy plugin add https://github.com/JeoCrypto/omarchy-glass-dock --enable
```

It loads with the Omarchy shell, so there's nothing to add to your autostart.

### Frosted blur (recommended)

Add to `~/.config/hypr/looknfeel.lua`:

```lua
hl.layer_rule({ match = { namespace = "^glass-dock$" }, blur = true, ignore_alpha = 0.2 })
```

### Update

```bash
omarchy plugin update io.github.jeocrypto.glass-dock
omarchy restart shell
```

The dock stays loaded while the shell runs, so restart the shell to pick up a new version.

### Remove

```bash
omarchy plugin remove io.github.jeocrypto.glass-dock
```

Your pinned-apps and aliases files in `~/.config/glass-dock/` are left in place; delete that folder if you don't want them.

### Run without the plugin system (optional)

Glass Dock can also run as its own Quickshell instance:

```bash
git clone https://github.com/JeoCrypto/omarchy-glass-dock
cd omarchy-glass-dock
./install.sh
qs -c glass-dock &
```

To start it at login, add `o.launch_on_start("qs -c glass-dock")` to `~/.config/hypr/autostart.lua`.

## Configure

| File | What it does |
|---|---|
| `~/.config/glass-dock/pinned` | Pinned apps: one desktop-file id per line, e.g. `org.gnome.Nautilus`, `chromium`, `foot`. Without this file the dock pins Files, Chromium and Foot. Changes apply immediately. |
| `~/.config/glass-dock/aliases` | Optional `<app-id> <desktop-id>` pairs, for windows whose app id doesn't match a desktop file (e.g. `my.custom.terminal foot`). |
| `~/.config/glass-dock/launcher` | Optional command for the app-grid button (default `omarchy-menu toggle apps`), e.g. `omarchy-shell shell toggle io.github.jeocrypto.launchpad`. |

Sizes (icon size, cell size, gaps, padding, radius) are at the top of `Dock.qml` (`~/.config/omarchy/plugins/io.github.jeocrypto.glass-dock/Dock.qml` when installed as a plugin).

To show or hide the dock from a keybinding or script:

```bash
omarchy-shell glass-dock toggle                   # plugin
qs -c glass-dock ipc call glass-dock toggle       # standalone
```

## Requirements

- Omarchy 4 (Hyprland 0.55+ with Lua config, Quickshell 0.3+)
- `uwsm` and `gtk-launch`, which Omarchy includes

## License

MIT
