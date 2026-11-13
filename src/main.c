/* AArch64 EL2 code called by the minimal entry stub. */
#include <stdint.h>
#include "boot_image.h"
#include "console.h"
#include "emmc.h"
#include "fb.h"

static const char *cpu_name(uint64_t midr)
{
    if ((midr >> 24) == 0x41u) {
        switch ((midr >> 4) & 0xfffu) {
        case 0xd03u: return "CORTEX-A53";
        case 0xd07u: return "CORTEX-A57";
        }
    }
    return "UNKNOWN";
}

__attribute__((section(".text.main"), noinline, used))
int main(void)
{
    uint64_t midr, current_el;
    __asm__ volatile("mrs %0, midr_el1" : "=r"(midr));
    __asm__ volatile("mrs %0, CurrentEL" : "=r"(current_el));

    console_t console;
    console_init(&console);
    console_color(&console, fb_rgb(100, 255, 180));
    console_write(&console, "bnuuyloader\n");
    console_color(&console, fb_rgb(220, 240, 220));
    console_printf(&console, "CPU: %s (AARCH64 EL%u)\n",
                   cpu_name(midr), (unsigned)(current_el >> 2) & 3u);
    console_present();

    emmc_report_t emmc;
    emmc_probe(&emmc);
    if (emmc.kernel_type == KERNEL_ARM64) {
        boot_image_t image;
        if (boot_image_prepare(&emmc, &image) == BOOT_READY) {
            console_write(&console, "STARTING KERNEL (EL1)\n");
            console_present();
            boot_el1(image.kernel, image.dtb);
        }
    }
    console_color(&console, fb_rgb(255, 60, 60));
    console_write(&console, "Unsupported boot image.\n");
    console_present();
    return 0;
}
