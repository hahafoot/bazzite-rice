# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Two coupled things, not one:

1. **A BlueBuild recipe** ([recipes/recipe.yml](recipes/recipe.yml)) that bakes a custom Bazzite GNOME + Hyprland OS image, built by GitHub Actions and published to `ghcr.io/hahafoot/bazzite-rice:latest`. Users `rpm-ostree rebase` onto it.
2. **A dotfiles tree** ([dotfiles/](dotfiles/)) symlinked into `~/.config/` (and `$HOME` for `home/*`) by [dotfiles/install.sh](dotfiles/install.sh). This is the Hyprland rice itself — the *running config* on a machine that has rebased to the image above.

The image and the dotfiles are independent: the image only provides binaries (Hyprland, Waybar, swww, mpvpaper, etc.); all behavior lives in `dotfiles/`. You can iterate on the rice locally without ever rebuilding the image.

Read [README.md](README.md) for the user-facing install flow and [instructions.md](instructions.md) for background on the three Bazzite-Hyprland approaches (this repo implements Method B).

## Working in the dotfiles (the common case)

Edits under `dotfiles/` take effect immediately on the live system because `install.sh` has symlinked the files into `~/.config/`. **You are editing the live config.** There is no build step.

After editing:

| Changed | How to reload |
|---|---|
| `dotfiles/hypr/hyprland.conf` | `hyprctl reload` (or `SUPER+CTRL+SHIFT+R`) |
| `dotfiles/hypr/workspace-watcher.lua` `RULES` table | `SUPER+SHIFT+R` (runs [dotfiles/hypr/reload-watcher.lua](dotfiles/hypr/reload-watcher.lua)) — the watcher reads `RULES` once at startup, so the running watcher is stale until restarted |
| `dotfiles/waybar/*` | `SUPER+SHIFT+B` (kills + relaunches waybar) |
| `dotfiles/hypr/monitors.conf` | `hyprctl reload`. Or run `~/.config/hypr/monitor-arranger.py` (`SUPER+SHIFT+D`) — it edits `monitors.conf` *through the symlink* so the repo picks up the change |
| New file added under `dotfiles/` | re-run `bash dotfiles/install.sh` to create the symlink |

Adding a *new* dotfile: drop it under `dotfiles/<subdir>/`, re-run `install.sh`. Files under `dotfiles/home/` symlink to `$HOME` directly (for `.zshrc`, `.p10k.zsh`); everything else symlinks to `$XDG_CONFIG_HOME`.

## Working on the image (recipe.yml)

Only needed when adding/removing system packages or COPRs.

```bash
# Local build (requires bluebuild CLI + podman/docker; CI is usually faster)
bluebuild build recipes/recipe.yml
```

CI in [.github/workflows/build.yml](.github/workflows/build.yml) builds on every push to `main` (paths-ignore: `**.md`, `dotfiles/**`, `wallpapers/**` — none are baked into the image), nightly at 10:05 UTC, and on `workflow_dispatch`. The `SIGNING_SECRET` repo secret holds the cosign private key matching [cosign.pub](cosign.pub).

The recipe pulls Hyprland packages from two COPRs (`nett00n/hyprland` for the core, `solopasha/hyprland` for the live-wallpaper extras + nwg-look) and LACT from `ilyaz/LACT`. `lactd.service` is the only systemd unit enabled by the recipe.

After publishing a new image, users pick it up via `rpm-ostree upgrade` (or it lands on next auto-update). There is no need to touch the rebase flow for normal recipe edits.

## Architecture notes worth knowing before editing

**Wallpaper system ([dotfiles/hypr/cycle-wallpaper.lua](dotfiles/hypr/cycle-wallpaper.lua), [dotfiles/hypr/pick-wallpaper.lua](dotfiles/hypr/pick-wallpaper.lua)).** Two backends behind one interface: `swww` for stills (incl. animated GIFs in non-span mode), `mpvpaper` for videos. The script handles per-monitor state (`~/.local/state/hypr/wallpaper-index-<MON>`), pre-fades to an extracted first frame before mpvpaper takes the surface (eliminates black-flash on video swaps), and synchronizes multi-monitor video launches via mpv's IPC socket so spanned videos stay frame-aligned. Wallpapers live in `<repo>/wallpapers/` (searched recursively). Animated GIFs route through `mpvpaper` rather than `swww` when spanning, because swww's per-monitor animation workers run on independent clocks and drift.

