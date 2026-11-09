#!/usr/bin/env bash
# Install or update LineageOS on the Surface Pro X internal drive.
#
# Run ON THE SURFACE as root, in the directory made by "build.sh images"
# (it holds super.img, ramdisk.img, Image and the DTB), from either:
#   - Fedora installed on the internal drive (the Fedora port), or
#   - a Linux system booted from USB (the Fedora port's USB image), for a
#     Surface with only Windows, or with nothing you want to keep.
#
#   sudo ./install-android.sh                  install, or update if present
#   sudo ./install-android.sh --dry-run        show what would happen, change nothing
#   sudo ./install-android.sh --erase-disk     from USB only: ERASE the whole drive
#                                              (Windows and everything else) and give
#                                              it to Android
#   sudo ./install-android.sh --wipe-data      update and erase Android's user data
#   sudo ./install-android.sh --data-size 64G  size of Android's data partition
#                                              (default: all the free space)
#   sudo ./install-android.sh --disk /dev/nvme0n1   drive to use (default: the
#                                              internal NVMe drive)
#   sudo ./install-android.sh --uninstall      remove the boot entry and boot files
#
# Without --erase-disk the installer creates its partitions (misc, metadata,
# super, userdata) in the largest block of UNALLOCATED space and never
# resizes, moves or deletes a partition. Make room first (shrink Windows or
# Fedora with their own tools).
#
# Booting:
#   - From installed Fedora: adds a GRUB entry next to Fedora's.
#     Boot it once with: sudo grub2-reboot lineage-spx && sudo reboot
#   - From USB: installs systemd-boot on the drive's EFI system partition and
#     makes it the first UEFI boot entry. Its menu lists LineageOS and, if
#     present, Windows.
set -euo pipefail

ENTRY_ID=lineage-spx
BOOT_SUBDIR=lineage-spx
DTB=sc8180x-surface-pro-x.dtb
NAMES=(misc metadata super userdata)
MISC_MIB=1
METADATA_MIB=64
ESP_MIB=512
MIN_DATA_GIB=8
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
EFI_LABEL="LineageOS (Surface Pro X)"
SDBOOT_SRC=/usr/lib/systemd/boot/efi/systemd-bootaa64.efi

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
msg2() { printf '\033[1;34m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

DRY=0 WIPE=0 YES=0 UNINSTALL=0 ERASE=0 DATA_SIZE="" DISK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --wipe-data) WIPE=1; shift ;;
        --erase-disk) ERASE=1; shift ;;
        --yes) YES=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --data-size) DATA_SIZE="$2"; shift 2 ;;
        --disk) DISK="$2"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

run() { # run CMD...: print, and execute unless --dry-run
    msg2 "$*"
    [ "$DRY" = 1 ] || "$@"
}

confirm() { # confirm QUESTION [WORD]: the user must type WORD (default "yes")
    local word="${2:-yes}" answer
    [ "$DRY" = 1 ] && return 0
    [ "$YES" = 1 ] && [ "$word" = yes ] && return 0
    read -r -p "$1 Type '$word' to continue: " answer
    [ "$answer" = "$word" ] || die "cancelled"
}

[ "$(id -u)" -eq 0 ] || die "run this with sudo"
grep -qa 'microsoft,surface-pro-x' /sys/firmware/devicetree/base/compatible 2>/dev/null ||
    die "this does not look like a Surface Pro X booted with the Surface Pro X device tree"

# --- Target drive and boot method ------------------------------------------
root_src="$(findmnt -no SOURCE / | sed 's/\[.*\]$//')"
ROOT_DISK=""
if [ -b "$root_src" ]; then
    pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1)"
    [ -n "$pk" ] && ROOT_DISK="/dev/$pk"
fi
if [ -z "$DISK" ]; then
    case "$ROOT_DISK" in
        /dev/nvme*) DISK="$ROOT_DISK" ;;
        *) DISK=/dev/nvme0n1 ;;
    esac
fi
[ -b "$DISK" ] || die "$DISK is not a block device (use --disk /dev/nvme0n1)"
case "$DISK" in /dev/nvme*) ;; *) die "$DISK is not the internal NVMe drive; Android only boots from it" ;; esac
SECTOR="$(blockdev --getss "$DISK")"

