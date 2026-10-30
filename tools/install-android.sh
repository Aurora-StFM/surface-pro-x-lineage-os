#!/usr/bin/env bash
# Install or update LineageOS on the Surface Pro X, next to Windows and Fedora.
#
# Run ON THE SURFACE, from Fedora, as root, in the directory made by
# "build.sh images" (it holds super.img, ramdisk.img, Image and the DTB):
#
#   sudo ./install-android.sh                 first install, or update if present
#   sudo ./install-android.sh --dry-run       show what would happen, change nothing
#   sudo ./install-android.sh --wipe-data     update and erase Android's user data
#   sudo ./install-android.sh --data-size 64G size of Android's data partition
#                                             (default: all the free space used)
#   sudo ./install-android.sh --uninstall     remove the boot entry and files
#
# First install: creates four partitions (misc, metadata, super, userdata) in
# the largest block of UNALLOCATED space on the internal drive. It never
# resizes, moves or deletes a partition. Make room first (shrink Windows or
# Fedora with their own tools), then run this.
#
# Booting: adds a GRUB entry "LineageOS (Surface Pro X)" next to Fedora's.
# Boot it once with: sudo grub2-reboot lineage-spx && sudo reboot
set -euo pipefail

ENTRY_ID=lineage-spx
BOOT_SUBDIR=lineage-spx
DTB=sc8180x-surface-pro-x.dtb
NAMES=(misc metadata super userdata)
MISC_MIB=1
METADATA_MIB=64
MIN_DATA_GIB=8

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
msg2() { printf '\033[1;34m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

DRY=0 WIPE=0 YES=0 UNINSTALL=0 DATA_SIZE="" DISK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --wipe-data) WIPE=1; shift ;;
        --yes) YES=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --data-size) DATA_SIZE="$2"; shift 2 ;;
        --disk) DISK="$2"; shift 2 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

run() { # run CMD...: print, and execute unless --dry-run
    msg2 "$*"
    [ "$DRY" = 1 ] || "$@"
}

confirm() {
    [ "$YES" = 1 ] && return 0
    [ "$DRY" = 1 ] && return 0
    local answer
    read -r -p "$1 Type 'yes' to continue: " answer
    [ "$answer" = yes ] || die "cancelled"
}

[ "$(id -u)" -eq 0 ] || die "run this with sudo"
grep -qa 'microsoft,surface-pro-x' /sys/firmware/devicetree/base/compatible 2>/dev/null ||
    die "this does not look like a Surface Pro X running Fedora with the Surface Pro X device tree"

# --- Boot files location -------------------------------------------------
# Fedora's GRUB reads entries from /boot/loader/entries. Paths in an entry are
# relative to the file system that holds /boot.
BOOT_MNT="$(findmnt -no TARGET --target /boot)"
if [ "$BOOT_MNT" = /boot ]; then PREFIX=""; else PREFIX="/boot"; fi
ENTRY_FILE="/boot/loader/entries/$ENTRY_ID.conf"
[ -d /boot/loader/entries ] || die "/boot/loader/entries not found (is this Fedora with GRUB and BLS?)"

if [ "$UNINSTALL" = 1 ]; then
    msg "Removing the boot entry and boot files"
    run rm -f "$ENTRY_FILE"
    run rm -rf "/boot/$BOOT_SUBDIR"
    msg "Done. The Android partitions were left alone. To delete them, use"
    msg2 "GNOME Disks/KDE Partition Manager, or: sgdisk -d <number> <disk> for each of: ${NAMES[*]}"
    exit 0
fi

for c in sgdisk partprobe udevadm mkfs.ext4 lsblk blockdev dd sha256sum findmnt; do
    command -v "$c" >/dev/null || die "missing $c (sudo dnf install gdisk parted e2fsprogs util-linux)"
done

# --- Images ----------------------------------------------------------------
IMG_DIR="$(cd "$(dirname "$0")" && pwd)"
for f in super.img ramdisk.img Image "$DTB" SHA256SUMS; do
    [ -f "$IMG_DIR/$f" ] || die "$IMG_DIR/$f is missing; run this from the directory build.sh images made"
