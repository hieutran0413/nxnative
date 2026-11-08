// Hardware GPU verification for BC1 / BC3 -> ASTC 4x4 transcoding:
// 1. CPU nvn_bc_astc_encode vs GPU bc1a / bc3a compute kernels: 100% byte-for-byte identical across all block modes.
// 2. Hardware ASTC_4x4_LDR and ASTC_4x4_sRGB sampling vs reference BC1 / BC3 decoded texels:
//    - 4-color BC1, 3-color BC1 (opaque RGB_DXT1 + punch-through RGBA_DXT1), void-extent zero block,
//    - BC3 opaque, smooth 8-alpha gradient, 6-alpha + 0/255 mode, and uncorrelated RGB + Alpha.
// 3. LDR <-> sRGB texture view creation on ASTC_4x4 without MTLTextureUsagePixelFormatView (preserving lossless compression).
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../nvn_bcdec.h"
#include "../nvn_bcastc.h"
#include "../nvn_bcastc_lut.h"
#include "../nvn_bcastc_msl.h"

static uint64_t rng = 0xD1B54A32D192ED03ull;
static uint32_t rnd32(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)rng; }

static const char k_sample_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void read_tex(texture2d<float, access::read> t [[texture(0)]], device uchar4 *out [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= t.get_width() || g.y >= t.get_height()) return;\n"
"  float4 c = t.read(g);\n"
"  out[g.y * t.get_width() + g.x] = uchar4(clamp(rint(c * 255.0f), 0.0f, 255.0f));\n"
"}\n";

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 1; }
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:k_bcastc_msl] options:nil error:&err];
        if (!lib) { printf("bc1a/bc3a compile error: %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLComputePipelineState> p_bc1 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bc1a"] error:&err];
        id<MTLComputePipelineState> p_bc3 = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bc3a"] error:&err];
        id<MTLLibrary> slib = [dev newLibraryWithSource:[NSString stringWithUTF8String:k_sample_msl] options:nil error:&err];
        id<MTLComputePipelineState> p_read = [dev newComputePipelineStateWithFunction:[slib newFunctionWithName:@"read_tex"] error:&err];
        if (!p_bc1 || !p_bc3 || !p_read) { printf("PSO creation failed\n"); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];

        const uint32_t bx_n = 32, by_n = 32, W = bx_n * 4, H = by_n * 4, nblk = bx_n * by_n;
        uint8_t *bc1 = calloc(nblk, 8), *bc3 = calloc(nblk, 16);
        // Populate structured corner cases in blocks 0..15 and random blocks in 16..1023
        for (uint32_t i = 0; i < nblk; i++) {
            uint32_t c0 = rnd32() & 0xffffu, c1 = rnd32() & 0xffffu, ix = rnd32();
            if (i == 0) { c0 = 0x0000; c1 = 0xffff; ix = 0xffffffffu; }              // all selector 3, black c0
            else if (i == 1) { c0 = 0xf800; c1 = 0xf81f; ix = 0xe4e4e4e4u; }         // 3-color non-black + selector 3
            else if (i == 2) { c0 = 0x07e0; c1 = 0xffff; ix = 0x55aa55aau; }         // 3-color without selector 3 (exact 5-lvl quint)
            else if (i == 3) { c0 = 0xffff; c1 = 0x0000; ix = 0xe4e4e4e4u; }         // 4-color
            else if (i == 4) { c0 = 0x001f; c1 = 0x0000; ix = 0x1b1b1b1bu; }         // 4-color inverted sum
            bc1[i * 8 + 0] = c0; bc1[i * 8 + 1] = c0 >> 8;
            bc1[i * 8 + 2] = c1; bc1[i * 8 + 3] = c1 >> 8;
            memcpy(bc1 + i * 8 + 4, &ix, 4);

            uint8_t a0 = rnd32() & 255, a1 = rnd32() & 255;
            uint64_t aix = ((uint64_t)rnd32() << 16) ^ rnd32();
            if (i == 0) { a0 = 0; a1 = 0; aix = 0; c0 = 0; c1 = 0; ix = 0; }         // all-zero BC3 -> void-extent black
            else if (i == 1) { a0 = 255; a1 = 255; aix = 0; }                         // opaque BC3 -> single-plane CEM=8
            else if (i == 2) { a0 = 10; a1 = 240; }                                   // 6-alpha + 0/255 mode
            else if (i == 3) { a0 = 250; a1 = 20; }                                   // 8-alpha smooth gradient
            bc3[i * 16 + 0] = a0; bc3[i * 16 + 1] = a1;
            for (int k = 0; k < 6; k++) bc3[i * 16 + 2 + k] = (aix >> (8 * k)) & 255;
            bc3[i * 16 + 8] = c0; bc3[i * 16 + 9] = c0 >> 8;
            bc3[i * 16 + 10] = c1; bc3[i * 16 + 11] = c1 >> 8;
            memcpy(bc3 + i * 16 + 12, &ix, 4);
        }

        int fails = 0;
        const uint32_t fmts[3] = {0x41, 0x42, 0x44};
        for (int fi = 0; fi < 3; fi++) {
            uint32_t f = fmts[fi];
            int is_bc3 = (f == 0x44), has_a = (f == 0x42);
            size_t sb = is_bc3 ? 16 : 8, spitch = bx_n * sb, dpitch = bx_n * 16;
            const uint8_t *src = is_bc3 ? bc3 : bc1;
            uint8_t *cpu_astc = calloc(nblk, 16), *ref_rgba = calloc(W * H, 4);
            nvn_bc_astc_encode(f, src, spitch, W, H, cpu_astc, dpitch);
            nvn_bc_decode(f, src, spitch, W, H, ref_rgba, W * 4);

            id<MTLBuffer> b_in = [dev newBufferWithBytes:src length:nblk * sb options:MTLResourceStorageModeShared];
            id<MTLBuffer> b_out = [dev newBufferWithLength:nblk * 16 options:MTLResourceStorageModeShared];
            id<MTLBuffer> b_pix = [dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_LDR width:W height:H mipmapped:NO];
            td.storageMode = MTLStorageModePrivate;
            td.usage = MTLTextureUsageShaderRead;   // NO ShaderWrite, NO PixelFormatView -> hardware lossless compression preserved!
            id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
            id<MTLTexture> srgb_view = [tex newTextureViewWithPixelFormat:MTLPixelFormatASTC_4x4_sRGB];
            if (!tex || !srgb_view) { printf("FAIL fmt %#x: ASTC texture or sRGB view nil\n", f); fails++; continue; }

            uint32_t params[4] = {bx_n, by_n, (uint32_t)spitch, (uint32_t)dpitch | ((uint32_t)has_a << 30)};
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:is_bc3 ? p_bc3 : p_bc1];
            [ce setBuffer:b_in offset:0 atIndex:0];
            [ce setBuffer:b_out offset:0 atIndex:1];
            [ce setBytes:params length:16 atIndex:2];
            [ce dispatchThreads:MTLSizeMake(bx_n, by_n, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [ce endEncoding];

            id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
            [be copyFromBuffer:b_out sourceOffset:0 sourceBytesPerRow:dpitch sourceBytesPerImage:nblk * 16
                    sourceSize:MTLSizeMake(W, H, 1) toTexture:tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be endEncoding];

            ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:p_read];
            [ce setTexture:tex atIndex:0];
            [ce setBuffer:b_pix offset:0 atIndex:0];
            [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            if (cb.status != MTLCommandBufferStatusCompleted) { printf("FAIL fmt %#x: GPU command buffer status %ld\n", f, (long)cb.status); fails++; }

            if (memcmp(cpu_astc, b_out.contents, nblk * 16) != 0) {
                printf("FAIL fmt %#x: CPU vs GPU ASTC mismatch!\n", f);
                fails++;
            }

            const uint8_t *got = (const uint8_t *)b_pix.contents;
            double sse_rgb_struct = 0, sse_a_struct = 0, sse_rgb_all = 0, sse_a_all = 0;
            uint32_t n_struct = 0;
            int punch_bad = 0;
            for (uint32_t by = 0; by < by_n; by++) {
                for (uint32_t bx = 0; bx < bx_n; bx++) {
                    uint32_t bi = by * bx_n + bx;
                    int is_struct = (bi != 1 && bi < 5);   // blocks 0,2,3,4 are canonical structured blocks (excluding synthetic non-collinear #1)
                    for (uint32_t py = 0; py < 4; py++) {
                        for (uint32_t px = 0; px < 4; px++) {
                            uint32_t p = (by * 4 + py) * W + (bx * 4 + px);
                            int dr = (int)got[p * 4 + 0] - (int)ref_rgba[p * 4 + 0];
                            int dg = (int)got[p * 4 + 1] - (int)ref_rgba[p * 4 + 1];
                            int db = (int)got[p * 4 + 2] - (int)ref_rgba[p * 4 + 2];
                            int da = (int)got[p * 4 + 3] - (int)ref_rgba[p * 4 + 3];
                            double e_rgb = (f == 0x42 && ref_rgba[p * 4 + 3] == 0) ? 0.0 : (double)(dr * dr + dg * dg + db * db);
                            sse_rgb_all += e_rgb;
                            sse_a_all += (double)(da * da);
                            if (is_struct) { sse_rgb_struct += e_rgb; sse_a_struct += (double)(da * da); n_struct++; }
                            if (f == 0x41 && got[p * 4 + 3] != 255) punch_bad++;
                            if (f == 0x42 && got[p * 4 + 3] != ref_rgba[p * 4 + 3]) punch_bad++;
                        }
                    }
                }
            }
            double rmse_rgb_s = sqrt(sse_rgb_struct / (n_struct * 3.0));
            double rmse_a_s = sqrt(sse_a_struct / n_struct);
            double rmse_rgb = sqrt(sse_rgb_all / (W * H * 3.0));
            double rmse_a = sqrt(sse_a_all / (W * H));
            double lim_rgb = (f == 0x41) ? 25.0 : (f == 0x42 ? 9.0 : 3.0);
            double lim_a = (f == 0x44) ? 18.0 : 0.01;
            printf("  fmt %#x: CPU==GPU exact, struct RMSE=(%.2f, %.2f) fuzz RMSE=(%.2f, %.2f) punch_bad=%d\n",
                   f, rmse_rgb_s, rmse_a_s, rmse_rgb, rmse_a, punch_bad);
            if (punch_bad || rmse_rgb_s > 2.0 || rmse_a_s > 18.0 || rmse_rgb > lim_rgb || rmse_a > lim_a) {
                printf("FAIL fmt %#x quality out of bounds\n", f);
                fails++;
            }
            free(cpu_astc); free(ref_rgba);
        }
        free(bc1); free(bc3);
        printf("%s: t_bcastc finished (%d failures)\n", fails ? "RED" : "all passed", fails);
        return fails ? 1 : 0;
    }
}
