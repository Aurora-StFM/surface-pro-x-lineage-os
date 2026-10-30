# LineageOS for the Surface Pro X

An unofficial LineageOS 23.2 (Android 16) port for the Microsoft Surface Pro X (SQ1/SQ2, Qualcomm SC8180X). It installs next to Windows and Fedora, or on its own on an empty drive.

> **Status: first version, not booted yet.** Everything here is written but has not run on a Surface. Expect the first builds and boots to need fixes; see [docs/bring-up.md](docs/bring-up.md) for how to find out what went wrong. This is not an official LineageOS build and is not affiliated with LineageOS, Microsoft or the [linux-surface](https://github.com/linux-surface) project. It was written with Claude, an AI assistant by Anthropic, which is credited as co-author on its commits.

## How it works

The Surface Pro X never shipped with Android, so there is no vendor Android code to start from. This port runs Android on the same mainline-based kernel as the [Fedora port](https://github.com/Aurora-StFM/surface-pro-x-fedora), the way Linaro runs AOSP on its Qualcomm development boards:

- **Kernel:** the Fedora port's linux-surface kernel, patches and configuration, with an Android config fragment on top ([kernel/android.config](kernel/android.config)). Kernel fixes made for Fedora carry over by bumping one commit in [config.env](config.env).
- **Boot:** a UEFI boot manager (Fedora's GRUB, or systemd-boot when Fedora isn't installed) starts the kernel with Android's ramdisk and the same device tree Fedora uses. There is no Android bootloader, no fastboot and no verified boot.
- **Storage:** four GPT partitions on the internal NVMe drive (`misc`, `metadata`, `super`, `userdata`), created in unallocated space so Windows and Fedora stay untouched, or on an erased drive.
- **Graphics:** the msm display driver with drm_hwcomposer and minigbm. Rendering is in software (SwiftShader and ANGLE) for this first version; hardware rendering with Mesa (freedreno and turnip, which already work under Fedora) is the next step.
- **Wi-Fi:** the same Qualcomm services as Fedora (rmtfs, tqftpserv, qrtr), since the modem DSP runs the Wi-Fi firmware.

[docs/design.md](docs/design.md) explains each choice.

## Expected status

| Area | Expected in this version |
|---|---|
| Boot to the home screen | Goal of this version |
| Display, touchscreen (single touch), Type Cover keyboard and touchpad | Should work (same kernel drivers as Fedora) |
| Graphics | Software rendering: works, but slow at 2880x1920 |
| Wi-Fi | Should work |
| Battery status | Should work |
| adb | Over the network (USB-C Ethernet adapter or Wi-Fi); USB device mode does not work on this tablet |
| Bluetooth | Experimental; the controller needs an address (see the Fedora port) |
| Screen brightness, audio, rotation, light sensor, multitouch and pen, cameras, LTE | Not yet |

## What you need

- **A Linux build PC** for LineageOS: x86_64, at least 32 GB of RAM (64 GB is better), about 400 GB of free disk space. The kernel is cross-compiled on the same machine.
- **A way to run Linux on the Surface Pro X:** either the [Fedora port](https://github.com/Aurora-StFM/surface-pro-x-fedora) installed on it, or the Fedora port's USB image (no installed Linux needed). The Fedora port's README explains how to build the USB image.
- **About 30 GB of unallocated space** on the Surface's internal drive, unless you give Android the whole drive.
- **A USB-C Ethernet adapter** is very useful for adb during bring-up.

## Building

1. **Get the LineageOS source** (see LineageOS's build guides for setting up a build machine):

   ```sh
   mkdir -p ~/lineage && cd ~/lineage
   repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs
   ```

2. **Add this device** with the local manifest, then sync:

   ```sh
   git clone https://github.com/Aurora-StFM/surface-pro-x-lineage-os.git ~/surface-pro-x-lineage-os
   ~/surface-pro-x-lineage-os/build.sh setup ~/lineage
   cd ~/lineage && repo sync -c -j8
   ```

   repo checks this repository out at `device/microsoft/spx`. Run the remaining commands from there.

3. **Build the kernel and stage the firmware** (run in `~/lineage/device/microsoft/spx`):

   ```sh
   ./build.sh kernel --android-configs ~/lineage/kernel/configs/b/android-6.12
   ./build.sh firmware          # or: --from-dir DIR for firmware from your own Windows
   ./build.sh adbkey            # optional: trust your PC's adb key
   ```

   `--android-configs` merges Android's own kernel requirements; use the newest `android-6.*` directory you find under `kernel/configs/`. The kernel build needs `aarch64-linux-gnu-gcc` or clang/LLVM.

4. **Build Android:**

   ```sh
   cd ~/lineage
   source build/envsetup.sh
   breakfast spx
   m -j$(nproc)
   ```

5. **Collect the images** to copy to the Surface:

   ```sh
   ~/lineage/device/microsoft/spx/build.sh images ~/lineage
   ```

   This writes `out/lineage-spx-images.tar` in the device directory.

## Installing

Copy `lineage-spx-images.tar` to the Surface (or onto a USB stick) and unpack it. The installer runs from Linux on the Surface and handles three situations:

| On the Surface now | Run the installer from | Boot menu afterwards |
|---|---|---|
| Fedora port installed | Installed Fedora | Fedora's GRUB, with a new LineageOS entry |
| Only Windows | The Fedora port's USB image | systemd-boot: LineageOS and Windows |
| Nothing you want to keep | The Fedora port's USB image, with `--erase-disk` | systemd-boot: LineageOS only |

Every mode accepts `--dry-run`, which shows the plan without changing anything. The installer asks before writing.

### Next to Fedora

```sh
tar xf lineage-spx-images.tar && cd images
sudo ./install-android.sh --dry-run
sudo ./install-android.sh
sudo grub2-reboot lineage-spx && sudo reboot
```

The installer creates the Android partitions in the largest block of unallocated space; it never resizes or deletes a partition. Fedora stays the default boot entry, so a failed Android boot only costs a restart.

### Without an installed Linux (Windows only, or an empty drive)

1. **Prepare the Surface** as in the Fedora port's README: save your BitLocker recovery key and turn off Secure Boot. To keep Windows, also shrink it in Disk Management and leave at least 30 GB *Unallocated*.
2. **Boot the Fedora port's USB image:** hold Volume Down, press and release Power, and keep holding until the Surface logo shows.
3. **In the USB system**, connect to Wi-Fi and install the boot tools:

   ```sh
   sudo dnf install systemd-boot-unsigned efibootmgr android-tools
   ```

4. **Run the installer** from the unpacked images directory:

   ```sh
   sudo ./install-android.sh --dry-run
   sudo ./install-android.sh                  # keep Windows, use the free space
   # or, to give Android the WHOLE drive (deletes Windows and everything else):
   sudo ./install-android.sh --erase-disk
   ```

   `--erase-disk` asks you to type the drive's name (`nvme0n1`) before it erases anything. Windows can only come back from a Surface recovery image afterwards (from Microsoft's Surface recovery page).

5. **Remove the USB drive and restart.** The installer puts systemd-boot on the drive's EFI system partition and makes it the first UEFI boot entry. Its menu lists LineageOS and, if you kept it, Windows. The Surface's own boot menu (Volume Down at power-on) also still works.

### Updating and removing

To update, build again and run `sudo ./install-android.sh` with the new images, from the same kind of system you installed from. Android's data is kept unless you add `--wipe-data`. `--uninstall` removes the boot entry and boot files; the partitions stay.

## When it doesn't boot

Boot back into Fedora (or the USB system) and run `sudo ./read-bootlog.sh`. Android keeps the kernel log, logcat and a status summary of its last five boots on the `metadata` partition, and the script copies them to `./spx-bootlogs`. [docs/bring-up.md](docs/bring-up.md) lists what to look for at each stage.

## Credits

This port packages other people's work: the [linux-surface](https://github.com/linux-surface) project (Maximilian Luz and contributors) for the kernel, device tree and firmware tooling; [linux-msm](https://github.com/linux-msm) for qrtr, rmtfs and tqftpserv; Linaro and the GloDroid project for showing how to run Android on mainline kernels; and LineageOS. The firmware belongs to Microsoft and Qualcomm and is not part of this repository; build it only for a device you own.
