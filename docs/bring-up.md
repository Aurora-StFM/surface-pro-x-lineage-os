# Bring-up guide

What to check, stage by stage, when the first builds and boots fail. When asking for help, include the output or log named for that stage.

## 1. Kernel build

`./build.sh kernel` stops with `CONFIG_... missing from the final config` when an option Android needs was switched off by a dependency. Run `make menuconfig` in `out/work/kernel-build` (with `ARCH=arm64`) to see why. Lines starting with `warning: not applied:` are options from `android.config` that didn't stick; most are harmless, but send them along.

Duplicate module names (`warning: duplicate module name`) mean two drivers built a `.ko` with the same file name. Android installs modules into one directory, so one of them must be disabled.

## 2. Android build

Errors that are likely in the first build, and where to fix them:

| Error | Fix |
|---|---|
| `... depends on undefined module "X"` for a graphics or HAL package | The module was renamed in this LineageOS release. Find the new name with `grep -rn 'name: "' <dir>/Android.bp` and update `device.mk` or `graphics.mk`. |
| Duplicate VINTF HAL declaration for `graphics.allocator` or `graphics.mapper` | The minigbm module now ships its own fragment; delete that entry from `manifest.xml`. |
| `Multiple same specifications` in file_contexts | Another policy already labels that file; delete the line from `sepolicy/vendor/file_contexts`. |
| Errors in `external/linux-msm/*` | Compare with the commit pinned in `local_manifests/spx.xml`. |
| VINTF compatibility check failures | Note the HAL named in the error. |

## 3. Kernel start (screen)

After choosing LineageOS in GRUB, kernel messages should scroll on the screen (`console=tty0`). If the screen stays black and the tablet doesn't reboot, the kernel did not start or the display handover failed (the same black-screen issue the Fedora port sometimes has); hold the power button and try again.

## 4. First-stage init

First-stage init mounts the dynamic partitions from `super` and `/metadata`. If it fails, init reboots after printing an error. Look for these on screen:

- `Could not find /dev/block/by-name/super` or a wait timeout: `androidboot.boot_devices` doesn't match the NVMe controller. Compare the value in `/boot/loader/entries/lineage-spx.conf` with `readlink -f /sys/class/block/nvme0n1` in Fedora.
- `Failed to mount /system`: `super.img` wasn't written completely, or the kernel lacks device-mapper support.

`sudo ./read-bootlog.sh` in Fedora reports "Android never got as far as mounting /metadata" in this case.

## 5. Second stage to the home screen

From here, logs are saved to `/metadata/spx-debug` every 10 seconds. Boot Fedora, run `sudo ./read-bootlog.sh`, and start with `boot.1/status.txt`:

- **Services:** lines like `init.svc.surfaceflinger=restarting` show which service keeps crashing. Search `logcat.txt` for its name.
- **Graphics:** if `surfaceflinger`, the composer or the allocator service restart, look for `drm_hwcomposer`, `minigbm` or `gralloc` in logcat. `dmesg.txt` shows whether the msm DRM driver probed (`[drm] Initialized msm`).
- **Data:** if `/data` didn't mount, look for `fs_mgr` and `vold` in logcat. The first boot formats it; that needs the partition start to be empty (the installer zeroes it).
- **Remote processors:** the `remoteproc` section lists each DSP's state. The modem (`mpss`) should be `running` once rmtfs starts; otherwise check `rmtfs` in logcat.

If the boot animation runs for a long time: the first boot compiles apps and can take 10 minutes or more with software rendering.

## 6. Using adb

USB device mode doesn't work on the Surface Pro X, so adb goes over the network on port 5555:

1. Plug in a USB-C Ethernet adapter (Android configures it automatically), or connect to Wi-Fi once the UI is up.
2. Find the address in `status.txt` (network section) or your router.
3. `adb connect <address>:5555`

With `./build.sh adbkey` before building, your PC is already trusted. Otherwise confirm the prompt on the tablet.

Useful commands once connected: `adb logcat`, `adb shell dmesg`, `adb shell dmesg | grep avc` (SELinux denials to turn into policy later), `adb shell getprop | grep init.svc`.

## 7. Wi-Fi

Wi-Fi needs the modem DSP running. Check in order:

1. `adb shell cat /sys/class/remoteproc/*/name /sys/class/remoteproc/*/state`: `mpss` should be `running`.
2. `adb shell ip link`: `wlan0` should exist.
3. `adb logcat | grep -iE 'wifi|wpa_supplicant'` for the framework side.
