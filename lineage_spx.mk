#
# Copyright (C) 2026 surface-pro-x-lineage-os contributors
#
# SPDX-License-Identifier: Apache-2.0
#

# 64-bit only: smaller and faster to build. Switch to core_64_bit.mk (and add
# TARGET_2ND_ARCH in BoardConfig.mk) if 32-bit apps are needed.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# Device
$(call inherit-product, device/microsoft/spx/device.mk)

# LineageOS (Wi-Fi only tablet; the LTE modem is not supported yet)
$(call inherit-product, vendor/lineage/config/common_full_tablet_wifionly.mk)

PRODUCT_NAME := lineage_spx
PRODUCT_DEVICE := spx
PRODUCT_BRAND := Microsoft
PRODUCT_MODEL := Surface Pro X
PRODUCT_MANUFACTURER := Microsoft

# Boot animation size (the panel is 2880x1920, landscape)
TARGET_SCREEN_WIDTH := 2880
TARGET_SCREEN_HEIGHT := 1920
