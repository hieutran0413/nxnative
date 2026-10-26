// BC1 RGB → ASTC 4x4 transcoding (nvn_bcastc.c and its Metal kernel): transcode on CPU and GPU, then compare Metal's ASTC decode with nvn_bc_decode.
// Usage: t_bcastc. Fails when the kernel differs from the C function, alpha differs, or any decoded color is off by more than 2.
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../tex/nvn_bcdec.h"
#include "../tex/nvn_bcastc.h"
#include "../tex/nvn_bcastc_msl.h"
#include "../tex/nvn_bc4rt_msl.h"

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 16); }
static int test_bc7_cpu_vs_metal(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    const uint32_t w=64,h=64,bx=w/4,by=h/4; const size_t row=(size_t)bx*16,n=row*by,pix=(size_t)w*h*4;
    uint8_t *blocks=malloc(n),*ref=malloc(pix); if(!blocks||!ref){free(blocks);free(ref);return 1;}
    for(size_t i=0;i<n;i+=16){blocks[i]=(uint8_t)(0x40|(rnd()&0x80));for(int k=1;k<16;k++)blocks[i+k]=(uint8_t)rnd();}
    if(nvn_bc_decode(0x4d,blocks,row,w,h,ref,(size_t)w*4)){free(blocks);free(ref);return 1;}
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC7_RGBAUnorm width:w height:h mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> tex=[dev newTextureWithDescriptor:td];id<MTLBuffer> out=[dev newBufferWithLength:pix options:MTLResourceStorageModeShared];NSError *e=nil;
    NSString *src=@"#include <metal_stdlib>\nusing namespace metal; kernel void rd(texture2d<float, access::sample> t [[texture(0)]], device uchar4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest); float2 uv=(float2(p)+0.5f)/float2(t.get_width(),t.get_height()); float4 c=t.sample(s,uv); o[p.y*t.get_width()+p.x]=uchar4(clamp(rint(c*255.0f),0.0f,255.0f)); }";
    id<MTLLibrary> lib=[dev newLibraryWithSource:src options:nil error:&e];id<MTLComputePipelineState> ps=lib?[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"rd"] error:&e]:nil;
    if(!tex||!out||!ps){printf("BC7 CPU/Metal fixture unavailable: %s\n",e.localizedDescription.UTF8String?:"Metal resource creation failed");free(blocks);free(ref);return 1;}
    [tex replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:blocks bytesPerRow:row];id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];[ce setComputePipelineState:ps];[ce setTexture:tex atIndex:0];[ce setBuffer:out offset:0 atIndex:0];[ce dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[ce endEncoding];[cb commit];[cb waitUntilCompleted];
    const uint8_t *got=out.contents;size_t bad=0;int max=0;for(size_t i=0;i<pix;i++){int d=abs((int)got[i]-(int)ref[i]);if(d){bad++;if(d>max)max=d;}}
    printf("BC7 mode-6 CPU/Metal decode: %zu/%zu bytes differ, max error %d\n",bad,pix,max);free(blocks);free(ref);return bad?1:0;
}
static int test_bc4_mips(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLComputePipelineState> p) {
    const uint32_t levels = 6, width = 32, height = 32, depth = 32;
    size_t boff[6], roff[6], bsize[6], rsize[6], total_b = 0, total_r = 0;
    for (uint32_t l = 0; l < levels; l++) { uint32_t w = width >> l, h = height >> l, z = depth >> l, bx = (w + 3) / 4, by = (h + 3) / 4;
        boff[l] = total_b; bsize[l] = (size_t)bx * 8 * by * z; total_b += bsize[l];
        roff[l] = total_r; rsize[l] = (size_t)w * h * z; total_r += rsize[l]; }
    uint8_t *blocks = malloc(total_b), *roundtrip = malloc(total_b), *ref = malloc(total_r), *got = malloc(total_r);
    if (!blocks || !roundtrip || !ref || !got) { printf("  ✗ BC4 mip fixture allocation failed\n"); return 1; }
    for (uint32_t l = 0; l < levels; l++) {
        uint32_t w = width >> l, h = height >> l, z = depth >> l, bx = (w + 3) / 4, by = (h + 3) / 4; size_t row = bx * 8, img = row * by;
        for (size_t i = 0; i < bsize[l]; i++) blocks[boff[l] + i] = (uint8_t)rnd();
        for (uint32_t zi = 0; zi < z; zi++) {
            uint8_t *plane = blocks + boff[l] + zi * img;
            for (uint32_t y = 0; y < by; y++) for (uint32_t x = 0; x < bx; x++) { uint8_t *b = plane + y * row + x * 8; b[0] = (uint8_t)(30 + zi); b[1] = (uint8_t)(220 - zi); }
            if (nvn_bc_decode(0x49, plane, row, w, h, ref + roff[l] + (size_t)zi * w * h, w)) { printf("  ✗ BC4 mip CPU decode failed at level %u slice %u\n", l, zi); return 1; }
        }
    }
    MTLTextureDescriptor *rd = [MTLTextureDescriptor new]; rd.textureType = MTLTextureType3D; rd.pixelFormat = MTLPixelFormatRGBA16Uint; rd.width = width / 4; rd.height = height / 4; rd.depth = depth; rd.mipmapLevelCount = levels; rd.storageMode = MTLStorageModePrivate; rd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    MTLTextureDescriptor *td = [MTLTextureDescriptor new]; td.textureType = MTLTextureType3D; td.pixelFormat = MTLPixelFormatR8Unorm; td.width = width; td.height = height; td.depth = depth; td.mipmapLevelCount = levels; td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> raw = [dev newTextureWithDescriptor:rd], dst = [dev newTextureWithDescriptor:td]; id<MTLBuffer> in = [dev newBufferWithBytes:blocks length:total_b options:MTLResourceStorageModeShared];
    id<MTLBuffer> rt = [dev newBufferWithLength:total_b options:MTLResourceStorageModeShared]; id<MTLBuffer> out = [dev newBufferWithLength:total_r options:MTLResourceStorageModeShared];
    if (!raw || !dst || !in || !rt || !out) { printf("  ✗ BC4 mip Metal resources unavailable\n"); return 1; }
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (uint32_t l = 0; l < levels; l++) { uint32_t w = width >> l, h = height >> l, z = depth >> l, bx = (w + 3) / 4, by = (h + 3) / 4; size_t row = bx * 8, img = row * by;
        [be copyFromBuffer:in sourceOffset:boff[l] sourceBytesPerRow:row sourceBytesPerImage:img sourceSize:MTLSizeMake(bx, by, z) toTexture:raw destinationSlice:0 destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)]; }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    cb = [q commandBuffer]; be = [cb blitCommandEncoder];
    for (uint32_t l = 0; l < levels; l++) { uint32_t w = width >> l, h = height >> l, z = depth >> l, bx = (w + 3) / 4, by = (h + 3) / 4; size_t row = bx * 8, img = row * by;
        [be copyFromTexture:raw sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(bx, by, z) toBuffer:rt destinationOffset:boff[l] destinationBytesPerRow:row destinationBytesPerImage:img]; }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (memcmp(blocks, rt.contents, total_b) != 0) { printf("  ✗ BC4 mip raw-texture copy changed bytes\n"); return 1; }
    cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:p];
    for (uint32_t l = 0; l < levels; l++) { uint32_t w = width >> l, h = height >> l, z = depth >> l, bx = (w + 3) / 4, by = (h + 3) / 4; size_t row = bx * 8, img = row * by;
        for (uint32_t zi = 0; zi < z; zi++) { uint32_t params[6] = {(uint32_t)(boff[l] + zi * img), (uint32_t)row, w, h, zi, l}; id<MTLBuffer> par = [dev newBufferWithBytes:params length:sizeof params options:MTLResourceStorageModeShared];
            [ce setBuffer:rt offset:0 atIndex:0]; [ce setBuffer:par offset:0 atIndex:1]; [ce setTexture:dst atIndex:0]; [ce dispatchThreadgroups:MTLSizeMake((bx + 7) / 8, (by + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; } }
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    cb = [q commandBuffer]; be = [cb blitCommandEncoder];
    for (uint32_t l = 0; l < levels; l++) { uint32_t w = width >> l, h = height >> l, z = depth >> l;
        [be copyFromTexture:dst sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, z) toBuffer:out destinationOffset:roff[l] destinationBytesPerRow:w destinationBytesPerImage:(size_t)w * h]; }
    [be endEncoding]; [cb commit]; [cb waitUntilCompleted]; memcpy(got, out.contents, total_r);
    size_t mismatch = 0; for (size_t i = 0; i < total_r; i++) mismatch += ref[i] != got[i];
    free(blocks); free(roundtrip); free(ref); free(got);
    if (mismatch) { printf("  ✗ BC4 mip decoder differs from CPU at %zu/%zu bytes\n", mismatch, total_r); return 1; }
    printf("BC4 render-target decode: exact CPU parity across 6 levels of 32x32x32\n"); return 0;
}
static const char k_bc4_shadow_test[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"vertex float4 bc4_v(uint id [[vertex_id]]) { const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[id],0,1); }\n"
"fragment ushort4 bc4_f(float4 pos [[position]], device const uchar *src [[buffer(0)]], constant uint &off [[buffer(1)]]) { uint2 p=uint2(pos.xy); device const ushort *q=(device const ushort *)(src+off+(p.y*8+p.x)*8); return ushort4(q[0],q[1],q[2],q[3]); }\n";
static int test_bc4_shadow_roundtrip(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLComputePipelineState> decode) {
    const uint32_t w=32,h=32,depth=3,bw=w/4,bh=h/4; const size_t row=bw*8,plane=row*bh,total=plane*depth;
    uint8_t *blocks=malloc(total),*ref=malloc((size_t)w*h*depth); if(!blocks||!ref){free(blocks);free(ref);return 1;}
    for(size_t i=0;i<total;i++) blocks[i]=(uint8_t)rnd();
    for(uint32_t z=0;z<depth;z++){uint8_t *p=blocks+z*plane; for(uint32_t y=0;y<bh;y++)for(uint32_t x=0;x<bw;x++){uint8_t *b=p+y*row+x*8;b[0]=(uint8_t)(35+z*17+x);b[1]=(uint8_t)(210-z*13-y);} nvn_bc_decode(0x49,p,row,w,h,ref+(size_t)z*w*h,w);}
    MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Uint width:bw height:bh mipmapped:NO]; sd.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead; sd.storageMode=MTLStorageModePrivate;
    MTLTextureDescriptor *rd=[MTLTextureDescriptor new]; rd.textureType=MTLTextureType3D;rd.pixelFormat=MTLPixelFormatRGBA16Uint;rd.width=bw;rd.height=bh;rd.depth=depth;rd.storageMode=MTLStorageModePrivate;rd.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    MTLTextureDescriptor *dd=[MTLTextureDescriptor new];dd.textureType=MTLTextureType3D;dd.pixelFormat=MTLPixelFormatR8Unorm;dd.width=w;dd.height=h;dd.depth=depth;dd.storageMode=MTLStorageModePrivate;dd.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
    id<MTLTexture> shadow=[dev newTextureWithDescriptor:sd],raw=[dev newTextureWithDescriptor:rd],dst=[dev newTextureWithDescriptor:dd];
    id<MTLBuffer> in=[dev newBufferWithBytes:blocks length:total options:MTLResourceStorageModeShared],shadow_bytes=[dev newBufferWithLength:total options:MTLResourceStorageModeShared],par=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared],out=[dev newBufferWithLength:(size_t)w*h*depth options:MTLResourceStorageModeShared];
    NSError *e=nil; id<MTLLibrary> lib=[dev newLibraryWithSource:@(k_bc4_shadow_test) options:nil error:&e]; id<MTLFunction> vf=[lib newFunctionWithName:@"bc4_v"],ff=[lib newFunctionWithName:@"bc4_f"];
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=vf;pd.fragmentFunction=ff;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Uint;
    id<MTLRenderPipelineState> pso=lib?[dev newRenderPipelineStateWithDescriptor:pd error:&e]:nil;
    if(!shadow||!raw||!dst||!in||!shadow_bytes||!par||!out||!pso){printf("  ✗ BC4 shadow pipeline/resources: %s\n",e.localizedDescription.UTF8String);free(blocks);free(ref);return 1;}
    for(uint32_t z=0;z<depth;z++){
        uint32_t off=(uint32_t)(z*plane);memcpy(par.contents,&off,sizeof off);
        MTLRenderPassDescriptor *rpd=[MTLRenderPassDescriptor renderPassDescriptor];rpd.colorAttachments[0].texture=shadow;rpd.colorAttachments[0].loadAction=MTLLoadActionDontCare;rpd.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLRenderCommandEncoder> re=[cb renderCommandEncoderWithDescriptor:rpd];[re setRenderPipelineState:pso];[re setFragmentBuffer:in offset:0 atIndex:0];[re setFragmentBuffer:par offset:0 atIndex:1];[re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[re endEncoding];
        id<MTLBlitCommandEncoder> be=[cb blitCommandEncoder];[be copyFromTexture:shadow sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(bw,bh,1) toBuffer:shadow_bytes destinationOffset:(size_t)z*plane destinationBytesPerRow:row destinationBytesPerImage:plane];[be endEncoding];[cb commit];[cb waitUntilCompleted];
    }
    if(memcmp(blocks,shadow_bytes.contents,total)){printf("  ✗ BC4 render shadow changed raw block bytes\n");free(blocks);free(ref);return 1;}
    id<MTLCommandBuffer> cb=[q commandBuffer];id<MTLBlitCommandEncoder> be=[cb blitCommandEncoder];for(uint32_t z=0;z<depth;z++)[be copyFromBuffer:shadow_bytes sourceOffset:(size_t)z*plane sourceBytesPerRow:row sourceBytesPerImage:plane sourceSize:MTLSizeMake(bw,bh,1) toTexture:raw destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,z)];[be endEncoding];[cb commit];[cb waitUntilCompleted];
    cb=[q commandBuffer];id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];[ce setComputePipelineState:decode];[ce setBuffer:shadow_bytes offset:0 atIndex:0];for(uint32_t z=0;z<depth;z++){uint32_t pp[6]={(uint32_t)(z*plane),(uint32_t)row,w,h,z,0};id<MTLBuffer> pb=[dev newBufferWithBytes:pp length:sizeof pp options:MTLResourceStorageModeShared];[ce setBuffer:pb offset:0 atIndex:1];[ce setTexture:dst atIndex:0];[ce dispatchThreadgroups:MTLSizeMake((bw+7)/8,(bh+7)/8,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];}[ce endEncoding];[cb commit];[cb waitUntilCompleted];
    cb=[q commandBuffer];be=[cb blitCommandEncoder];[be copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,depth) toBuffer:out destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:(size_t)w*h];[be endEncoding];[cb commit];[cb waitUntilCompleted];
    size_t mismatch=0;for(size_t i=0;i<(size_t)w*h*depth;i++) mismatch+=((uint8_t*)out.contents)[i]!=ref[i];free(blocks);free(ref);
    if(mismatch){printf("  ✗ BC4 rendered shadow→raw copy→decode differs at %zu/%u pixels\n",mismatch,w*h*depth);return 1;}
    printf("BC4 render shadow → raw 3D block copy → decode: exact CPU parity (%ux%ux%u)\n",w,h,depth);return 0;
}
static const char k_rd[] = "#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void rd(texture2d<float> t [[texture(0)]], device uchar4 *o [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
"  if (g.x >= t.get_width() || g.y >= t.get_height()) return; o[g.y * t.get_width() + g.x] = uchar4(round(t.read(g) * 255.0)); }\n";