done
msg "Checking images"
(cd "$IMG_DIR" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch, copy the images again"

# super.img is usually an Android sparse image; the raw size is in its header.
SUPER_SPARSE=0
if [ "$(od -An -tx4 -N4 "$IMG_DIR/super.img" | tr -d ' ')" = ed26ff3a ]; then
    SUPER_SPARSE=1
    command -v simg2img >/dev/null || die "super.img is a sparse image; install android-tools (sudo dnf install android-tools)"
    read -r blk_sz total_blks < <(od -An -tu4 -j12 -N8 "$IMG_DIR/super.img")
    SUPER_BYTES=$((blk_sz * total_blks))
else
    SUPER_BYTES="$(stat -c %s "$IMG_DIR/super.img")"
fi
msg2 "super image: $((SUPER_BYTES / 1048576)) MiB$([ "$SUPER_SPARSE" = 1 ] && echo ' (sparse)')"

# --- Disk ------------------------------------------------------------------
if [ -z "$DISK" ]; then
    root_src="$(findmnt -no SOURCE / | sed 's/\[.*\]$//')"
    DISK="/dev/$(lsblk -no PKNAME "$root_src" | head -n1)"
fi
[ -b "$DISK" ] || die "$DISK is not a block device (use --disk /dev/nvme0n1)"
case "$DISK" in /dev/nvme*) ;; *) die "$DISK is not the internal NVMe drive; Android only supports booting from it" ;; esac
SECTOR="$(blockdev --getss "$DISK")"

part_by_name() { # print /dev/... of the partition on $DISK with this GPT name
    lsblk -rno PATH,PARTLABEL "$DISK" | awk -v n="$1" '$2 == n { print $1 }'
}

found=0
for n in "${NAMES[@]}"; do
    count="$(part_by_name "$n" | wc -l)"
    [ "$count" -le 1 ] || die "more than one partition named '$n' on $DISK"
    [ "$count" -eq 1 ] && found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
    MODE=install
elif [ "$found" -eq "${#NAMES[@]}" ]; then
    MODE=update
else
    die "only some of the Android partitions (${NAMES[*]}) exist on $DISK; fix that by hand first"
fi

# --- Create partitions (first install) ---------------------------------------
if [ "$MODE" = install ]; then
    msg "First install: looking for unallocated space on $DISK"
    first="$(sgdisk -F "$DISK" | tail -n1)"
    last="$(sgdisk -E "$DISK" | tail -n1)"
    [[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$last" -gt "$first" ]] ||
        die "no unallocated space on $DISK; shrink Windows or Fedora first"
    align=$((1048576 / SECTOR))
    start=$(( (first + align - 1) / align * align ))
    free_bytes=$(( (last - start + 1) * SECTOR ))

    mib() { echo $(( $1 * 1048576 / SECTOR )); }
    misc_sec="$(mib $MISC_MIB)"
    meta_sec="$(mib $METADATA_MIB)"
    super_sec=$(( (SUPER_BYTES + 1048575) / 1048576 * 1048576 / SECTOR ))
    fixed=$(( (misc_sec + meta_sec + super_sec) * SECTOR ))
    if [ -n "$DATA_SIZE" ]; then
        data_bytes="$(numfmt --from=iec "${DATA_SIZE%B}")"
    else
        data_bytes=$(( free_bytes - fixed ))
    fi
    data_sec=$(( data_bytes / 1048576 * 1048576 / SECTOR ))
    [ "$data_sec" -ge "$(mib $((MIN_DATA_GIB * 1024)))" ] ||
        die "not enough room: $((free_bytes / 1073741824)) GiB free, Android needs $(( fixed / 1073741824 + MIN_DATA_GIB )) GiB or more"
    [ $(( (misc_sec + meta_sec + super_sec + data_sec) * SECTOR )) -le "$free_bytes" ] ||
        die "--data-size $DATA_SIZE does not fit in the $((free_bytes / 1073741824)) GiB of free space"

    msg "Plan for $DISK (largest free block: $((free_bytes / 1073741824)) GiB)"
    s=$start
    PLAN=()
    for n in "${NAMES[@]}"; do
        case "$n" in
            misc) len=$misc_sec ;; metadata) len=$meta_sec ;;
            super) len=$super_sec ;; userdata) len=$data_sec ;;
        esac
        e=$(( s + len - 1 ))
        printf '    %-9s %10s  sectors %s-%s\n' "$n" "$(numfmt --to=iec $((len * SECTOR)))" "$s" "$e"
        PLAN+=("-n" "0:$s:$e" "-t" "0:8300" "-c" "0:$n")
        s=$(( e + 1 ))
    done
    echo "    Existing partitions are not touched."
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS "$DISK"
    confirm "Create these partitions on $DISK?"
    run sgdisk "${PLAN[@]}" "$DISK"
    run partprobe "$DISK"
    run udevadm settle
    WIPE=1
fi

if [ "$DRY" = 1 ] && [ "$MODE" = install ]; then
    msg "Dry run: stopping before writing to the (not yet created) partitions"
    exit 0
fi

declare -A DEV
for n in "${NAMES[@]}"; do
    DEV[$n]="$(part_by_name "$n")"
    [ -b "${DEV[$n]}" ] || die "partition '$n' not found after creating it"
    findmnt -rno TARGET "${DEV[$n]}" >/dev/null && die "${DEV[$n]} ($n) is mounted; unmount it first"
