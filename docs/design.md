# Design notes

Why the port is built the way it is, and what each choice costs. Read this before changing the boot path, the partitions or the graphics stack.

## Starting point

Normal LineageOS ports start from the phone maker's Android code: a Qualcomm vendor kernel, closed drivers and vendor HALs. The Surface Pro X only ever shipped Windows, so none of that exists. What does exist is a mainline-based Linux kernel that runs this tablet well (linux-surface, packaged by the Fedora port), and a known way to run AOSP on mainline kernels with open drivers (Linaro's Dragonboard and SM8x50 targets, GloDroid, Cuttlefish). This port combines the two.

## Kernel

`kernel/build-kernel.sh` checks out the Fedora port at `FEDORA_KIT_COMMIT` and reads its `config.env`, so it builds exactly the kernel commit, patches and base configuration Fedora uses. It then merges:

1. Android's own base config from the LineageOS tree, when `--android-configs` points at it (`kernel/configs/b/android-6.12`). Options that only exist in Android's kernel fork (ashmem, dm-default-key, xt_quota2, uid_sys_stats, ...) are skipped by Kconfig; nothing in this port depends on them.
2. `kernel/android.config`, last. It builds in what Android needs before modules can load (binder, device mapper, the file systems, netfilter for netd, crypto for file-based encryption). Android has no `/sbin/modprobe` for the kernel's on-demand module loading, so anything normally auto-loaded is built in; `MODPROBE_PATH=/system/bin/modprobe` is a fallback.

Kernel modules go to `/vendor/lib/modules` in one flat directory, and ueventd loads them by modalias (`modalias_handling enabled` in `ueventd.spx.rc`), like udev on Fedora. `qcom_pd_mapper` is loaded explicitly in `init.spx.rc` because nothing requests it by alias (qrtr is built in).

The kernel is a prebuilt (`TARGET_PREBUILT_KERNEL`) rather than built inside the Android tree. LineageOS warns about that, but it keeps one kernel build for both ports and lets kernel work happen in the Fedora repository.

## Boot

The Surface's UEFI firmware runs Fedora's GRUB. GRUB loads three files from `/boot/lineage-spx/`:

- `Image`: the kernel.
- `ramdisk.img`: Android's generic ramdisk, which holds first-stage init and `fstab.spx`.
- `sc8180x-surface-pro-x.dtb`: the same device tree Fedora boots with.

The kernel command line is written by `tools/install-android.sh` into the GRUB (BLS) entry. Besides Fedora's arguments it sets:

| Argument | Why |
|---|---|
| `androidboot.hardware=spx` | Selects `fstab.spx` and `init.spx.rc` |
| `androidboot.boot_devices=soc@0/1c18000.pcie` | ueventd creates `/dev/block/by-name/*` only for these controllers. The installer finds the NVMe drive's PCIe controller from sysfs. |
| `androidboot.selinux=permissive` | Bring-up: log SELinux denials instead of failing |
| `androidboot.verifiedbootstate=orange` | There is no verified boot; this is what an unlocked bootloader reports |
| `androidboot.serialno=...` | adb needs a serial number |
| `firmware_class.path=/vendor/firmware` | The kernel's firmware loader looks in `/lib/firmware` by default |
| `console=tty0` | Kernel messages on the screen, so early failures are visible |

There is no boot.img, no Android bootloader and no fastboot, which is why updates go through the installer in Fedora rather than `fastboot flash`. Google's UEFI generic bootloader (GBL) could replace GRUB later and give a more standard Android boot, but it is new and untested on hardware like this.

## Storage

| Partition | Size | Contents |
|---|---|---|
| `misc` | 1 MiB | Android's bootloader message area (unused for now) |
| `metadata` | 64 MiB | ext4, mounted in first-stage init. Also holds the bring-up logs. |
| `super` | 8 GiB | Dynamic partitions: system, system_ext, product, vendor |
| `userdata` | the rest | ext4 with file-based encryption; Android formats it on first boot |

Partitions are found by GPT name, so they can sit anywhere on the drive. No A/B slots and no virtual A/B: the installer rewrites `super` in place.

Encryption: file-based encryption (fscrypt v2) works with the upstream kernel. Metadata encryption and checkpointing are off because they need dm-default-key and dm-bow, which only exist in Android's kernel. The KeyMint and Gatekeeper HALs are the AOSP software implementations, so keys are not protected by hardware. Treat the device as having no secure storage.

## Graphics

Display: the msm DRM/KMS driver drives the panel exactly as under Fedora. On the Android side, drm_hwcomposer is the composer HAL and minigbm, built with its msm backend, is the gralloc (it allocates scanout buffers from the msm driver).

Rendering in this version is software: SwiftShader (Vulkan) with ANGLE on top (GLES). It needs nothing from the GPU, which makes it the safest way to reach the home screen, but it will be slow at 2880x1920.

Hardware rendering is the next step. Under Fedora, Mesa's freedreno (GL) and turnip (Vulkan) drivers already run on the Adreno 680. AOSP's `external/mesa3d` no longer builds these drivers, so the plan is to build Mesa separately for Android with the NDK and meson (as Mesa's documentation describes, or with GloDroid's aospext), then ship the libraries as vendor prebuilts with `ro.hardware.egl=mesa` and `ro.hardware.vulkan=freedreno`. The turnip GMEM bug noted in the Fedora port may show up here too.

## Remote processors and Wi-Fi

The WCN3990 Wi-Fi chip is driven by ath10k, but its firmware runs on the modem DSP. The modem needs:

- `rmtfs`, which serves it zero-filled file system images (same as the Fedora port; its real EFS partitions are not reachable) and starts the modem (`-s`).
- `tqftpserv`, which serves firmware files from `/vendor/firmware` (built with `-DANDROID`, which selects that path).
- the in-kernel qrtr name service and PD mapper.

These come from linux-msm's repositories, which include Android build files; the local manifest pins them.

## What is left out for now

- Audio: needs a HAL for the WCD934x codec and speaker amplifiers, plus the ADSP start-up dance from the Fedora port.
- Backlight: Android sets brightness through a lights HAL or the composer; neither drives the panel's backlight yet.
- Sensors (accelerometer, light, compass): the SLPI DSP, hexagonrpcd and libssc stack from the Fedora port would need an Android sensors HAL.
- Multitouch and pen: iptsd would need porting.
- LTE, cameras: not working on Linux either.
