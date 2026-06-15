#!/usr/bin/python3
"""SUPER+SHIFT+ENTER: open a kitty terminal in the focused file-manager's folder.

If the currently focused window is a Nautilus (Files) window, open kitty in the
directory that window is showing. Otherwise just open a normal kitty.

Nautilus does not expose its current location over D-Bus, so we read it off the
header-bar breadcrumb via AT-SPI: the first breadcrumb button is the root anchor
("Home" for $HOME, the host name for "/"), and the buttons after it are the path
components. We reconstruct the path and confirm it exists before using it.
"""
import os
import sys
import subprocess

KITTY = "kitty"


def launch(directory=None):
    if directory and os.path.isdir(directory):
        os.execvp(KITTY, [KITTY, "--directory", directory])
    os.execvp(KITTY, [KITTY])


def focused_is_nautilus():
    """Ask Hyprland whether the active window is a Nautilus window."""
    try:
        out = subprocess.run(
            ["hyprctl", "activewindow", "-j"],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return False
    import json
    try:
        cls = (json.loads(out).get("class") or "").lower()
    except Exception:
        return False
    return "nautilus" in cls or "org.gnome.files" in cls


def nautilus_dir():
    """Return the folder shown by the active Nautilus window, or None."""
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi

    Atspi.init()
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if "nautilus" not in (app.get_name() or "").lower():
            continue
        for f in range(app.get_child_count()):
            frame = app.get_child_at_index(f)
            st = frame.get_state_set()
            if not (st and st.contains(Atspi.StateType.ACTIVE)):
                continue
            return _path_from_breadcrumb(frame)
    return None


def _path_from_breadcrumb(frame):
    buttons = []  # (name, desc) in document order

    def walk(node, depth=0):
        if node is None or depth > 25:
            return
        try:
            role = node.get_role_name()
            name = node.get_name()
            desc = node.get_description()
        except Exception:
            return
        if role in ("push button", "button"):
            buttons.append((name or "", desc or ""))
        for j in range(node.get_child_count()):
            walk(node.get_child_at_index(j), depth + 1)

    walk(frame)

    names = [b[0] for b in buttons]
    try:
        start = names.index("Forward") + 1
    except ValueError:
        return None
    # Breadcrumb ends at the "Current Folder Menu" button.
    end = len(buttons)
    for k in range(start, len(buttons)):
        if names[k] == "Current Folder Menu":
            end = k
            break
    crumbs = buttons[start:end]
    if not crumbs:
        return None

    def label(b):
        # Anchor button repeats its text ("Home Home") and carries a clean desc;
        # component buttons have an empty desc and a single-word name.
        return b[1] if b[1] else b[0]

    anchor = label(crumbs[0])
    comps = [label(b) for b in crumbs[1:]]

    home = os.path.expanduser("~")
    home_path = os.path.join(home, *comps) if comps else home
    root_path = "/" + "/".join(comps) if comps else "/"

    order = [home_path, root_path] if anchor == "Home" else [root_path, home_path]
    for p in order:
        if os.path.isdir(p):
            return p
    return None


def main():
    directory = None
    if focused_is_nautilus():
        try:
            directory = nautilus_dir()
        except Exception:
            directory = None
    if "--dry" in sys.argv:
        print(directory)
        return
    launch(directory)


if __name__ == "__main__":
    main()
