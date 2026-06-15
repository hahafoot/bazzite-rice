#!/usr/bin/python3
# GTK4 monitor arranger for Hyprland.
# Pinned to the system interpreter: `env python3` resolves to linuxbrew's
# python3 in interactive shells, which has no `gi` (PyGObject) module.
#
# Reads the current monitor state from `hyprctl monitors -j`, lets you drag
# monitors around a canvas, change mode/scale/rotation/enabled, then live-applies
# via `hyprctl keyword monitor ...` and (on Save) writes the result to
# ~/.config/hypr/monitors.conf -- which hyprland.conf sources.
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, Gdk, GLib, Pango  # noqa: E402

import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

CONF_PATH = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "hypr" / "monitors.conf"

TRANSFORMS = [
    ("Normal", 0),
    ("90° CW", 1),
    ("180°", 2),
    ("270° CW", 3),
    ("Flipped", 4),
    ("Flipped + 90°", 5),
    ("Flipped + 180°", 6),
    ("Flipped + 270°", 7),
]
TRANSFORM_LABEL = {v: l for l, v in TRANSFORMS}


@dataclass
class Monitor:
    name: str
    description: str
    enabled: bool
    width: int
    height: int
    refresh: float
    x: int
    y: int
    scale: float
    transform: int
    available_modes: list = field(default_factory=list)

    @property
    def mode_str(self) -> str:
        return f"{self.width}x{self.height}@{self.refresh:g}"

    @property
    def logical_w(self) -> int:
        w = int(self.width / self.scale)
        h = int(self.height / self.scale)
        return h if self.transform % 2 else w

    @property
    def logical_h(self) -> int:
        w = int(self.width / self.scale)
        h = int(self.height / self.scale)
        return w if self.transform % 2 else h

    def to_monitor_line(self) -> str:
        if not self.enabled:
            return f"monitor = {self.name}, disable"
        base = f"monitor = {self.name}, {self.width}x{self.height}@{self.refresh:g}, {self.x}x{self.y}, {self.scale:g}"
        if self.transform:
            base += f", transform, {self.transform}"
        return base

    def to_keyword_arg(self) -> str:
        if not self.enabled:
            return f"{self.name}, disable"
        arg = f"{self.name}, {self.width}x{self.height}@{self.refresh:g}, {self.x}x{self.y}, {self.scale:g}"
        if self.transform:
            arg += f", transform, {self.transform}"
        return arg


def load_monitors() -> list[Monitor]:
    try:
        out = subprocess.check_output(["hyprctl", "monitors", "all", "-j"], text=True)
    except Exception as e:
        print(f"hyprctl failed: {e}", file=sys.stderr)
        return []
    data = json.loads(out)
    mons = []
    for m in data:
        mons.append(Monitor(
            name=m["name"],
            description=m.get("description", ""),
            enabled=not m.get("disabled", False),
            width=m["width"],
            height=m["height"],
            refresh=float(m.get("refreshRate", 60.0)),
            x=m.get("x", 0),
            y=m.get("y", 0),
            scale=float(m.get("scale", 1.0)),
            transform=int(m.get("transform", 0)),
            available_modes=m.get("availableModes", []),
        ))
    return mons


def parse_mode(s: str) -> Optional[tuple[int, int, float]]:
    # "2560x1440@165.00Hz" or "2560x1440@165"
    m = re.match(r"(\d+)x(\d+)@([\d.]+)", s)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), float(m.group(3))


