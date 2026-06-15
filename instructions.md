# Installing & Ricing Hyprland on Bazzite — A Complete Guide

> **TL;DR:** Bazzite is an *immutable / atomic* OS, so the normal "just install the package" path doesn't apply. You have three real options, in order of how clean they are on an atomic system: **(A) rebase to a prebuilt Hyprland-on-Bazzite image**, **(B) build your own custom image** with BlueBuild/`image-template`, or **(C) layer Hyprland with `rpm-ostree` from a COPR** (works, but officially discouraged). The *ricing* part is identical to any distro once Hyprland is running, because all of it lives in your writable `~/.config`.

---

## 0. Understand what you're dealing with

Bazzite is built on Fedora Atomic (rpm-ostree / bootc). The base system (`/usr`) is an immutable, image-based filesystem that updates atomically and can be rolled back. This has two consequences:

1. **Installing a window manager is harder than on Arch/normal Fedora.** There's no `dnf install hyprland` into a mutable root. You either bake Hyprland into the image or "layer" it on top with `rpm-ostree`, which is heavier and can pause updates.
2. **Configuring/ricing Hyprland is exactly the same as anywhere else.** Everything you tweak — `~/.config/hypr/`, Waybar, rofi, wallpapers, themes — lives in `$HOME`, which is fully writable. Immutability only complicates the *install*, not the *rice*.

Before you start, know your hardware path. Bazzite ships separate images for AMD/Intel (open Mesa) vs. NVIDIA (proprietary). If you're on NVIDIA, use an NVIDIA base image — Mesa's open NVK driver is still flaky for this. And on an atomic system you can **always roll back** (`rpm-ostree rollback`, or pick the previous deployment in the boot menu), so experimentation is low-risk.

```bash
# See your current image, deployments, and any layered packages
rpm-ostree status
hyprland --version    # (after install) tells you which config syntax you need — see §6
```

---

## Method A — Rebase to a prebuilt Hyprland image (recommended for "just works")

This is the most atomic-native approach: someone has already baked Hyprland + a sane desktop into a Bazzite-derived image, and you simply switch your system to it. Updates come down as image updates. No layering, no broken upgrades.

