// Metal 4 argument-table integration for the production BC1 → ASTC kernel.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 16); }

static int bcd_case(uint32_t test_fmt, uint32_t width, uint32_t height) {
    const uint32_t kernel_fmt = test_fmt <= 7 ? test_fmt : (test_fmt <= 10 ? 1 : test_fmt == 11 ? 2 : 3);
    const uint32_t bpp = kernel_fmt <= 3 ? 4 : (kernel_fmt <= 5 ? 1 : 2);
    const BOOL signed_fmt = kernel_fmt == 5 || kernel_fmt == 7;
    const BOOL alpha_fmt = kernel_fmt == 2 || kernel_fmt == 3 || test_fmt == 8 || test_fmt == 10;
    const BOOL srgb_fmt = test_fmt >= 9;
    const uint32_t bb = (kernel_fmt == 1 || kernel_fmt == 4 || kernel_fmt == 5) ? 8 : 16;
    const uint32_t bx = (width + 3) / 4, by = (height + 3) / 4;
    const size_t pitch = (size_t)bx * bb, op = (size_t)width * bpp, out_n = op * height, src_n = pitch * by;
    const uint32_t nvfmt[] = {0, 0x41, 0x43, 0x44, 0x49, 0x4a, 0x4b, 0x4c, 0x42, 0x45, 0x46, 0x47, 0x48};
    id<MTLBuffer> src = [g_dev newBufferWithLength:src_n options:MTLResourceStorageModeShared];
    id<MTLBuffer> params = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    MTLPixelFormat pf = bpp == 4 ? MTLPixelFormatRGBA8Unorm : bpp == 2 ? (signed_fmt ? MTLPixelFormatRG8Snorm : MTLPixelFormatRG8Unorm) : (signed_fmt ? MTLPixelFormatR8Snorm : MTLPixelFormatR8Unorm);
    if (kernel_fmt == 1 || alpha_fmt) pf = MTLPixelFormatRGBA8Unorm;
    if (srgb_fmt) pf = MTLPixelFormatRGBA8Unorm_sRGB;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    td.usage |= MTLTextureUsagePixelFormatView;
    id<MTLTexture> dst = [g_dev newTextureWithDescriptor:td];
    id<MTLTexture> write_view = srgb_fmt ? [dst newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm] : dst;
    uint8_t *expected = malloc(out_n);
    if (!src || !params || !dst || !expected) { fprintf(stderr, "bcd format %u allocation failed\n", test_fmt); free(expected); return 1; }
    uint8_t *src_bytes = src.contents; for (size_t i = 0; i < src_n; i++) src_bytes[i] = (uint8_t)rnd();
    if (nvn_bc_decode(nvfmt[test_fmt], src_bytes, pitch, width, height, expected, op)) { fprintf(stderr, "bcd test format %u CPU decode failed\n", test_fmt); free(expected); return 1; }
    uint32_t p[5] = {0, (uint32_t)pitch, width, height, kernel_fmt}; memcpy(params.contents, p, sizeof p);
    MTL4ArgumentTableDescriptor *atd = [MTL4ArgumentTableDescriptor new]; atd.maxBufferBindCount = 2; atd.maxTextureBindCount = 1;
    NSError *error = nil; id<MTL4ArgumentTable> table = [g_dev newArgumentTableWithDescriptor:atd error:&error];
    [table setAddress:src.gpuAddress atIndex:0]; [table setAddress:params.gpuAddress atIndex:1]; [table setTexture:write_view.gpuResourceID atIndex:0];
    mtl_sub_begin(); id<MTL4ComputeCommandEncoder> ce = enc_c_begin(NULL); [ce setArgumentTable:table]; [ce setComputePipelineState:bcd_pso()];
    enc_c_dispatch(ce, MTLSizeMake((bx + 7) / 8, (by + 7) / 8, 1), MTLSizeMake(8, 8, 1)); enc_c_end(ce);
    uint64_t fence = mtl_sub_commit(); int failed = !mtl_wait(fence, 5000000000ull) || mtl_last_commit_error();
    const size_t read_pitch = (op + 255) & ~(size_t)255, read_n = read_pitch * height;
    id<MTLBuffer> read = [g_dev newBufferWithLength:read_n options:MTLResourceStorageModeShared];
    mtl_sub_begin(); id<MTL4ComputeCommandEncoder> copy = enc_c_begin(NULL); [copy copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:read_pitch destinationBytesPerImage:read_n]; enc_c_end(copy);
    fence = mtl_sub_commit(); if (!mtl_wait(fence, 5000000000ull) || mtl_last_commit_error()) failed = 1;
    size_t diff = 0, compared = 0, maxerr = 0; const uint8_t *actual = read.contents;
    for (uint32_t y = 0; y < height; y++) for (uint32_t x = 0; x < width; x++) for (uint32_t c = 0; c < bpp; c++) {
        size_t i = (size_t)y * op + (size_t)x * bpp + c;
        size_t ai = (size_t)y * read_pitch + (size_t)x * bpp + c;
        int want = (int)expected[i];
        if (signed_fmt) { int8_t s = (int8_t)want; want = (int)lrintf(fmaxf(-1.0f, (float)s / 127.0f) * 127.0f); if (want < 0) want += 256; }
        if ((test_fmt == 1 || test_fmt == 9) && c == 3) continue; // RGB_DXT1 alpha is one by NVN format semantics.
        size_t e = (size_t)abs((int)actual[ai] - want); compared++; diff += e > 1;
        if (e > maxerr) maxerr = e;
    }
    printf("bcd fmt %u NVN 0x%02x %ux%u%s: %zu/%zu compared bytes differ by >1, max error %zu\n", test_fmt, nvfmt[test_fmt], width, height, srgb_fmt ? " sRGB raw-store" : "", diff, compared, maxerr);
    if (diff) failed = 1;
    free(expected); res_add(src); res_add(params); res_add(dst); res_add(write_view); res_add(read); mtl_drain(); return failed;
}

