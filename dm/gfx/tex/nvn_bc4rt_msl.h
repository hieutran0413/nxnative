// BC4 raw-block render-target decode for GPUs without BC support.
// One thread handles one 4x4 block from a raw 8-byte-per-block buffer and writes the decoded R8 plane.
#pragma once
static const char k_bc4rt_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct P { uint off, pitch, w, h, z, level; };\n"
"kernel void bc4rt(device const uchar *src [[buffer(0)]], constant P &p [[buffer(1)]], texture3d<float, access::write> dst [[texture(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  uint nbx = (p.w + 3) / 4, nby = (p.h + 3) / 4; if (g.x >= nbx || g.y >= nby || p.z >= dst.get_depth(p.level)) return;\n"
"  device const uchar *b = src + p.off + g.y * p.pitch + g.x * 8; uint a0 = b[0], a1 = b[1], pal[8]; pal[0] = a0; pal[1] = a1;\n"
"  if (a0 > a1) { pal[2] = (56173*a0 + 9363*a1 + 32768) >> 16; pal[3] = (46812*a0 + 18724*a1 + 32768) >> 16; pal[4] = (37450*a0 + 28086*a1 + 32768) >> 16; pal[5] = (28086*a0 + 37450*a1 + 32768) >> 16; pal[6] = (18724*a0 + 46812*a1 + 32768) >> 16; pal[7] = (9363*a0 + 56173*a1 + 32768) >> 16; }\n"
"  else { pal[2] = (52429*a0 + 13107*a1 + 32768) >> 16; pal[3] = (39321*a0 + 26215*a1 + 32768) >> 16; pal[4] = (26215*a0 + 39321*a1 + 32768) >> 16; pal[5] = (13107*a0 + 52429*a1 + 32768) >> 16; pal[6] = 0; pal[7] = 255; }\n"
"  uint lo = b[2] | (uint(b[3]) << 8) | (uint(b[4]) << 16), hi = b[5] | (uint(b[6]) << 8) | (uint(b[7]) << 16);\n"
"  for (uint i = 0; i < 16; i++) { uint x = g.x * 4 + (i & 3), y = g.y * 4 + (i >> 2); if (x < p.w && y < p.h) { uint idx = i < 8 ? ((lo >> (3*i)) & 7) : ((hi >> (3*(i-8))) & 7); dst.write(float(pal[idx]) / 255.0, uint3(x, y, p.z), p.level); } }\n"
"}\n";
