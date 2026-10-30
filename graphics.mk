#
# Copyright (C) 2026 surface-pro-x-lineage-os contributors
#
# SPDX-License-Identifier: Apache-2.0
#
# Graphics stack.
#
# Display output goes through the msm DRM/KMS driver (same as Fedora):
#   drm_hwcomposer (composer HAL)  +  minigbm built for msm (gralloc 4).
#
# Rendering, first version: software (SwiftShader Vulkan + ANGLE for GLES),
# the same "SwANGLE" setup Linaro boots new Snapdragon boards with. It is slow
# at 2880x1920 but needs nothing but the CPU, which makes it the safest way to
# reach the home screen.
#
# Next step: hardware rendering with Mesa (freedreno GL + turnip Vulkan) on
# the Adreno 680, which already works under Fedora. AOSP's external/mesa3d no
# longer builds freedreno, so Mesa will be built separately (NDK + meson) and
# added as prebuilts; see docs/design.md.
#

# Composer: drm_hwcomposer (AIDL HWC3)
PRODUCT_PACKAGES += \
    android.hardware.composer.hwc3-service.drm

# Gralloc: minigbm with its msm backend (allocates scanout buffers from the
# msm DRM driver, everything else from the dma-buf system heap).
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator@4.0-service.minigbm_msm \
    android.hardware.graphics.mapper@4.0-impl.minigbm_msm

# Rendering: ANGLE (GLES) on SwiftShader (Vulkan)
PRODUCT_PACKAGES += \
    libEGL_angle \
    libGLESv1_CM_angle \
    libGLESv2_angle \
    vulkan.pastel

PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true

PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=angle \
    ro.hardware.vulkan=pastel \
    ro.opengles.version=196609

# Skia on GL is the safer choice with a software Vulkan driver.
PRODUCT_VENDOR_PROPERTIES += \
    debug.hwui.renderer=skiagl \
    debug.renderengine.backend=skiaglthreaded

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.vulkan.level-0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.level.xml \
    frameworks/native/data/etc/android.hardware.vulkan.version-1_1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.version.xml \
    frameworks/native/data/etc/android.software.opengles.deqp.level-2021-03-01.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.opengles.deqp.level.xml
