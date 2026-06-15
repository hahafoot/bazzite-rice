# bazzite-rice

A custom Bazzite GNOME image with Hyprland baked in, built via [BlueBuild](https://blue-build.org/) and published to GHCR. Implements **Method B** of [instructions.md](instructions.md).

Image: `ghcr.io/hahafoot/bazzite-rice:latest`

## What's inside

- **Base:** `ghcr.io/ublue-os/bazzite-gnome:stable`
- **Compositor stack** (from the `nett00n/hyprland` and `solopasha/hyprland` COPRs):
  Hyprland, xdg-desktop-portal-hyprland, hyprlock, hypridle, hyprpicker, hyprshot, hyprcursor, hyprpolkitagent
- **Desktop bits:** Waybar, rofi (2.x, wayland-native), SwayNotificationCenter, wlogout, kitty, grim, slurp, cliphist
- **Live-wallpaper stack:** swww, mpvpaper, waypaper, mpv
- **GUI helpers:** pavucontrol, network-manager-applet, blueman, qt6ct, kvantum, nwg-look, papirus-icon-theme
- **Extras:** zsh, luajit, jetbrains-mono-fonts

Full package list lives in [recipes/recipe.yml](recipes/recipe.yml).

---

## Install — rebase your Bazzite system to this image

> **Prereq:** You're already on Bazzite (any variant). If not, install Bazzite first from [bazzite.gg](https://bazzite.gg). Your existing apps, flatpaks, and `$HOME` survive the rebase; only `/usr` is swapped.

The rebase is a two-step dance: first to the **unsigned** ref so the signing policy and cosign public key install, then to the **signed** ref so future updates are verified.

```bash
# 1. Rebase to the unsigned image (installs the signing policy)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/hahafoot/bazzite-rice:latest
systemctl reboot

# 2. Rebase to the signed image (verified going forward)
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/hahafoot/bazzite-rice:latest
systemctl reboot
```

After the second reboot, pick **Hyprland** from the GDM session menu (gear icon on the login screen) and log in.

### Apply the dotfiles

Clone this repo and run the install script:

```bash
git clone https://github.com/hahafoot/bazzite-rice.git ~/Documents/bazzite-rice
bash ~/Documents/bazzite-rice/dotfiles/install.sh
```

The script symlinks everything under `dotfiles/` into `~/.config/` (and `dotfiles/home/` into `$HOME`), backing up any pre-existing real files as `*.bak.<timestamp>`. It's idempotent — re-run it any time to refresh the symlinks. It also fetches `sketchybar-app-font` for Waybar workspace icons.

Reload Hyprland with `hyprctl reload` (or log out and back in).

### Keep it updated

Once rebased, normal Bazzite/ostree updates pull new versions of this image automatically. To upgrade on demand:

```bash
rpm-ostree upgrade
systemctl reboot
```

### Rollback

- **OS:** `rpm-ostree rollback`, or pick the prior deployment in the GRUB menu at boot.
- **Dotfiles:** restore the `*.bak.<timestamp>` files left in `~/.config/` (and `$HOME`) by `install.sh`.
- **Rebase away entirely:** `rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/bazzite-gnome:stable` and reboot.

---

## Fork it and build your own

If you want your own variant (different packages, different base), fork this repo and:

1. Edit [recipes/recipe.yml](recipes/recipe.yml) to add/remove packages.
2. Generate a cosign keypair for image signing:
   ```bash
   COSIGN_PASSWORD="" cosign generate-key-pair
   ```
   This creates `cosign.pub` (commit it) and `cosign.key` (kept out of git by `.gitignore`).
3. On GitHub: **Settings → Secrets and variables → Actions → New repository secret**
   - **Name:** `SIGNING_SECRET`
   - **Value:** the full contents of `cosign.key` (including the `BEGIN`/`END` lines)
4. Push. GitHub Actions builds the image in ~6 minutes and publishes it to `ghcr.io/<you>/<repo>:latest`.
5. On the GitHub Packages page for the new image, set visibility to **public** so `rpm-ostree` can pull it without auth.
6. Rebase to your fork using the two-step flow above, substituting your image ref.
