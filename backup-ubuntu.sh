#!/usr/bin/env bash
#
# backup-ubuntu.sh - Full backup of your home folder plus lists of your apt,
# Flatpak and Snap packages (optionally /etc and GNOME/dconf settings) to a drive.
#
# Each run creates a complete snapshot:
#   <drive>/ubuntu-backup/<hostname>/<YYYY-MM-DD_HH-MM-SS>/
# Files unchanged since the previous run are hard-linked instead of copied, so
# every snapshot looks complete but only changed files use extra space.
# This needs a Linux filesystem (ext4, btrfs, xfs) on the drive.
#
# Usage:
#   ./backup-ubuntu.sh [options] /media/<you>/<DriveName>
#
# Options:
#   -e, --etc        also back up /etc (asks for your sudo password)
#   -k, --keep N     after a successful run keep only the newest N snapshots
#                    (default: keep all)
#   -n, --dry-run    show what would be done, change nothing
#   -h, --help       show this help
#
# Extra exclusions: put rsync patterns (one per line) into
#   ~/.config/backup-ubuntu/exclude.txt
# e.g.  .local/share/Steam/     or     Videos/Movies/

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
ORIG_ARGS=("$@")
SYSTEM_CONFIG=0
KEEP=0
DRY_RUN=0
TARGET=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--etc)     SYSTEM_CONFIG=1; shift ;;
    -k|--keep)    [[ $# -ge 2 ]] || die "--keep needs a number"; KEEP="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1 (see --help)" ;;
    *)            TARGET="$1"; shift ;;
  esac
done

[[ -n "$TARGET" ]] || { usage; exit 1; }
[[ "$KEEP" =~ ^[0-9]+$ ]] || die "--keep must be a number"
[[ -d "$TARGET" ]] || die "'$TARGET' is not a folder. Is the drive plugged in and mounted?"
TARGET="$(readlink -f "$TARGET")"

# ---------- safety checks ----------
[[ "$TARGET" != "$HOME" && "$TARGET" != "$HOME"/* ]] \
  || die "Target is inside your home folder. Choose an external drive."
[[ "$(stat -c %d "$HOME")" != "$(stat -c %d "$TARGET")" ]] \
  || die "Target is on the same drive as your home folder. Choose an external drive."
[[ -w "$TARGET" ]] || die "'$TARGET' is not writable by you (check the drive or remount it)."
command -v rsync >/dev/null 2>&1 || die "rsync is missing. Install it with: sudo apt install rsync"

# Keep the machine awake while the backup runs (re-runs this script under systemd-inhibit).
if [[ -z "${BACKUP_UBUNTU_INHIBITED:-}" && $DRY_RUN -eq 0 ]] && command -v systemd-inhibit >/dev/null 2>&1; then
  export BACKUP_UBUNTU_INHIBITED=1
  exec systemd-inhibit --what=sleep:idle --who="$SCRIPT_NAME" --why="Backup in progress" \
       bash "$0" "${ORIG_ARGS[@]}"
fi

if [[ $SYSTEM_CONFIG -eq 1 && $DRY_RUN -eq 0 ]]; then
  sudo -v || die "--etc needs sudo rights"
fi

FSTYPE="$(stat -f -c %T "$TARGET")"
case "$FSTYPE" in
  vfat|msdos|exfat|fuseblk|ntfs*) POSIX=0 ;;
  *)                              POSIX=1 ;;
esac

# ---------- paths ----------
HOST="$(hostname -s)"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BASE="$TARGET/ubuntu-backup/$HOST"
DEST="$BASE/$STAMP"
LATEST="$BASE/latest"
LOG="$BASE/backup-$STAMP.log"
PKG="$DEST/packages"

if [[ $DRY_RUN -eq 0 ]]; then
  mkdir -p "$DEST" || die "cannot create $DEST"
fi

log() {
  local ts msg
  ts="$(date +%H:%M:%S)"
  msg="[$ts] $*"
  echo "$msg"
  [[ $DRY_RUN -eq 1 ]] || echo "$msg" >> "$LOG"
}

trap 'log "Backup interrupted."; exit 130' INT TERM

log "Backup of $HOME -> $DEST (drive filesystem: $FSTYPE)"
[[ $DRY_RUN -eq 1 ]] && log "DRY RUN: nothing will be written."

# ---------- rsync setup ----------
if [[ $POSIX -eq 1 ]]; then
  RSYNC_OPTS=(-aHAX --numeric-ids)
else
  log "WARNING: the drive uses $FSTYPE, which cannot store Linux permissions, owners,"
  log "         symlinks or hard links. Files are copied, but permissions will not be"
  log "         restored faithfully. Use an ext4/btrfs/xfs drive for a complete backup."
  RSYNC_OPTS=(-rt --no-links)
fi

LINKDEST=()
if [[ $POSIX -eq 1 && -d "$LATEST" ]]; then
  PREV="$(readlink -f "$LATEST")/home"
  if [[ -d "$PREV" ]]; then
    LINKDEST=(--link-dest="$PREV")
    log "Unchanged files will be hard-linked from the previous snapshot."
  fi
fi

EXCLUDES=(
  --exclude='.cache/'
  --exclude='.thumbnails/'
  --exclude='.local/share/Trash/'
  --exclude='.Trash-*/'
  --exclude='.gvfs/'
  --exclude='.var/app/*/cache/'
)
USER_EXCLUDE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/backup-ubuntu/exclude.txt"
if [[ -f "$USER_EXCLUDE_FILE" ]]; then
  EXCLUDES+=(--exclude-from="$USER_EXCLUDE_FILE")
  log "Using extra exclusions from $USER_EXCLUDE_FILE"
fi

DRY=()
[[ $DRY_RUN -eq 1 ]] && DRY=(--dry-run)

# ---------- 1. home folder ----------
log "Copying home folder..."
rsync "${RSYNC_OPTS[@]}" "${LINKDEST[@]}" "${EXCLUDES[@]}" "${DRY[@]}" \
      --mkpath --info=progress2,stats2 "$HOME/" "$DEST/home/"
rc=$?
case $rc in
  0)     log "Home folder copied successfully." ;;
  23|24) HOME_WARN=1
         log "WARNING: rsync finished with code $rc: some files were skipped (vanished, unreadable,"
         log "         or attributes not copyable). Check the output above." ;;
  *)     log "ERROR: rsync failed with code $rc. Snapshot is incomplete: $DEST"; exit "$rc" ;;
