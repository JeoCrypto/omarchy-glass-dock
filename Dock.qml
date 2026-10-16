// Glass Dock: a small, pixel-aligned macOS-style dock for Omarchy / Hyprland.
// Loaded as an Omarchy shell plugin (manifest.json, kind "panel", keepLoaded),
// or standalone through shell.qml with `qs -c glass-dock`.
//
//   ~/.config/glass-dock/pinned   one desktop-file id per line (e.g. org.gnome.Nautilus)
//   ~/.config/glass-dock/aliases  optional "<app-id> <desktop-id>" pairs, for windows
//                                 whose app id doesn't match a desktop file
//
// Colours follow the current Omarchy theme.
//
// All geometry is in whole logical pixels; at 2x scaling every edge lands on
// a physical pixel. Icons are loaded at device resolution (IconImage), so they
// stay sharp instead of being upscaled.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

Item {
  id: root

  // Injected by the Omarchy shell when loaded as a plugin; unused here.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  // Panel lifecycle (`omarchy-shell shell summon|hide <id>`): show or hide the dock.
  property bool opened: revealed
  // Stays up until close(), or until the pointer enters the dock and leaves it.
  function open() { hideTimer.stop(); revealed = true }
  function close() { revealed = false }

  // ---- Geometry (logical px) ----
  readonly property int iconSize: 32
  readonly property int cellSize: 40
  readonly property int cellGap: 4
  readonly property int padding: 6
  readonly property int radius: 16
  readonly property int bottomMargin: 6
  readonly property int dotSize: 4
  readonly property int labelSpace: 34   // room above the dock for the hover label
  readonly property int dockHeight: padding * 2 + cellSize

  // ---- Theme ----
  property color bg: "#1c1917"
  property color fg: "#f6efe7"
  property color accent: "#e8743b"

  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    __printErrors: false
    onFileChanged: reload()
    onLoaded: {
      const pick = (key) => {
        const m = text().match(new RegExp("^" + key + "\\s*=\\s*\"(#[0-9a-fA-F]{6})\"", "m"))
        return m ? m[1] : null
      }
      root.bg = pick("background") || root.bg
      root.fg = pick("bright_foreground") || pick("foreground") || root.fg
      root.accent = pick("accent") || root.accent
    }
  }

  // Switching themes replaces the theme directory, which drops the file watch,
  // so re-read the colours periodically as well.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: themeColors.reload()
  }

  // ---- Pinned apps ----
  // Used until ~/.config/glass-dock/pinned exists
  readonly property var defaultPinned: ["org.gnome.Nautilus", "chromium", "foot"]
  property var pinned: defaultPinned

  readonly property string configDir: Quickshell.env("HOME") + "/.config/glass-dock"

  FileView {
    path: root.configDir + "/pinned"
    watchChanges: true
    onFileChanged: reload()
    __printErrors: false
    onLoaded: root.pinned = text().split("\n").map(s => s.trim()).filter(s => s && !s.startsWith("#"))
    onLoadFailed: root.pinned = root.defaultPinned
  }

  // Map an app id to a desktop entry, with optional user aliases.
  property var aliases: ({})

  FileView {
    path: root.configDir + "/aliases"
    watchChanges: true
    __printErrors: false
    onFileChanged: reload()
    onLoaded: {
      const map = {}
      for (const line of text().split("\n")) {
        const parts = line.trim().split(/\s+/)
        if (parts.length === 2 && !parts[0].startsWith("#")) map[parts[0]] = parts[1]
      }
      root.aliases = map
    }
  }

  function entryFor(appId) {
    if (!appId) return null
    return DesktopEntries.byId(aliases[appId] || appId) || DesktopEntries.heuristicLookup(aliases[appId] || appId)
  }

  function entryKey(appId) {
    const e = entryFor(appId)
    return e ? e.id : appId
  }

  // Windows that should never show up in the dock (Omarchy's screensaver, etc.)
  readonly property var ignoredAppIds: /^(org\.omarchy\.screensaver)$/

  // Pinned apps first (in order), then running apps that aren't pinned.
  readonly property var items: {
    const toplevels = ToplevelManager.toplevels.values
    // Re-evaluate once desktop entries finish loading (byId is null until then).
    const _apps = DesktopEntries.applications.values.length
    const out = []
    const seen = {}
    for (const id of pinned) {
      const e = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id)
      if (!e || seen[e.id]) continue
      seen[e.id] = true
      out.push({ key: e.id, entry: e, appId: id })
    }
    for (const t of toplevels) {
      if (ignoredAppIds.test(t.appId)) continue
      const key = entryKey(t.appId)
      if (seen[key]) continue
      seen[key] = true
      out.push({ key: key, entry: entryFor(t.appId), appId: t.appId })
    }
    return out
  }

  function windowsFor(key) {
    return ToplevelManager.toplevels.values.filter(t => !ignoredAppIds.test(t.appId) && entryKey(t.appId) === key)
  }

  function activate(item) {
    const wins = windowsFor(item.key)
    if (wins.length === 0) {
      Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", item.key])
    } else {
      // Focus the app; if it's already focused, cycle to its next window.
      const i = wins.findIndex(w => w.activated)
      wins[i >= 0 ? (i + 1) % wins.length : 0].activate()
    }
    dock.hide()
  }

  // ---- Auto-hide ----
  property bool revealed: false

  // qs -c glass-dock ipc call glass-dock toggle|reveal|conceal (standalone), or
  // omarchy-shell glass-dock toggle (plugin)
  IpcHandler {
    target: "glass-dock"
    function reveal(): void { root.revealed = true; hideTimer.restart() }
    function conceal(): void { root.revealed = false }
    function toggle(): void { root.revealed = !root.revealed }
  }

  Timer {
    id: hideTimer
    interval: 450
    onTriggered: if (!dockHover.hovered) root.revealed = false
  }

  // Thin invisible strip along the bottom edge that reveals the dock.
  PanelWindow {
    anchors { left: true; right: true; bottom: true }
    implicitHeight: 2
    color: "transparent"
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "glass-dock-hotspot"

    HoverHandler {
      onHoveredChanged: {
        if (hovered) { root.revealed = true; hideTimer.stop() }
        else hideTimer.restart()
      }
    }
  }

  PanelWindow {
    id: dock
    anchors.bottom: true
    margins.bottom: root.bottomMargin
    implicitWidth: Math.max(card.width, 1) + 40   // side room for edge labels
    implicitHeight: root.dockHeight + root.labelSpace
    color: "transparent"
    exclusiveZone: 0
    visible: root.revealed || card.y < card.hiddenY
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "glass-dock"

    // Only the card itself takes input; the label area is click-through.
    mask: Region { item: card }

    function hide() { root.revealed = false }

    HoverHandler {
      id: dockHover
      onHoveredChanged: hovered ? hideTimer.stop() : hideTimer.restart()
    }

    Rectangle {
      id: card
      anchors.horizontalCenter: parent.horizontalCenter
      readonly property int hiddenY: root.labelSpace + root.dockHeight + root.bottomMargin
      y: root.revealed ? root.labelSpace : hiddenY
      width: row.width + root.padding * 2
      height: root.dockHeight
      radius: root.radius
      color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 0.55)
      // Hairline: half a logical pixel is exactly one physical pixel at 2x.
      border.width: 0.5
      border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)

      Behavior on y { NumberAnimation { id: slide; duration: 220; easing.type: Easing.OutCubic } }

      Row {
        id: row
        x: root.padding
        y: root.padding
        spacing: root.cellGap

        // Launcher (apps grid), drawn so it is crisp at any scale.
        DockCell {
          label: "Apps"
          onActivated: { Quickshell.execDetached(["omarchy-menu", "toggle", "apps"]); dock.hide() }

          Grid {
            anchors.centerIn: parent
            columns: 3
            spacing: 3
            Repeater {
              model: 9
              Rectangle { width: 5; height: 5; radius: 1.5; color: root.accent }
            }
          }
        }

        // Thin divider between the launcher and apps
        Item {
          width: 1; height: root.cellSize
          Rectangle {
            anchors.centerIn: parent
            width: 0.5; height: 24
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
          }
        }

        Repeater {
          model: root.items

          DockCell {
            required property var modelData
            readonly property int windowCount: root.windowsFor(modelData.key).length
            label: modelData.entry ? modelData.entry.name : modelData.appId
            running: windowCount > 0
            onActivated: root.activate(modelData)
            onMiddleClicked: Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", modelData.key])

            IconImage {
              anchors.centerIn: parent
              implicitSize: root.iconSize
              source: Quickshell.iconPath(modelData.entry ? modelData.entry.icon : modelData.appId, "application-x-executable")
              asynchronous: true
            }
          }
        }
      }
    }
  }

  // One square cell: hover highlight, running dot and a label above.
  component DockCell: Item {
    id: cell
    property string label: ""
    property bool running: false
    signal activated()
    signal middleClicked()

    width: root.cellSize
    height: root.cellSize

    Rectangle {
      anchors.fill: parent
      radius: 10
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, mouse.pressed ? 0.18 : 0.10)
      opacity: mouse.containsMouse ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // Running indicator, centred in the bottom padding
    Rectangle {
      visible: cell.running
      width: root.dotSize; height: root.dotSize; radius: root.dotSize / 2
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height + 1
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.75)
    }

    // macOS-style name label above the hovered icon
    Rectangle {
      visible: mouse.containsMouse && cell.label !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      y: -root.padding - height - 8
      width: labelText.implicitWidth + 20
      height: 24
      radius: 8
      color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 0.92)
      border.width: 0.5
      border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)

      Text {
        id: labelText
        anchors.centerIn: parent
        text: cell.label
        color: root.fg
        font.family: "sans-serif"
        font.pixelSize: 12
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onClicked: (e) => e.button === Qt.MiddleButton ? cell.middleClicked() : cell.activated()
    }
  }
}