done

super_part_bytes="$(blockdev --getsize64 "${DEV[super]}")"
[ "$super_part_bytes" -ge "$SUPER_BYTES" ] ||
    die "the super partition (${DEV[super]}) is smaller than super.img; delete the Android partitions and install again"

if [ "$MODE" = update ]; then
    msg "Updating LineageOS on $DISK$([ "$WIPE" = 1 ] && echo ' and ERASING Android data')"
    confirm "Write the new system to ${DEV[super]}$([ "$WIPE" = 1 ] && echo " and erase ${DEV[userdata]}")?"
fi

# --- Write --------------------------------------------------------------------
msg "Writing the system (super) partition"
if [ "$SUPER_SPARSE" = 1 ]; then
    run simg2img "$IMG_DIR/super.img" "${DEV[super]}"
else
    run dd if="$IMG_DIR/super.img" of="${DEV[super]}" bs=4M oflag=direct conv=fsync status=progress
fi

if [ "$WIPE" = 1 ]; then
    msg "Preparing metadata, misc and userdata"
    # Android's e2fsck may be older than Fedora's mkfs; skip the newest features.
    run mkfs.ext4 -F -q -L metadata -O ^orphan_file,^metadata_csum_seed "${DEV[metadata]}"
    run dd if=/dev/zero of="${DEV[misc]}" bs=1M count=$MISC_MIB conv=fsync status=none
    # Android formats userdata (with file-based encryption) on first boot
    # when it finds the start of the partition empty.
    run dd if=/dev/zero of="${DEV[userdata]}" bs=1M count=64 conv=fsync status=none
fi
run sync

# --- Boot entry -----------------------------------------------------------------
msg "Installing boot files to /boot/$BOOT_SUBDIR"
run mkdir -p "/boot/$BOOT_SUBDIR"
run install -m644 "$IMG_DIR/Image" "$IMG_DIR/ramdisk.img" "$IMG_DIR/$DTB" "/boot/$BOOT_SUBDIR/"

# Android names block devices under /dev/block/by-name only for the storage
# controllers listed in androidboot.boot_devices: here the PCIe controller of
# the NVMe drive, e.g. "soc@0/1c18000.pcie".
syspath="$(readlink -f "/sys/class/block/$(basename "$DISK")")"
rel="${syspath#/sys/devices/platform/}"
BOOT_DEVICES=""
acc=""
IFS=/ read -r -a parts <<<"$rel"
for p in "${parts[@]}"; do
    acc="${acc:+$acc/}$p"
    if [[ "$p" =~ ^[0-9a-f]+\.pcie?$ ]]; then BOOT_DEVICES="$acc"; break; fi
done
[ -n "$BOOT_DEVICES" ] || die "could not find the NVMe controller's platform device in $syspath"
msg2 "androidboot.boot_devices=$BOOT_DEVICES"

# A stable serial number for adb, derived from this Fedora install.
SERIAL="spx$(sha256sum /etc/machine-id | cut -c1-12)"

KARGS="efi=novamap clk_ignore_unused"
[ -r /etc/surface-pro-x/kernel-args ] && KARGS="$(tr '\n' ' ' < /etc/surface-pro-x/kernel-args)"
OPTIONS="$KARGS console=tty0 printk.devkmsg=on firmware_class.path=/vendor/firmware"
OPTIONS="$OPTIONS androidboot.hardware=spx androidboot.boot_devices=$BOOT_DEVICES"
OPTIONS="$OPTIONS androidboot.selinux=permissive androidboot.verifiedbootstate=orange"
OPTIONS="$OPTIONS androidboot.serialno=$SERIAL"
OPTIONS="$(echo "$OPTIONS" | tr -s ' ')"

ENTRY="title LineageOS (Surface Pro X)
version $ENTRY_ID
linux $PREFIX/$BOOT_SUBDIR/Image
initrd $PREFIX/$BOOT_SUBDIR/ramdisk.img
devicetree $PREFIX/$BOOT_SUBDIR/$DTB
options $OPTIONS
grub_users \$grub_users
grub_arg --unrestricted
grub_class lineageos"
msg "Writing $ENTRY_FILE"
if [ "$DRY" = 1 ]; then
    sed 's/^/      /' <<<"$ENTRY"
else
    printf '%s\n' "$ENTRY" > "$ENTRY_FILE"
fi

msg "Done ($MODE)."
echo "    Fedora stays the default. To boot LineageOS once:"
echo "        sudo grub2-reboot $ENTRY_ID && sudo reboot"
echo "    The first boot takes several minutes. If it fails, boot Fedora and run"
echo "        sudo ./read-bootlog.sh"