esac

# ---------- 2. packages, settings, /etc ----------
if [[ $DRY_RUN -eq 0 ]]; then
  mkdir -p "$PKG"
  {
    echo "Backup date: $(date)"
    echo "Host: $HOST"
    lsb_release -ds 2>/dev/null
    uname -r
  } > "$PKG/system-info.txt"

  log "Saving apt package lists and sources..."
  mkdir -p "$PKG/apt"
  apt-mark showmanual > "$PKG/apt/manually-installed.txt" 2>/dev/null
  dpkg --get-selections > "$PKG/apt/dpkg-selections.txt" 2>/dev/null
  dpkg-query -W -f='${Package}\t${Version}\n' > "$PKG/apt/all-packages-with-versions.txt" 2>/dev/null
  for f in /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences.d \
           /etc/apt/trusted.gpg.d /etc/apt/keyrings; do
    [[ -e "$f" ]] && cp -r "$f" "$PKG/apt/" 2>/dev/null
  done

  if command -v flatpak >/dev/null 2>&1; then
    log "Saving Flatpak app list..."
    mkdir -p "$PKG/flatpak"
    flatpak list --app --columns=application,branch,origin,installation > "$PKG/flatpak/apps.txt" 2>/dev/null
    flatpak remotes --columns=name,url > "$PKG/flatpak/remotes.txt" 2>/dev/null
    flatpak override --user --show > "$PKG/flatpak/user-overrides.txt" 2>/dev/null
  fi

  if command -v snap >/dev/null 2>&1; then
    log "Saving Snap package list..."
    mkdir -p "$PKG/snap"
    snap list > "$PKG/snap/snap-list.txt" 2>/dev/null
    snap list 2>/dev/null | awk 'NR>1 {print $1, $4, $6}' > "$PKG/snap/snaps-name-channel-notes.txt"
  fi

  if command -v dconf >/dev/null 2>&1; then
    log "Saving GNOME/dconf settings..."
    mkdir -p "$PKG/desktop"
    dconf dump / > "$PKG/desktop/dconf-settings.ini" 2>/dev/null
  fi

  crontab -l > "$PKG/crontab-user.txt" 2>/dev/null || rm -f "$PKG/crontab-user.txt"

  if [[ $SYSTEM_CONFIG -eq 1 ]]; then
    log "Backing up /etc (sudo)..."
    if sudo tar -czf "$DEST/etc-backup.tar.gz" -C / etc; then
      sudo chown "$(id -u):$(id -g)" "$DEST/etc-backup.tar.gz"
      log "/etc saved."
    else
      log "WARNING: /etc backup failed."
    fi
  fi

  cat > "$DEST/README.txt" <<EOF
