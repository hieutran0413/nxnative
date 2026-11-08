// CPU BC1 / BC3 -> ASTC 4x4 transcoder; matches nvn_bcastc_msl.h byte-for-byte.
#include "nvn_bcastc.h"
#include "nvn_bcastc_lut.h"
#include <string.h>

enum { ASTC_4x4_sRGB = 186, ASTC_4x4_LDR = 204 };

int nvn_bc_astc_pf(uint32_t f, int allow_bc3, uint32_t *pf) {
    switch (f) {
    case 0x41: case 0x42: *pf = ASTC_4x4_LDR; return 1;
    case 0x45: case 0x46: *pf = ASTC_4x4_sRGB; return 1;
    case 0x44: if (!allow_bc3) return 0; *pf = ASTC_4x4_LDR; return 1;
    case 0x48: if (!allow_bc3) return 0; *pf = ASTC_4x4_sRGB; return 1;
    default: return 0;
    }
}

static inline uint32_t rbit32(uint32_t x) {
    x = ((x & 0x55555555u) << 1) | ((x >> 1) & 0x55555555u);
    x = ((x & 0x33333333u) << 2) | ((x >> 2) & 0x33333333u);
    x = ((x & 0x0f0f0f0fu) << 4) | ((x >> 4) & 0x0f0f0f0fu);
    return __builtin_bswap32(x);
}

static inline uint64_t rbit64(uint64_t x) {
    return ((uint64_t)rbit32((uint32_t)x) << 32) | rbit32((uint32_t)(x >> 32));
}

static inline void rgb565_u8(uint32_t c, uint32_t *r, uint32_t *g, uint32_t *b) {
    uint32_t r5 = (c >> 11) & 31u, g6 = (c >> 5) & 63u, b5 = c & 31u;
    *r = (r5 << 3) | (r5 >> 2);
    *g = (g6 << 2) | (g6 >> 4);
    *b = (b5 << 3) | (b5 >> 2);
}

static inline void store_astc(uint8_t astc[16], uint64_t lo, uint64_t hi) {
    memcpy(astc, &lo, 8);
    memcpy(astc + 8, &hi, 8);
}

// Single-plane 4x4 LDR RGB Direct (mode 0x042, CEM = 8, 8-bit endpoints, 4-level 2-bit weights, A = 255).
static inline void emit_rgb_4lvl(uint32_t r0, uint32_t g0, uint32_t b0, uint32_t r1, uint32_t g1, uint32_t b1, uint32_t w32, uint8_t astc[16]) {
    if (r0 + g0 + b0 > r1 + g1 + b1) {
        uint32_t t;
        t = r0; r0 = r1; r1 = t;
        t = g0; g0 = g1; g1 = t;
        t = b0; b0 = b1; b1 = t;
        w32 ^= 0xffffffffu;
    }
    uint64_t lo = 0x042ull | (8ull << 13)
                | ((uint64_t)r0 << 17) | ((uint64_t)r1 << 25)
                | ((uint64_t)g0 << 33) | ((uint64_t)g1 << 41)
                | ((uint64_t)b0 << 49) | ((uint64_t)b1 << 57);
    uint64_t hi = ((uint64_t)rbit32(w32) << 32) | (b1 >> 7);
    store_astc(astc, lo, hi);
}

