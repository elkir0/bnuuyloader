#include <stdint.h>
#include "boot_image.h"

#define KERNEL_LOAD ((uintptr_t)0x40080000u)
#define DTB_LOAD ((uintptr_t)0x60000000u)
#define KERNEL_MAX (32u * 1024u * 1024u)
#define IMAGE_MAX (64u * 1024u * 1024u)
#define DTB_MAX (1024u * 1024u)

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const uint8_t *p)
{
    return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}

static uint32_t be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
           (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

int boot_image_prepare(const emmc_report_t *report, boot_image_t *image)
{
    if (report->kernel_type != KERNEL_ARM64 || report->ramdisk_size ||
        report->kernel_size < 64u || report->kernel_size > KERNEL_MAX ||
        report->second_size < 40u || report->second_size > DTB_MAX)
        return BOOT_UNSUPPORTED;

    uint64_t page = report->page_size;
    if (page < 512u || page > 65536u || (page & (page - 1u)))
        return BOOT_UNSUPPORTED;
    uint64_t second_offset = page + ((report->kernel_size + page - 1u) & ~(page - 1u));
    if (second_offset + report->second_size > (uint64_t)report->boot_sectors * 512u ||
        second_offset > 0xffffffffu)
        return BOOT_UNSUPPORTED;

    int error = emmc_read_boot(report, (uint32_t)page, KERNEL_LOAD, 512u);
    if (error)
        return BOOT_READ_FAILED;
    const uint8_t *kernel = (const uint8_t *)KERNEL_LOAD;
    uint64_t image_size = le64(kernel + 16);
    if (le32(kernel + 0x38) != 0x644d5241u ||
        le64(kernel + 8) != 0x80000u ||
        (le64(kernel + 24) & 1u) ||
        (image_size && (image_size < report->kernel_size || image_size > IMAGE_MAX)))
        return BOOT_UNSUPPORTED;

    if (report->kernel_size > 512u &&
        emmc_read_boot(report, (uint32_t)page + 512u, KERNEL_LOAD + 512u,
                       report->kernel_size - 512u))
        return BOOT_READ_FAILED;
    if (emmc_read_boot(report, (uint32_t)second_offset, DTB_LOAD,
                       report->second_size))
        return BOOT_READ_FAILED;
    const uint8_t *dtb = (const uint8_t *)DTB_LOAD;
    uint32_t dtb_size = be32(dtb + 4);
    uint32_t structure = be32(dtb + 8);
    uint32_t strings = be32(dtb + 12);
    uint32_t reservations = be32(dtb + 16);
    uint32_t version = be32(dtb + 20);
    uint32_t strings_size = be32(dtb + 32);
    uint32_t structure_size = be32(dtb + 36);
    if (be32(dtb) != 0xd00dfeedu || dtb_size < 72u ||
        dtb_size > report->second_size || version < 17u ||
        reservations > dtb_size - 16u ||
        structure > dtb_size || structure_size > dtb_size - structure ||
        strings > dtb_size || strings_size > dtb_size - strings)
        return BOOT_UNSUPPORTED;

    image->kernel = KERNEL_LOAD;
    image->dtb = DTB_LOAD;
    return BOOT_READY;
}
