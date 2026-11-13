#include <stdarg.h>
#include <stdint.h>

#include "console.h"
#include "fb.h"

#define CONSOLE_X 84u
#define CONSOLE_Y 1530u
#define CONSOLE_WIDTH 1272u
#define CONSOLE_HEIGHT 720u
#define SCALE 3u
#define ADVANCE_X (6u * SCALE)
#define ADVANCE_Y (9u * SCALE)
#define COLUMNS (CONSOLE_WIDTH / ADVANCE_X)
#define ROWS (CONSOLE_HEIGHT / ADVANCE_Y)

#define G(ch, a, b, c, d, e, f, g) [ch - 32] = {a, b, c, d, e, f, g}
static const uint8_t font[96][7] = {
    G('!', 4,4,4,4,4,0,4),
    G('(', 2,4,8,8,8,4,2),
    G(')', 8,4,2,2,2,4,8),
    G('-', 0,0,0,31,0,0,0),
    G('.', 0,0,0,0,0,0,4),
    G('/', 1,2,2,4,8,8,16),
    G(':', 0,4,4,0,4,4,0),
    G('?', 14,17,1,2,4,0,4),
    G('@', 14,17,23,21,23,16,14),
    G('0', 14,17,19,21,25,17,14),
    G('1', 4,12,4,4,4,4,14),
    G('2', 14,17,1,2,4,8,31),
    G('3', 30,1,1,14,1,1,30),
    G('4', 2,6,10,18,31,2,2),
    G('5', 31,16,30,1,1,17,14),
    G('6', 6,8,16,30,17,17,14),
    G('7', 31,1,2,4,8,8,8),
    G('8', 14,17,17,14,17,17,14),
    G('9', 14,17,17,15,1,2,12),
    G('A', 14,17,17,31,17,17,17),
    G('B', 30,17,17,30,17,17,30),
    G('C', 14,17,16,16,16,17,14),
    G('D', 30,17,17,17,17,17,30),
    G('E', 31,16,16,30,16,16,31),
    G('F', 31,16,16,30,16,16,16),
    G('G', 14,17,16,23,17,17,14),
    G('H', 17,17,17,31,17,17,17),
    G('I', 14,4,4,4,4,4,14),
    G('J', 7,2,2,2,18,18,12),
    G('K', 17,18,20,24,20,18,17),
    G('L', 16,16,16,16,16,16,31),
    G('M', 17,27,21,21,17,17,17),
    G('N', 17,25,21,19,17,17,17),
    G('O', 14,17,17,17,17,17,14),
    G('P', 30,17,17,30,16,16,16),
    G('Q', 14,17,17,17,21,18,13),
    G('R', 30,17,17,30,20,18,17),
    G('S', 15,16,16,14,1,1,30),
    G('T', 31,4,4,4,4,4,4),
    G('U', 17,17,17,17,17,17,14),
    G('V', 17,17,17,17,17,10,4),
    G('W', 17,17,17,21,21,21,10),
    G('X', 17,17,10,4,10,17,17),
    G('Y', 17,17,10,4,4,4,4),
    G('Z', 31,1,2,4,8,16,31),
    G('a', 0,0,14,1,15,17,15),
    G('b', 16,16,30,17,17,17,30),
    G('c', 0,0,14,17,16,17,14),
    G('d', 1,1,15,17,17,17,15),
    G('e', 0,0,14,17,31,16,14),
    G('f', 6,9,8,28,8,8,8),
    G('g', 0,0,15,17,15,1,14),
    G('h', 16,16,30,17,17,17,17),
    G('i', 4,0,12,4,4,4,14),
    G('j', 2,0,6,2,2,18,12),
    G('k', 16,16,18,20,24,20,18),
    G('l', 12,4,4,4,4,4,14),
    G('m', 0,0,26,21,21,21,21),
    G('n', 0,0,30,17,17,17,17),
    G('o', 0,0,14,17,17,17,14),
    G('p', 0,0,30,17,30,16,16),
    G('q', 0,0,15,17,15,1,1),
    G('r', 0,0,22,25,16,16,16),
    G('s', 0,0,15,16,14,1,30),
    G('t', 8,8,28,8,8,9,6),
    G('u', 0,0,17,17,17,19,13),
    G('v', 0,0,17,17,17,10,4),
    G('w', 0,0,17,17,21,21,10),
    G('x', 0,0,17,10,4,10,17),
    G('y', 0,0,17,17,15,1,14),
    G('z', 0,0,31,2,4,8,31),
};
#undef G

void console_init(console_t *console)
{
    console->column = 0;
    console->row = 0;
    console->color = fb_rgb(220, 240, 220);
    fb_fill_rect(CONSOLE_X, CONSOLE_Y, CONSOLE_WIDTH, CONSOLE_HEIGHT, 0);
}

void console_color(console_t *console, uint32_t color)
{
    console->color = color;
}

void console_putc(console_t *console, char character)
{
    if (character == '\n') {
        console->column = 0;
        if (console->row < ROWS)
            ++console->row;
        return;
    }
    if (character == '\r') {
        console->column = 0;
        return;
    }
    if (console->column == COLUMNS) {
        console->column = 0;
        ++console->row;
    }
    if (console->row >= ROWS)
        return;
    unsigned index = (unsigned char)character;
    if (index < 32 || index > 127)
        index = '?';
    const uint8_t *glyph = font[index - 32];
    unsigned left = CONSOLE_X + console->column * ADVANCE_X;
    unsigned top = CONSOLE_Y + console->row * ADVANCE_Y;
    for (unsigned y = 0; y < 7; ++y)
        for (unsigned x = 0; x < 5; ++x)
            if (glyph[y] & (1u << (4u - x)))
                fb_fill_rect(left + x * SCALE, top + y * SCALE,
                             SCALE, SCALE, console->color);
    ++console->column;
}

void console_write(console_t *console, const char *text)
{
    while (*text)
        console_putc(console, *text++);
}

static void print_unsigned(console_t *console, uint64_t value, unsigned base, unsigned min_digits)
{
    char digits[32];
    unsigned count = 0;
    do {
        unsigned digit = (unsigned)(value % base);
        digits[count++] = "0123456789ABCDEF"[digit];
        value /= base;
    } while (value);
    while (count < min_digits)
        digits[count++] = '0';
    while (count)
        console_putc(console, digits[--count]);
}

void console_printf(console_t *console, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    while (*format) {
        if (*format != '%') {
            console_putc(console, *format++);
            continue;
        }
        ++format;
        switch (*format++) {
        case 's': console_write(console, va_arg(args, const char *)); break;
        case 'u': print_unsigned(console, va_arg(args, unsigned), 10, 1); break;
        case 'x': print_unsigned(console, va_arg(args, unsigned), 16, 8); break;
        case 'p': print_unsigned(console, va_arg(args, uint64_t), 16, 16); break;
        case '%': console_putc(console, '%'); break;
        default: console_putc(console, '?'); break;
        }
    }
    va_end(args);
}

void console_present(void)
{
    fb_present_rect(CONSOLE_X, CONSOLE_Y, CONSOLE_WIDTH, CONSOLE_HEIGHT);
}
