#!/usr/bin/env bash
# Surface Pro X LineageOS port: helper entry point (run on the x86_64 build PC).
#
#   ./build.sh kernel [--android-configs DIR]  build the kernel into prebuilt/kernel
#   ./build.sh firmware [--from-dir DIR]       stage firmware into prebuilt/firmware
#   ./build.sh adbkey [PUBKEY]                 trust your adb key in the build
#                                              (default ~/.android/adbkey.pub)
#   ./build.sh setup ANDROID_TREE              add the local manifest to a LineageOS
#                                              checkout (then run repo sync there)
#   ./build.sh images ANDROID_TREE [DEST]      collect the files the installer needs
#                                              into DEST (default out/images) and pack
#                                              them as out/lineage-spx-images.tar
#
# The Android build itself runs in the LineageOS tree:
#   source build/envsetup.sh && breakfast spx && m -j$(nproc)
# See README.md for the whole sequence.
set -euo pipefail
. "$(dirname "$0")/lib/common.sh"

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
    kernel)
        exec "$KIT_DIR/kernel/build-kernel.sh" "$@" ;;
    firmware)
        exec "$KIT_DIR/firmware/build-firmware.sh" "$@" ;;
    adbkey)
        key="${1:-$HOME/.android/adbkey.pub}"
        [ -f "$key" ] || die "no adb public key at $key (run 'adb start-server' once to create one)"
        mkdir -p "$PREBUILT_DIR"
        cp "$key" "$PREBUILT_DIR/adb_keys"
        msg "Copied $key to prebuilt/adb_keys; rebuild Android to include it" ;;
    setup)
        tree="${1:?usage: build.sh setup ANDROID_TREE}"
        [ -d "$tree/.repo" ] || die "$tree is not a repo checkout (no .repo directory)"
        mkdir -p "$tree/.repo/local_manifests"
        cp "$KIT_DIR/local_manifests/spx.xml" "$tree/.repo/local_manifests/spx.xml"
        msg "Added .repo/local_manifests/spx.xml; now run: cd $tree && repo sync"
        if [ "$(realpath "$KIT_DIR")" != "$(realpath -m "$tree/device/microsoft/spx")" ]; then
            msg2 "repo will check this repository out at $tree/device/microsoft/spx."
            msg2 "To work from this clone instead, remove the device/microsoft/spx project"
            msg2 "from the local manifest and symlink or move this directory there."
        fi ;;
    images)
        tree="${1:?usage: build.sh images ANDROID_TREE [DEST]}"
        dest="${2:-$OUT_DIR/images}"
        prod="$tree/out/target/product/spx"
        for f in super.img ramdisk.img; do
            [ -f "$prod/$f" ] || die "$prod/$f not found; build Android first"
        done
        [ -f "$PREBUILT_DIR/kernel/Image" ] || die "no kernel in prebuilt/kernel; run ./build.sh kernel"
        rm -rf "$dest"
        mkdir -p "$dest"
        cp "$prod/super.img" "$prod/ramdisk.img" "$dest/"
        cp "$PREBUILT_DIR/kernel/Image" "$PREBUILT_DIR/kernel/$(basename "$SPX_DTB")" \
           "$PREBUILT_DIR/kernel/kernel.release" "$dest/"
        cp "$KIT_DIR/tools/install-android.sh" "$KIT_DIR/tools/read-bootlog.sh" "$dest/"
        (cd "$dest" && sha256sum super.img ramdisk.img Image "$(basename "$SPX_DTB")" > SHA256SUMS)
        tar -C "$(dirname "$dest")" -cf "$OUT_DIR/lineage-spx-images.tar" "$(basename "$dest")"
        msg "Images in $dest, packed as $OUT_DIR/lineage-spx-images.tar"
        msg2 "Copy the tar to the Surface (Fedora), unpack it and run: sudo ./install-android.sh" ;;
    ""|-h|--help)
        sed -n '2,17p' "$0" ;;
    *)
        die "unknown command: $cmd (try --help)" ;;
esac