static int upload_path(uint32_t w, uint32_t h) {
    uint32_t bx = (w + 3) / 4, by = (h + 3) / 4;
    size_t pitch = (size_t)bx * 8, ap = (size_t)bx * 16, src_n = pitch * by, out_n = ap * by, out_off = (src_n + 255) & ~(size_t)255;
    id<MTLBuffer> input = [g_dev newBufferWithLength:src_n options:MTLResourceStorageModeShared];
    id<MTLBuffer> verify_ref = [g_dev newBufferWithLength:src_n options:MTLResourceStorageModeShared];
    if (!input || !verify_ref) return 1;
    uint8_t *src = input.contents;
    for (uint32_t i = 0; i < bx * by; i++) {
        uint8_t *p = src + (size_t)(i / bx) * pitch + (i % bx) * 8;
        uint16_t c0 = (uint16_t)rnd(), c1 = (uint16_t)rnd(); if (c0 > c1) { uint16_t t = c0; c0 = c1; c1 = t; }
        p[0] = (uint8_t)c0; p[1] = (uint8_t)(c0 >> 8); p[2] = (uint8_t)c1; p[3] = (uint8_t)(c1 >> 8);
        uint32_t ix = 0; for (uint32_t k = 0; k < 16; k++) ix |= (rnd() % 3u) << (2 * k);
        p[4] = (uint8_t)ix; p[5] = (uint8_t)(ix >> 8); p[6] = (uint8_t)(ix >> 16); p[7] = (uint8_t)(ix >> 24);
    }
    memcpy(verify_ref.contents, input.contents, src_n); res_add(input); res_add(verify_ref);
    up_begin(); size_t stage_off; id<MTLBuffer> stage = up_alloc(out_off + out_n, &stage_off);
    [g_up_ce copyFromBuffer:input sourceOffset:0 toBuffer:stage destinationOffset:stage_off size:src_n];
    size_t po; id<MTLBuffer> params = up_param_alloc(&po);
    uint32_t *p = (uint32_t *)((uint8_t *)params.contents + po);
    p[0] = (uint32_t)stage_off; p[1] = (uint32_t)pitch; p[2] = w; p[3] = h; p[4] = 1;
    p[5] = (uint32_t)(stage_off + out_off); p[6] = (uint32_t)ap;
    [g_up_keep addObject:verify_ref];
    if (g_nup_decs == g_up_deccap) { g_up_deccap = g_up_deccap ? g_up_deccap * 2 : 16; g_up_decs = realloc(g_up_decs, g_up_deccap * sizeof *g_up_decs); }
    g_up_decs[g_nup_decs++] = (up_dec){stage, params, verify_ref, 0, po, bx, by, nil, 1, 9001};
    up_flush(); up_wait_zero(&g_up_pending);
    printf("Production upload flush verifier completed for %ux%u; source and transcode parity are reported above.\n", w, h);
    return 0;
}

