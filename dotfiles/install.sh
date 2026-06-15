#!/usr/bin/env bash
# Symlink everything under dotfiles/ into ~/.config/, preserving any pre-existing
# real file (or foreign symlink) as <file>.bak.<timestamp>. Idempotent:
# re-running just refreshes links and prunes ones left by removed dotfiles.
#
# Files under dotfiles/home/ are symlinked into $HOME directly instead of
# $XDG_CONFIG_HOME (for ~/.zshrc, ~/.p10k.zsh, and other $HOME-rooted dotfiles).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_REAL="$(readlink -f "$SRC")"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$DEST"

# Skip install.sh itself and any compiled-Python junk (those would otherwise be
# symlinked into ~/.config and $HOME, and re-appear on every Python run).
find "$SRC" -type f ! -name install.sh ! -path '*/__pycache__/*' ! -name '*.pyc' -print0 |
while IFS= read -r -d '' src; do
    rel="${src#"$SRC"/}"
    if [[ "$rel" == home/* ]]; then
        dst="$HOME/${rel#home/}"
    else
        dst="$DEST/$rel"
    fi
    mkdir -p "$(dirname "$dst")"

    if [[ -L "$dst" ]]; then
        # Our own link (points into the repo) is replaced atomically by ln -sf.
        # A foreign symlink is preserved like a real file would be.
        if [[ "$(readlink -m -- "$dst")" != "$SRC_REAL"/* ]]; then
            mv "$dst" "$dst.bak.$STAMP"
            echo "backed up (foreign symlink): $dst -> $dst.bak.$STAMP"
        fi
    elif [[ -e "$dst" ]]; then
        mv "$dst" "$dst.bak.$STAMP"
        echo "backed up: $dst -> $dst.bak.$STAMP"
    fi

    # -f: atomically replaces the target so an editor/watcher (e.g. Hyprland's
    # config inotify) never sees a missing-file window that would make it
    # regenerate a stub config.
    ln -sf "$src" "$dst"
    echo "linked: $rel"
done

# Prune symlinks left behind by removed/renamed dotfiles (e.g. the old *.sh
# scripts after the Lua port). Only broken links (-xtype l) whose canonical
# target is inside this repo are removed; foreign and live links are untouched.
# readlink -m canonicalizes without requiring the target to exist, so /home vs
# /var/home spelling and dangling targets both compare correctly.
while IFS= read -r -d '' link; do
    [[ "$(readlink -m -- "$link")" == "$SRC_REAL"/* ]] && rm -v -- "$link"
done < <(
    find "$DEST" "$HOME/.local" -xtype l -print0 2>/dev/null
    find "$HOME" -maxdepth 1 -xtype l -print0 2>/dev/null
)

# Pick up any newly-linked systemd user units.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
fi

FONT_DIR="$HOME/.local/share/fonts"
mkdir -p "$FONT_DIR"

# sketchybar-app-font: app glyphs in the waybar workspace module.
if [[ ! -f "$FONT_DIR/sketchybar-app-font.ttf" ]]; then
    if curl -fsSL -o "$FONT_DIR/sketchybar-app-font.ttf" \
        https://github.com/kvndrsslr/sketchybar-app-font/releases/latest/download/sketchybar-app-font.ttf; then
        echo "installed font: sketchybar-app-font"
    else
        echo "warn: failed to download sketchybar-app-font (waybar workspace icons will fall back)"
    fi
fi

# Symbols Nerd Font: powers the glyphs in waybar's cpu/gpu/network/pulseaudio
# modules (style.css references "Symbols Nerd Font Mono"). Without it they tofu.
if ! fc-list 2>/dev/null | grep -qi "Symbols Nerd Font"; then
    if curl -fsSL -o /tmp/SymbolsNerdFont.tar.xz \
        https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.tar.xz; then
        tar -xJf /tmp/SymbolsNerdFont.tar.xz -C "$FONT_DIR" '*.ttf' 2>/dev/null ||
            tar -xJf /tmp/SymbolsNerdFont.tar.xz -C "$FONT_DIR"
        rm -f /tmp/SymbolsNerdFont.tar.xz
        echo "installed font: Symbols Nerd Font"
    else
        echo "warn: failed to download Symbols Nerd Font (waybar cpu/gpu/net glyphs will tofu)"
    fi
fi

fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || true

echo
echo "Done. Reload Hyprland with: hyprctl reload"
echo "If you backed up real files, they're at *.bak.$STAMP -- review and delete when satisfied."
