// Runtime BC1 / BC3 -> ASTC 4x4 block transcoding for Apple GPUs without native BC hardware (A16 and older).
// Each 4x4 BC1 (8 B) or BC3 (16 B) block becomes one 16 B ASTC 4x4 block (1 byte/pixel instead of 4 bytes/pixel RGBA8),
// cutting both GPU resident footprint and texture sampling bandwidth by 4x while keeping BC4/BC5 exact in R8/RG8.
#pragma once
#include <stddef.h>
#include <stdint.h>

// Metal pixel format for NVN BC1 / BC3 formats transcoded to ASTC 4x4: 204 = ASTC_4x4_LDR, 186 = ASTC_4x4_sRGB, 0 = not transcoded.
// allow_bc3 controls whether DXT5 / BC3 (0x44, 0x48) is transcoded in addition to BC1 (0x41, 0x42, 0x45, 0x46).
int nvn_bc_astc_pf(uint32_t nvn_fmt, int allow_bc3, uint32_t *mtl_pf);

// Transcode one 8-byte BC1 block into one 16-byte ASTC 4x4 block. has_alpha != 0 for RGBA_DXT1 (0x42, 0x46), 0 for RGB_DXT1 (0x41, 0x45).
void nvn_bc1_astc_block(const uint8_t bc[8], int has_alpha, uint8_t astc[16]);

// Transcode one 16-byte BC3 (DXT5) block into one 16-byte ASTC 4x4 block.
void nvn_bc3_astc_block(const uint8_t bc[16], uint8_t astc[16]);

// Transcode a linear row-major grid of BC1 or BC3 blocks covering w x h texels into ASTC 4x4 blocks (dpitch bytes per block-row).
// Returns 0 on success, -1 if nvn_fmt is not a supported BC1 / BC3 format.
int nvn_bc_astc_encode(uint32_t nvn_fmt, const uint8_t *src, size_t spitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch);
