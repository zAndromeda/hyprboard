# Clipboard canvas (Quickshell + Hyprland)

## Install

```sh
mkdir -p ~/.config/quickshell/clip
cp shell.qml Pill.qml ~/.config/quickshell/clip/
```

Needs: `quickshell`, `cliphist`, `wl-clipboard`, Qt 6.5+.
Optional: `imagemagick` (caps huge images to 1200px thumbnails), `wtype` (paste-after-copy),
a pywal-format colours file (wallpaper theme).

## hyprland.conf

```ini
# the widget captures the clipboard itself (live), so you only need to start it:
exec-once = qs -c clip

# optional keybinds
bind = SUPER, V,       exec, qs -c clip ipc call clip toggle
bind = SUPER SHIFT, V, exec, qs -c clip ipc call clip pin

# optional blur (older layerrule syntax; newer Hyprland changed it, check the wiki)
layerrule = blur, clipcanvas
layerrule = ignorealpha 0.3, clipcanvas
```

If you already have `exec-once = wl-paste ... --watch cliphist store` lines, remove them.
They would just store each copy twice (cliphist de-duplicates, so it is harmless, only wasteful).

No keybind is needed to catch copies: the widget watches the Wayland clipboard, so Ctrl+C,
Ctrl+Shift+C and any "Copy" button all show up straight away. Highlighting text with the mouse
(primary selection) is not recorded.

## Using it

- Hover the top-right corner: the panel peeks in over the top-right quarter of the screen.
- Drag the grip (top-left of the panel) down or left: it grows to the right half and stays.
- Drag a pinned panel's grip back to the top-right corner: it hides again.
- New copies appear on the canvas live, even while pinned.
- Drag items anywhere. Click one to select it, then drag a corner to resize it.
- Items never end up on top of each other: after you drop or resize one, the others slide out of the way
  (turn it off in settings; "Tidy up now" re-runs it).
- Hover any item: it expands, and scales up when the canvas is zoomed out so it stays readable.
- Search box: type to dim everything that doesn't match. Just start typing on the canvas, or press Ctrl+F.
- Arrow keys move the selection, Enter copies, F2 (or double-click) edits text, Delete removes.
- `+ Note` makes a new note you can type into. Editing a clipboard item turns it into your own note.
- Pin keeps an item forever on a shelf along the top of the canvas, even after cliphist forgets it.
- ⚙ settings: wallpaper colours on/off, avoid-overlap on/off, paste-after-copy on/off, wipe everything
  (asks you to confirm first).

## Saved between restarts

Everything is stored in `~/.local/state/quickshell-clip/state.json` (layout, sizes, view, settings, pins, notes;
pinned images in `pins/`). Clipboard history itself lives in cliphist's own database, which also survives
reboots. Layouts are remembered separately for each monitor.

## Wallpaper colours

Reads `~/.cache/wal/colors.json` (pywal format) and follows it live. wallust, matugen and others can write
this format from a template. Toggle it off in settings to use the neutral grey theme.

## Paste after copy

Settings -> "Paste after copy" hides the panel and sends Ctrl+V with `wtype`. Terminals that paste with
Ctrl+Shift+V won't pick it up.
