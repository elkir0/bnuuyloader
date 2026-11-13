.syntax unified
.arm
.text
.global _start
_start:
    /* The decoder wrote the JPEG tail through the data cache. Clean every
       cache line containing the AArch64 entry, this stub, or C code/data. */
    movw r4, #CACHE_CLEAN_START_ADDRESS_LO
    movt r4, #CACHE_CLEAN_START_ADDRESS_HI
    movw r6, #CACHE_CLEAN_END_ADDRESS_LO
    movt r6, #CACHE_CLEAN_END_ADDRESS_HI
clean_tail:
    mcr p15, 0, r4, c7, c10, 1  /* DCCMVAC: clean line by address to PoC. */
    add r4, r4, #64
    cmp r4, r6
    blo clean_tail

    dsb sy                       /* Finish the data-cache clean before fetch. */
    mcr p15, 0, r0, c7, c5, 0  /* ICIALLU: invalidate I-cache; operand ignored. */
    dsb sy                       /* Finish invalidation before the mode switch. */
    isb                          /* Discard prefetched ARM32 instructions. */

    /* The observed monitor call enters the address in r1 as AArch64 EL2 code.
       r2=0x800 and r3=1 are the arguments used by the working handoff. */
    movw r0, #0x0400
    movt r0, #0x8200              /* Samsung monitor function 0x82000400. */
    movw r1, #A64_ENTRY_ADDRESS_LO
    movt r1, #A64_ENTRY_ADDRESS_HI
    mov r2, #0x800
    mov r3, #1
    smc #0                       /* Enter the monitor; expected not to return. */
halt:
    b halt                       /* A returned SMC cannot resume S-Boot safely. */