// Single-plane 4x4 LDR RGB Direct with 5-level quint weights (mode 0x052, CEM = 8, 8-bit endpoints, weights in {0, 2, 4}).
static inline void emit_rgb_5lvl(uint32_t r0, uint32_t g0, uint32_t b0, uint32_t r1, uint32_t g1, uint32_t b1, const uint8_t q[16], uint8_t astc[16]) {
    uint8_t qq[16];
    int flip = (r0 + g0 + b0 > r1 + g1 + b1);
    if (flip) {
        uint32_t t;
        t = r0; r0 = r1; r1 = t;
        t = g0; g0 = g1; g1 = t;
        t = b0; b0 = b1; b1 = t;
    }
    for (int i = 0; i < 16; i++) qq[i] = flip ? (uint8_t)(4u - q[i]) : q[i];
    uint64_t wb = (uint64_t)k_astc_quint[qq[0] + 5u * qq[1] + 25u * qq[2]]
                | ((uint64_t)k_astc_quint[qq[3] + 5u * qq[4] + 25u * qq[5]] << 7)
                | ((uint64_t)k_astc_quint[qq[6] + 5u * qq[7] + 25u * qq[8]] << 14)
                | ((uint64_t)k_astc_quint[qq[9] + 5u * qq[10] + 25u * qq[11]] << 21)
                | ((uint64_t)k_astc_quint[qq[12] + 5u * qq[13] + 25u * qq[14]] << 28)
                | ((uint64_t)(k_astc_quint[qq[15]] & 7u) << 35);
    uint64_t lo = 0x052ull | (8ull << 13)
                | ((uint64_t)r0 << 17) | ((uint64_t)r1 << 25)
                | ((uint64_t)g0 << 33) | ((uint64_t)g1 << 41)
                | ((uint64_t)b0 << 49) | ((uint64_t)b1 << 57);
    uint64_t hi = (rbit64(wb) & ~0x3ffffffull) | (b1 >> 7);
    store_astc(astc, lo, hi);
}

// Pack 8 Range-13 (0..47) endpoint codes into 45 ISE bits (Khronos ASTC Spec C.2.12).
static inline uint64_t pack_ise_8x48(const uint8_t q[8]) {
    uint32_t T0 = k_astc_trit[(q[0] >> 4) + 3u * (q[1] >> 4) + 9u * (q[2] >> 4) + 27u * (q[3] >> 4) + 81u * (q[4] >> 4)];
    uint32_t T1 = k_astc_trit[(q[5] >> 4) + 3u * (q[6] >> 4) + 9u * (q[7] >> 4)];
    uint64_t b0 = (uint64_t)(q[0] & 15u)
                | ((uint64_t)(T0 & 3u) << 4)
                | ((uint64_t)(q[1] & 15u) << 6)
                | ((uint64_t)((T0 >> 2) & 3u) << 10)
                | ((uint64_t)(q[2] & 15u) << 12)
                | ((uint64_t)((T0 >> 4) & 1u) << 16)
                | ((uint64_t)(q[3] & 15u) << 17)
                | ((uint64_t)((T0 >> 5) & 3u) << 21)
                | ((uint64_t)(q[4] & 15u) << 23)
                | ((uint64_t)((T0 >> 7) & 1u) << 27);
    uint64_t b1 = (uint64_t)(q[5] & 15u)
                | ((uint64_t)(T1 & 3u) << 4)
                | ((uint64_t)(q[6] & 15u) << 6)
                | ((uint64_t)((T1 >> 2) & 3u) << 10)
                | ((uint64_t)(q[7] & 15u) << 12)
                | ((uint64_t)((T1 >> 4) & 1u) << 16);
    return b0 | (b1 << 28);
}

// Dual-plane 4x4 LDR RGBA Direct (mode 0x442, D = 1, CEM = 12, CCS = 3 -> Plane 1 = RGB, Plane 2 = Alpha).
// Enforces unquantized s0 <= s1 so CEM = 12 never triggers blue contraction.
static inline void emit_rgba_dual(uint32_t r0, uint32_t g0, uint32_t b0, uint32_t r1, uint32_t g1, uint32_t b1,
                                  uint32_t a0, uint32_t a1, uint32_t w_rgb32, uint32_t w_a32, uint8_t astc[16]) {
    uint8_t qe[8] = {
        k_astc_q48[r0], k_astc_q48[r1],
        k_astc_q48[g0], k_astc_q48[g1],
        k_astc_q48[b0], k_astc_q48[b1],
        k_astc_q48[a0], k_astc_q48[a1],
    };
    uint32_t s0 = (uint32_t)k_astc_unq48[qe[0]] + k_astc_unq48[qe[2]] + k_astc_unq48[qe[4]];
    uint32_t s1 = (uint32_t)k_astc_unq48[qe[1]] + k_astc_unq48[qe[3]] + k_astc_unq48[qe[5]];
    if (s0 > s1) {
        uint8_t t;
        t = qe[0]; qe[0] = qe[1]; qe[1] = t;
        t = qe[2]; qe[2] = qe[3]; qe[3] = t;
        t = qe[4]; qe[4] = qe[5]; qe[5] = t;
        w_rgb32 ^= 0xffffffffu;
    }
    uint64_t w64 = 0;
    for (int i = 0; i < 16; i++) {
        uint64_t wr = (w_rgb32 >> (2 * i)) & 3u;
        uint64_t wa = (w_a32 >> (2 * i)) & 3u;
        w64 |= (wr << (4 * i)) | (wa << (4 * i + 2));
    }
    uint64_t lo = 0x442ull | (12ull << 13) | (pack_ise_8x48(qe) << 17) | (3ull << 62);
    uint64_t hi = rbit64(w64);
    store_astc(astc, lo, hi);
}