class MonitorCanvas(Gtk.DrawingArea):
    def __init__(self, on_select, on_change):
        super().__init__()
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.set_draw_func(self._draw)
        self.monitors: list[Monitor] = []
        self.selected: Optional[Monitor] = None
        self.on_select = on_select
        self.on_change = on_change

        self._drag_mon: Optional[Monitor] = None
        self._drag_origin: tuple[int, int] = (0, 0)
        self._drag_pointer: tuple[float, float] = (0.0, 0.0)

        click = Gtk.GestureClick.new()
        click.connect("pressed", self._on_press)
        self.add_controller(click)

        drag = Gtk.GestureDrag.new()
        drag.connect("drag-begin", self._on_drag_begin)
        drag.connect("drag-update", self._on_drag_update)
        drag.connect("drag-end", self._on_drag_end)
        self.add_controller(drag)

    def set_monitors(self, mons: list[Monitor], keep_selection_name: Optional[str] = None):
        self.monitors = mons
        if keep_selection_name:
            self.selected = next((m for m in mons if m.name == keep_selection_name), None)
        else:
            self.selected = mons[0] if mons else None
        self.queue_draw()
        self.on_select(self.selected)

    def _bbox(self) -> tuple[int, int, int, int]:
        if not self.monitors:
            return 0, 0, 1, 1
        xs = [m.x for m in self.monitors] + [m.x + m.logical_w for m in self.monitors]
        ys = [m.y for m in self.monitors] + [m.y + m.logical_h for m in self.monitors]
        return min(xs), min(ys), max(xs), max(ys)

    def _scale_for(self, width: int, height: int) -> tuple[float, float, float]:
        x0, y0, x1, y1 = self._bbox()
        bw, bh = max(1, x1 - x0), max(1, y1 - y0)
        pad = 40
        sx = (width - 2 * pad) / bw
        sy = (height - 2 * pad) / bh
        s = min(sx, sy)
        ox = pad - x0 * s + (width - 2 * pad - bw * s) / 2
        oy = pad - y0 * s + (height - 2 * pad - bh * s) / 2
        return s, ox, oy

    def _draw(self, area, cr, width, height):
        cr.set_source_rgb(0.12, 0.12, 0.15)
        cr.paint()

        if not self.monitors:
            cr.set_source_rgb(0.7, 0.7, 0.7)
            cr.select_font_face("Sans")
            cr.set_font_size(14)
            cr.move_to(20, 30)
            cr.show_text("No monitors detected. Is Hyprland running?")
            return

        s, ox, oy = self._scale_for(width, height)

        for mon in self.monitors:
            x = mon.x * s + ox
            y = mon.y * s + oy
            w = mon.logical_w * s
            h = mon.logical_h * s

            if not mon.enabled:
                cr.set_source_rgba(0.3, 0.3, 0.3, 0.6)
            elif mon is self.selected:
                cr.set_source_rgb(0.20, 0.27, 0.43)
            else:
                cr.set_source_rgb(0.22, 0.22, 0.28)
            cr.rectangle(x, y, w, h)
            cr.fill()

            if mon is self.selected:
                cr.set_source_rgb(0.66, 0.81, 0.93)
                cr.set_line_width(3)
            else:
                cr.set_source_rgb(0.45, 0.45, 0.55)
                cr.set_line_width(1.5)
            cr.rectangle(x, y, w, h)
            cr.stroke()

            cr.set_source_rgb(0.95, 0.95, 0.98)
            cr.select_font_face("Sans", 0, 1)
            cr.set_font_size(max(10, min(18, h / 8)))
            label = mon.name + ("" if mon.enabled else "  (off)")
            ext = cr.text_extents(label)
            cr.move_to(x + (w - ext.width) / 2, y + h / 2 - 4)
            cr.show_text(label)

            cr.set_source_rgb(0.75, 0.75, 0.85)
            cr.select_font_face("Sans")
            cr.set_font_size(max(8, min(13, h / 12)))
            sub = f"{mon.width}×{mon.height} @{mon.refresh:g}  ×{mon.scale:g}"
            if mon.transform:
                sub += f"  ⟳{mon.transform * 90 % 360}°"
            ext = cr.text_extents(sub)
            cr.move_to(x + (w - ext.width) / 2, y + h / 2 + 14)
            cr.show_text(sub)

    def _hit(self, px: float, py: float) -> Optional[Monitor]:
        w = self.get_width()
        h = self.get_height()
        s, ox, oy = self._scale_for(w, h)
        # iterate top-most last so selection prefers last drawn
        for mon in reversed(self.monitors):
            x = mon.x * s + ox
            y = mon.y * s + oy
            mw = mon.logical_w * s
            mh = mon.logical_h * s
            if x <= px <= x + mw and y <= py <= y + mh:
                return mon
        return None

    def _on_press(self, gesture, n_press, x, y):
        m = self._hit(x, y)
        self.selected = m
        self.queue_draw()
        self.on_select(m)

    def _on_drag_begin(self, gesture, sx, sy):
        m = self._hit(sx, sy)
        if not m or not m.enabled:
            self._drag_mon = None
            return
        self._drag_mon = m
        self._drag_origin = (m.x, m.y)
        self._drag_pointer = (sx, sy)
        self.selected = m
        self.on_select(m)
        self.queue_draw()

    def _on_drag_update(self, gesture, dx, dy):
        if not self._drag_mon:
            return
        w = self.get_width()
        h = self.get_height()
        s, _ox, _oy = self._scale_for(w, h)
        if s <= 0:
            return
        new_x = int(self._drag_origin[0] + dx / s)
        new_y = int(self._drag_origin[1] + dy / s)
        # snap to edges of other monitors within ~20 logical px
        snap = 20
        for other in self.monitors:
            if other is self._drag_mon or not other.enabled:
                continue
            for cand in (other.x, other.x + other.logical_w, other.x - self._drag_mon.logical_w):
                if abs(new_x - cand) < snap:
                    new_x = cand
                    break
            for cand in (other.y, other.y + other.logical_h, other.y - self._drag_mon.logical_h):
                if abs(new_y - cand) < snap:
                    new_y = cand
                    break
        self._drag_mon.x = new_x
        self._drag_mon.y = new_y
        self.queue_draw()
        self.on_change()

    def _on_drag_end(self, gesture, dx, dy):
        self._drag_mon = None


