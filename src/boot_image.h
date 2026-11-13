#ifndef BNUUY_BOOT_IMAGE_H
#define BNUUY_BOOT_IMAGE_H

#include <stdint.h>
#include "emmc.h"

enum {
    BOOT_READY = 0,
    BOOT_UNSUPPORTED = -1,
    BOOT_READ_FAILED = -2,
};

typedef struct {
    uintptr_t kernel;
    uintptr_t dtb;
} boot_image_t;

int boot_image_prepare(const emmc_report_t *report, boot_image_t *image);
__attribute__((noreturn)) void boot_el1(uintptr_t kernel, uintptr_t dtb);

#endif
