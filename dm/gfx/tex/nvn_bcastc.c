// See nvn_bcastc.h
#include "nvn_bcastc.h"
#include "nvn_bcastc_lut.h"
#include <string.h>

static void put(uint8_t *o, unsigned pos, unsigned n, unsigned v) { for (unsigned i = 0; i < n; i++) if ((v >> i) & 1) o[(pos + i) >> 3] |= (uint8_t)(1u << ((pos + i) & 7)); }

const uint8_t *nvn_bc1_astc_quint_lut(size_t *size) {
    if (size) *size = sizeof nvn_bc1_astc_quint_lut_data;
    return nvn_bc1_astc_quint_lut_data;
}


int nvn_bc1_astc_safe(const uint8_t *src, size_t pitch, uint32_t w, uint32_t h) {
    uint32_t nbx = (w + 3) / 4, nby = (h + 3) / 4;
    for (uint32_t by = 0; by < nby; by++) for (uint32_t bx = 0; bx < nbx; bx++) {
        const uint8_t *b = src + (size_t)by * pitch + (size_t)bx * 8;
        unsigned c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8);
        if (c0 <= c1) {
            uint32_t ix = b[4] | (b[5] << 8) | (b[6] << 16) | ((uint32_t)b[7] << 24);
            for (unsigned i = 0; i < 16; i++) if (((ix >> (2 * i)) & 3u) == 3u) return 0;
        }
    }
    return 1;
}

int nvn_bc1_astc_block(const uint8_t *b, uint8_t *o) {
    unsigned c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8); uint32_t ix = b[4] | (b[5] << 8) | (b[6] << 16) | ((uint32_t)b[7] << 24);
    int e0[3] = {(int)((((c0 >> 11) & 31) * 527 + 23) >> 6), (int)((((c0 >> 5) & 63) * 259 + 33) >> 6), (int)(((c0 & 31) * 527 + 23) >> 6)};   // the same expansion to 8 bits as bcdec
    int e1[3] = {(int)((((c1 >> 11) & 31) * 527 + 23) >> 6), (int)((((c1 >> 5) & 63) * 259 + 33) >> 6), (int)(((c1 & 31) * 527 + 23) >> 6)};
    int four = c0 > c1, sw = e1[0] + e1[1] + e1[2] < e0[0] + e0[1] + e0[2], lost = 0;   // ASTC's RGB-direct mode wants the endpoint with the larger sum second (else it swaps them and contracts blue), so the darker one goes first
    const int *lo = sw ? e1 : e0, *hi = sw ? e0 : e1;
    static const uint8_t m4[4] = {0, 3, 1, 2}, m3[4] = {0, 4, 2, 0};   // palette index → weight code; five-level weights represent the 3-colour midpoint exactly
    memset(o, 0, 16);
    put(o, 0, 11, four ? 0x042 : 0x052);   // 4x4 grid, one plane, RGB direct; five-level weights for 3-colour blocks
    put(o, 13, 4, 8);
    for (int k = 0; k < 3; k++) { put(o, 17 + 16 * k, 8, (unsigned)lo[k]); put(o, 25 + 16 * k, 8, (unsigned)hi[k]); }
    unsigned weights[16];
    for (int i = 0; i < 16; i++) {
        unsigned idx = (ix >> (2 * i)) & 3, code;
        if (!four && idx == 3) { code = 0; lost = 1; }   // the darker endpoint
        else { code = four ? m4[idx] : m3[idx]; if (sw) code = (four ? 3 : 4) - code; }
        weights[i] = code;
        if (four) { put(o, 127 - 2 * i, 1, code & 1); put(o, 126 - 2 * i, 1, code >> 1); }   // 4-level weights are bit-reversed from the top of the block
    }
    if (!four) {
        const uint8_t *lut = nvn_bc1_astc_quint_lut(NULL);
        for (unsigned g = 0; g < 6; g++) {
            unsigned a = g * 3 < 16 ? weights[g * 3] : 0;
            unsigned b = g * 3 + 1 < 16 ? weights[g * 3 + 1] : 0;
            unsigned c = g * 3 + 2 < 16 ? weights[g * 3 + 2] : 0;
            uint8_t code = lut[a + 5 * b + 25 * c];
            for (unsigned bit = 0; bit < 7; bit++) put(o, 127 - 7 * g - bit, 1, (code >> bit) & 1);
        }
    }
    return lost;
}

size_t nvn_bc1_astc(const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch) {
    size_t lost = 0;
    for (uint32_t by = 0; by * 4 < h; by++) for (uint32_t bx = 0; bx * 4 < w; bx++) lost += (size_t)nvn_bc1_astc_block(src + by * pitch + bx * 8, dst + by * dpitch + bx * 16);
    return lost;
}
