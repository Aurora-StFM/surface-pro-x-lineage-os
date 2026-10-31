#!/usr/bin/env bash
# Copy Android's bring-up logs from the "metadata" partition to Linux.
#
# Run ON THE SURFACE, from Fedora or the USB system, after booting LineageOS:
#   sudo ./read-bootlog.sh [DEST]      (default: ./spx-bootlogs)
#
# Android writes dmesg, logcat and a status summary of the last 5 boots to
# /metadata/spx-debug (boot.1 is the newest). If boot.1 is missing or old,
# Android did not get as far as mounting /metadata: the kernel or first-stage
# init failed. Watch the screen during boot for kernel messages in that case.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run this with sudo" >&2; exit 1; }
DEST="${1:-$PWD/spx-bootlogs}"

dev="$(lsblk -rno PATH,PARTLABEL | awk '$2 == "metadata" { print $1; exit }')"
[ -n "$dev" ] || { echo "no partition named 'metadata' found" >&2; exit 1; }

mnt="$(mktemp -d)"
trap 'umount "$mnt" 2>/dev/null; rmdir "$mnt"' EXIT
mount -o ro "$dev" "$mnt"

if [ ! -d "$mnt/spx-debug" ]; then
    echo "No logs on $dev. Either first-stage init did not mount /metadata, or"
    echo "Android stopped before its boot logger started. Check the messages on screen."
    exit 1
fi

mkdir -p "$DEST"
cp -r "$mnt/spx-debug/." "$DEST/"
chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$DEST"
echo "Copied to $DEST:"
for d in "$DEST"/boot.*; do
    [ -d "$d" ] || continue
    state="did not finish booting"
    [ -e "$d/COMPLETED" ] && state="finished booting"
    [ -e "$d/SHUTDOWN" ] && state="$state, rebooted: $(sed -n 3p "$d/SHUTDOWN")"
    printf '  %s  %s  (%s)\n' "$(basename "$d")" "$(date -r "$d/status.txt" '+%F %T' 2>/dev/null || echo '?')" "$state"
done
echo "Start with boot.1/status.txt, then boot.1/logcat.txt and boot.1/dmesg.txt."
