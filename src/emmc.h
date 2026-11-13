#ifndef BNUUY_EMMC_H
#define BNUUY_EMMC_H

#include <stdint.h>

enum {
    KERNEL_UNKNOWN,
    KERNEL_ARM32,
    KERNEL_ARM64,
};

typedef struct {
    unsigned stages;
    int read_error;
    uint32_t pit_entries;
    uint32_t boot_lba;
    uint32_t boot_sectors;
    uint32_t kernel_size;
    uint32_t kernel_addr;
    uint32_t ramdisk_size;
    uint32_t second_size;
    uint32_t page_size;
    unsigned kernel_type;
    uint32_t verid;
    uint32_t ctrl;
    uint32_t status;
    uint32_t raw_interrupts;
    uint32_t idmac_interrupts;
} emmc_report_t;

void emmc_probe(emmc_report_t *report);
int emmc_read_boot(const emmc_report_t *report, uint32_t byte_offset,
                   uintptr_t destination, uint32_t length);

#endif
