#
# Copyright (C) 2026 surface-pro-x-lineage-os contributors
#
# SPDX-License-Identifier: Apache-2.0
#
# Microsoft Surface Pro X (SQ1/SQ2, Qualcomm SC8180X).
#
# This board runs a mainline-based kernel (the Fedora port's linux-surface
# kernel), is started by GRUB from the UEFI firmware, and has no Android
# bootloader, no A/B slots and no verified boot. See docs/design.md.
#

DEVICE_PATH := device/microsoft/spx

# Architecture (Kryo 495: Cortex-A76 + Cortex-A55 based)
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a-dotprod
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := cortex-a76
TARGET_CPU_VARIANT_RUNTIME := cortex-a76

# Platform
TARGET_BOARD_PLATFORM := sc8180x
TARGET_BOOTLOADER_BOARD_NAME := spx
TARGET_NO_BOOTLOADER := true
TARGET_NO_RECOVERY := true

# Kernel: built outside the Android tree by kernel/build-kernel.sh.
ifeq ($(wildcard $(DEVICE_PATH)/prebuilt/kernel/Image),)
    $(error Surface Pro X: no kernel in $(DEVICE_PATH)/prebuilt/kernel. Run $(DEVICE_PATH)/build.sh kernel first)
endif
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/kernel/Image
BOARD_KERNEL_IMAGE_NAME := Image
BOARD_KERNEL_PAGESIZE := 4096
BOARD_RAMDISK_USE_LZ4 := false
# Modules land in /vendor/lib/modules; ueventd loads them by modalias.
BOARD_VENDOR_KERNEL_MODULES := $(wildcard $(DEVICE_PATH)/prebuilt/kernel/modules/*.ko)
# The real command line lives in the GRUB entry tools/install-android.sh
# writes. It is listed here only for reference (no boot.img is flashed).
BOARD_KERNEL_CMDLINE := efi=novamap clk_ignore_unused androidboot.hardware=spx

# Partitions
BOARD_FLASH_BLOCK_SIZE := 4096
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_USES_METADATA_PARTITION := true
TARGET_USERIMAGES_USE_EXT4 := true
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_PARTITION_SIZE := 1073741824

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_SYSTEM_EXT := system_ext
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_PRODUCT := product
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_VENDOR := vendor
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4

# Dynamic partitions: one 8 GiB "super" partition on the NVMe drive.
BOARD_SUPER_PARTITION_SIZE := 8589934592
BOARD_SUPER_PARTITION_GROUPS := spx_dynamic_partitions
# Group size = super size minus 4 MiB for the partition metadata.
BOARD_SPX_DYNAMIC_PARTITIONS_SIZE := 8585740288
BOARD_SPX_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product vendor
BOARD_BUILD_SUPER_IMAGE_BY_DEFAULT := true

# Verified boot: off. GRUB cannot pass a verified boot state.
BOARD_AVB_ENABLE := false

# Graphics
TARGET_USES_HWC2 := true

# Wi-Fi (ath10k on the WCN3990, through the modem DSP)
BOARD_WLAN_DEVICE := qcwcn
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
BOARD_HOSTAPD_DRIVER := NL80211
WIFI_HIDL_UNIFIED_SUPPLICANT_SERVICE_RC_ENTRY := true
WIFI_HIDL_FEATURE_DUAL_INTERFACE := true

# Bluetooth (experimental, see README)
BOARD_HAVE_BLUETOOTH := true

# SELinux
BOARD_VENDOR_SEPOLICY_DIRS += $(DEVICE_PATH)/sepolicy/vendor

# VINTF
DEVICE_MANIFEST_FILE := $(DEVICE_PATH)/manifest.xml

# Firmware files are ELF (.mbn); they are copied verbatim into the vendor image.
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
