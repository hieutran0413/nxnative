// BC1 → ASTC 4x4 LDR block transcode for GPUs without BC. Four-colour blocks use 4-level weights; opaque three-colour blocks without selector 3 use 5-level weights so their midpoint is represented within the test's 2-level bound.
// Blocks with selector 3 must use exact fallback. In RGB_DXT1 it is opaque black; in RGBA_DXT1 it is transparent. Neither is represented by this RGB-direct block.
// The Metal kernel in nvn_bcastc_msl.h implements the same transcoding.
#pragma once
#include <stddef.h>
#include <stdint.h>

// Return 1 when all three-colour blocks avoid selector 3; four-colour blocks are representable within the tested color bound.
int nvn_bc1_astc_safe(const uint8_t *bc, size_t pitch, uint32_t w, uint32_t h);
// One BC1 block (8 bytes) → one ASTC block (16 bytes). Returns 1 when a 3-colour block uses index 3, which is RGB black or RGBA punch-through alpha and requires exact fallback.
int nvn_bc1_astc_block(const uint8_t *bc, uint8_t *astc);
// A w×h pixel region: src is laid out by block rows (pitch bytes per block row), dst by block rows of dpitch bytes (at least ceil(w/4) * 16). Returns the number of blocks with an unfaithful index 3.
size_t nvn_bc1_astc(const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch);
const uint8_t *nvn_bc1_astc_quint_lut(size_t *size);