static inline uint32_t best_w4_rgb(int pr, int pg, int pb, int r0, int g0, int b0, int r1, int g1, int b1) {
    static const int kw[4] = {0, 21, 43, 64};
    uint32_t best = 0, best_e = 0xffffffffu;
    for (uint32_t w = 0; w < 4; w++) {
        int rr = ((64 - kw[w]) * r0 + kw[w] * r1 + 32) >> 6;
        int gg = ((64 - kw[w]) * g0 + kw[w] * g1 + 32) >> 6;
        int bb = ((64 - kw[w]) * b0 + kw[w] * b1 + 32) >> 6;
        int dr = pr - rr, dg = pg - gg, db = pb - bb;
        uint32_t e = (uint32_t)(dr * dr + dg * dg + db * db);
        if (e < best_e) { best_e = e; best = w; }
    }
    return best;
}

void nvn_bc1_astc_block(const uint8_t bc[8], int has_alpha, uint8_t astc[16]) {
    uint32_t c0 = (uint32_t)bc[0] | ((uint32_t)bc[1] << 8);
    uint32_t c1 = (uint32_t)bc[2] | ((uint32_t)bc[3] << 8);
    uint32_t ix = (uint32_t)bc[4] | ((uint32_t)bc[5] << 8) | ((uint32_t)bc[6] << 16) | ((uint32_t)bc[7] << 24);
    uint32_t r0, g0, b0, r1, g1, b1;
    rgb565_u8(c0, &r0, &g0, &b0);
    rgb565_u8(c1, &r1, &g1, &b1);

    if (c0 > c1) {
        // 4-color BC1: selectors 0,1,2,3 -> weights 0, 3, 1, 2 (0, 1, 1/3, 2/3).
        uint32_t w = 0;
        for (int i = 0; i < 16; i++) {
            uint32_t s = (ix >> (2 * i)) & 3u;
            uint32_t m = s == 0 ? 0u : s == 1 ? 3u : s == 2 ? 1u : 2u;
            w |= m << (2 * i);
        }
        emit_rgb_4lvl(r0, g0, b0, r1, g1, b1, w, astc);
        return;
    }

    // 3-color BC1 (c0 <= c1): check whether selector 3 appears in the block.
    uint32_t s3_mask = (ix & (ix >> 1)) & 0x55555555u;
    if (!s3_mask) {
        // No selector 3: selectors 0,1,2 -> 5-level quint weights 0, 4, 2 (exact 0, 1, 1/2).
        uint8_t q[16];
        for (int i = 0; i < 16; i++) {
            uint32_t s = (ix >> (2 * i)) & 3u;
            q[i] = s == 0 ? 0 : s == 1 ? 4 : 2;
        }
        emit_rgb_5lvl(r0, g0, b0, r1, g1, b1, q, astc);
        return;
    }

    if (has_alpha) {
        // RGBA_DXT1 punch-through: selector 3 is transparent (0,0,0,0), selectors 0..2 have A = 255.
        if (ix == 0xffffffffu) { memcpy(astc, k_astc_void_black, 16); return; }
        // If one endpoint is already black, (0, max_c) puts black at w_rgb = 0 too.
        uint32_t er0 = r0, eg0 = g0, eb0 = b0, er1 = r1, eg1 = g1, eb1 = b1;
        int dark0 = (r0 + g0 + b0 <= r1 + g1 + b1);
        uint32_t w_rgb = 0, w_a = 0;
        for (int i = 0; i < 16; i++) {
            uint32_t s = (ix >> (2 * i)) & 3u;
            if (s == 3u) {
                uint32_t wr = dark0 ? 0u : 3u;
                w_rgb |= wr << (2 * i);
                // w_a stays 0 -> exact A = 0
            } else {
                uint32_t wr = s == 0 ? 0u : s == 1 ? 3u : (dark0 ? 2u : 1u);
                w_rgb |= wr << (2 * i);
                w_a |= 3u << (2 * i);   // exact A = 255
            }
        }
        emit_rgba_dual(er0, eg0, eb0, er1, eg1, eb1, 0, 255, w_rgb, w_a, astc);
        return;
    }

    // RGB_DXT1 opaque 3-color with selector 3 = opaque black (0, 0, 0, 255).
    // Fast exact path when c0 == 0: colors are (0,0,0), c1, c1/2 -> exact 5-level quint!
    if (c0 == 0) {
        uint8_t q[16];
        for (int i = 0; i < 16; i++) {
            uint32_t s = (ix >> (2 * i)) & 3u;
            q[i] = (s == 0 || s == 3) ? 0 : s == 1 ? 4 : 2;
        }
        emit_rgb_5lvl(0, 0, 0, r1, g1, b1, q, astc);
        return;
    }
    // General case: evaluate candidate lines (0 -> c0), (0 -> c1), (0 -> mid), and (c0 -> c1), pick minimum SSE.
    int pr[4] = {(int)r0, (int)r1, (int)((r0 + r1) >> 1), 0};
    int pg[4] = {(int)g0, (int)g1, (int)((g0 + g1) >> 1), 0};
    int pb[4] = {(int)b0, (int)b1, (int)((b0 + b1) >> 1), 0};
    int cand[4][6] = {
        {0, 0, 0, (int)r1, (int)g1, (int)b1},
        {0, 0, 0, (int)r0, (int)g0, (int)b0},
        {0, 0, 0, pr[2], pg[2], pb[2]},
        {(int)r0, (int)g0, (int)b0, (int)r1, (int)g1, (int)b1},
    };
    static const int kw[4] = {0, 21, 43, 64};
    uint32_t best_c = 0, best_w = 0, best_err = 0xffffffffu;
    for (uint32_t c = 0; c < 4; c++) {
        uint32_t cw = 0, cerr = 0;
        for (int i = 0; i < 16; i++) {
            uint32_t s = (ix >> (2 * i)) & 3u;
            uint32_t w = best_w4_rgb(pr[s], pg[s], pb[s], cand[c][0], cand[c][1], cand[c][2], cand[c][3], cand[c][4], cand[c][5]);
            int rr = ((64 - kw[w]) * cand[c][0] + kw[w] * cand[c][3] + 32) >> 6;
            int gg = ((64 - kw[w]) * cand[c][1] + kw[w] * cand[c][4] + 32) >> 6;
            int bb = ((64 - kw[w]) * cand[c][2] + kw[w] * cand[c][5] + 32) >> 6;
            int dr = pr[s] - rr, dg = pg[s] - gg, db = pb[s] - bb;
            cerr += (uint32_t)(dr * dr + dg * dg + db * db);
            cw |= w << (2 * i);
        }
        if (cerr < best_err) { best_err = cerr; best_c = c; best_w = cw; }
    }
    emit_rgb_4lvl((uint32_t)cand[best_c][0], (uint32_t)cand[best_c][1], (uint32_t)cand[best_c][2],
                  (uint32_t)cand[best_c][3], (uint32_t)cand[best_c][4], (uint32_t)cand[best_c][5], best_w, astc);
}

