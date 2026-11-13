#ifndef BNUUY_FB_H
#define BNUUY_FB_H

#include <stdint.h>

uint32_t fb_rgb(uint8_t red, uint8_t green, uint8_t blue);
void fb_put_pixel(unsigned x, unsigned y, uint32_t rgb);
void fb_fill_rect(unsigned x, unsigned y, unsigned width, unsigned height, uint32_t rgb);
void fb_draw_rect(unsigned x, unsigned y, unsigned width, unsigned height, uint32_t rgb);
void fb_clear(uint32_t rgb);
void fb_present_rect(unsigned x, unsigned y, unsigned width, unsigned height);
void fb_present(void);

#endif