Backup of $HOST, snapshot $STAMP, made $(date)

home/                complete copy of your home folder
packages/apt/        manually installed package list, apt sources and keys
packages/flatpak/    Flatpak apps (application, branch, origin) and remotes
packages/snap/       Snap packages with tracked channel (base snaps are marked)
packages/desktop/    GNOME settings (dconf)
etc-backup.tar.gz    /etc (only if made with --etc)

Restore hints (run from inside this snapshot folder)
EOF

  cat >> "$DEST/README.txt" <<'EOF'

Files (preview first with --dry-run; existing files get overwritten):
  rsync -aHAX --numeric-ids --info=progress2 --dry-run home/ "$HOME/"
  rsync -aHAX --numeric-ids --info=progress2 home/ "$HOME/"

apt:
  sudo cp -r packages/apt/sources.list packages/apt/sources.list.d /etc/apt/   (add other dirs the same way if needed)
  sudo apt-get update
  xargs -a packages/apt/manually-installed.txt -r sudo apt-get install -y

Flatpak:
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  awk 'tolower($1)!="application" && NF>=3 {print $1, $2, $3}' packages/flatpak/apps.txt |
    while read -r app branch origin; do flatpak install -y "$origin" "$app//$branch"; done

Snap:
  while read -r name channel notes; do
    case "$notes" in *base*) continue ;; esac
    sudo snap install "$name" --channel="$channel"
  done < packages/snap/snaps-name-channel-notes.txt

GNOME settings:
  dconf load / < packages/desktop/dconf-settings.ini

Note: "apt-mark showmanual" includes packages from Ubuntu's default install,
so the apt step may take a while on a fresh system.
EOF

  if [[ $POSIX -eq 1 ]]; then
    ln -sfn "$DEST" "$LATEST"
  fi

  if [[ $KEEP -gt 0 ]]; then
    mapfile -t OLD < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n -"$KEEP")
    for d in "${OLD[@]}"; do
      log "Removing old snapshot (keeping $KEEP): $d"
      rm -rf -- "$d"
    done
  fi

  log "DONE. Snapshot: $DEST"
  log "Free space on drive now: $(df -h --output=avail "$TARGET" | tail -1 | tr -d ' ')"
  [[ ${HOME_WARN:-0} -eq 1 ]] && log "Finished with warnings, see log: $LOG"
else
  log "DRY RUN: package lists, dconf, /etc (with --etc) and retention would also run."
  log "DRY RUN finished. Nothing was written."
fi

exit 0
