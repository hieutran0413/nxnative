// The Metal kernel of nvn_bcastc.c: one thread per BC1 block of a buffer, writing the ASTC block into the same buffer (a third buffer counts 3-colour blocks with an unfaithful index 3; offsets in bytes: off / pitch for the BC1 blocks, ooff / opitch for the ASTC blocks)
#pragma once
static const char k_bcastc_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct T { uint off, pitch, w, h, fmt, ooff, opitch; };\n"
"static void put(thread uint *o, uint pos, uint n, uint v) { for (uint i = 0; i < n; i++) o[(pos + i) >> 5] |= ((v >> i) & 1u) << ((pos + i) & 31); }\n"
"kernel void bc1a(device uchar *buf [[buffer(0)]], device const T &p [[buffer(1)]], device atomic_uint *lost [[buffer(2)]], device const uchar *quintLut [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {\n"
"  uint nbx = (p.w + 3) / 4, nby = (p.h + 3) / 4; if (g.x >= nbx || g.y >= nby) return;\n"
"  device const uchar *b = buf + p.off + g.y * p.pitch + g.x * 8;\n"
"  uint c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8), ix = b[4] | (b[5] << 8) | (b[6] << 16) | (uint(b[7]) << 24);\n"
"  int3 e0 = int3(int((((c0 >> 11) & 31) * 527 + 23) >> 6), int((((c0 >> 5) & 63) * 259 + 33) >> 6), int(((c0 & 31) * 527 + 23) >> 6));\n"
"  int3 e1 = int3(int((((c1 >> 11) & 31) * 527 + 23) >> 6), int((((c1 >> 5) & 63) * 259 + 33) >> 6), int(((c1 & 31) * 527 + 23) >> 6));\n"
"  bool four = c0 > c1, sw = (e1.x + e1.y + e1.z) < (e0.x + e0.y + e0.z); int3 lo = sw ? e1 : e0, hi = sw ? e0 : e1;\n"
"  uint m4[4] = {0, 3, 1, 2}, m3[4] = {0, 4, 2, 0}, weight[16]; uint o[4] = {0, 0, 0, 0};\n"
"  put(o, 0, 11, four ? 0x042 : 0x052); put(o, 13, 4, 8);\n"
"  put(o, 17, 8, uint(lo.x)); put(o, 25, 8, uint(hi.x)); put(o, 33, 8, uint(lo.y)); put(o, 41, 8, uint(hi.y)); put(o, 49, 8, uint(lo.z)); put(o, 57, 8, uint(hi.z));\n"
"  bool hit = false;\n"
"  for (int i = 0; i < 16; i++) { uint idx = (ix >> (2 * i)) & 3, code;\n"
"    if (!four && idx == 3) { code = 0; hit = true; } else { code = four ? m4[idx] : m3[idx]; if (sw) code = (four ? 3 : 4) - code; }\n"
"    weight[i] = code; if (four) { put(o, 127 - 2 * i, 1, code & 1); put(o, 126 - 2 * i, 1, code >> 1); } }\n"
"  if (!four) for (uint group = 0; group < 6; group++) { uint i = group * 3, a = i < 16 ? weight[i] : 0, z = i + 1 < 16 ? weight[i + 1] : 0, c = i + 2 < 16 ? weight[i + 2] : 0; uchar q = quintLut[a + 5 * z + 25 * c]; for (uint bit = 0; bit < 7; bit++) put(o, 127 - 7 * group - bit, 1, (q >> bit) & 1); }\n"
"  if (hit) atomic_fetch_add_explicit(lost, 1u, memory_order_relaxed);\n"
"  device uchar *d = buf + p.ooff + g.y * p.opitch + g.x * 16;\n"
"  for (int i = 0; i < 16; i++) d[i] = uchar(o[i >> 2] >> (8 * (i & 3))); }\n";
