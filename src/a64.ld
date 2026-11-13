ENTRY(_start)
SECTIONS
{
    . = PAYLOAD_BASE_ADDRESS + A64_ENTRY_OFFSET;
    .entry : { KEEP(*(.text.entry)) }

    /* The ARM32 slot ends at this AArch64 C entry address. */
    . = PAYLOAD_BASE_ADDRESS + MAIN_ENTRY_OFFSET;
    .main : {
        KEEP(*(.text.main))
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
    }
    .bss (NOLOAD) : { *(.bss .bss.* COMMON) }
    ASSERT(SIZEOF(.bss) == 0, "main.c requires BSS initialization")

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