int main(void) { @autoreleasepool {
    const uint32_t w = 1024, h = 1024, bx = w / 4, by = h / 4;
    const size_t pitch = bx * 8, ap = bx * 16, src_n = pitch * by, out_n = ap * by, out_off = (src_n + 255) & ~(size_t)255;
    int failed = 0;
    setenv("DM_BC1A_VERIFY", "1", 1);
    mtl_init();
    for (uint32_t fmt = 1; fmt <= 8; fmt++) failed += bcd_case(fmt, 19, 17);
    for (uint32_t fmt = 9; fmt <= 12; fmt++) failed += bcd_case(fmt, 19, 17);
    id<MTLBuffer> b = [g_dev newBufferWithLength:out_off + out_n options:MTLResourceStorageModeShared];
    id<MTLBuffer> count = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    size_t lut_n = 0; const uint8_t *lut_data = nvn_bc1_astc_quint_lut(&lut_n);
    id<MTLBuffer> lut = [g_dev newBufferWithBytes:lut_data length:lut_n options:MTLResourceStorageModeShared];
    uint8_t *expected = malloc(out_n);
    if (!b || !count || !lut || !expected) { fprintf(stderr, "Metal 4 BC1 ASTC allocation failed\n"); return 1; }
    res_add(b); res_add(count); res_add(lut); memset(count.contents, 0, count.length);
    uint8_t *src = b.contents;
    for (uint32_t i = 0; i < bx * by; i++) {
        uint8_t *p = src + (size_t)(i / bx) * pitch + (i % bx) * 8;
        uint16_t c0 = (uint16_t)rnd(), c1 = (uint16_t)rnd();
        if (c0 > c1) { uint16_t tmp = c0; c0 = c1; c1 = tmp; }
        p[0] = (uint8_t)c0; p[1] = (uint8_t)(c0 >> 8); p[2] = (uint8_t)c1; p[3] = (uint8_t)(c1 >> 8);
        uint32_t ix = 0; for (uint32_t k = 0; k < 16; k++) ix |= (rnd() % 3u) << (2 * k);
        p[4] = (uint8_t)ix; p[5] = (uint8_t)(ix >> 8); p[6] = (uint8_t)(ix >> 16); p[7] = (uint8_t)(ix >> 24);
    }
    memset(src + out_off, 0xcd, out_n);
    nvn_bc1_astc(src, pitch, w, h, expected, ap);
    mtl_sub_begin();
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin(NULL);
    [ce setComputePipelineState:bc1a_pso()];
    [g_ct setAddress:b.gpuAddress atIndex:0];
    uint32_t params[7] = {0, (uint32_t)pitch, w, h, 1, (uint32_t)out_off, (uint32_t)ap};
    size_t po; id<MTLBuffer> pb = up_param_alloc(&po); memcpy((uint8_t *)pb.contents + po, params, sizeof params); res_add(pb);
    [g_ct setAddress:pb.gpuAddress + po atIndex:1]; [g_ct setAddress:count.gpuAddress atIndex:2]; [g_ct setAddress:lut.gpuAddress atIndex:3];
    enc_c_dispatch(ce, MTLSizeMake((bx + 7) / 8, (by + 7) / 8, 1), MTLSizeMake(8, 8, 1));
    enc_c_end(ce);
    uint64_t fence = mtl_sub_commit();
    if (!mtl_wait(fence, 5000000000ull) || mtl_last_commit_error()) { fprintf(stderr, "Metal 4 BC1 ASTC submission failed\n"); failed++; }
    size_t bad = memcmp((uint8_t *)b.contents + out_off, expected, out_n) != 0;
    if (bad) {
        size_t bytes = 0; const uint8_t *got = (const uint8_t *)b.contents + out_off;
        for (size_t i = 0; i < out_n; i++) bytes += got[i] != expected[i];
        fprintf(stderr, "Metal 4 BC1 → ASTC differs from CPU: %zu/%zu output bytes\n", bytes, out_n); failed++;
    } else printf("Metal 4 BC1 → ASTC: exact CPU parity for randomized 3-colour blocks (%ux%u)\n", w, h);
    free(expected); mtl_drain();
    failed += upload_path(1024, 1024);
    mtl_drain();
    printf("t_bcastc_mtl4: %s\n", failed ? "FAIL" : "OK"); return failed != 0;
} }
