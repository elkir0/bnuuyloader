#include <stdint.h>
#include "emmc.h"

#define MMC ((uintptr_t)0x15540000u)
#define DESC ((uintptr_t)0x241c0000u)
#define DATA ((uintptr_t)0x241c1000u)
#define PIT ((uintptr_t)0x241c2000u)

static volatile uint32_t *reg(unsigned offset)
{
    return (volatile uint32_t *)(MMC + offset);
}

static void clean(uintptr_t address, unsigned length)
{
    for (uintptr_t p = address & ~(uintptr_t)63u; p < address + length; p += 64u)
        __asm__ volatile("dc cvac, %0" : : "r"(p) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
}

static void invalidate(uintptr_t address, unsigned length)
{
    for (uintptr_t p = address & ~(uintptr_t)63u; p < address + length; p += 64u)
        __asm__ volatile("dc ivac, %0" : : "r"(p) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
}

static int read_sector(uint32_t lba, uintptr_t destination)
{
    volatile uint32_t *desc = (volatile uint32_t *)DESC;
    /* S-Boot uses the controller's 64-bit, eight-word IDMAC descriptor. */
    desc[0] = 0x80000004u | 3u; /* OWN, last, first. */
    desc[1] = 0;
    desc[2] = 512;
    desc[3] = 0;
    desc[4] = (uint32_t)destination;
    desc[5] = 0;
    desc[6] = 0;
    desc[7] = 0;
    for (unsigned i = 0; i < 128; ++i)
        ((volatile uint32_t *)destination)[i] = 0;
    clean(DESC, 32);
    clean(destination, 512);

    *reg(0x44) = 0xffffffffu; /* Clear prior raw interrupts. */
    /* Exynos5433 uses 64-bit IDMAC registers: 0x8c is DBADDRU, not IDSTS. */
    *reg(0x8c) = 0;
    *reg(0x90) = 0xffffffffu; /* Clear IDMAC interrupts. */
    *reg(0x1c) = 512;
    *reg(0x20) = 512;
    *reg(0x88) = (uint32_t)DESC;
    *reg(0x80) |= 0x80u; /* IDMAC enabled; leave the bus and clock setup intact. */
    *reg(0x00) |= (1u << 25) | (1u << 5);
    *reg(0x28) = lba; /* S-Boot selects high-capacity, block-addressed eMMC. */
    __asm__ volatile("dsb sy" : : : "memory");
    *reg(0x2c) = 0x80002351u; /* CMD17, data, R1 response, wait for prior data. */

    for (unsigned timeout = 2000000u; timeout; --timeout) {
        uint32_t status = *reg(0x44);
        if (status & 0xbfc2u)
            return -1;
        if ((status & 0xcu) == 0xcu) {
            invalidate(destination, 512);
            return 0;
        }
    }
    return -2;
}

static uint32_t u32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* Bit 0: PIT read, bit 1: BOOT entry found, bit 2: Android header read,
   bit 3: first kernel sector read. */
void emmc_probe(emmc_report_t *report)
{
    uint8_t *pit = (uint8_t *)PIT;
    report->stages = 0;
    report->read_error = 0;
    report->pit_entries = 0;
    report->boot_lba = 0;
    report->boot_sectors = 0;
    report->kernel_size = 0;
    report->kernel_addr = 0;
    report->ramdisk_size = 0;
    report->second_size = 0;
    report->page_size = 0;
    report->kernel_type = KERNEL_UNKNOWN;
    report->verid = *reg(0x6c);
    report->ctrl = *reg(0x00);
    report->status = *reg(0x48);
    report->raw_interrupts = 0;
    report->idmac_interrupts = 0;
    for (unsigned sector = 0; sector < 7; ++sector) {
        int error = read_sector(34u + sector, PIT + sector * 512u);
        if (error) {
            report->read_error = error;
            goto done;
        }
    }
    report->stages |= 1u;
    if (u32(pit) != 0x12349876u)
        goto done;
    unsigned count = u32(pit + 4);
    if (!count || count > 26u || 28u + count * 132u > 7u * 512u)
        goto done;
    report->pit_entries = count;
    for (unsigned i = 0; i < count; ++i) {
        const uint8_t *entry = pit + 28u + i * 132u;
        if (entry[36] == 'B' && entry[37] == 'O' && entry[38] == 'O' &&
            entry[39] == 'T' && entry[40] == 0) {
            report->stages |= 2u;
            report->boot_lba = u32(entry + 20);
            report->boot_sectors = u32(entry + 24);
            int error = read_sector(report->boot_lba, DATA);
            if (error) {
                report->read_error = error;
                goto done;
            }
            const uint8_t *header = (const uint8_t *)DATA;
            if (header[0] == 'A' && header[1] == 'N' && header[2] == 'D' &&
                header[3] == 'R' && header[4] == 'O' && header[5] == 'I' &&
                header[6] == 'D' && header[7] == '!')
                report->stages |= 4u;
            if (report->stages & 4u) {
                report->kernel_size = u32(header + 8);
                report->kernel_addr = u32(header + 12);
                report->ramdisk_size = u32(header + 16);
                report->second_size = u32(header + 24);
                report->page_size = u32(header + 36);
                uint32_t page = report->page_size;
                if (page >= 512u && page <= 65536u && !(page & (page - 1u)) &&
                    report->kernel_size >= 64u && page / 512u < report->boot_sectors) {
                    error = read_sector(report->boot_lba + page / 512u, DATA);
                    if (error) {
                        report->read_error = error;
                        goto done;
                    }
                    report->stages |= 8u;
                    const uint8_t *kernel = (const uint8_t *)DATA;
                    if (u32(kernel + 0x24) == 0x016f2818u)
                        report->kernel_type = KERNEL_ARM32;
                    else if (u32(kernel + 0x38) == 0x644d5241u)
                        report->kernel_type = KERNEL_ARM64;
                }
            }
            goto done;
        }
    }
done:
    report->status = *reg(0x48);
    report->raw_interrupts = *reg(0x44);
    report->idmac_interrupts = *reg(0x90);
}

int emmc_read_boot(const emmc_report_t *report, uint32_t byte_offset,
                   uintptr_t destination, uint32_t length)
{
    if (!(report->stages & 4u) || (byte_offset & 511u) ||
        (destination & 511u) || !length)
        return -3;
    uint64_t first = byte_offset / 512u;
    uint64_t count = ((uint64_t)length + 511u) / 512u;
    if (first + count > report->boot_sectors ||
        (uint64_t)report->boot_lba + first + count > 0x100000000ull)
        return -3;
    for (uint64_t i = 0; i < count; ++i) {
        int error = read_sector(report->boot_lba + (uint32_t)(first + i),
                                destination + (uintptr_t)i * 512u);
        if (error)
            return error;
    }
    return 0;
}
