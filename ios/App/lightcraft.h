// LightCraft's engine and camera link (Rust, apps/lightcraft-ios-core): strings returned are the
// caller's, freed with lc_free.
#ifndef LIGHTCRAFT_H
#define LIGHTCRAFT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

void lc_free(char *s);

void *lc_open(const char *dir, int32_t nice, bool previews);
void lc_close(void *h);
char *lc_execute(void *h, const char *command, const char *params);
char *lc_render(void *h, uint64_t photo, uint32_t w, uint32_t hh, bool draft, uint8_t *buf, size_t cap);
char *lc_render_before(void *h, uint64_t photo, uint32_t w, uint32_t hh, uint8_t *buf, size_t cap);
char *lc_thumb(void *h, uint64_t photo, uint32_t edge, uint8_t *buf, size_t cap);
char *lc_render_uncropped(void *h, uint64_t photo, uint32_t w, uint32_t hh, bool draft, uint8_t *buf, size_t cap);
char *lc_render_variant(void *h, uint64_t photo, const char *preset, int32_t amount, uint32_t edge, uint8_t *buf, size_t cap);
char *lc_export_jpeg(void *h, uint64_t photo, const char *path, int32_t quality, uint32_t long_edge);
char *lc_export(void *h, uint64_t photo, const char *path, const char *params);

void *lc_tether_start(const char *config);
char *lc_tether_poll(void *t);
void lc_tether_set_raw(void *t, bool raw);
void lc_tether_stop(void *t);

#endif
