#include <stdint.h>
#include "fb.h"

// note 4 resolution
#define FB_WIDTH 1440u
#define FB_HEIGHT 2560u
#define FB_STRIDE (FB_WIDTH * 4u)
#define FB_BASE ((uintptr_t)0x67000000u)
#define DECON_UPDATE (*(volatile uint32_t *)(uintptr_t)0x13801410u)
#define DECON_TRIGGER (*(volatile uint32_t *)(uintptr_t)0x13802040u)

uint32_t fb_rgb(uint8_t red, uint8_t green, uint8_t blue)
{
    return ((uint32_t)red << 16) | ((uint32_t)green << 8) | blue;
}

void fb_put_pixel(unsigned x, unsigned y, uint32_t rgb)
{
    if (x >= FB_WIDTH || y >= FB_HEIGHT)
        return;
    *(volatile uint32_t *)(FB_BASE + (uintptr_t)y * FB_STRIDE + (uintptr_t)x * 4u) = rgb;
}

void fb_fill_rect(unsigned x, unsigned y, unsigned width, unsigned height, uint32_t rgb)
{
    if (x >= FB_WIDTH || y >= FB_HEIGHT || !width || !height)
        return;
    if (width > FB_WIDTH - x)
        width = FB_WIDTH - x;
    if (height > FB_HEIGHT - y)
        height = FB_HEIGHT - y;
    for (unsigned row = 0; row < height; ++row) {
        volatile uint32_t *pixel = (volatile uint32_t *)(FB_BASE + (uintptr_t)(y + row) * FB_STRIDE + (uintptr_t)x * 4u);
        for (unsigned col = 0; col < width; ++col)
            pixel[col] = rgb;
    }
}

void fb_draw_rect(unsigned x, unsigned y, unsigned width, unsigned height, uint32_t rgb)
{
    if (!width || !height)
        return;
    fb_fill_rect(x, y, width, 1, rgb);
    if (height > 1 && y < FB_HEIGHT && height - 1 < FB_HEIGHT - y)
        fb_fill_rect(x, y + height - 1, width, 1, rgb);
    fb_fill_rect(x, y, 1, height, rgb);
    if (width > 1 && x < FB_WIDTH && width - 1 < FB_WIDTH - x)
        fb_fill_rect(x + width - 1, y, 1, height, rgb);
}

void fb_clear(uint32_t rgb)
{
    fb_fill_rect(0, 0, FB_WIDTH, FB_HEIGHT, rgb);
}

void fb_present_rect(unsigned x, unsigned y, unsigned width, unsigned height)
{
    if (x >= FB_WIDTH || y >= FB_HEIGHT || !width || !height)
        return;
    if (width > FB_WIDTH - x)
        width = FB_WIDTH - x;
    if (height > FB_HEIGHT - y)
        height = FB_HEIGHT - y;
    for (unsigned row = 0; row < height; ++row) {
        uintptr_t start = FB_BASE + (uintptr_t)(y + row) * FB_STRIDE + (uintptr_t)x * 4u;
        uintptr_t end = start + (uintptr_t)width * 4u;
        for (uintptr_t line = start & ~(uintptr_t)63u; line < end; line += 64u)
            __asm__ volatile("dc cvac, %0" : : "r"(line) : "memory");
    }
    __asm__ volatile("dsb sy" : : : "memory");
    DECON_UPDATE |= 1u;
    __asm__ volatile("dsb sy" : : : "memory");
    DECON_TRIGGER = 0xe0000003u;
    __asm__ volatile("dsb sy\n\tisb" : : : "memory");
}

void fb_present(void)
{
    fb_present_rect(0, 0, FB_WIDTH, FB_HEIGHT);
}
