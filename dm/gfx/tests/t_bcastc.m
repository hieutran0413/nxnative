// BC1 → ASTC 4x4 transcoding (nvn_bcastc.c and its Metal kernel): the blocks are transcoded on the CPU and by the kernel, uploaded into an ASTC_4x4_LDR texture, read back through Metal's own ASTC decoder and compared with nvn_bc_decode (bcdec).
// Usage: t_bcastc. Fails when the kernel differs from the C function, or when a 4-colour block's pixel is off by more than 2 (the transparent pixels and the 3-colour midpoints are reported, not checked)
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../tex/nvn_bcdec.h"
#include "../tex/nvn_bcastc.h"
#include "../tex/nvn_bcastc_msl.h"

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 16); }
static const char k_rd[] = "#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void rd(texture2d<float> t [[texture(0)]], device uchar4 *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= t.get_width() || g.y >= t.get_height()) return; o[g.y * t.get_width() + g.x] = uchar4(round(t.read(g) * 255.0)); }\n";

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    id<MTLLibrary> l1 = [dev newLibraryWithSource:@(k_bcastc_msl) options:nil error:&e]; if (!l1) { printf("kernel: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> p1 = [dev newComputePipelineStateWithFunction:[l1 newFunctionWithName:@"bc1a"] error:&e];
    id<MTLLibrary> l2 = [dev newLibraryWithSource:@(k_rd) options:nil error:&e];
    id<MTLComputePipelineState> p2 = [dev newComputePipelineStateWithFunction:[l2 newFunctionWithName:@"rd"] error:&e];
    int fails = 0;
    for (int mode = 0; mode < 3; mode++) {   // 0: random blocks, 1: blocks made like an encoder does (4-colour, smooth endpoints), 2: random with a size that is no multiple of 4
        uint32_t w = mode == 2 ? 253 : 256, h = mode == 2 ? 122 : 256, nbx = (w + 3) / 4, nby = (h + 3) / 4;
        size_t pitch = nbx * 8, apitch = nbx * 16; uint8_t *bc = malloc(pitch * nby), *astc = malloc(apitch * nby);
        for (uint32_t i = 0; i < nbx * nby; i++) { uint8_t *b = bc + (i / nbx) * pitch + (i % nbx) * 8;
            if (mode == 1) { uint32_t r = rnd() % 32, g = rnd() % 64, bl = rnd() % 32, r2 = (r + rnd() % 6) % 32, g2 = (g + rnd() % 12) % 64, b2 = (bl + rnd() % 6) % 32;
                uint32_t c0 = (r << 11) | (g << 5) | bl, c1 = (r2 << 11) | (g2 << 5) | b2; if (c0 <= c1) { uint32_t t = c0; c0 = c1; c1 = t; } if (c0 == c1) c0 ^= 1;
                b[0] = c0; b[1] = c0 >> 8; b[2] = c1; b[3] = c1 >> 8; for (int k = 4; k < 8; k++) b[k] = rnd(); }
            else for (int k = 0; k < 8; k++) b[k] = rnd(); }
        size_t lost = nvn_bc1_astc(bc, pitch, w, h, astc, apitch);
        // The kernel: BC1 blocks at offset 0, ASTC blocks after them
        size_t off2 = (pitch * nby + 255) & ~(size_t)255; id<MTLBuffer> buf = [dev newBufferWithLength:off2 + apitch * nby options:MTLResourceStorageModeShared]; memcpy(buf.contents, bc, pitch * nby); memset((uint8_t *)buf.contents + off2, 0xCD, apitch * nby);
        uint32_t pr[7] = {0, (uint32_t)pitch, w, h, 1, (uint32_t)off2, (uint32_t)apitch}; id<MTLBuffer> par = [dev newBufferWithBytes:pr length:sizeof pr options:MTLResourceStorageModeShared];
        id<MTLBuffer> cnt = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(cnt.contents, 0, 16);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_LDR width:w height:h mipmapped:NO]; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td]; id<MTLBuffer> out = [dev newBufferWithLength:(size_t)w * h * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:p1]; [ce setBuffer:buf offset:0 atIndex:0]; [ce setBuffer:par offset:0 atIndex:1]; [ce setBuffer:cnt offset:0 atIndex:2]; [ce dispatchThreadgroups:MTLSizeMake((nbx + 7) / 8, (nby + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [ce endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (*(uint32_t *)cnt.contents != lost) { printf("  ✗ mode %d: the kernel counted %u lost transparent indices, the C function %zu\n", mode, *(uint32_t *)cnt.contents, lost); fails++; }
        int kdiff = memcmp((uint8_t *)buf.contents + off2, astc, apitch * nby) != 0; if (kdiff) { printf("  ✗ mode %d: the kernel's blocks differ from the C function's\n", mode); fails++; }
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:astc bytesPerRow:apitch];
        cb = [q commandBuffer]; ce = [cb computeCommandEncoder]; [ce setComputePipelineState:p2]; [ce setTexture:tex atIndex:0]; [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t *ref = malloc((size_t)w * h * 4); nvn_bc_decode(0x42, bc, pitch, w, h, ref, (size_t)w * 4);
        const uint8_t *got = out.contents; int max4 = 0, max3 = 0; size_t n4 = 0, n3 = 0, ntr = 0, hist[4] = {0}, big = 0;
        for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
            const uint8_t *b = bc + (y / 4) * pitch + (x / 4) * 8; unsigned c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8); uint32_t ix = b[4] | (b[5] << 8) | (b[6] << 16) | ((uint32_t)b[7] << 24);
            int four = c0 > c1, tr = !four && ((ix >> (2 * ((y & 3) * 4 + (x & 3)))) & 3) == 3; const uint8_t *r = ref + ((size_t)y * w + x) * 4, *g = got + ((size_t)y * w + x) * 4;
            if (tr) { ntr++; continue; }
            int d = 0; for (int k = 0; k < 3; k++) { int a = abs((int)r[k] - (int)g[k]); if (a > d) d = a; }
            if (four) { n4++; if (d > max4) max4 = d; hist[d > 3 ? 3 : d]++; if (d > 2) big++; } else { n3++; if (d > max3) max3 = d; }
        }
        printf("mode %d %ux%u: %zu blocks with a lost transparent index; 4-colour pixels %zu max error %d (error 0/1/2/>=3: %zu/%zu/%zu/%zu); 3-colour pixels %zu max error %d; transparent pixels %zu\n", mode, w, h, lost, n4, max4, hist[0], hist[1], hist[2], hist[3], n3, max3, ntr);
        if (big) { printf("  ✗ mode %d: %zu 4-colour pixels are off by more than 2\n", mode, big); fails++; }
        free(bc); free(astc); free(ref);
    }
    {   // What an unwritten ASTC block reads as: zeros are invalid (Metal's error colour), the void-extent block that nvn_mtl.m's new-texture fill uses is transparent black
        uint8_t blk[2][16] = {{0}, {0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}};
        for (int k = 0; k < 2; k++) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_LDR width:4 height:4 mipmapped:NO]; td.storageMode = MTLStorageModeShared;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td]; [tex replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:blk[k] bytesPerRow:16];
            id<MTLBuffer> out = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:p2]; [ce setTexture:tex atIndex:0]; [ce setBuffer:out offset:0 atIndex:0]; [ce dispatchThreads:MTLSizeMake(4, 4, 1) threadsPerThreadgroup:MTLSizeMake(4, 4, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
            const uint8_t *o = out.contents; printf("%s block reads as %d,%d,%d,%d\n", k ? "void-extent" : "all-zero", o[0], o[1], o[2], o[3]);
            if (k && (o[0] || o[1] || o[2] || o[3])) { printf("  ✗ the void-extent block is not transparent black\n"); fails++; }
        }
    }
    printf(fails ? "FAIL (%d)\n" : "OK\n", fails); return fails ? 1 : 0;
} }
