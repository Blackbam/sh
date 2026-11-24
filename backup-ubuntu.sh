#!/usr/bin/env bash
#
# backup-ubuntu.sh - Fast backup of your Ubuntu SETUP: installed packages
# (apt, Flatpak, Snap), apt sources and keys, GNOME settings, crontab and
# optionally /etc. Takes seconds and only a few MB.
#
# Your HOME FOLDER is not copied by this script. Use restic for that (see
# "HOME FOLDER BACKUP" below). At the end the script prints the exact commands
# for your drive.
#
# Usage:
#   ./backup-ubuntu.sh [options] /media/<you>/<DriveName>
#
# Options:
#   -e, --etc    also save /etc as a .tar.gz (asks for your sudo password)
#   -h, --help   show this help
#
# Output:
#   <drive>/ubuntu-backup/<hostname>/setup-<YYYY-MM-DD_HH-MM-SS>/
#
# ---------------------------------------------------------------------------
# HOME FOLDER BACKUP (recommended: restic)
# ---------------------------------------------------------------------------
# Why the old rsync approach was slow: a home folder holds hundreds of
# thousands of small files (.git, node_modules, browser profiles, ...).
# rsync with -H -A -X and --link-dest checks every file on the USB drive one
# by one, and on an NTFS drive (FUSE driver) each check is very slow. The
# drive spends its time seeking instead of writing.
#
# restic packs files into large chunks, writes them sequentially, compresses,
# deduplicates and uses all CPU cores. It also stores permissions itself, so it
# works on ext4, exFAT and NTFS. The first 100 GB backup typically takes
# 15-30 minutes on a USB 3 drive. Later runs only send changed data and
# usually take a few minutes.
#
#   sudo apt install restic
#
#   # once: create the repository (choose a password, store it safely;
#   # without it the backup cannot be read)
#   restic init -r /media/<you>/<Drive>/restic-home
#
#   # each backup
#   restic -r /media/<you>/<Drive>/restic-home backup "$HOME" \
#       --one-file-system --exclude-caches \
#       --exclude "$HOME/.cache" --exclude "$HOME/.local/share/Trash" \
#       --exclude "$HOME/.var/app/*/cache" --exclude "$HOME/snap/*/*/.cache"
#
#   # list, keep the newest 5, verify
#   restic -r /media/<you>/<Drive>/restic-home snapshots
#   restic -r /media/<you>/<Drive>/restic-home forget --keep-last 5 --prune
#   restic -r /media/<you>/<Drive>/restic-home check
#
#   # restore everything (files return to /home/<you>/...)
#   restic -r /media/<you>/<Drive>/restic-home restore latest --target /
#   # restore a single folder
#   restic -r /media/<you>/<Drive>/restic-home restore latest --target / --include "$HOME/Documents"
#
# Tip: put the password in a file (chmod 600) and add
#   --password-file ~/.config/restic-pass
# so backups run without a prompt.
#
# No-install alternative (one full archive each time, no incremental runs):
# a single sequential stream is still fast because the drive never seeks.
#   tar -C "$HOME" --exclude=./.cache --exclude=./.local/share/Trash -cf - . \
#     | zstd -T0 -3 > /media/<you>/<Drive>/home-$(date +%F).tar.zst
#   # restore:  zstd -dc home-<date>.tar.zst | tar -C "$HOME" -xf -
# (zstd: sudo apt install zstd. On a FAT32 drive files are limited to 4 GB;
#  format the drive as ext4 or exFAT.)
#
# If it is still slow:
#   - check the drive really runs at USB 3 speed: `lsusb -t` should show
#     5000M or more for the drive. Use a blue/USB 3 port and cable.
#   - NTFS drives use a slow FUSE driver; ext4 or exFAT are much faster.
#   - An external SSD is several times faster than a USB hard disk.
#   - Exclude large folders you do not need (VMs, Steam, Downloads) with
#     --exclude.

set -uo pipefail

SYSTEM_CONFIG=0
TARGET=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--etc)  SYSTEM_CONFIG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        die "unknown option: $1 (see --help)" ;;
    *)         TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]] || { usage; exit 1; }
[[ -d "$TARGET" ]] || die "'$TARGET' is not a folder. Is the drive plugged in and mounted?"
TARGET="$(readlink -f "$TARGET")"
[[ -w "$TARGET" ]] || die "'$TARGET' is not writable by you (check the drive or remount it)."

if [[ $SYSTEM_CONFIG -eq 1 ]]; then
  sudo -v || die "--etc needs sudo rights"
fi

HOST="$(hostname -s)"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
DEST="$TARGET/ubuntu-backup/$HOST/setup-$STAMP"
mkdir -p "$DEST" || die "cannot create $DEST"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "Saving setup of $HOST -> $DEST"

{
  echo "Backup date: $(date)"
  echo "Host: $HOST"
  lsb_release -ds 2>/dev/null
  uname -r
} > "$DEST/system-info.txt"

# ---------- apt ----------
log "apt: package lists, sources and keys"
mkdir -p "$DEST/apt"
apt-mark showmanual > "$DEST/apt/manually-installed.txt" 2>/dev/null
dpkg --get-selections > "$DEST/apt/dpkg-selections.txt" 2>/dev/null
dpkg-query -W -f='${Package}\t${Version}\n' > "$DEST/apt/all-packages-with-versions.txt" 2>/dev/null
for f in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences.d \
         /etc/apt/trusted.gpg.d /etc/apt/keyrings; do
  [[ -e "$f" ]] && cp -r "$f" "$DEST/apt/" 2>/dev/null
