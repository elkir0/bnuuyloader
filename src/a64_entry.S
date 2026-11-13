.section .text.entry, "ax"
.global _start
_start:
    /* The monitor branches here without a C runtime or initialized stack. */
    movz x9, #A64_STACK_ADDRESS_LO
    movk x9, #A64_STACK_ADDRESS_HI, lsl #16
    mov sp, x9                    /* Set the stack before any C call. */
    bl main                       /* Jump to our C code. */
halt:
    b halt                        /* Keep the screen visible if main returns. */
