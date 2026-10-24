// BC1 → ASTC 4x4 LDR block transcoding for GPUs without BC (A15 / A16 etc.): a BC1-family texture (NVN formats 0x41 0x42 0x45 0x46) is stored as ASTC 4x4 (1 byte per pixel) instead of RGBA8 (4 bytes per pixel).
// Both formats have 4x4 blocks and a 4-colour palette on a line between two endpoints, so a block maps to one single-partition RGB-direct ASTC block with 8-bit endpoints and 2-bit weights:
// the BC1 weights 0, 1/3, 2/3, 1 are the ASTC weights 0, 21, 43, 64 (of 64), within 1 of the decoded 8-bit value. 3-colour blocks (c0 <= c1) lose their midpoint (kept at 1/3) and their transparent index (drawn as the darker endpoint, alpha 1).
// The Metal kernel in nvn_bcastc_msl.h implements the same transcoding.
#pragma once
#include <stddef.h>
#include <stdint.h>

// One BC1 block (8 bytes) → one ASTC block (16 bytes). Returns 1 when the block is a 3-colour block that uses the transparent index (its alpha is lost), else 0
int nvn_bc1_astc_block(const uint8_t *bc, uint8_t *astc);
// A w×h pixel region: src is laid out by block rows (pitch bytes per block row), dst by block rows of dpitch bytes (at least ceil(w/4) * 16). Returns the number of blocks with a lost transparent index
size_t nvn_bc1_astc(const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch);
