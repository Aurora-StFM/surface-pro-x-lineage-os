#!/usr/bin/env bash
# Build the Surface Pro X kernel for Android and put it where the device tree
# expects it (prebuilt/kernel/).
#
# The kernel source, patches and base configuration come from the Fedora port
# (pinned by FEDORA_KIT_COMMIT in config.env); kernel/android.config is merged
# on top. Optionally, Android's own required options are merged as well:
#
#   build-kernel.sh                              Fedora inputs + android.config
#   build-kernel.sh --android-configs DIR        also merge DIR/android-base.config
#                                                (e.g. <lineage>/kernel/configs/<rel>/android-6.12)
#
# Cross-compiles with aarch64-linux-gnu-gcc when installed, otherwise with
# clang/LLVM (LLVM=1). Set KERNEL_TOOLCHAIN=gcc or llvm to force one.
set -euo pipefail
. "$(dirname "$0")/../lib/common.sh"

ANDROID_CONFIGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --android-configs) ANDROID_CONFIGS="$(realpath "$2")"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_cmds git curl make flex bison bc perl sha256sum

: "${KERNEL_TOOLCHAIN:=auto}"
if [ "$KERNEL_TOOLCHAIN" = auto ]; then
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then KERNEL_TOOLCHAIN=gcc; else KERNEL_TOOLCHAIN=llvm; fi
fi
case "$KERNEL_TOOLCHAIN" in
    gcc)  require_cmds aarch64-linux-gnu-gcc; TOOLCHAIN_ARGS=(CROSS_COMPILE=aarch64-linux-gnu-) ;;
    llvm) require_cmds clang ld.lld llvm-objcopy; TOOLCHAIN_ARGS=(LLVM=1) ;;
    *) die "KERNEL_TOOLCHAIN must be gcc, llvm or auto" ;;
esac

load_fedora_kit

SRC="$WORK_DIR/kernel-src"
BUILD="$WORK_DIR/kernel-build"
STAGE="$WORK_DIR/kernel-stage"
CFG="$WORK_DIR/kernel-config"
OUT="$PREBUILT_DIR/kernel"
JOBS="${JOBS:-$(nproc)}"
KMAKE=(make -C "$SRC" O="$BUILD" ARCH=arm64 "${TOOLCHAIN_ARGS[@]}"
       LOCALVERSION="$KERNEL_LOCALVERSION")

mkdir -p "$WORK_DIR" "$CFG"

msg "Fetching kernel source ($KERNEL_REPO @ ${KERNEL_COMMIT:0:12})"
git_fetch_commit "$KERNEL_REPO" "$SRC" "$KERNEL_COMMIT"