**Workspace assignment ([dotfiles/hypr/workspace-watcher.lua](dotfiles/hypr/workspace-watcher.lua)).** Hyprland's `windowrule` block silently *accepts but ignores* `workspace=`/`assign=`/`move=` (observed on 0.54; the workaround is still in use on the 0.55.x this system now runs, and has not been retested) — so this script subscribes to Hyprland's event socket (`.socket2.sock`) and dispatches `movetoworkspacesilent` itself. The `RULES` table is an ordered list of `{pattern, workspace}` pairs (order matters — first match wins); class names are matched as Lua patterns (current rules are regex-equivalent). Edit there, then reload with `SUPER+SHIFT+R`.

**Startup apps ([dotfiles/hypr/startup-apps.{conf,sh}](dotfiles/hypr/startup-apps.conf), [toggle-startup-apps.lua](dotfiles/hypr/toggle-startup-apps.lua)).** `startup-apps.conf` is a pipe-delimited `state|name|command` table read on Hyprland start. `SUPER+SHIFT+A` opens a rofi menu that lets the user remove an entry (kills the process too) or pick a `.desktop` from installed apps to add as a new entry. The `name` field doubles as the `pgrep -if` pattern, so it must appear in the running process's argv (e.g. `spotify` matches `com.spotify.Client`).

**Monitor arranger ([dotfiles/hypr/monitor-arranger.py](dotfiles/hypr/monitor-arranger.py)).** GTK4 GUI: reads `hyprctl monitors -j`, lets the user drag/resize/rotate, calls `hyprctl keyword monitor …` to apply live, and on Save writes `~/.config/hypr/monitors.conf` *through the symlink* so the dotfiles repo picks up the change. `hyprland.conf` sources `monitors.conf` at the top — keep that `source =` line and the `monitor = , preferred, auto, 1` fallback at the bottom of `monitors.conf`.

**Portal/session startup.** The `exec-once` block at the top of [hyprland.conf](dotfiles/hypr/hyprland.conf) is load-bearing for screen-sharing: it pushes `WAYLAND_DISPLAY`/`XDG_CURRENT_DESKTOP`/`XDG_SESSION_TYPE` into systemd+dbus *before* starting `hyprland-session.target` (from [dotfiles/systemd/user/hyprland-session.target](dotfiles/systemd/user/hyprland-session.target)), which in turn brings up `graphical-session.target` (a `Requisite` of `xdg-desktop-portal.service`). Then it kills any portals that autostarted before env was set and restarts the Hyprland portal. Don't reorder these without understanding why.

**Waybar.** Two outputs (`primary` on DP-1, `secondary` on DP-2) share [modules.jsonc](dotfiles/waybar/modules.jsonc); [config.jsonc](dotfiles/waybar/config.jsonc) only overrides per-output bits. Helper scripts under [scripts/](dotfiles/waybar/scripts/) feed CPU, GPU, and media (playerctl-based, with marquee scrolling) modules. The `primary`/`secondary` layer namespaces are blur-targeted by a `layerrule` in `hyprland.conf` — renaming them breaks waybar blur.

**Hyprland logging gotcha.** `debug { disable_logs = false }` is set deliberately. Without it Hyprland silences stdout/logfile shortly after startup, making it impossible to see why a reload silently reverts to defaults. Keep it.

## Conventions

- Shell scripts use `set -euo pipefail` (or `set -u` for the event-loop watchers that must survive bad event lines). New scripts should match.
- Scripts addressing the repo (e.g. for `WALL_DIR`) resolve it via `readlink -f "$0"` + `../..` from `dotfiles/hypr/`. Don't hardcode `~/Documents/bazzite-rice` — users may clone elsewhere.
- Per-runtime state goes in `$XDG_STATE_HOME/hypr/` (default `~/.local/state/hypr/`), per-user caches in `$XDG_CACHE_HOME/`. The wallpaper system uses both.
- The fallback monitor line `monitor = , preferred, auto, 1` must stay in `monitors.conf` so an unplugged-then-replugged display still comes up.
- `cosign.key` and `*.key` are gitignored; never commit them. `cosign.pub` is committed.
