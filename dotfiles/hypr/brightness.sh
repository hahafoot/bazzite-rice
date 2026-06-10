#!/usr/bin/env bash
# Adjust external-monitor brightness over DDC/CI (this is a desktop — no
# internal backlight, so brightnessctl is useless; ddcutil drives the panels).
# Usage: brightness.sh up|down [step]   (step is a percentage, default 10)
set -euo pipefail

dir="${1:-}"
step="${2:-10}"

case "$dir" in
    up)   sign=1 ;;
    down) sign=-1 ;;
    *) echo "usage: $0 up|down [step]" >&2; exit 1 ;;
esac
delta=$(( sign * step ))

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
mkdir -p "$state_dir"
cache="$state_dir/ddc-displays"
sigfile="$state_dir/ddc-displays.sig"
lock="$state_dir/brightness.lock"

# Serialize. ddcutil talks raw I2C, which is NOT concurrency-safe: overlapping
# calls (e.g. from key autorepeat while held) wedge the bus and freeze the
# session. flock -n drops this press if an adjustment is already in flight,
# which also rate-limits a held key to one step at a time.
exec 9>"$lock"
flock -n 9 || exit 0

# Cache the display list. `ddcutil detect` scans every I2C bus and is far too
# slow (1–2s) to run on every keypress — detect once, then reuse. But key the
# cache to the set of currently-connected outputs (read instantly from DRM
# sysfs, no I2C): if a monitor was asleep/off when detect last ran it would be
# missing from the cache and never get adjusted, so re-detect whenever the
# connected set changes (monitor wakes, is replugged, etc.).
sig=$(grep -lx connected /sys/class/drm/*/status 2>/dev/null | sort | tr '\n' ' ')
if [[ ! -s "$cache" || "$sig" != "$(cat "$sigfile" 2>/dev/null)" ]]; then
    ddcutil detect --terse 2>/dev/null | grep -oP '^Display \K[0-9]+' > "$cache" || true
    printf '%s' "$sig" > "$sigfile"
    # Display numbers may have shifted — drop tracked levels so they re-init
    # from the panels' actual brightness on this run.
    rm -f "$state_dir"/level-*
fi
mapfile -t displays < "$cache"
[[ ${#displays[@]} -eq 0 ]] && { rm -f "$cache" "$sigfile"; notify-send -a brightness "No DDC displays found"; exit 1; }

# ddcutil's default inter-op I2C delays make each call ~1s. .2 cuts a write to
# ~0.65s — the practical floor here (.15 is no faster) — and still lands every
# write on both panels. Lower with care: too small and setvcp silently fails.
dc=(--sleep-multiplier .2)

# Responsiveness: instead of a relative setvcp + a read-back for the OSD (three
# serial DDC round-trips per press), track each monitor's level in a state file
# and set absolute values. The new % is then known with zero extra DDC traffic,
# and the per-monitor writes run in PARALLEL — safe because each display is on
# its own I2C bus (the earlier freeze was many procs contending one bus; flock
# above still prevents overlapping *invocations*). Levels re-init from the panel
# via one getvcp only when a level file is missing (first run / after re-detect).
pids=()
osd=""
for d in "${displays[@]}"; do
    lf="$state_dir/level-$d"
    cur=$(cat "$lf" 2>/dev/null || true)
    if [[ -z "$cur" ]]; then
        read -r _ _ _ cur _ < <(ddcutil --display "$d" "${dc[@]}" getvcp 10 --terse 2>/dev/null)
        cur=${cur:-50}
    fi
    new=$(( cur + delta ))
    (( new < 0 ))   && new=0
    (( new > 100 )) && new=100
    printf '%s' "$new" > "$lf"
    [[ -z "$osd" ]] && osd=$new
    ddcutil --display "$d" "${dc[@]}" --noverify setvcp 10 "$new" >/dev/null 2>&1 &
    pids+=($!)
done
wait "${pids[@]}" 2>/dev/null || true

notify-send -a brightness -h string:x-canonical-private-synchronous:brightness \
    -h "int:value:${osd:-0}" "Brightness ${osd:-0}%"