class MonitorArranger(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title("Hyprland Monitor Arranger")
        self.set_default_size(1000, 640)

        self._loading = False

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_child(root)

        header = Gtk.HeaderBar()
        self.set_titlebar(header)

        reload_btn = Gtk.Button(label="Reload")
        reload_btn.connect("clicked", lambda *_: self.reload_state(apply=False))
        header.pack_start(reload_btn)

        apply_btn = Gtk.Button(label="Apply (live)")
        apply_btn.add_css_class("suggested-action")
        apply_btn.connect("clicked", lambda *_: self.apply_live())
        header.pack_end(apply_btn)

        save_btn = Gtk.Button(label="Save")
        save_btn.connect("clicked", lambda *_: self.save_persistent())
        header.pack_end(save_btn)

        # Body: canvas on left, properties on right
        body = Gtk.Paned(orientation=Gtk.Orientation.HORIZONTAL)
        body.set_vexpand(True)
        body.set_position(640)
        root.append(body)

        self.canvas = MonitorCanvas(on_select=self._on_canvas_select, on_change=self._on_canvas_change)
        body.set_start_child(self.canvas)
        body.set_resize_start_child(True)

        # Properties panel
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        side.set_margin_start(12); side.set_margin_end(12)
        side.set_margin_top(12); side.set_margin_bottom(12)
        body.set_end_child(side)

        self.title_lbl = Gtk.Label(xalign=0)
        self.title_lbl.add_css_class("title-3")
        side.append(self.title_lbl)

        self.desc_lbl = Gtk.Label(xalign=0)
        self.desc_lbl.set_wrap(True)
        self.desc_lbl.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self.desc_lbl.add_css_class("dim-label")
        side.append(self.desc_lbl)

        self.enabled_chk = Gtk.CheckButton(label="Enabled")
        self.enabled_chk.connect("toggled", self._on_enabled_toggled)
        side.append(self.enabled_chk)

        grid = Gtk.Grid(column_spacing=10, row_spacing=8)
        side.append(grid)

        grid.attach(Gtk.Label(label="Mode", xalign=0), 0, 0, 1, 1)
        self.mode_combo = Gtk.ComboBoxText()
        self.mode_combo.connect("changed", self._on_mode_changed)
        self.mode_combo.set_hexpand(True)
        grid.attach(self.mode_combo, 1, 0, 1, 1)

        grid.attach(Gtk.Label(label="Scale", xalign=0), 0, 1, 1, 1)
        self.scale_spin = Gtk.SpinButton.new_with_range(0.5, 4.0, 0.05)
        self.scale_spin.set_digits(2)
        self.scale_spin.connect("value-changed", self._on_scale_changed)
        grid.attach(self.scale_spin, 1, 1, 1, 1)

        grid.attach(Gtk.Label(label="Rotation", xalign=0), 0, 2, 1, 1)
        self.rot_combo = Gtk.ComboBoxText()
        for label, _v in TRANSFORMS:
            self.rot_combo.append_text(label)
        self.rot_combo.connect("changed", self._on_rot_changed)
        grid.attach(self.rot_combo, 1, 2, 1, 1)

        grid.attach(Gtk.Label(label="Position X", xalign=0), 0, 3, 1, 1)
        self.x_spin = Gtk.SpinButton.new_with_range(-20000, 20000, 10)
        self.x_spin.connect("value-changed", self._on_pos_changed)
        grid.attach(self.x_spin, 1, 3, 1, 1)

        grid.attach(Gtk.Label(label="Position Y", xalign=0), 0, 4, 1, 1)
        self.y_spin = Gtk.SpinButton.new_with_range(-20000, 20000, 10)
        self.y_spin.connect("value-changed", self._on_pos_changed)
        grid.attach(self.y_spin, 1, 4, 1, 1)

        # Footer hint
        hint = Gtk.Label(xalign=0)
        hint.set_markup(
            "<small>Drag monitors to position. <b>Apply</b> tests changes live, "
            f"<b>Save</b> writes to <tt>{CONF_PATH}</tt>.</small>"
        )
        hint.set_wrap(True)
        hint.add_css_class("dim-label")
        side.append(hint)

        self.status_lbl = Gtk.Label(xalign=0)
        self.status_lbl.add_css_class("dim-label")
        side.append(self.status_lbl)

        self.reload_state(apply=False)

    # ---- data flow ----

    def reload_state(self, apply: bool):
        keep = self.canvas.selected.name if self.canvas.selected else None
        mons = load_monitors()
        if not mons:
            self._set_status("hyprctl returned no monitors")
        self.canvas.set_monitors(mons, keep_selection_name=keep)

    def _on_canvas_select(self, mon: Optional[Monitor]):
        self._loading = True
        try:
            if not mon:
                self.title_lbl.set_text("(no monitor selected)")
                self.desc_lbl.set_text("")
                self.enabled_chk.set_sensitive(False)
                self.mode_combo.set_sensitive(False)
                self.scale_spin.set_sensitive(False)
                self.rot_combo.set_sensitive(False)
                self.x_spin.set_sensitive(False)
                self.y_spin.set_sensitive(False)
                return

            self.title_lbl.set_text(mon.name)
            self.desc_lbl.set_text(mon.description)
            self.enabled_chk.set_sensitive(True)
            self.enabled_chk.set_active(mon.enabled)

            self.mode_combo.set_sensitive(mon.enabled)
            self.mode_combo.remove_all()
            seen = set()
            current = mon.mode_str
            modes = list(mon.available_modes)
            if current not in modes and current.split("@")[0]:
                modes.insert(0, current)
            for m in modes:
                key = m.replace("Hz", "")
                if key in seen:
                    continue
                seen.add(key)
                self.mode_combo.append_text(key)
            for i, m in enumerate(self.mode_combo.get_model()):
                if m[0] == current:
                    self.mode_combo.set_active(i)
                    break
            else:
                if len(self.mode_combo.get_model()):
                    self.mode_combo.set_active(0)

            self.scale_spin.set_sensitive(mon.enabled)
            self.scale_spin.set_value(mon.scale)

            self.rot_combo.set_sensitive(mon.enabled)
            self.rot_combo.set_active(mon.transform)

            self.x_spin.set_sensitive(mon.enabled)
            self.x_spin.set_value(mon.x)
            self.y_spin.set_sensitive(mon.enabled)
            self.y_spin.set_value(mon.y)
        finally:
            self._loading = False

    def _on_canvas_change(self):
        if self._loading or not self.canvas.selected:
            return
        self._loading = True
        try:
            self.x_spin.set_value(self.canvas.selected.x)
            self.y_spin.set_value(self.canvas.selected.y)
        finally:
            self._loading = False

    def _on_enabled_toggled(self, btn):
        if self._loading or not self.canvas.selected:
            return
        self.canvas.selected.enabled = btn.get_active()
        self.canvas.queue_draw()
        self._on_canvas_select(self.canvas.selected)

    def _on_mode_changed(self, combo):
        if self._loading or not self.canvas.selected:
            return
        text = combo.get_active_text()
        if not text:
            return
        parsed = parse_mode(text)
        if not parsed:
            return
        w, h, r = parsed
        self.canvas.selected.width = w
        self.canvas.selected.height = h
        self.canvas.selected.refresh = r
        self.canvas.queue_draw()

    def _on_scale_changed(self, spin):
        if self._loading or not self.canvas.selected:
            return
        self.canvas.selected.scale = round(spin.get_value(), 2)
        self.canvas.queue_draw()

    def _on_rot_changed(self, combo):
        if self._loading or not self.canvas.selected:
            return
        i = combo.get_active()
        if i < 0:
            return
        self.canvas.selected.transform = TRANSFORMS[i][1]
        self.canvas.queue_draw()

    def _on_pos_changed(self, spin):
        if self._loading or not self.canvas.selected:
            return
        self.canvas.selected.x = int(self.x_spin.get_value())
        self.canvas.selected.y = int(self.y_spin.get_value())
        self.canvas.queue_draw()

    # ---- actions ----

    def apply_live(self):
        errors = []
        for mon in self.canvas.monitors:
            try:
                subprocess.run(
                    ["hyprctl", "keyword", "monitor", mon.to_keyword_arg()],
                    check=True, capture_output=True, text=True,
                )
            except subprocess.CalledProcessError as e:
                errors.append(f"{mon.name}: {e.stderr.strip() or e.stdout.strip() or e}")
        if errors:
            self._set_status("apply failed: " + "; ".join(errors))
        else:
            self._set_status("applied live (not yet persisted -- click Save)")

    def save_persistent(self):
        self.apply_live()
        CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
        header = (
            "# Managed by monitor-arranger.py. Hand edits are preserved on next read,\n"
            "# but will be overwritten the next time you click Save in the GUI.\n"
            "# Sourced by hyprland.conf via `source = ~/.config/hypr/monitors.conf`.\n"
        )
        body = "\n".join(m.to_monitor_line() for m in self.canvas.monitors)
        fallback = "\nmonitor = , preferred, auto, 1\n"

        # Write through the symlink if present so the dotfiles repo picks it up.
        target = CONF_PATH
        if target.is_symlink():
            try:
                target = Path(os.readlink(target))
                if not target.is_absolute():
                    target = CONF_PATH.parent / target
            except OSError:
                target = CONF_PATH

        tmp = target.with_suffix(target.suffix + ".tmp")
        tmp.write_text(header + body + fallback)
        shutil.move(str(tmp), str(target))
        self._set_status(f"saved to {target}")
        try:
            subprocess.run(["notify-send", "monitor-arranger", f"saved {target.name}"], check=False)
        except FileNotFoundError:
            pass

    def _set_status(self, msg: str):
        self.status_lbl.set_text(msg)
        GLib.timeout_add_seconds(8, lambda: self.status_lbl.set_text("") or False)


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="dev.hahafoot.monitor-arranger")

    def do_activate(self):
        win = MonitorArranger(self)
        win.present()


if __name__ == "__main__":
    sys.exit(App().run(sys.argv))