shopt -s nullglob
PATCHES=("$FEDORA_KIT_DIR"/kernel/patches/*.patch "$KIT_DIR"/kernel/patches/*.patch)
shopt -u nullglob
for p in "${PATCHES[@]}"; do
    msg2 "applying $(basename "$p")"
    git -C "$SRC" apply --whitespace=nowarn "$p" || die "patch failed: $p"
done

msg "Preparing configuration"
fetch_verified "$BASE_CONFIG_URL" "$CFG/base.config" "$BASE_CONFIG_SHA256"
fetch_verified "$SPX_CONFIG_URL" "$CFG/spx.config" "$SPX_CONFIG_SHA256"
FRAGMENTS=("$CFG/base.config" "$CFG/spx.config"
           "$FEDORA_KIT_DIR/kernel/overrides.config" "$FEDORA_KIT_DIR/kernel/fedora.config")
if [ -n "$ANDROID_CONFIGS" ]; then
    [ -f "$ANDROID_CONFIGS/android-base.config" ] || die "no android-base.config in $ANDROID_CONFIGS"
    FRAGMENTS+=("$ANDROID_CONFIGS/android-base.config")
    [ -f "$ANDROID_CONFIGS/android-base-arm64.config" ] && FRAGMENTS+=("$ANDROID_CONFIGS/android-base-arm64.config")
fi
FRAGMENTS+=("$KIT_DIR/kernel/android.config")
rm -rf "$BUILD"
mkdir -p "$BUILD"
(cd "$BUILD" && ARCH=arm64 "$SRC/scripts/kconfig/merge_config.sh" -m -O "$BUILD" "${FRAGMENTS[@]}" >/dev/null)
"${KMAKE[@]}" olddefconfig >/dev/null

# Options Android cannot boot without. If one of these is missing, a
# dependency in the merged config turned it off; check with menuconfig.
for opt in ANDROID_BINDER_IPC=y ANDROID_BINDERFS=y SECURITY_SELINUX=y BLK_DEV_DM=y \
           DM_VERITY=y BLK_DEV_LOOP=y EXT4_FS=y EROFS_FS=y FUSE_FS=y FS_ENCRYPTION=y \
           BPF_SYSCALL=y CGROUP_BPF=y CPUSETS_V1=y BLK_CGROUP=y PSI=y BLK_DEV_NVME=y PCIE_QCOM=y RD_GZIP=y \
           DMABUF_HEAPS_SYSTEM=y SYNC_FILE=y NETFILTER_XT_MATCH_BPF=y IP6_NF_IPTABLES=y \
           DRM_MSM=m ATH10K_SNOC=m SURFACE_AGGREGATOR=m QCOM_PD_MAPPER=m; do
    grep -q "^CONFIG_${opt}\$" "$BUILD/.config" || die "CONFIG_${opt} missing from the final config"
done
grep -q '^CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"$' "$BUILD/.config" ||
    die "CONFIG_ANDROID_BINDER_DEVICES must be \"binder,hwbinder,vndbinder\""
# Report other android.config settings that did not survive (not fatal).
while IFS= read -r line; do
    case "$line" in CONFIG_*=*) ;; *) continue ;; esac
    grep -qxF "$line" "$BUILD/.config" || warn "not applied: $line"
done < "$KIT_DIR/kernel/android.config"

KREL="$("${KMAKE[@]}" -s kernelrelease)"
msg "Building kernel $KREL with $JOBS jobs ($KERNEL_TOOLCHAIN; this takes a while)"
"${KMAKE[@]}" -j"$JOBS" Image modules dtbs

msg "Staging kernel, device tree and modules"
rm -rf "$STAGE"
"${KMAKE[@]}" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install >/dev/null
[ -f "$BUILD/arch/arm64/boot/dts/$SPX_DTB" ] || die "$SPX_DTB was not built"

rm -rf "$OUT.new"
mkdir -p "$OUT.new/modules"
install -m644 "$BUILD/arch/arm64/boot/Image" "$OUT.new/Image"
install -m644 "$BUILD/arch/arm64/boot/dts/$SPX_DTB" "$OUT.new/$(basename "$SPX_DTB")"
install -m644 "$BUILD/.config" "$OUT.new/config"
echo "$KREL" > "$OUT.new/kernel.release"

# Android installs vendor modules into one flat directory and runs depmod
# itself, so module file names must be unique. Duplicates are reported and
# the first one kept; disable the unneeded driver if this ever triggers.
dups=0
while IFS= read -r -d '' ko; do
    name="$(basename "$ko")"
    if [ -e "$OUT.new/modules/$name" ]; then
        warn "duplicate module name $name (keeping the first, skipping ${ko#"$STAGE"/})"
        dups=$((dups + 1))
        continue
    fi
    install -m644 "$ko" "$OUT.new/modules/$name"
done < <(find "$STAGE/lib/modules/$KREL" -name '*.ko' -print0 | sort -z)
nmods="$(find "$OUT.new/modules" -name '*.ko' | wc -l)"

rm -rf "$OUT"
mv "$OUT.new" "$OUT"
cat > "$OUT/README" <<EOF
Generated by kernel/build-kernel.sh; do not edit.
kernel:   $KREL ($KERNEL_REPO @ $KERNEL_COMMIT)
fedora:   $FEDORA_KIT_REPO @ $FEDORA_KIT_COMMIT
modules:  $nmods ($dups duplicate names skipped)
EOF
msg "Done: $OUT ($KREL, $nmods modules)"
