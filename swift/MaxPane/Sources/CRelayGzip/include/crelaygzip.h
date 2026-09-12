#ifndef CRELAYGZIP_H
#define CRELAYGZIP_H
#include <stddef.h>
#include <stdint.h>

// Inflate a complete RFC1952 gzip member (what flate2's GzEncoder emits, which is
// what RelayTTY sends as BUFFER_REPLAY_GZ / 0x13).
// Returns 0 on success and sets *out (malloc'd, caller frees) and *out_len.
// Returns a negative zlib error code on failure.
int crelay_gunzip(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len);
void crelay_free(uint8_t *p);
#endif
