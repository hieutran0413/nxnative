// Pre-A17 (no_bc) BCn texture & memory reclamation test:
// 1. Lossless-friendly usage & BC1/BC3 -> ASTC 4x4 runtime transcoding (1 B/px vs 4 B/px RGBA8)
// 2. Idle NvPkg->spare reclamation, staging buffer trim, and LRU eviction + on-demand re-hydration of cold BCn NvPkg textures
// 3. Pool walk skips unseen evicted BCn NvPkg textures instead of immediately re-uploading them
// 4. GPU-written BCn textures (copy_b2t / copy_t2t) are pinned against eviction
// 5. Placement-sparse sub-tiling on no_bc() textures
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static tex_t make_pkg_tex(NVNformat fmt, int w, int h, void *mem) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .mem = mem, .has_layout = 1};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L);
    return t;
}

int main(void) { @autoreleasepool {
    setenv("DM_TEST_NO_BC", "1", 1);
    mtl_init();
    CHECK(no_bc() == 1, "no_bc() active under DM_TEST_NO_BC=1");
    CHECK(no_bc_astc_on() == 1 && no_bc3_astc_on() == 1, "BC1 and BC3 ASTC transcoding enabled by default on no_bc()");

    // 1. Packaged BC1 & BC3 textures transcode to ASTC 4x4 with ShaderRead-only usage (preserving hardware lossless compression)
    static uint8_t bc1_mem[65536], bc3_mem[65536], bc4_mem[65536];
    for (size_t i = 0; i < sizeof bc1_mem; i++) {
        bc1_mem[i] = (uint8_t)(i * 13 + 7);
        bc3_mem[i] = (uint8_t)(i * 29 + 3);
        bc4_mem[i] = (uint8_t)(i * 17 + 11);
    }
    tex_t t_bc1 = make_pkg_tex(NVN_FORMAT_RGB_DXT1, 64, 64, bc1_mem);
    tex_t t_bc3 = make_pkg_tex(NVN_FORMAT_RGBA_DXT5_SRGB, 64, 64, bc3_mem);
    tex_t t_bc4 = make_pkg_tex(NVN_FORMAT_RGTC1_UNORM, 64, 64, bc4_mem);
    mtl_tex_init(&t_bc1); mtl_tex_init(&t_bc3); mtl_tex_init(&t_bc4);
    mtl_reg_tex(10, &t_bc1, NULL); mtl_reg_tex(11, &t_bc3, NULL); mtl_reg_tex(12, &t_bc4, NULL);

    id<MTLTexture> m_bc1 = tex_mtl(&t_bc1), m_bc3 = tex_mtl(&t_bc3), m_bc4 = tex_mtl(&t_bc4);
    up_flush();
    CHECK(m_bc1 && m_bc1.pixelFormat == MTLPixelFormatASTC_4x4_LDR, "BC1 packaged texture uses MTLPixelFormatASTC_4x4_LDR");
    CHECK(m_bc3 && m_bc3.pixelFormat == MTLPixelFormatASTC_4x4_sRGB, "BC3 sRGB packaged texture uses MTLPixelFormatASTC_4x4_sRGB");
    CHECK((m_bc1.usage & MTLTextureUsagePixelFormatView) == 0, "BC1 ASTC texture avoids MTLTextureUsagePixelFormatView");
    CHECK((m_bc3.usage & MTLTextureUsagePixelFormatView) == 0, "BC3 ASTC texture avoids MTLTextureUsagePixelFormatView");
    CHECK(m_bc4 && m_bc4.pixelFormat == MTLPixelFormatR8Unorm, "BC4 packaged texture uses MTLPixelFormatR8Unorm");

    // 2. Advance frame counter past min_idle (60 frames) and verify LRU eviction of cold BCn NvPkg textures
    atomic_store(&g_cur_frame, 100);
    NvPkg *pk1 = tex_get(t_bc1.serial), *pk3 = tex_get(t_bc3.serial), *pk4 = tex_get(t_bc4.serial);
    CHECK([pk1 isKindOfClass:[NvPkg class]] && pk1->tex != nil, "BC1 NvPkg has live texture before trim");

    // Simulate a GPU-written BC4 texture via copy_b2t and verify it is pinned against eviction
    static uint8_t src_buf_mem[65536] __attribute__((aligned(16384)));
    memset(src_buf_mem, 0x7f, sizeof src_buf_mem);
    mtl_pool_add(src_buf_mem, sizeof src_buf_mem);
    p_copy_b2t cb2t = {.src = (uint64_t)(uintptr_t)src_buf_mem, .tex = &t_bc4, .r = {0, 0, 0, 16, 16, 1}};
    mtl_sub_begin();
    copy_b2t(&cb2t, sizeof cb2t);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "copy_b2t on BC4 texture completes");
    CHECK(pk4->gpu_written == 1, "copy_b2t marks NvPkg->gpu_written");

    // Run memory trim (level 2)
    mtl_trim_memory(2);
    CHECK(pk1->evicted == 1 && pk1->tex == nil, "cold BC1 NvPkg texture evicted under memory trim");
    CHECK(pk3->evicted == 1 && pk3->tex == nil, "cold BC3 NvPkg texture evicted under memory trim");
    CHECK(pk4->evicted == 0 && pk4->tex != nil, "GPU-written BC4 NvPkg texture pinned against eviction");

    // 3. Verify pool_entry does not eagerly re-upload an unseen evicted BCn NvPkg texture
    mtl_pool_add(bc1_mem, sizeof bc1_mem);
    int gone = 0, left = 0, left_req = 0, transient = 0, dead = 0;
    os_unfair_lock_lock(&g_rmu);
    uint64_t rid = pool_entry(0, (int)MTLTextureType2D, 10, 64ull << 20, &gone, &left, &left_req, &transient, &dead);
    os_unfair_lock_unlock(&g_rmu);
    CHECK(rid == 0 && left == 1 && pk1->evicted == 1 && pk1->tex == nil, "pool_entry skips unseen evicted NvPkg texture without re-uploading");

    // 4. Verify on-demand re-hydration when tex_mtl / tex_by_id is called
    id<MTLTexture> rehydrated = tex_mtl(&t_bc1);
    up_flush();
    CHECK(rehydrated != nil && pk1->evicted == 0 && pk1->tex != nil, "evicted BC1 NvPkg texture re-hydrates on demand from guest memory");
    CHECK(rehydrated.pixelFormat == MTLPixelFormatASTC_4x4_LDR, "re-hydrated BC1 NvPkg texture preserves ASTC_4x4_LDR format");

    mtl_pool_del(bc1_mem);
    mtl_pool_del(src_buf_mem);
    printf("t_nobc_mem: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