# GRUB mode: running from Fedora on the same drive. Otherwise (USB) the
# installer brings its own boot manager, systemd-boot, on the drive's ESP.
if [ "$ROOT_DISK" = "$DISK" ]; then
    BOOT_MODE=grub
    [ "$ERASE" = 1 ] && die "--erase-disk would erase the system you are running; boot from USB to use it"
    [ -d /boot/loader/entries ] || die "/boot/loader/entries not found (is this Fedora with GRUB and BLS?)"
else
    BOOT_MODE=systemd-boot
fi

part_by_name() { # print /dev/... of the partition on $DISK with this GPT name
    lsblk -rno PATH,PARTLABEL "$DISK" | awk -v n="$1" '$2 == n { print $1 }'
}
esp_part() { # print /dev/... of the EFI system partition on $DISK
    lsblk -rno PATH,PARTTYPE "$DISK" | awk -v t="$ESP_TYPE" 'tolower($2) == t { print $1; exit }'
}

ESP_MNT=""
mount_esp() { # mount the ESP (if not mounted) and set ESP_MNT
    local esp
    esp="$(esp_part)"
    [ -n "$esp" ] || die "no EFI system partition on $DISK"
    ESP_MNT="$(findmnt -rno TARGET "$esp" | head -n1)"
    if [ -z "$ESP_MNT" ]; then
        ESP_MNT="$(mktemp -d)"
        mount "$esp" "$ESP_MNT"
        trap 'umount "$ESP_MNT" 2>/dev/null; rmdir "$ESP_MNT" 2>/dev/null' EXIT
    fi
}

# --- Uninstall --------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    msg "Removing LineageOS boot entries and boot files"
    if [ "$BOOT_MODE" = grub ]; then
        run rm -f "/boot/loader/entries/$ENTRY_ID.conf"
        run rm -rf "/boot/$BOOT_SUBDIR"
    else
        mount_esp
        run rm -f "$ESP_MNT/loader/entries/$ENTRY_ID.conf"
        run rm -rf "${ESP_MNT:?}/$BOOT_SUBDIR"
        if command -v efibootmgr >/dev/null; then
            for n in $(efibootmgr | awk -v l="$EFI_LABEL" 'index($0, l) { sub(/^Boot/, "", $1); sub(/\*$/, "", $1); print $1 }'); do
                run efibootmgr -q -b "$n" -B
            done
        fi
        msg2 "systemd-boot itself stays in EFI/systemd on the ESP (harmless; delete it if you like)"
    fi
    msg "Done. The Android partitions were left alone. To delete them, use"
    msg2 "GNOME Disks/KDE Partition Manager, or: sgdisk -d <number> $DISK for each of: ${NAMES[*]}"
    exit 0
fi

for c in sgdisk partprobe udevadm mkfs.ext4 lsblk blockdev dd sha256sum findmnt numfmt; do
    command -v "$c" >/dev/null || die "missing $c (sudo dnf install gdisk parted e2fsprogs util-linux coreutils)"
done
if [ "$BOOT_MODE" = systemd-boot ]; then
    [ -f "$SDBOOT_SRC" ] && command -v efibootmgr >/dev/null ||
        die "booting from USB needs systemd-boot and efibootmgr: sudo dnf install systemd-boot-unsigned efibootmgr"
    [ "$ERASE" = 1 ] && { command -v mkfs.vfat >/dev/null || die "missing mkfs.vfat (sudo dnf install dosfstools)"; }
fi

# --- Images ------------------------------------------------------------------
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
msg2 "target drive: $DISK ($(numfmt --to=iec "$(blockdev --getsize64 "$DISK")")), boot via $BOOT_MODE"

# --- Install or update? --------------------------------------------------------
found=0
for n in "${NAMES[@]}"; do
    count="$(part_by_name "$n" | wc -l)"
    [ "$count" -le 1 ] || die "more than one partition named '$n' on $DISK"
    [ "$count" -eq 1 ] && found=$((found + 1))
done

if [ "$ERASE" = 1 ]; then
    MODE=install