Community images that do this (check the repo's activity/README before committing — maintenance varies, and some go dormant):

- **`dakota5488/bazzite-hyprland`** — Bazzite base + Hyprland.
- **`billyaddlers/phosphophypr`** — Hyprland-focused image based on Bazzite GNOME.
- **`gabeklavans/bazzite-hyprland`** — close-to-stock Bazzite with Hyprland (note: builds have been disabled at times, so verify it's current).

The rebase pattern is two-step: first to the **unsigned** ref to pull in the signing keys/policy, then to the **signed** image. Using `dakota5488/bazzite-hyprland` as the example (substitute the image you picked, and always read its README for the exact ref/tag):

```bash
# 1) Rebase to the unsigned image to install signing keys + policy
rpm-ostree rebase ostree-unverified-registry:ghcr.io/dakota5488/bazzite-hyprland:latest

# 2) Reboot
systemctl reboot

# 3) Rebase to the SIGNED image (verified going forward)
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dakota5488/bazzite-hyprland:latest

# 4) Reboot again, then pick "Hyprland" at the login screen
systemctl reboot
```

> ⚠️ Exact image names, tags, and signing details change. **Treat the repo README as the source of truth** — copy its commands verbatim rather than the above.

**Pros:** cleanest on atomic; updates handled for you; rollback-safe.
**Cons:** you inherit someone else's choices; third-party trust; some images are under-maintained.

---

## Method B — Build your own custom image (the "correct" long-term way)

If you want Hyprland *and* full control *and* atomic update safety, bake your own image. This is exactly how the Method-A images are made. Two routes:

- **`ublue-os/image-template`** — fork it, edit the `Containerfile`/build files to add the Hyprland COPR + packages, push to GitHub. GitHub Actions builds and publishes the image to `ghcr.io` for free. Then rebase to it (same `rpm-ostree rebase` flow as Method A).
- **BlueBuild** — a friendlier, YAML-recipe layer on top of the same idea. You declare modules/packages in a `recipe.yml`, it builds the image in CI.

Sketch of a BlueBuild recipe adding Hyprland on top of Bazzite:

```yaml
# recipe.yml (illustrative — see BlueBuild docs for current schema)
name: my-bazzite-hyprland
description: Bazzite + Hyprland
base-image: ghcr.io/ublue-os/bazzite
image-version: stable

modules:
  - type: dnf
    repos:
      copr:
        - solopasha/hyprland      # or ashbuk/Hyprland-Fedora, nett00n/hyprland
    install:
      packages:
        - hyprland
        - xdg-desktop-portal-hyprland
        - hyprpaper
        - hyprlock
        - hypridle
        - waybar
        - rofi-wayland
        - swww
        - SwayNotificationCenter
        - wlogout
        - hyprpicker
        - grim
        - slurp
        - cliphist
        - wl-clipboard
```

**Pros:** reproducible, update-safe, fully yours, easy to share.
**Cons:** highest upfront effort; you maintain the recipe.

---

## Method C — Layer Hyprland with `rpm-ostree` (works, officially discouraged)

This installs Hyprland directly onto your running Bazzite image. It's the fastest to try, but the Bazzite docs explicitly call layering a **last resort** for system-level packages only — layered packages can pause/slow OS upgrades and break them until removed, and third-party COPRs add risk (including GPG/signature breakage on update).

### C.1 — Pick a COPR

Hyprland isn't always current in Fedora's own repos, so you'll use a COPR. The landscape (verify which is freshest *today* — these shift):

- **`solopasha/hyprland`** — historically the "officially recommended" one with the widest package set (hyprland, hyprpaper, hyprlock, hypridle, hyprpicker, hyprshot, waybar variants, AGS, hyprpanel, etc.). Has had stale stretches.
- **`ashbuk/Hyprland-Fedora`** — clean, minimal, Fedora-spec-compliant, tracks upstream closely (was at 0.53.0 around New Year 2026). Core compositor + portal only.
- **`nett00n/hyprland`** (source: github.com/nett00n/hyprland-copr) — reproducible builds, created specifically because of solopasha's dormancy.

### C.2 — Add the repo and layer the packages

On atomic Fedora you don't use `dnf copr enable`; you drop the COPR's `.repo` file into `/etc/yum.repos.d/` and then layer with `rpm-ostree`:

```bash
# Grab the COPR .repo file (replace fedora-42 with YOUR Fedora version: check /etc/os-release)
sudo curl -o /etc/yum.repos.d/solopasha-hyprland.repo \
  "https://copr.fedorainfracloud.org/coprs/solopasha/hyprland/repo/fedora-42/solopasha-hyprland-fedora-42.repo"

# Layer the compositor + the essentials
rpm-ostree install hyprland xdg-desktop-portal-hyprland \
  hyprpaper hyprlock hypridle hyprpicker \
  waybar rofi-wayland swww SwayNotificationCenter wlogout \
  grim slurp cliphist wl-clipboard

# Reboot to apply the new deployment
systemctl reboot
```

After reboot, log out, choose **Hyprland** from the session picker (gear icon) on the SDDM/GDM login screen, and log in.

### C.3 — When updates break (the predictable failure)

If `rpm-ostree upgrade` later fails with **GPG signature errors**, the docs' fix is to either remove the COPR repo (and the packages from it) or edit the `.repo` file to set `gpgcheck=0` — at your own risk:

```bash
# Option 1: back out the layered packages
rpm-ostree uninstall hyprland xdg-desktop-portal-hyprland hyprpaper hyprlock hypridle ...

# Option 2: relax signature checking on that repo (risky)
sudo sed -i 's/gpgcheck=1/gpgcheck=0/' /etc/yum.repos.d/solopasha-hyprland.repo
```

**Pros:** fast, no CI, no rebase.
**Cons:** layering a whole WM exceeds the docs' intended use; slower/longer upgrades; periodic signature breakage; you own the fallout.

---

## Which method should *you* pick?

| Goal | Use |
|---|---|
| Try Hyprland tonight, minimal fuss | **A** (prebuilt image) |
| Permanent, update-safe, fully customized base | **B** (own image) |
| Maximum control, willing to babysit updates | **C** (layering) |
| You hate maintaining anything | **A** |

A reasonable progression: start with **A** to learn Hyprland, then graduate to **B** once you know exactly which packages you want baked in.

---

## 5. First boot into Hyprland

- At the login screen (SDDM on KDE-based images, GDM on GNOME-based), use the session menu to select **Hyprland**.
- Default emergency binds if your config errors out before your own binds load: **SUPER+Q** (terminal), **SUPER+R** (run), **SUPER+M** (exit). Memorize these — you'll need them while ricing.
- If you get a black screen or instant logout, switch to a TTY (**Ctrl+Alt+F3**), check `~/.config/hypr/hyprland.conf` for errors, or just `rpm-ostree rollback` / pick the previous deployment at boot.

---

## 6. ⚠️ Config syntax: hyprlang (`.conf`) vs. Lua (`.lua`)

This is the single biggest gotcha right now. **Since Hyprland 0.55, the classic `hyprland.conf` "hyprlang" syntax is deprecated in favor of a Lua config (`hyprland.lua`).** But virtually the entire dotfiles ecosystem (Waybar setups, the big rice frameworks, every tutorial) still uses `.conf`. So:

- Run `hyprland --version`. If you're on **≤ 0.54**, use `hyprland.conf` (hyprlang) — everything below applies directly.
- If you're on **≥ 0.55**, hyprlang still works (deprecated ≠ removed) but throws warnings; the *forward* path is `hyprland.lua`. The upstream wiki and Arch wiki have migrated their examples to Lua.

Because the ecosystem hasn't moved, this guide writes config in **hyprlang `.conf`** and shows the Lua equivalents at the end of the section.

### 6.1 — A clean, modern starter `~/.config/hypr/hyprland.conf`

```ini
# ---- Monitors (use `hyprctl monitors` to find names) ----
monitor=,preferred,auto,1

# ---- Autostart ----
exec-once = waybar &
exec-once = swww-daemon & sleep 1 && swww img ~/Pictures/wall.png
exec-once = hypridle &
exec-once = wl-paste --watch cliphist store &
exec-once = swaync &

# ---- Look & feel ----
general {
    gaps_in = 6
    gaps_out = 14
    border_size = 2
    col.active_border = rgba(89b4faee) rgba(cba6f7ee) 45deg
    col.inactive_border = rgba(45475aaa)
    layout = dwindle
}

decoration {
    rounding = 12
    blur {
        enabled = true
        size = 6
        passes = 3        # higher passes prevents blur artifacts at larger sizes
        new_optimizations = true
    }
    shadow {
        enabled = true
        range = 20
        render_power = 3
        color = rgba(00000044)
    }
    active_opacity = 1.0
    inactive_opacity = 0.92
}

animations {
    enabled = true
    bezier = smooth, 0.05, 0.9, 0.1, 1.0
    animation = windows, 1, 5, smooth
    animation = windowsOut, 1, 5, smooth, popin 80%
    animation = fade, 1, 6, smooth
    animation = workspaces, 1, 5, smooth, slide
    animation = border, 1, 8, smooth
}

input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
    touchpad { natural_scroll = true }
}

misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}

# ---- Keybinds ----
$mod = SUPER
bind = $mod, RETURN, exec, kitty
bind = $mod, Q, killactive,
bind = $mod, E, exec, nautilus
bind = $mod, SPACE, exec, rofi -show drun
bind = $mod, F, fullscreen,
bind = $mod, V, togglefloating,
bind = $mod, L, exec, hyprlock
bind = $mod SHIFT, S, exec, hyprshot -m region
bind = $mod, ESCAPE, exec, wlogout

# Move focus / workspaces
bind = $mod, left, movefocus, l
bind = $mod, right, movefocus, r
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
```

Save and it reloads instantly (or `hyprctl reload`).

### 6.2 — The same ideas in Lua (0.55+)

```lua
-- ~/.config/hypr/hyprland.lua
hl.config({
  general = {
    gaps_in = 6, gaps_out = 14, border_size = 2,
    ["col.active_border"] = "rgba(89b4faee) rgba(cba6f7ee) 45deg",
    layout = "dwindle",
  },
  decoration = {
    rounding = 12,
    blur = { enabled = true, size = 6, passes = 3 },
  },
})

hl.animation({ leaf = "windows",   enabled = true, speed = 5, bezier = "smooth" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, style = "slide" })

hl.bind("SUPER + RETURN", hl.dsp.exec_cmd("kitty"))
hl.bind("SUPER + SPACE",  hl.dsp.exec_cmd("rofi -show drun"))
```

When in doubt, let Hyprland generate a default config (it does this automatically on first run with no config present), then edit that — it'll be in whichever syntax your version defaults to.

---

## 7. The ricing toolkit (2026 edition)

Pick one from each row. Install them via your chosen method (bake into the image for B, layer for C, or many are already present in the prebuilt images for A). Most are in the same Hyprland COPR or in Fedora/Flathub.

| Role | Modern picks |
|---|---|
| **Status bar** | **Waybar** (default choice), **HyprPanel** (AGS-based, batteries-included), **Quickshell** shells (e.g. Caelestia, end-4's *illogical-impulse*) |
| **App launcher** | **rofi** (`rofi-wayland`), **walker**, **fuzzel**, **wofi** |
| **Wallpaper** | **swww** (animated, transitions), **hyprpaper** (static, IPC) |
| **Notifications** | **swaync** (has a control center), **mako**, **dunst** |
| **Lock / idle** | **hyprlock** + **hypridle** |
| **Power menu** | **wlogout** |
| **Screenshots** | **hyprshot**, or **grim + slurp**, annotate with **satty** |
| **Clipboard** | **cliphist** + **wl-clipboard** |
| **Dynamic color** | **wallust** (Rust, the modern pywal successor) or **pywal16** |
| **Terminal** | **ghostty**, **kitty**, **foot**, **alacritty**, **wezterm** |
| **GTK/Qt theming** | **nwg-look** (GTK), **Kvantum** (Qt) |
| **Cursors** | **hyprcursor** |

**Fonts matter:** install a **Nerd Font** (e.g. *JetBrainsMono Nerd Font*) or Waybar/rofi will show tofu boxes instead of icons.

---

## 8. Make it look genuinely modern

The "wow" look is a small number of compounding choices:

1. **Cohesive palette.** Pick *one* and apply it everywhere (Hyprland borders, Waybar, rofi, terminal, GTK, Qt): **Catppuccin Mocha**, **Tokyo Night**, **Gruvbox Material**, or **Rosé Pine** are the safe modern bets.
2. **Space + rounding + restraint.** Generous `gaps_out`, `rounding = 10–14`, a 2px gradient active border, and *subtle* blur. Over-blurring and huge shadows read as amateur.
3. **A floating, pill-style Waybar.** Center the clock, group modules into rounded "islands," add margins so it floats off the screen edge. This single change does most of the visual heavy lifting.
4. **Animated wallpaper via `swww`** with a soft transition (`--transition-type grow`), matched to your palette.
5. **Consistent GTK + Qt.** Run `nwg-look` to set the GTK theme/icons/cursor and `Kvantum` for Qt apps so Nautilus/Dolphin and dialogs don't clash with your rice.
6. **A blurred `hyprlock`** with a clock and your wallpaper — cheap, high-impact polish.
7. **Dynamic theming with `wallust`:** generate a palette from the current wallpaper and template it into Waybar/rofi/kitty so everything recolors when you change the background. Wire `pywalfox` into Firefox to extend it to the browser.

Browse **r/unixporn** and the *itsfoss* / *informatecdigital* dotfile roundups for inspiration, then steal *configs*, not installers (see the caveat below).

---

## 9. Big dotfile frameworks — and the Bazzite caveat

There are gorgeous turnkey rices: **HyDE** (HyprDots), **ML4W**, **JaKooLit's Hyprland-Dots**, **end-4/dots-hyprland** (*illogical-impulse*), **Caelestia**, **HyprFlux**. They give you a polished desktop in minutes — *on Arch*.

**The catch on Bazzite:** almost all of these ship `install.sh` scripts that assume a mutable root and use `pacman`/`yay`/the AUR. **Do not run their installers on Bazzite** — they'll fail or try to do unsafe things to an atomic system. Instead:

1. Install the **tools** they depend on via your image/COPR (Waybar, rofi, swww, etc. — §7).
2. Copy only the **config files** from the repo into `~/.config/` manually, or manage them with **GNU Stow** or **chezmoi** (which work fine on any distro).
3. Skip the package-install step entirely.

This is the genuinely non-obvious part of ricing Hyprland specifically on an atomic distro: the *aesthetics* are portable, the *installers* are not.

---

## 10. NVIDIA, troubleshooting & atomic-specific notes

- **NVIDIA:** start from a `-nvidia` Bazzite base. Hyprland generally needs the NVIDIA modules loaded and a couple of env vars; consult the Hyprland wiki's NVIDIA page for the current required `env =` lines (these change with driver versions). NVK (open) is still error-prone for Hyprland.
- **Updates feel slow / pause:** expected with layered packages (Method C). Fewer layers = healthier system.
- **GPG signature errors on upgrade:** §C.3.
- **Rollback anything:** `rpm-ostree rollback`, or choose the prior deployment in the boot menu. This is the atomic superpower — break your rice freely.
- **Inspect state:** `rpm-ostree status` (deployments + layered pkgs), `hyprctl monitors` / `hyprctl devices` (hardware names for your config), `hyprctl reload` (apply config), `journalctl -b` (debug a failed session).

---

## Sources & further reading

**Bazzite / atomic install mechanics**
- Bazzite docs — Package Layering (`rpm-ostree`), incl. COPR risk + GPG fix: https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/
- Bazzite main image / rebase refs (Universal Blue): https://github.com/ublue-os/bazzite
- Universal Blue `image-template` (build your own): https://github.com/ublue-os/image-template
- BlueBuild docs: https://blue-build.org/
- Framework KB — managing Bazzite with bootc + rpm-ostree (rollbacks/pinning): https://knowledgebase.frame.work/en_us/how-to-manage-bazzite-with-bootc-and-rpm-ostree-SJ8bn4vhke
- Bazzite (overview), Wikipedia: https://en.wikipedia.org/wiki/Bazzite_(operating_system)

**Prebuilt Hyprland-on-Bazzite images**
- dakota5488/bazzite-hyprland: https://github.com/Dakota5488/bazzite-hyprland
- billyaddlers/phosphophypr: https://github.com/BillyAddlers/phosphophypr
- gabeklavans/bazzite-hyprland: https://github.com/gabeklavans/bazzite-hyprland
- Universal Blue forum — "Bazzite-based image that uses hyprland": https://universal-blue.discourse.group/t/made-a-bazzite-based-image-that-uses-hyprland-instead-of-kde/9780

**Hyprland COPRs for Fedora**
- solopasha/hyprland (COPR): https://copr.fedorainfracloud.org/coprs/solopasha/hyprland/
- solopasha/hyprlandRPM (package list/specs): https://github.com/solopasha/hyprlandRPM
- ashbuk/Hyprland-Fedora (clean build, 0.53+): https://dev.to/ashbuk/hyprland-0530-for-fedora-1afm
- nett00n/hyprland-copr (reproducible): https://github.com/nett00n/hyprland-copr
- Building Hyprland on Fedora HOWTO (deps): https://github.com/hyprwm/Hyprland/discussions/284

**Hyprland configuration (incl. the 0.55 Lua migration)**
- Hyprland Wiki — Start Here / Configuring: https://wiki.hypr.land/Configuring/Start/
- Hyprland Wiki — Variables: https://wiki.hypr.land/Configuring/Basics/Variables/
- Hyprland Wiki — Binds: https://wiki.hypr.land/Configuring/Basics/Binds/
- Hyprland Wiki — Animations: https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/
- Arch Wiki — Hyprland (notes v0.55 Lua recommendation): https://wiki.archlinux.org/title/Hyprland

**Ricing inspiration & dotfile frameworks**
- It's FOSS — best Hyprland dotfiles (2026): https://itsfoss.com/best-hyprland-dotfiles/
- informaticdigital — dotfiles for Hyprland: https://informatecdigital.com/en/dotfiles-to-customize-your-Hyprland-desktop-on-Arch-and-Endeavouros/
- GitHub topic — hyprland-rice: https://github.com/topics/hyprland-rice
- HyprFlux config reference: https://www.hyprflux.dev/features/hyprland.html
- r/unixporn (community showcase): https://www.reddit.com/r/unixporn/

> Versions move fast (Hyprland was ~0.53 in Fedora COPRs at the end of 2025 and is on the Lua-config track at 0.55+). Always cross-check the exact image ref, COPR freshness, and config syntax for **your** installed version before following any single command verbatim.
