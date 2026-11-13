#ifndef BNUUY_CONSOLE_H
#define BNUUY_CONSOLE_H

#include <stdint.h>

typedef struct {
    unsigned column;
    unsigned row;
    uint32_t color;
} console_t;

void console_init(console_t *console);
void console_color(console_t *console, uint32_t color);
void console_putc(console_t *console, char character);
void console_write(console_t *console, const char *text);
void console_printf(console_t *console, const char *format, ...);
void console_present(void);

#endif