static const char k_compare_srgb[] = "#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void cmp(texture2d<float, access::sample> a [[texture(0)]], texture2d<float, access::sample> b [[texture(1)]], device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
"  constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest); float2 uv=(float2(p)+0.5f)/float2(a.get_width(),a.get_height()); uint i=p.y*a.get_width()+p.x; o[i*2]=a.sample(s,uv); o[i*2+1]=b.sample(s,uv); }\n";

static int compare_real_bc1_astc(id<MTLDevice> dev, id<MTLCommandQueue> q, const char *bc_path, const char *astc_path, uint32_t w, uint32_t h) {
    uint32_t bx=(w+3)/4, by=(h+3)/4; size_t bc_pitch=(size_t)bx*8, astc_pitch=(size_t)bx*16, bc_n=bc_pitch*by, astc_n=astc_pitch*by, pixels=(size_t)w*h;
    uint8_t *bc=malloc(bc_n), *astc=malloc(astc_n); if(!bc||!astc){free(bc);free(astc);fprintf(stderr,"compare: allocation failed\n");return 1;}
    FILE *f=fopen(bc_path,"rb"); if(!f||fread(bc,1,bc_n,f)!=bc_n||fgetc(f)!=EOF){if(f)fclose(f);free(bc);free(astc);fprintf(stderr,"compare: invalid BC input %s (expected %zu bytes)\n",bc_path,bc_n);return 1;} fclose(f);
    f=fopen(astc_path,"rb"); if(!f||fread(astc,1,astc_n,f)!=astc_n||fgetc(f)!=EOF){if(f)fclose(f);free(bc);free(astc);fprintf(stderr,"compare: invalid ASTC input %s (expected %zu bytes)\n",astc_path,astc_n);return 1;} fclose(f);
    MTLTextureDescriptor *bd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC1_RGBA_sRGB width:w height:h mipmapped:NO]; bd.storageMode=MTLStorageModeShared; bd.usage=MTLTextureUsageShaderRead;
    MTLTextureDescriptor *ad=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_sRGB width:w height:h mipmapped:NO]; ad.storageMode=MTLStorageModeShared; ad.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> bt=[dev newTextureWithDescriptor:bd], at=[dev newTextureWithDescriptor:ad]; id<MTLBuffer> out=[dev newBufferWithLength:pixels*2*sizeof(float)*4 options:MTLResourceStorageModeShared]; NSError *e=nil;
    id<MTLLibrary> lib=[dev newLibraryWithSource:@(k_compare_srgb) options:nil error:&e]; id<MTLComputePipelineState> ps=lib?[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cmp"] error:&e]:nil;
    if(!bt||!at||!out||!ps){fprintf(stderr,"compare: Metal resources unavailable: %s\n",e.localizedDescription.UTF8String? : "texture creation failed");free(bc);free(astc);return 1;}
    [bt replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:bc bytesPerRow:bc_pitch]; [at replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:astc bytesPerRow:astc_pitch];
    id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder]; [ce setComputePipelineState:ps]; [ce setTexture:bt atIndex:0]; [ce setTexture:at atIndex:1]; [ce setBuffer:out offset:0 atIndex:0]; [ce dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const float *v=out.contents; double sum=0; float maxerr=0; size_t over1=0,over3=0,alpha=0;
    for(size_t i=0;i<pixels;i++){float d=0;for(int c=0;c<3;c++){float x=fabsf(v[i*8+c]-v[i*8+4+c]);if(x>d)d=x;}sum+=d;if(d>maxerr)maxerr=d;if(d>1.0f/255.0f)over1++;if(d>3.0f/255.0f)over3++;alpha+=fabsf(v[i*8+3]-v[i*8+7])>0.5f;}
    printf("real BC1 sRGB vs ASTC sRGB sample %ux%u: max %.6f (%0.2f/255), mean %.6f (%zu >1/255, %zu >3/255), alpha mismatches %zu\n",w,h,maxerr,maxerr*255.0f,sum/pixels,over1,over3,alpha);
    free(bc);free(astc);return 0;
}

