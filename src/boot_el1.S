.section .text.boot_el1, "ax"
.global boot_el1
boot_el1:
    /* x0 is the Image entry; x1 is the DTB physical address. */
    msr daifset, #0xf              /* Mask Debug, SError, IRQ, and FIQ. */
    mov x9, x0
    mov x0, x1
    mov x1, xzr
    mov x2, xzr
    mov x3, xzr

    movz x10, #0x8000, lsl #16
    msr hcr_el2, x10               /* EL1 executes AArch64 without EL2 traps. */
    mrs x10, cnthctl_el2
    orr x10, x10, #3
    msr cnthctl_el2, x10           /* Allow EL1 physical and virtual timers. */
    msr cntvoff_el2, xzr
    msr cptr_el2, xzr
    msr mdcr_el2, xzr

    mrs x10, sctlr_el1
    mov x11, #0x1005
    bic x10, x10, x11
    msr sctlr_el1, x10            /* EL1 MMU and caches off at kernel entry. */
    ic iallu                       /* Discard stale instruction cache lines. */
    dsb sy
    isb

    msr elr_el2, x9               /* Return target is the Image's first byte. */
    mov x10, #0x3c5
    msr spsr_el2, x10             /* EL1h with all exception classes masked. */
    eret
