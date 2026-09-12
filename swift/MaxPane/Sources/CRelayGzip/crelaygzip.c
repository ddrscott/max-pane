#include "include/crelaygzip.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

int crelay_gunzip(const uint8_t *in, size_t in_len, uint8_t **out, size_t *out_len) {
    z_stream s;
    memset(&s, 0, sizeof(s));
    // 16 + MAX_WBITS => gzip container only (NOT raw deflate, NOT zlib/RFC1950).
    int rc = inflateInit2(&s, 16 + MAX_WBITS);
    if (rc != Z_OK) return rc;

    size_t cap = in_len * 6 + 65536;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { inflateEnd(&s); return Z_MEM_ERROR; }

    s.next_in = (Bytef *)in;
    s.avail_in = (uInt)in_len;
    size_t produced = 0;

    for (;;) {
        if (produced == cap) {
            cap *= 2;
            uint8_t *nb = (uint8_t *)realloc(buf, cap);
            if (!nb) { free(buf); inflateEnd(&s); return Z_MEM_ERROR; }
            buf = nb;
        }
        s.next_out = buf + produced;
        s.avail_out = (uInt)(cap - produced);
        rc = inflate(&s, Z_NO_FLUSH);
        produced = cap - s.avail_out;
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) { free(buf); inflateEnd(&s); return rc; }
        if (s.avail_out != 0 && s.avail_in == 0) break; // ran out of input
    }
    inflateEnd(&s);
    *out = buf;
    *out_len = produced;
    return 0;
}

void crelay_free(uint8_t *p) { free(p); }