elif [ "$found" -eq 0 ]; then
    MODE=install
    if [ "$BOOT_MODE" = systemd-boot ] && [ -z "$(esp_part)" ]; then
        die "$DISK has no EFI system partition; use --erase-disk to set the drive up from scratch"
    fi
elif [ "$found" -eq "${#NAMES[@]}" ]; then
    MODE=update
else
    die "only some of the Android partitions (${NAMES[*]}) exist on $DISK; fix that by hand first"
fi

for p in $(lsblk -rno PATH "$DISK" | tail -n +2); do
    if [ "$ERASE" = 1 ] && findmnt -rno TARGET "$p" >/dev/null; then
        die "$p is mounted; unmount everything on $DISK before --erase-disk"
    fi
done

# --- Partitions (install) -------------------------------------------------------
if [ "$MODE" = install ]; then
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS "$DISK"
    if [ "$ERASE" = 1 ]; then
        msg "ERASING $DISK: every partition on it (Windows, recovery, Fedora, data) will be destroyed"
        confirm "Really erase all of $DISK?" "$(basename "$DISK")"
        run sgdisk --zap-all "$DISK"
        run sgdisk --clear "$DISK"
        run partprobe "$DISK"
        [ "$DRY" = 1 ] || udevadm settle
    fi

    msg "Looking for unallocated space on $DISK"
    if [ "$ERASE" = 1 ] && [ "$DRY" = 1 ]; then
        # The drive was not really cleared; plan as if it were empty.
        first=2048
        last=$(( $(blockdev --getsz "$DISK") * 512 / SECTOR - 34 ))
    else
        first="$(sgdisk -F "$DISK" | tail -n1)"
        last="$(sgdisk -E "$DISK" | tail -n1)"
    fi
    [[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ && "$last" -gt "$first" ]] ||
        die "no unallocated space on $DISK; shrink Windows or Fedora first"
    align=$((1048576 / SECTOR))
    start=$(( (first + align - 1) / align * align ))
    free_bytes=$(( (last - start + 1) * SECTOR ))

    mib() { echo $(( $1 * 1048576 / SECTOR )); }
    LAYOUT=()
    [ "$ERASE" = 1 ] && LAYOUT+=(esp)
    LAYOUT+=("${NAMES[@]}")
    super_sec=$(( (SUPER_BYTES + 1048575) / 1048576 * 1048576 / SECTOR ))
    fixed_sec=$(( $(mib $MISC_MIB) + $(mib $METADATA_MIB) + super_sec ))
    [ "$ERASE" = 1 ] && fixed_sec=$(( fixed_sec + $(mib $ESP_MIB) ))
    if [ -n "$DATA_SIZE" ]; then
        data_bytes="$(numfmt --from=iec "${DATA_SIZE%B}")"
    else
        data_bytes=$(( free_bytes - fixed_sec * SECTOR ))
    fi
    data_sec=$(( data_bytes / 1048576 * 1048576 / SECTOR ))
    [ "$data_sec" -ge "$(mib $((MIN_DATA_GIB * 1024)))" ] ||
        die "not enough room: $((free_bytes / 1073741824)) GiB free, Android needs $(( fixed_sec * SECTOR / 1073741824 + MIN_DATA_GIB )) GiB or more"
    [ $(( (fixed_sec + data_sec) * SECTOR )) -le "$free_bytes" ] ||
        die "--data-size $DATA_SIZE does not fit in the $((free_bytes / 1073741824)) GiB of free space"

    msg "Plan for $DISK (free block: $((free_bytes / 1073741824)) GiB)"
    s=$start
    PLAN=()
    for n in "${LAYOUT[@]}"; do
        case "$n" in
            esp) len=$(mib $ESP_MIB); type=ef00; name="EFI system partition" ;;
            misc) len=$(mib $MISC_MIB); type=8300; name=$n ;;
            metadata) len=$(mib $METADATA_MIB); type=8300; name=$n ;;
            super) len=$super_sec; type=8300; name=$n ;;
            userdata) len=$data_sec; type=8300; name=$n ;;
        esac
        e=$(( s + len - 1 ))
        printf '    %-21s %10s  sectors %s-%s\n' "$name" "$(numfmt --to=iec $((len * SECTOR)))" "$s" "$e"
        PLAN+=("-n" "0:$s:$e" "-t" "0:$type" "-c" "0:$name")
        s=$(( e + 1 ))
    done
    [ "$ERASE" = 1 ] || echo "    Existing partitions are not touched."
    [ "$ERASE" = 1 ] || confirm "Create these partitions on $DISK?"
    run sgdisk "${PLAN[@]}" "$DISK"
    run partprobe "$DISK"
    [ "$DRY" = 1 ] || udevadm settle
    WIPE=1