done

# ---------- Flatpak ----------
if command -v flatpak >/dev/null 2>&1; then
  log "Flatpak: apps and remotes"
  mkdir -p "$DEST/flatpak"
  flatpak list --app --columns=application,branch,origin > "$DEST/flatpak/apps.txt" 2>/dev/null
  flatpak remotes --columns=name,url > "$DEST/flatpak/remotes.txt" 2>/dev/null
  flatpak override --user --show > "$DEST/flatpak/user-overrides.txt" 2>/dev/null
fi

# ---------- Snap ----------
if command -v snap >/dev/null 2>&1; then
  log "Snap: packages and channels"
  mkdir -p "$DEST/snap"
  snap list > "$DEST/snap/snap-list.txt" 2>/dev/null
  snap list 2>/dev/null | awk 'NR>1 {print $1, $4, $6}' > "$DEST/snap/snaps-name-channel-notes.txt"
fi

# ---------- desktop / user ----------
if command -v dconf >/dev/null 2>&1; then
  log "GNOME/dconf settings"
  mkdir -p "$DEST/desktop"
  dconf dump / > "$DEST/desktop/dconf-settings.ini" 2>/dev/null
fi
crontab -l > "$DEST/crontab-user.txt" 2>/dev/null || rm -f "$DEST/crontab-user.txt"

# ---------- /etc ----------
if [[ $SYSTEM_CONFIG -eq 1 ]]; then
  log "/etc (sudo)"
  if sudo tar -czf "$DEST/etc-backup.tar.gz" -C / etc 2>/dev/null; then
    sudo chown "$(id -u):$(id -g)" "$DEST/etc-backup.tar.gz"
  else
    log "WARNING: /etc backup failed or was incomplete."
  fi
fi

# ---------- restore script ----------
cat > "$DEST/restore-packages.sh" <<'EOF'
#!/usr/bin/env bash
# Reinstall packages and settings from this backup on a fresh Ubuntu.
# Run from anywhere:  bash /path/to/setup-<date>/restore-packages.sh
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

echo "== apt sources and keys =="
for d in sources.list sources.list.d preferences.d trusted.gpg.d keyrings; do
  [[ -e "apt/$d" ]] && sudo cp -r "apt/$d" /etc/apt/
done
sudo apt-get update
echo "== apt packages (already installed ones are skipped) =="
# skip names this release does not know, otherwise apt aborts the whole install
grep -Fxf <(apt-cache pkgnames) apt/manually-installed.txt | xargs -r sudo apt-get install -y

if [[ -f flatpak/apps.txt ]] && command -v flatpak >/dev/null; then
  echo "== Flatpak =="
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  # other remotes (may need their .flatpakref/.flatpakrepo again if this fails)
  while read -r name url; do
    [[ -z "$name" || "$name" == "Name" || "$name" == "flathub" ]] && continue
    flatpak remote-add --if-not-exists "$name" "$url" \
      || echo "Could not add remote $name ($url). Install its apps manually."
  done < flatpak/remotes.txt
  while read -r app branch origin; do
    [[ -z "$app" || "$app" == "Application ID" ]] && continue
    flatpak install -y --noninteractive "$origin" "$app//$branch"
  done < flatpak/apps.txt
fi

if [[ -f snap/snaps-name-channel-notes.txt ]] && command -v snap >/dev/null; then
  echo "== Snap =="
  while read -r name channel notes; do
    case "$notes" in *base*|*core*|*snapd*) continue ;; esac
    opts=(); [[ "$notes" == *classic* ]] && opts=(--classic)
    sudo snap install "$name" --channel="$channel" "${opts[@]}"
  done < snap/snaps-name-channel-notes.txt
fi

if [[ -f desktop/dconf-settings.ini ]]; then
  read -rp "Load GNOME settings (dconf)? Overwrites current desktop settings [y/N] " a
  [[ "$a" == [yYjJ]* ]] && dconf load / < desktop/dconf-settings.ini
fi

[[ -f crontab-user.txt ]] && echo "Crontab saved in crontab-user.txt (load with: crontab crontab-user.txt)"
[[ -f etc-backup.tar.gz ]] && echo "/etc is in etc-backup.tar.gz. Copy single files back as needed, do not extract over /."
echo "Done."
EOF
chmod +x "$DEST/restore-packages.sh"

log "DONE. Setup saved in: $DEST"
log "Size: $(du -sh "$DEST" | cut -f1)"

# ---------- home folder hint ----------
REPO="$TARGET/restic-home"
echo
echo "Home folder: back it up with restic (fast, incremental). Commands for this drive:"
if ! command -v restic >/dev/null 2>&1; then
  echo "  sudo apt install restic"
fi
if [[ ! -f "$REPO/config" ]]; then
  echo "  restic init -r \"$REPO\"            # once"
fi
cat <<EOF
  restic -r "$REPO" backup "\$HOME" --one-file-system --exclude-caches \\
      --exclude "\$HOME/.cache" --exclude "\$HOME/.local/share/Trash" \\
      --exclude "\$HOME/.var/app/*/cache" --exclude "\$HOME/snap/*/*/.cache"
  restic -r "$REPO" forget --keep-last 5 --prune   # optional cleanup
See the top of $0 for restore commands and alternatives.
EOF
