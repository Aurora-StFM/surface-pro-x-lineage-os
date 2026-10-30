#
# Copyright (C) 2026 surface-pro-x-lineage-os contributors
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/microsoft/spx

# Storage and runtime
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)
$(call inherit-product, frameworks/native/build/tablet-10in-xhdpi-2048-dalvik-heap.mk)

# The vendor side is a fresh port; an older shipping level keeps the
# requirements on vendor HALs (HIDL gralloc 4, kernel checks) achievable.
PRODUCT_SHIPPING_API_LEVEL := 33
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false
PRODUCT_USE_DYNAMIC_PARTITIONS := true

PRODUCT_CHARACTERISTICS := tablet
PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xhdpi

# Boot, mounts and init
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/fstab.spx:$(TARGET_COPY_OUT_RAMDISK)/fstab.spx \
    $(LOCAL_PATH)/rootdir/etc/fstab.spx:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.spx \
    $(LOCAL_PATH)/rootdir/etc/init.spx.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.spx.rc \
    $(LOCAL_PATH)/rootdir/etc/init.spx.debug.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.spx.debug.rc \
    $(LOCAL_PATH)/rootdir/etc/ueventd.spx.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \
    $(LOCAL_PATH)/rootdir/bin/spx-bootlog.sh:$(TARGET_COPY_OUT_VENDOR)/bin/spx-bootlog.sh \
    $(LOCAL_PATH)/rootdir/bin/spx-rmtfs-prepare.sh:$(TARGET_COPY_OUT_VENDOR)/bin/spx-rmtfs-prepare.sh

# Firmware (staged by firmware/build-firmware.sh)
SPX_FIRMWARE_DIR := $(LOCAL_PATH)/prebuilt/firmware
ifeq ($(wildcard $(SPX_FIRMWARE_DIR)/qcom),)
    $(warning Surface Pro X: no firmware in $(SPX_FIRMWARE_DIR). Wi-Fi, GPU and DSPs will not work. Run $(LOCAL_PATH)/build.sh firmware)
else
    PRODUCT_COPY_FILES += $(foreach f,$(shell cd $(SPX_FIRMWARE_DIR) && find . -type f ! -name README | sed 's|^\./||' | sort), \
        $(SPX_FIRMWARE_DIR)/$(f):$(TARGET_COPY_OUT_VENDOR)/firmware/$(f))
endif

# Hardware features
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/tablet_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/tablet_core_hardware.xml \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.touchscreen.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml

# Graphics (software rendering for now, see graphics.mk)
$(call inherit-product, $(LOCAL_PATH)/graphics.mk)

# Display density for the 13" 2880x1920 panel
PRODUCT_VENDOR_PROPERTIES += \
    ro.sf.lcd_density=280

# Overlays
PRODUCT_PACKAGES += \
    SpxFrameworksOverlay

# Software security HALs (no TEE on this port). Keys are NOT hardware-backed.
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service.nonsecure \
    android.hardware.gatekeeper-service.nonsecure

# Battery (Surface System Aggregator battery and charger via power_supply)
PRODUCT_PACKAGES += \
    android.hardware.health-service.example

# Power
PRODUCT_PACKAGES += \
    android.hardware.power-service.example

# Wi-Fi
PRODUCT_PACKAGES += \
    android.hardware.wifi-service \
    hostapd \
    libwpa_client \
    wificond \
    wpa_supplicant \
    wpa_supplicant.conf

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/wifi/wpa_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant_overlay.conf \
    $(LOCAL_PATH)/configs/wifi/p2p_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/p2p_supplicant_overlay.conf

PRODUCT_VENDOR_PROPERTIES += \
    wifi.interface=wlan0

# Bluetooth (HCI user channel on hci0; experimental)
PRODUCT_PACKAGES += \
    android.hardware.bluetooth-service.default

# Qualcomm remote processor services (linux-msm: qrtr, rmtfs, tqftpserv).
# The modem DSP runs the Wi-Fi firmware, so Wi-Fi needs these.
PRODUCT_PACKAGES += \
    libqrtr \
    qrtr-cfg \
    qrtr-lookup \
    rmtfs \
    tqftpserv

# Debugging during bring-up: adb over the network (USB-C Ethernet adapter or
# Wi-Fi), since USB device mode does not work on this tablet.
PRODUCT_SYSTEM_PROPERTIES += \
    service.adb.tcp.port=5555

# Your adb public key (build.sh adbkey copies it here), so adb works without
# confirming the connection on the screen.
ifneq ($(wildcard $(LOCAL_PATH)/prebuilt/adb_keys),)
    PRODUCT_ADB_KEYS := $(LOCAL_PATH)/prebuilt/adb_keys
endif