int main(int argc, const char **argv) { @autoreleasepool {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue]; NSError *e = nil;
    if (argc == 6 && !strcmp(argv[1], "--compare-bc1-srgb")) { uint32_t w=(uint32_t)strtoul(argv[4],NULL,10),h=(uint32_t)strtoul(argv[5],NULL,10); if(!w||!h||!dev||!q)return 2; return compare_real_bc1_astc(dev,q,argv[2],argv[3],w,h); }
    id<MTLLibrary> l1 = [dev newLibraryWithSource:@(k_bcastc_msl) options:nil error:&e]; if (!l1) { printf("kernel: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLComputePipelineState> p1 = [dev newComputePipelineStateWithFunction:[l1 newFunctionWithName:@"bc1a"] error:&e];
    id<MTLLibrary> l2 = [dev newLibraryWithSource:@(k_rd) options:nil error:&e];
    id<MTLComputePipelineState> p2 = [dev newComputePipelineStateWithFunction:[l2 newFunctionWithName:@"rd"] error:&e];
    size_t lut_size = 0; const uint8_t *lut_data = nvn_bc1_astc_quint_lut(&lut_size); id<MTLBuffer> lut = [dev newBufferWithBytes:lut_data length:lut_size options:MTLResourceStorageModeShared];
    int fails = test_bc7_cpu_vs_metal(dev,q);
    {   // Decode raw BC4 blocks written by a render target into the no-BC 3D R8 representation.
        const uint32_t w = 19, h = 17, depth = 3, nbx = (w + 3) / 4, nby = (h + 3) / 4;
        const size_t pitch = nbx * 8, plane = pitch * nby, bytes = plane * depth;
        uint8_t *bc = malloc(bytes), *ref = malloc((size_t)w * h * depth), *got = malloc((size_t)w * h * depth);
        for (size_t i = 0; i < bytes; i++) bc[i] = (uint8_t)rnd();
        for (uint32_t z = 0; z < depth; z++) {
            uint8_t *b = bc + z * plane;
            b[0] = (uint8_t)(40 + z); b[1] = (uint8_t)(210 - z); // six interpolants
            b[8] = (uint8_t)(210 - z); b[9] = (uint8_t)(40 + z); // four interpolants plus 0 and 255
        }
        for (uint32_t z = 0; z < depth; z++) if (nvn_bc_decode(0x49, bc + z * plane, pitch, w, h, ref + (size_t)z * w * h, w)) { printf("  ✗ BC4 CPU reference decode failed at slice %u\n", z); fails++; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:w height:h * depth mipmapped:NO];
        td.textureType = MTLTextureType3D; td.depth = depth; td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Uint width:nbx height:nby mipmapped:NO];
        rd.textureType = MTLTextureType3D; rd.depth = depth; rd.storageMode = MTLStorageModePrivate; rd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> raw = [dev newTextureWithDescriptor:rd]; id<MTLBuffer> initial = [dev newBufferWithBytes:bc length:bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> src = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(k_bc4rt_msl) options:nil error:&e];
        id<MTLComputePipelineState> p = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bc4rt"] error:&e] : nil;
        if (!p) { printf("  ✗ BC4 render-target decoder compile: %s\n", e.localizedDescription.UTF8String); fails++; }
        else {
            id<MTLCommandBuffer> copycb = [q commandBuffer]; id<MTLBlitCommandEncoder> copybe = [copycb blitCommandEncoder];
            for (uint32_t z = 0; z < depth; z++) [copybe copyFromBuffer:initial sourceOffset:(size_t)z * plane sourceBytesPerRow:pitch sourceBytesPerImage:plane sourceSize:MTLSizeMake(nbx, nby, 1) toTexture:raw destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, z)];
            [copybe endEncoding]; [copycb commit]; [copycb waitUntilCompleted];
            copycb = [q commandBuffer]; copybe = [copycb blitCommandEncoder];
            for (uint32_t z = 0; z < depth; z++) [copybe copyFromTexture:raw sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, z) sourceSize:MTLSizeMake(nbx, nby, 1) toBuffer:src destinationOffset:(size_t)z * plane destinationBytesPerRow:pitch destinationBytesPerImage:plane];
            [copybe endEncoding]; [copycb commit]; [copycb waitUntilCompleted];
            if (memcmp(src.contents, bc, bytes)) { printf("  ✗ BC4 raw 3D RGBA16UI → block-buffer copy changed bytes\n"); fails++; }
            id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:p]; [ce setBuffer:src offset:0 atIndex:0];
            for (uint32_t z = 0; z < depth; z++) { uint32_t params[6] = {(uint32_t)(z * plane), (uint32_t)pitch, w, h, z, 0}; id<MTLBuffer> par = [dev newBufferWithBytes:params length:sizeof params options:MTLResourceStorageModeShared]; [ce setBuffer:par offset:0 atIndex:1]; [ce setTexture:dst atIndex:0]; [ce dispatchThreadgroups:MTLSizeMake((nbx + 7) / 8, (nby + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; }
            [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
            id<MTLBuffer> readback = [dev newBufferWithLength:(size_t)w * h * depth options:MTLResourceStorageModeShared];
            cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, depth) toBuffer:readback destinationOffset:0 destinationBytesPerRow:w destinationBytesPerImage:(size_t)w * h]; [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
            memcpy(got, readback.contents, (size_t)w * h * depth);
            size_t mismatch = 0; for (size_t i = 0; i < (size_t)w * h * depth; i++) mismatch += ref[i] != got[i];
            if (mismatch) { printf("  ✗ BC4 GPU decode differs from CPU at %zu/%zu bytes\n", mismatch, (size_t)w * h * depth); fails++; }
            else printf("BC4 render-target decode: exact CPU parity for %ux%ux%u\n", w, h, depth);
            fails += test_bc4_mips(dev, q, p);
            fails += test_bc4_shadow_roundtrip(dev, q, p);
        }
        free(bc); free(ref); free(got);
    }
    for (int mode = 0; mode < 5; mode++) {   // random risky blocks, 4-colour encoder-like blocks, odd-size risky blocks, fixed 3-colour blocks, random 3-colour endpoints/selectors
        uint32_t w = mode == 2 ? 253 : 256, h = mode == 2 ? 122 : 256, nbx = (w + 3) / 4, nby = (h + 3) / 4;
        size_t pitch = nbx * 8, apitch = nbx * 16; uint8_t *bc = malloc(pitch * nby), *astc = malloc(apitch * nby);
        for (uint32_t i = 0; i < nbx * nby; i++) { uint8_t *b = bc + (i / nbx) * pitch + (i % nbx) * 8;
            if (mode == 1) { uint32_t r = rnd() % 32, g = rnd() % 64, bl = rnd() % 32, r2 = (r + rnd() % 6) % 32, g2 = (g + rnd() % 12) % 64, b2 = (bl + rnd() % 6) % 32;
                uint32_t c0 = (r << 11) | (g << 5) | bl, c1 = (r2 << 11) | (g2 << 5) | b2; if (c0 <= c1) { if (c1 < 65535) c0 = c1 + 1; else c1 = c0 - 1; }
                b[0] = c0; b[1] = c0 >> 8; b[2] = c1; b[3] = c1 >> 8; for (int k = 4; k < 8; k++) b[k] = rnd(); }
            else if (mode == 3 || mode == 4) { uint32_t c0, c1, ix = 0;
                if (mode == 3) { c0 = 0; c1 = 65535; }
                else { c0 = rnd() & 65535; c1 = rnd() & 65535; if (c0 > c1) { uint32_t tmp = c0; c0 = c1; c1 = tmp; } }
                b[0] = c0; b[1] = c0 >> 8; b[2] = c1; b[3] = c1 >> 8;
                for (int k = 0; k < 16; k++) ix |= (uint32_t)(mode == 3 ? k % 3 : rnd() % 3) << (2 * k); b[4] = ix; b[5] = ix >> 8; b[6] = ix >> 16; b[7] = ix >> 24; }
            else for (int k = 0; k < 8; k++) b[k] = rnd(); }
        int safe = nvn_bc1_astc_safe(bc, pitch, w, h);
        int expected_safe = mode == 1 || mode == 3 || mode == 4;
        if (expected_safe != safe) { printf("  ✗ mode %d: classifier returned %d for %s input\n", mode, safe, expected_safe ? "ASTC-safe" : "RGBA8-fallback"); fails++; }
        if (!safe) { printf("mode %d %ux%u: classifier requires lossless RGBA8 fallback\n", mode, w, h); free(bc); free(astc); continue; }
        size_t lossy = nvn_bc1_astc(bc, pitch, w, h, astc, apitch);
        // The kernel: BC1 blocks at offset 0, ASTC blocks after them
        size_t off2 = (pitch * nby + 255) & ~(size_t)255; id<MTLBuffer> buf = [dev newBufferWithLength:off2 + apitch * nby options:MTLResourceStorageModeShared]; memcpy(buf.contents, bc, pitch * nby); memset((uint8_t *)buf.contents + off2, 0xCD, apitch * nby);
        uint32_t pr[7] = {0, (uint32_t)pitch, w, h, 1, (uint32_t)off2, (uint32_t)apitch}; id<MTLBuffer> par = [dev newBufferWithBytes:pr length:sizeof pr options:MTLResourceStorageModeShared];
        id<MTLBuffer> cnt = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(cnt.contents, 0, 16);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_LDR width:w height:h mipmapped:NO]; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td]; id<MTLBuffer> out = [dev newBufferWithLength:(size_t)w * h * 4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:p1]; [ce setBuffer:buf offset:0 atIndex:0]; [ce setBuffer:par offset:0 atIndex:1]; [ce setBuffer:cnt offset:0 atIndex:2]; [ce setBuffer:lut offset:0 atIndex:3]; [ce dispatchThreadgroups:MTLSizeMake((nbx + 7) / 8, (nby + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [ce endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (*(uint32_t *)cnt.contents != lossy) { printf("  ✗ mode %d: the kernel counted %u lossy blocks, the C function %zu\n", mode, *(uint32_t *)cnt.contents, lossy); fails++; }
        int kdiff = memcmp((uint8_t *)buf.contents + off2, astc, apitch * nby) != 0; if (kdiff) { printf("  ✗ mode %d: the kernel's blocks differ from the C function's\n", mode); fails++; }
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:astc bytesPerRow:apitch];
        cb = [q commandBuffer]; ce = [cb computeCommandEncoder]; [ce setComputePipelineState:p2]; [ce setTexture:tex atIndex:0]; [ce setBuffer:out offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
        uint8_t *ref = malloc((size_t)w * h * 4); nvn_bc_decode(0x41, bc, pitch, w, h, ref, (size_t)w * 4);
        const uint8_t *got = out.contents; int max4 = 0, max3 = 0; size_t n4 = 0, n3 = 0, ntr = 0, hist[4] = {0}, big = 0, big3 = 0, bad_alpha = 0;
        for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
            const uint8_t *b = bc + (y / 4) * pitch + (x / 4) * 8; unsigned c0 = b[0] | (b[1] << 8), c1 = b[2] | (b[3] << 8); uint32_t ix = b[4] | (b[5] << 8) | (b[6] << 16) | ((uint32_t)b[7] << 24);
            int four = c0 > c1, ix3 = !four && ((ix >> (2 * ((y & 3) * 4 + (x & 3)))) & 3) == 3; const uint8_t *r = ref + ((size_t)y * w + x) * 4, *g = got + ((size_t)y * w + x) * 4;
            if (ix3) ntr++;
            if (r[3] != g[3]) bad_alpha++;
            int d = 0; for (int k = 0; k < 3; k++) { int a = abs((int)r[k] - (int)g[k]); if (a > d) d = a; }
            if (four) { n4++; if (d > max4) max4 = d; hist[d > 3 ? 3 : d]++; if (d > 2) big++; } else { n3++; if (d > max3) max3 = d; if (d > 2) big3++; }
        }
        if (mode == 1 || mode == 4) {   // BC1 sRGB must decode to the same linear shader values as an sRGB BC texture.
            MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatASTC_4x4_sRGB width:w height:h mipmapped:NO]; sd.storageMode = MTLStorageModeShared;
            id<MTLTexture> srgb = [dev newTextureWithDescriptor:sd]; id<MTLBuffer> sout = [dev newBufferWithLength:(size_t)w*h*4 options:MTLResourceStorageModeShared];
            if (!srgb || !sout) { printf("  ✗ mode %d: sRGB ASTC resources unavailable\n", mode); fails++; }
            else {
                [srgb replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:astc bytesPerRow:apitch];
                id<MTLCommandBuffer> scb=[q commandBuffer]; id<MTLComputeCommandEncoder> sce=[scb computeCommandEncoder]; [sce setComputePipelineState:p2]; [sce setTexture:srgb atIndex:0]; [sce setBuffer:sout offset:0 atIndex:0]; [sce dispatchThreads:MTLSizeMake(w,h,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [sce endEncoding]; [scb commit]; [scb waitUntilCompleted];
                const uint8_t *soutb=sout.contents,*ldr=out.contents; int smax=0, transfer_max=0; size_t salpha=0; uint8_t *srgb_ref=malloc((size_t)w*h*4); nvn_bc_decode(0x41,bc,pitch,w,h,srgb_ref,(size_t)w*4);
                for(size_t i=0;i<(size_t)w*h;i++){ for(int c=0;c<3;c++){ double v=srgb_ref[i*4+c]/255.0, lin=v<=0.04045?v/12.92:pow((v+0.055)/1.055,2.4); int e=abs((int)soutb[i*4+c]-(int)lrint(lin*255.0)); if(e>smax)smax=e; v=ldr[i*4+c]/255.0; lin=v<=0.04045?v/12.92:pow((v+0.055)/1.055,2.4); e=abs((int)soutb[i*4+c]-(int)lrint(lin*255.0)); if(e>transfer_max)transfer_max=e; } salpha += soutb[i*4+3]!=255; }
                printf("mode %d ASTC sRGB sample: max error vs BC1 linear %d; max error vs LDR sample transfer %d; alpha mismatches %zu\n",mode,smax,transfer_max,salpha);
                if(smax>3||transfer_max>2||salpha) { printf("  ✗ mode %d: ASTC sRGB sampling differs from BC1 semantics\n",mode); fails++; } free(srgb_ref);
            }
        }
        printf("mode %d %ux%u: %zu blocks with a lossy index 3; 4-colour pixels %zu max error %d (error 0/1/2/>=3: %zu/%zu/%zu/%zu); 3-colour pixels %zu max error %d (%zu over 2); index-3 pixels %zu; alpha mismatches %zu\n", mode, w, h, lossy, n4, max4, hist[0], hist[1], hist[2], hist[3], n3, max3, big3, ntr, bad_alpha);
        if (big) { printf("  ✗ mode %d: %zu 4-colour pixels are off by more than 2\n", mode, big); fails++; }
        if (big3) { printf("  ✗ mode %d: %zu 3-colour pixels are off by more than 2\n", mode, big3); fails++; }
        if (bad_alpha) { printf("  ✗ mode %d: %zu pixels have the wrong alpha\n", mode, bad_alpha); fails++; }
        free(bc); free(astc); free(ref);
    }
    {   // RGB_DXT1 has opaque index 3; RGBA_DXT1 has punch-through transparent index 3.
        uint8_t bc[8] = {0, 0, 0, 0, 255, 255, 255, 255}, rgb[64], rgba[64];
        nvn_bc_decode(0x41, bc, 8, 4, 4, rgb, 16); nvn_bc_decode(0x42, bc, 8, 4, 4, rgba, 16);
        for (int i = 0; i < 16; i++) { if (rgb[i * 4 + 3] != 255 || rgba[i * 4 + 3] != 0) { printf("  ✗ BC1 format alpha semantics differ at pixel %d\n", i); fails++; break; } }
        if (nvn_bc1_astc_safe(bc, 8, 4, 4)) { printf("  ✗ BC1 selector-3 alpha fixture was classified as ASTC-safe\n"); fails++; }
        uint8_t astc[16]; if (nvn_bc1_astc_block(bc, astc) != 1) { printf("  ✗ BC1 selector-3 fixture did not request exact fallback\n"); fails++; }
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