void nvn_bc3_astc_block(const uint8_t bc[16], uint8_t astc[16]) {
    uint32_t a0 = bc[0], a1 = bc[1];
    uint64_t aix = 0;
    for (int i = 0; i < 6; i++) aix |= (uint64_t)bc[2 + i] << (8 * i);

    uint32_t pal[8];
    pal[0] = a0; pal[1] = a1;
    if (a0 > a1) {
        pal[2] = (6u * a0 + 1u * a1) / 7u;
        pal[3] = (5u * a0 + 2u * a1) / 7u;
        pal[4] = (4u * a0 + 3u * a1) / 7u;
        pal[5] = (3u * a0 + 4u * a1) / 7u;
        pal[6] = (2u * a0 + 5u * a1) / 7u;
        pal[7] = (1u * a0 + 6u * a1) / 7u;
    } else {
        pal[2] = (4u * a0 + 1u * a1) / 5u;
        pal[3] = (3u * a0 + 2u * a1) / 5u;
        pal[4] = (2u * a0 + 3u * a1) / 5u;
        pal[5] = (1u * a0 + 4u * a1) / 5u;
        pal[6] = 0u;
        pal[7] = 255u;
    }

    uint32_t alpha[16], amin = 255u, amax = 0u;
    for (int i = 0; i < 16; i++) {
        uint32_t a = pal[(aix >> (3 * i)) & 7u];
        alpha[i] = a;
        if (a < amin) amin = a;
        if (a > amax) amax = a;
    }

    uint32_t c0 = (uint32_t)bc[8] | ((uint32_t)bc[9] << 8);
    uint32_t c1 = (uint32_t)bc[10] | ((uint32_t)bc[11] << 8);
    uint32_t cix = (uint32_t)bc[12] | ((uint32_t)bc[13] << 8) | ((uint32_t)bc[14] << 16) | ((uint32_t)bc[15] << 24);
    if (amax == 0u && c0 == 0u && c1 == 0u) {
        memcpy(astc, k_astc_void_black, 16);
        return;
    }

    uint32_t r0, g0, b0, r1, g1, b1;
    rgb565_u8(c0, &r0, &g0, &b0);
    rgb565_u8(c1, &r1, &g1, &b1);

    // BC3 color block ALWAYS uses 4-color interpolation regardless of c0 vs c1.
    uint32_t w_rgb = 0;
    for (int i = 0; i < 16; i++) {
        uint32_t s = (cix >> (2 * i)) & 3u;
        uint32_t m = s == 0 ? 0u : s == 1 ? 3u : s == 2 ? 1u : 2u;
        w_rgb |= m << (2 * i);
    }

    // Constant opaque alpha = 255: use single-plane CEM = 8 (full 8-bit RGB endpoint precision).
    if (amin == 255u) {
        emit_rgb_4lvl(r0, g0, b0, r1, g1, b1, w_rgb, astc);
        return;
    }

    // Dual-plane CEM = 12 (Plane 1 = RGB, Plane 2 = Alpha over [amin, amax]).
    uint32_t ua0 = k_astc_unq48[k_astc_q48[amin]];
    uint32_t ua1 = k_astc_unq48[k_astc_q48[amax]];
    uint32_t w_a = 0;
    if (ua1 > ua0) {
        static const uint32_t kw[4] = {0, 21, 43, 64};
        for (int i = 0; i < 16; i++) {
            uint32_t target = alpha[i], bw = 0, be = 0xffffffffu;
            for (uint32_t w = 0; w < 4; w++) {
                uint32_t av = ((64u - kw[w]) * ua0 + kw[w] * ua1 + 32u) >> 6;
                uint32_t e = target > av ? target - av : av - target;
                if (e < be) { be = e; bw = w; }
            }
            w_a |= bw << (2 * i);
        }
    }
    emit_rgba_dual(r0, g0, b0, r1, g1, b1, amin, amax, w_rgb, w_a, astc);
}

int nvn_bc_astc_encode(uint32_t f, const uint8_t *src, size_t spitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch) {
    uint32_t pf;
    if (!nvn_bc_astc_pf(f, 1, &pf)) return -1;
    uint32_t bx_n = (w + 3u) / 4u, by_n = (h + 3u) / 4u;
    int is_bc3 = (f == 0x44 || f == 0x48);
    int has_alpha = (f == 0x42 || f == 0x46);
    size_t sb = is_bc3 ? 16u : 8u;
    for (uint32_t by = 0; by < by_n; by++) {
        const uint8_t *sr = src + (size_t)by * spitch;
        uint8_t *dr = dst + (size_t)by * dpitch;
        if (is_bc3) {
            for (uint32_t bx = 0; bx < bx_n; bx++)
                nvn_bc3_astc_block(sr + (size_t)bx * sb, dr + (size_t)bx * 16u);
        } else {
            for (uint32_t bx = 0; bx < bx_n; bx++)
                nvn_bc1_astc_block(sr + (size_t)bx * sb, has_alpha, dr + (size_t)bx * 16u);
        }
    }
    return 0;
}