fi

if [ "$DRY" = 1 ] && [ "$MODE" = install ]; then
    msg "Dry run: stopping before writing to the (not yet created) partitions"
    exit 0
fi

declare -A DEV
for n in "${NAMES[@]}"; do
    DEV[$n]="$(part_by_name "$n")"
    [ -b "${DEV[$n]}" ] || die "partition '$n' not found"
    findmnt -rno TARGET "${DEV[$n]}" >/dev/null && die "${DEV[$n]} ($n) is mounted; unmount it first"
done

super_part_bytes="$(blockdev --getsize64 "${DEV[super]}")"
[ "$super_part_bytes" -ge "$SUPER_BYTES" ] ||
    die "the super partition (${DEV[super]}) is smaller than super.img; delete the Android partitions and install again"

if [ "$MODE" = update ]; then
    msg "Updating LineageOS on $DISK$([ "$WIPE" = 1 ] && echo ' and ERASING Android data')"
    confirm "Write the new system to ${DEV[super]}$([ "$WIPE" = 1 ] && echo " and erase ${DEV[userdata]}")?"
fi

# --- Write ------------------------------------------------------------------------
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
if [ "$ERASE" = 1 ]; then
    run mkfs.vfat -F 32 -n ESP "$(esp_part)"
fi
run sync

# --- Kernel command line ------------------------------------------------------------
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

# A stable serial number for adb, derived from the drive's partition table ID.
SERIAL="spx$(blkid -s PTUUID -o value "$DISK" | tr -d '-' | cut -c1-12)"

KARGS="efi=novamap clk_ignore_unused"
[ -r /etc/surface-pro-x/kernel-args ] && KARGS="$(tr '\n' ' ' < /etc/surface-pro-x/kernel-args)"
OPTIONS="$KARGS console=tty0 printk.devkmsg=on firmware_class.path=/vendor/firmware"
OPTIONS="$OPTIONS androidboot.hardware=spx androidboot.boot_devices=$BOOT_DEVICES"
OPTIONS="$OPTIONS androidboot.selinux=permissive androidboot.verifiedbootstate=orange"
OPTIONS="$OPTIONS androidboot.serialno=$SERIAL"
# Bring-up: when init hits a fatal error, panic instead of rebooting, and
# leave the panic on screen (panic=0) so the last messages can be read.
OPTIONS="$OPTIONS androidboot.init_fatal_panic=true panic=0 log_buf_len=4M"
# Audio: keep AOSP's example audio HAL away from the real sound card until
# routing for it exists; it uses virtual streams instead.
OPTIONS="$OPTIONS androidboot.audio.tinyalsa.ignore_output=true androidboot.audio.tinyalsa.simulate_input=true"
OPTIONS="$(echo "$OPTIONS" | tr -s ' ')"

write_file() { # write_file PATH CONTENT
    msg2 "writing $1"
    if [ "$DRY" = 1 ]; then
        printf '%s\n' "$2" | sed 's/^/      /'
    else
        printf '%s\n' "$2" > "$1"
    fi
}

# --- Boot entry ----------------------------------------------------------------------
if [ "$BOOT_MODE" = grub ]; then
    # Paths in a BLS entry are relative to the file system that holds /boot.
    BOOT_MNT="$(findmnt -no TARGET --target /boot)"
    if [ "$BOOT_MNT" = /boot ]; then PREFIX=""; else PREFIX="/boot"; fi
    msg "Installing boot files to /boot/$BOOT_SUBDIR"
    run mkdir -p "/boot/$BOOT_SUBDIR"
    run install -m644 "$IMG_DIR/Image" "$IMG_DIR/ramdisk.img" "$IMG_DIR/$DTB" "/boot/$BOOT_SUBDIR/"
    write_file "/boot/loader/entries/$ENTRY_ID.conf" "title LineageOS (Surface Pro X)
