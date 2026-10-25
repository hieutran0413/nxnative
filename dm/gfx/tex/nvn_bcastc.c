// See nvn_bcastc.h
#include "nvn_bcastc.h"
#include <string.h>

static void put(uint8_t *o, unsigned pos, unsigned n, unsigned v) { for (unsigned i = 0; i < n; i++) if ((v >> i) & 1) o[(pos + i) >> 3] |= (uint8_t)(1u << ((pos + i) & 7)); }

int nvn_bc1_astc_block(const uint8_t *b, uint8_t *o) {
    unsigned c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8); uint32_t ix = b[4] | (b[5] << 8) | (b[6] << 16) | ((uint32_t)b[7] << 24);
    int e0[3] = {(int)((((c0 >> 11) & 31) * 527 + 23) >> 6), (int)((((c0 >> 5) & 63) * 259 + 33) >> 6), (int)(((c0 & 31) * 527 + 23) >> 6)};   // the same expansion to 8 bits as bcdec
    int e1[3] = {(int)((((c1 >> 11) & 31) * 527 + 23) >> 6), (int)((((c1 >> 5) & 63) * 259 + 33) >> 6), (int)(((c1 & 31) * 527 + 23) >> 6)};
    int four = c0 > c1, sw = e1[0] + e1[1] + e1[2] < e0[0] + e0[1] + e0[2], lost = 0;   // ASTC's RGB-direct mode wants the endpoint with the larger sum second (else it swaps them and contracts blue), so the darker one goes first
    const int *lo = sw ? e1 : e0, *hi = sw ? e0 : e1;
    static const uint8_t m4[4] = {0, 3, 1, 2}, m3[4] = {0, 3, 1, 0};   // palette index → weight code 0..3 (0, 21, 43, 64); the 3-colour midpoint takes 21
    memset(o, 0, 16);
    put(o, 0, 11, 0x042);   // block mode: 4x4 grid, 2-bit weights, one plane. One partition (bits 11-12 = 0), colour endpoint mode 8 (RGB direct) in bits 13-16
    put(o, 13, 4, 8);
    for (int k = 0; k < 3; k++) { put(o, 17 + 16 * k, 8, (unsigned)lo[k]); put(o, 25 + 16 * k, 8, (unsigned)hi[k]); }
    for (int i = 0; i < 16; i++) {
        unsigned idx = (ix >> (2 * i)) & 3, code;
        if (!four && idx == 3) { code = 0; lost = 1; }   // the darker endpoint
        else { code = four ? m4[idx] : m3[idx]; if (sw) code = 3 - code; }
        put(o, 127 - 2 * i, 1, code & 1); put(o, 126 - 2 * i, 1, code >> 1);   // the weights are bit-reversed from the top of the block
    }
    return lost;
}

size_t nvn_bc1_astc(const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch) {
    size_t lost = 0;
    for (uint32_t by = 0; by * 4 < h; by++) for (uint32_t bx = 0; bx * 4 < w; bx++) lost += (size_t)nvn_bc1_astc_block(src + by * pitch + bx * 8, dst + by * dpitch + bx * 16);
    return lost;
}