version $ENTRY_ID
linux $PREFIX/$BOOT_SUBDIR/Image
initrd $PREFIX/$BOOT_SUBDIR/ramdisk.img
devicetree $PREFIX/$BOOT_SUBDIR/$DTB
options $OPTIONS
grub_users \$grub_users
grub_arg --unrestricted
grub_class lineageos"
    msg "Done ($MODE)."
    echo "    Fedora stays the default. To boot LineageOS once:"
    echo "        sudo grub2-reboot $ENTRY_ID && sudo reboot"
else
    mount_esp
    need=$(( $(stat -c %s "$IMG_DIR/Image") + $(stat -c %s "$IMG_DIR/ramdisk.img") + 4194304 ))
    have=$(( $(stat -f -c '%a * %S' "$ESP_MNT") ))
    [ -d "$ESP_MNT/$BOOT_SUBDIR" ] && have=$(( have + $(du -sb "$ESP_MNT/$BOOT_SUBDIR" | cut -f1) ))
    [ "$have" -ge "$need" ] ||
        die "the EFI system partition has $((have / 1048576)) MiB free, LineageOS needs $((need / 1048576)) MiB"

    if [ -d "$ESP_MNT/EFI/fedora" ] && ! efibootmgr | grep -qF "$EFI_LABEL"; then
        warn "Fedora is installed on $DISK. systemd-boot will become the default boot"
        warn "manager and does not list Fedora; you would reach Fedora through the Surface"
        warn "boot menu (Volume Down at power-on). Running this from the installed Fedora"
        warn "instead adds LineageOS to Fedora's GRUB menu."
        confirm "Make systemd-boot the default anyway?"
    fi
    msg "Installing systemd-boot and boot files to the EFI system partition"
    run mkdir -p "$ESP_MNT/EFI/systemd" "$ESP_MNT/loader/entries" "$ESP_MNT/$BOOT_SUBDIR"
    run install -m644 "$SDBOOT_SRC" "$ESP_MNT/EFI/systemd/systemd-bootaa64.efi"
    if [ "$ERASE" = 1 ]; then
        # Fallback path, so the drive boots even if the UEFI entry is lost.
        run mkdir -p "$ESP_MNT/EFI/BOOT"
        run install -m644 "$SDBOOT_SRC" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
    fi
    run install -m644 "$IMG_DIR/Image" "$IMG_DIR/ramdisk.img" "$IMG_DIR/$DTB" "$ESP_MNT/$BOOT_SUBDIR/"
    [ -f "$ESP_MNT/loader/loader.conf" ] ||
        write_file "$ESP_MNT/loader/loader.conf" "default $ENTRY_ID.conf
timeout 5
console-mode max"
    write_file "$ESP_MNT/loader/entries/$ENTRY_ID.conf" "title LineageOS (Surface Pro X)
linux /$BOOT_SUBDIR/Image
initrd /$BOOT_SUBDIR/ramdisk.img
devicetree /$BOOT_SUBDIR/$DTB
options $OPTIONS"

    if ! efibootmgr | grep -qF "$EFI_LABEL"; then
        espdev="$(esp_part)"
        espnum="$(cat "/sys/class/block/$(basename "$espdev")/partition")"
        msg "Adding the UEFI boot entry \"$EFI_LABEL\" (first in the boot order)"
        if ! run efibootmgr -q --create --disk "$DISK" --part "$espnum" \
                --label "$EFI_LABEL" --loader '\EFI\systemd\systemd-bootaa64.efi'; then
            warn "efibootmgr failed. Add the entry from a UEFI shell instead:"
            warn "  bcfg boot add 0 FS0:\\EFI\\systemd\\systemd-bootaa64.efi \"$EFI_LABEL\""
        fi
    fi
    msg "Done ($MODE)."
    echo "    Remove the USB drive and restart. The systemd-boot menu shows LineageOS"
    [ "$ERASE" = 1 ] || echo "    and Windows (if present). Hold Space at start-up if the menu doesn't appear."
fi
echo "    The first boot takes several minutes. If it fails, boot Linux (Fedora or"
echo "    the USB system) and run: sudo ./read-bootlog.sh"
