#!/usr/bin/env bash
# Sodium Mobile 2.1 build script (run by .github/workflows/build.yml). Downloads official Sodium 0.8.14, applies the mobile patches, builds the Fabric jar into out/.
set -eo pipefail

# ---- step 1: Download source and apply mobile patch
(
set -e
curl -fL -o src.zip https://github.com/CaffeineMC/sodium/archive/refs/tags/mc1.21.11-0.8.14.zip
unzip -q src.zip
cat > mobile.patch <<'PATCH_EOF'
diff -ruN a/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumConfigBuilder.java b/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumConfigBuilder.java
--- a/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumConfigBuilder.java	2026-09-30 09:51:54.810175340 +0000
+++ b/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumConfigBuilder.java	2026-09-30 09:51:54.919978860 +0000
@@ -632,6 +632,38 @@

         performancePage.addOptionGroup(builder.createOptionGroup()
                 .addOption(
+                        builder.createIntegerOption(Identifier.parse("sodium:performance.mobile_upload_budget"))
+                                .setStorageHandler(this.sodiumStorage)
+                                .setName(Component.translatable("sodium.options.mobile_upload_budget.name"))
+                                .setValueFormatter(ControlValueFormatterImpls.translateVariable("sodium.options.mobile_upload_budget.value"))
+                                .setTooltip(Component.translatable("sodium.options.mobile_upload_budget.tooltip"))
+                                .setRange(1, 5, 1)
+                                .setDefaultValue(DEFAULTS.performance.mobileUploadBudgetMs)
+                                .setBinding(value -> this.sodiumOpts.performance.mobileUploadBudgetMs = value, () -> this.sodiumOpts.performance.mobileUploadBudgetMs)
+                                .setImpact(OptionImpact.HIGH)
+                )
+                .addOption(
+                        builder.createBooleanOption(Identifier.parse("sodium:performance.mobile_adaptive_chunk_work"))
+                                .setStorageHandler(this.sodiumStorage)
+                                .setName(Component.translatable("sodium.options.mobile_adaptive_chunk_work.name"))
+                                .setTooltip(Component.translatable("sodium.options.mobile_adaptive_chunk_work.tooltip"))
+                                .setDefaultValue(DEFAULTS.performance.mobileAdaptiveChunkWork)
+                                .setBinding(value -> this.sodiumOpts.performance.mobileAdaptiveChunkWork = value, () -> this.sodiumOpts.performance.mobileAdaptiveChunkWork)
+                                .setImpact(OptionImpact.HIGH)
+                )
+                .addOption(
+                        builder.createBooleanOption(Identifier.parse("sodium:performance.mobile_fast_texture_sampling"))
+                                .setStorageHandler(this.sodiumStorage)
+                                .setName(Component.translatable("sodium.options.mobile_fast_texture_sampling.name"))
+                                .setTooltip(Component.translatable("sodium.options.mobile_fast_texture_sampling.tooltip"))
+                                .setDefaultValue(DEFAULTS.performance.mobileFastTextureSampling)
+                                .setBinding(value -> this.sodiumOpts.performance.mobileFastTextureSampling = value, () -> this.sodiumOpts.performance.mobileFastTextureSampling)
+                                .setImpact(OptionImpact.MEDIUM)
+                )
+        );
+
+        performancePage.addOptionGroup(builder.createOptionGroup()
+                .addOption(
                         builder.createEnumOption(Identifier.parse("sodium:performance.quad_splitting"), QuadSplittingMode.class)
                                 .setStorageHandler(this.sodiumStorage)
                                 .setName(Component.translatable("sodium.options.quad_splitting.name"))
diff -ruN a/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumOptions.java b/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumOptions.java
--- a/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumOptions.java	2026-09-30 09:51:54.810254796 +0000
+++ b/common/src/main/java/net/caffeinemc/mods/sodium/client/gui/SodiumOptions.java	2026-09-30 09:51:54.907672070 +0000
@@ -54,6 +54,13 @@
         public boolean useNoErrorGLContext = true;

         public QuadSplittingMode quadSplittingMode = QuadSplittingMode.SAFE;
+
+        // Sodium Mobile: minimum per-frame time budget (ms) for uploading chunk meshes to the GPU
+        public int mobileUploadBudgetMs = 2;
+        // Sodium Mobile: temporarily reduce chunk work after frame-time spikes
+        public boolean mobileAdaptiveChunkWork = true;
+        // Sodium Mobile: cheaper terrain texture sampling (slightly different look at a distance)
+        public boolean mobileFastTextureSampling = false;
     }

     public static class AdvancedSettings {
diff -ruN a/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/RenderSectionManager.java b/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/RenderSectionManager.java
--- a/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/RenderSectionManager.java	2026-09-30 09:51:54.812612870 +0000
+++ b/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/RenderSectionManager.java	2026-09-30 09:51:54.917836444 +0000
@@ -67,7 +67,14 @@
     private static final float NEARBY_SORT_DISTANCE = Mth.square(25.0f);

     private static final float FRAME_DURATION_UPLOAD_FRACTION = 0.1f;
-    private static final long MIN_UPLOAD_DURATION_BUDGET = 2_000_000L; // 2ms
+
+    // Sodium Mobile: adaptive chunk work. A frame longer than SPIKE_RATIO times the running average lowers
+    // mobileWorkFactor (scales the chunk build and upload budgets); it then recovers slowly so the budget
+    // does not oscillate. Helps weak mobile CPUs where one slow frame would otherwise be followed by more of the same.
+    private static final float MOBILE_SPIKE_RATIO = 1.6f;
+    private static final float MOBILE_SPIKE_DECAY = 0.8f;
+    private static final float MOBILE_RECOVERY_PER_FRAME = 0.01f;
+    private static final float MOBILE_MIN_WORK_FACTOR = 0.3f;

     private final ChunkBuilder builder;

@@ -109,6 +116,7 @@
     private int frame;
     private long lastFrameDuration = -1;
     private long averageFrameDuration = -1;
+    private float mobileWorkFactor = 1.0f;
     private long lastFrameAtTime = System.nanoTime();
     private static final float FRAME_DURATION_UPDATE_RATIO = 0.05f;

@@ -162,6 +170,16 @@
         }
         this.averageFrameDuration = Mth.clamp(this.averageFrameDuration, 1_000_100, 100_000_000);

+        if (SodiumClientMod.options().performance.mobileAdaptiveChunkWork) {
+            if (this.lastFrameDuration > this.averageFrameDuration * MOBILE_SPIKE_RATIO) {
+                this.mobileWorkFactor = Math.max(MOBILE_MIN_WORK_FACTOR, this.mobileWorkFactor * MOBILE_SPIKE_DECAY);
+            } else {
+                this.mobileWorkFactor = Math.min(1.0f, this.mobileWorkFactor + MOBILE_RECOVERY_PER_FRAME);
+            }
+        } else {
+            this.mobileWorkFactor = 1.0f;
+        }
+
         this.frame += 1;

         this.cameraPosition = cameraPosition;
diff -ruN a/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/shader/DefaultShaderInterface.java b/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/shader/DefaultShaderInterface.java
--- a/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/shader/DefaultShaderInterface.java	2026-09-30 09:51:54.814996702 +0000
+++ b/common/src/main/java/net/caffeinemc/mods/sodium/client/render/chunk/shader/DefaultShaderInterface.java	2026-09-30 09:51:54.919331656 +0000
@@ -7,6 +7,7 @@
 import com.mojang.blaze3d.textures.FilterMode;
 import com.mojang.blaze3d.textures.GpuSampler;
 import com.mojang.blaze3d.textures.GpuTextureView;
+import net.caffeinemc.mods.sodium.client.SodiumClientMod;
 import net.caffeinemc.mods.sodium.client.gl.buffer.GlBuffer;
 import net.caffeinemc.mods.sodium.client.gl.device.GLRenderDevice;
 import net.caffeinemc.mods.sodium.client.gl.shader.uniform.*;
@@ -36,6 +37,7 @@
     private final GlUniformFloat2v uniformTexCoordShrink;
     private final GlUniformFloat2v uniformTexelSize;
     private final GlUniformBool uniformRGSS;
+    private final GlUniformBool uniformFastSampling;
     private final GlUniformInt uniformCurrentTime;
     private final GlUniformFloat uniformFadePeriod;

@@ -51,6 +53,7 @@
         this.uniformTexCoordShrink = context.bindUniform("u_TexCoordShrink", GlUniformFloat2v::new);
         this.uniformTexelSize = context.bindUniform("u_TexelSize", GlUniformFloat2v::new);
         this.uniformRGSS = context.bindUniform("u_UseRGSS", GlUniformBool::new);
+        this.uniformFastSampling = context.bindUniform("u_FastSampling", GlUniformBool::new);

         this.uniformCurrentTime = context.bindUniform("u_CurrentTime", GlUniformInt::new);
         this.uniformFadePeriod = context.bindUniform("u_FadePeriodInv", GlUniformFloat::new);
@@ -92,6 +95,7 @@
         this.uniformFadePeriod.setFloat((float) (1.0 / (Minecraft.getInstance().options.chunkSectionFadeInTime().get() * 1000.0))); // this is in seconds!

         this.uniformRGSS.setBool(Minecraft.getInstance().options.textureFiltering().get() == TextureFilteringMethod.RGSS);
+        this.uniformFastSampling.setBool(SodiumClientMod.options().performance.mobileFastTextureSampling);

         this.fogShader.setup(parameters);
     }
diff -ruN a/common/src/main/resources/assets/sodium/lang/en_us.json b/common/src/main/resources/assets/sodium/lang/en_us.json
--- a/common/src/main/resources/assets/sodium/lang/en_us.json	2026-09-30 09:51:54.826113872 +0000
+++ b/common/src/main/resources/assets/sodium/lang/en_us.json	2026-09-30 09:51:54.920172052 +0000
@@ -46,6 +46,13 @@
   "sodium.options.use_entity_culling.tooltip": "If enabled, entities which are within the camera viewport, but not inside of a visible chunk, will be skipped during rendering. This optimization uses the visibility data which already exists for chunk rendering and does not add overhead.",
   "sodium.options.animate_only_visible_textures.name": "Animate Only Visible Textures",
   "sodium.options.animate_only_visible_textures.tooltip": "If enabled, only the animated textures which are determined to be visible in the current image will be updated. This can provide a significant performance improvement on some hardware, especially with heavier resource packs. If you experience issues with some textures not being animated, try disabling this option.",
+  "sodium.options.mobile_upload_budget.name": "Mobile: Chunk Upload Budget",
+  "sodium.options.mobile_upload_budget.tooltip": "Minimum time per frame spent sending new chunk meshes to the GPU. Lower values reduce stutter while moving, but new chunks appear a little later.",
+  "sodium.options.mobile_upload_budget.value": "%s ms",
+  "sodium.options.mobile_adaptive_chunk_work.name": "Mobile: Adaptive Chunk Work",
+  "sodium.options.mobile_adaptive_chunk_work.tooltip": "Temporarily reduces background chunk building and uploading after a slow frame, then restores it gradually. Helps keep frame times steady on weak devices.",
+  "sodium.options.mobile_fast_texture_sampling.name": "Mobile: Fast Texture Sampling",
+  "sodium.options.mobile_fast_texture_sampling.tooltip": "Uses a single plain texture lookup per pixel for terrain instead of Sodium's sharpened sampling. Cheaper on the GPU, but distant blocks look slightly different.",
   "sodium.options.cpu_render_ahead_limit.name": "CPU Render-Ahead Limit",
   "sodium.options.cpu_render_ahead_limit.tooltip": "For debugging only. Specifies the maximum number of frames which can be in-flight to the GPU. Changing this value is not recommended, as very low or high values may create frame rate instability.",
   "sodium.options.cpu_render_ahead_limit.value": "%s frame(s)",
diff -ruN a/common/src/main/resources/assets/sodium/shaders/blocks/block_layer_opaque.fsh b/common/src/main/resources/assets/sodium/shaders/blocks/block_layer_opaque.fsh
--- a/common/src/main/resources/assets/sodium/shaders/blocks/block_layer_opaque.fsh	2026-09-30 09:51:54.826196839 +0000
+++ b/common/src/main/resources/assets/sodium/shaders/blocks/block_layer_opaque.fsh	2026-09-30 09:51:54.919743402 +0000
@@ -17,6 +17,8 @@
 uniform vec2 u_RenderFog; // The start and end position for border fog
 uniform vec2 u_TexelSize;
 uniform bool u_UseRGSS;
+// Sodium Mobile: skip the derivative-based sharpening and use one plain texture lookup per pixel
+uniform bool u_FastSampling;

 out vec4 fragColor; // The output fragment for the color framebuffer

@@ -84,7 +86,8 @@
 }

 void main() {
-    vec4 color = u_UseRGSS ? sampleRGSS(u_BlockTex, v_TexCoord, u_TexelSize) : sampleNearest(u_BlockTex, v_TexCoord, u_TexelSize);
+    vec4 color = u_FastSampling ? texture(u_BlockTex, v_TexCoord)
+            : (u_UseRGSS ? sampleRGSS(u_BlockTex, v_TexCoord, u_TexelSize) : sampleNearest(u_BlockTex, v_TexCoord, u_TexelSize));
     color *= v_Color; // Apply per-vertex color modulator

 #ifdef USE_FRAGMENT_DISCARD
PATCH_EOF
cd sodium-mc1.21.11-0.8.14
git apply -p1 --whitespace=nowarn ../mobile.patch
)

# ---- step 2: Apply far chunk culling and far texture detail
(
set -e
cd sodium-mc1.21.11-0.8.14
python3 - <<'PY_EOF'
import re, sys, os

BASE = "common/src/main"
JAVA = BASE + "/java/net/caffeinemc/mods/sodium/client/"
P_OPTS = JAVA + "gui/SodiumOptions.java"
P_CFG = JAVA + "gui/SodiumConfigBuilder.java"
P_RSM = JAVA + "render/chunk/RenderSectionManager.java"
P_DSI = JAVA + "render/chunk/shader/DefaultShaderInterface.java"
P_LANG = BASE + "/resources/assets/sodium/lang/en_us.json"
P_FSH = BASE + "/resources/assets/sodium/shaders/blocks/block_layer_opaque.fsh"

applied = []


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def wr(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


class Skip(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Skip(msg)


def insert_after(s, anchor, text, what):
    need(s.count(anchor) == 1, what + ": anchor not found exactly once")
    i = s.index(anchor) + len(anchor)
    return s[:i] + text + s[i:]


def option_block(ident, name, formatter, tip, lo, hi, step, field, impact):
    return (
        "\n                .addOption(\n"
        "                        builder.createIntegerOption(Identifier.parse(\"sodium:performance.%s\"))\n"
        "                                .setStorageHandler(this.sodiumStorage)\n"
        "                                .setName(Component.translatable(\"sodium.options.%s.name\"))\n"
        "                                .setValueFormatter(ControlValueFormatterImpls.translateVariable(\"sodium.options.%s.value\"))\n"
        "                                .setTooltip(Component.translatable(\"sodium.options.%s.tooltip\"))\n"
        "                                .setRange(%d, %d, %d)\n"
        "                                .setDefaultValue(DEFAULTS.performance.%s)\n"
        "                                .setBinding(value -> this.sodiumOpts.performance.%s = value, () -> this.sodiumOpts.performance.%s)\n"
        "                                .setImpact(OptionImpact.%s)\n"
        "                )"
    ) % (ident, ident, ident, ident, lo, hi, step, field, field, field, impact)


def lang_lines(items):
    out = ""
    for k, v in items:
        out += '  "%s": "%s",\n' % (k, v)
    return out


def add_options(s_opts, s_cfg, s_lang, fields, blocks, lang):
    s_opts = insert_after(
        s_opts,
        "public boolean mobileFastTextureSampling = false;\n",
        fields,
        "SodiumOptions",
    )
    marker = "sodium:performance.mobile_fast_texture_sampling"
    need(s_cfg.count(marker) == 1, "SodiumConfigBuilder: marker not found")
    start = s_cfg.index(marker)
    end = s_cfg.find("\n        );", start)
    need(end > 0, "SodiumConfigBuilder: end of option group not found")
    s_cfg = s_cfg[:end] + blocks + s_cfg[end:]
    m = re.search(r'^[ \t]*"sodium\.options\.mobile_fast_texture_sampling\.tooltip".*\n', s_lang, re.M)
    need(m is not None, "en_us.json: anchor not found")
    s_lang = s_lang[: m.end()] + lang + s_lang[m.end():]
    return s_opts, s_cfg, s_lang


# ---------------------------------------------------------------- culling
def feature_cull():
    s_opts, s_cfg, s_lang, s_rsm = rd(P_OPTS), rd(P_CFG), rd(P_LANG), rd(P_RSM)

    fields = (
        "        // Sodium Mobile: stop drawing terrain beyond this % of the render distance (100 = off)\n"
        "        public int mobileFarCullPercent = 100;\n"
    )
    blocks = option_block(
        "mobile_far_cull", "", "", "", 50, 100, 5, "mobileFarCullPercent", "HIGH"
    )
    lang = lang_lines([
        ("sodium.options.mobile_far_cull.name", "Mobile: Far Chunk Culling"),
        ("sodium.options.mobile_far_cull.tooltip",
         "Stops drawing (and building) terrain beyond this percentage of your render distance. Lower values give more FPS, but if you go below the fog distance a visible edge can appear. 100% is off."),
        ("sodium.options.mobile_far_cull.value", "%s%%"),
    ])
    s_opts, s_cfg, s_lang = add_options(s_opts, s_cfg, s_lang, fields, blocks, lang)

    # scale the visibility search distance
    pat = re.compile(r"((?:final\s+)?(?:var|float)\s+searchDistance\s*=\s*)([^;]+);")
    ms = pat.findall(s_rsm)
    need(len(ms) == 1, "RenderSectionManager: searchDistance assignment found %d times" % len(ms))
    s_rsm = pat.sub(lambda m: m.group(1) + "mobileCullDistance(" + m.group(2) + ");", s_rsm, count=1)
    need("SodiumClientMod" in s_rsm, "RenderSectionManager: SodiumClientMod not available")
    last = s_rsm.rstrip().rfind("}")
    need(last > 0, "RenderSectionManager: class end not found")
    method = (
        "\n    // Sodium Mobile: far chunk culling. Shrinks the visibility search distance to a percentage of the\n"
        "    // render distance. Never goes below 64 blocks, and 100% leaves vanilla behaviour untouched.\n"
        "    private static float mobileCullDistance(float distance) {\n"
        "        int percent = SodiumClientMod.options().performance.mobileFarCullPercent;\n"
        "        if (percent >= 100) {\n"
        "            return distance;\n"
        "        }\n"
        "        return Math.min(distance, Math.max(distance * (percent / 100.0f), 64.0f));\n"
        "    }\n"
    )
    s_rsm = s_rsm[:last] + method + s_rsm[last:]
    wr(P_OPTS, s_opts); wr(P_CFG, s_cfg); wr(P_LANG, s_lang); wr(P_RSM, s_rsm)


# ---------------------------------------------------------------- far texture lod
def feature_lod():
    s_opts, s_cfg, s_lang, s_dsi, s_fsh = rd(P_OPTS), rd(P_CFG), rd(P_LANG), rd(P_DSI), rd(P_FSH)

    fields = (
        "        // Sodium Mobile: extra mip levels for distant terrain (0 = off, 1 = 8x8, 2 = 4x4) and where they start\n"
        "        public int mobileFarLodLevel = 0;\n"
        "        public int mobileFarLodStartChunks = 8;\n"
    )
    blocks = (
        option_block("mobile_far_lod_level", "", "", "", 0, 2, 1, "mobileFarLodLevel", "MEDIUM")
        + option_block("mobile_far_lod_start", "", "", "", 2, 32, 1, "mobileFarLodStartChunks", "MEDIUM")
    )
    lang = lang_lines([
        ("sodium.options.mobile_far_lod_level.name", "Mobile: Far Texture Detail"),
        ("sodium.options.mobile_far_lod_level.tooltip",
         "Distant terrain uses smaller versions of block textures (level 1 = 8x8, level 2 = 4x4), which is cheaper for the GPU. Needs Mipmap Levels of 2 or higher in Video Settings. 0 is off."),
        ("sodium.options.mobile_far_lod_level.value", "Level %s"),
        ("sodium.options.mobile_far_lod_start.name", "Mobile: Far Texture Start"),
        ("sodium.options.mobile_far_lod_start.tooltip",
         "How many chunks away from you the smaller textures begin to blend in."),
        ("sodium.options.mobile_far_lod_start.value", "%s chunks"),
    ])
    s_opts, s_cfg, s_lang = add_options(s_opts, s_cfg, s_lang, fields, blocks, lang)

    # java: uniform
    s_dsi = insert_after(
        s_dsi, "    private final GlUniformBool uniformFastSampling;\n",
        "    private final GlUniformFloat2v uniformFarLod;\n", "DefaultShaderInterface field")
    s_dsi = insert_after(
        s_dsi, '        this.uniformFastSampling = context.bindUniform("u_FastSampling", GlUniformBool::new);\n',
        '        this.uniformFarLod = context.bindUniform("u_FarLod", GlUniformFloat2v::new);\n',
        "DefaultShaderInterface bind")
    s_dsi = insert_after(
        s_dsi,
        "        this.uniformFastSampling.setBool(SodiumClientMod.options().performance.mobileFastTextureSampling);\n",
        "        this.uniformFarLod.set(new float[] {\n"
        "                SodiumClientMod.options().performance.mobileFarLodStartChunks * 16.0f,\n"
        "                (float) SodiumClientMod.options().performance.mobileFarLodLevel\n"
        "        });\n",
        "DefaultShaderInterface set")

    # shader
    need("v_FragDistance" in s_fsh, "fsh: v_FragDistance missing")
    need(s_fsh.count("uniform bool u_FastSampling;\n") == 1, "fsh: u_FastSampling anchor")
    need(s_fsh.count("texture(u_BlockTex, v_TexCoord)") == 1, "fsh: fast sampling call")
    need(s_fsh.count("void main() {\n") == 1, "fsh: main anchor")
    nx, ny = s_fsh.count("dFdx(uv)"), s_fsh.count("dFdy(uv)")
    need(nx >= 1 and ny >= 1, "fsh: derivative anchors")

    s_fsh = s_fsh.replace("dFdx(uv)", "(dFdx(uv) * g_LodScale)").replace("dFdy(uv)", "(dFdy(uv) * g_LodScale)")
    s_fsh = s_fsh.replace("texture(u_BlockTex, v_TexCoord)", "texture(u_BlockTex, v_TexCoord, g_LodBias)")
    s_fsh = s_fsh.replace(
        "uniform bool u_FastSampling;\n",
        "uniform bool u_FastSampling;\n"
        "// Sodium Mobile: distant terrain uses smaller mip levels. x = start distance (blocks), y = extra mip levels (0 = off)\n"
        "uniform vec2 u_FarLod;\n"
        "float g_LodBias = 0.0;\n"
        "float g_LodScale = 1.0;\n", 1)
    s_fsh = s_fsh.replace(
        "void main() {\n",
        "void main() {\n"
        "    if (u_FarLod.y > 0.0) {\n"
        "        float farLevels = u_FarLod.y;\n"
        "        float farDistance = 0.0;\n"
        "#ifdef USE_FOG\n"
        "        farDistance = v_FragDistance.x;\n"
        "#endif\n"
        "#ifdef USE_FRAGMENT_DISCARD\n"
        "        farLevels = min(farLevels, 1.0); // keep cutout edges (leaves, glass) readable\n"
        "#endif\n"
        "        g_LodBias = clamp((farDistance - u_FarLod.x) * (1.0 / 32.0), 0.0, 1.0) * farLevels;\n"
        "        g_LodScale = exp2(g_LodBias);\n"
        "    }\n", 1)
    wr(P_OPTS, s_opts); wr(P_CFG, s_cfg); wr(P_LANG, s_lang); wr(P_DSI, s_dsi); wr(P_FSH, s_fsh)


# ---------------------------------------------------------------- core: work factor applied to build/upload budgets
def feature_core():
    s_rsm = rd(P_RSM)
    pat_rem = re.compile(r"(\w+)(\s+remainingDuration\s*=\s*)(this\.builder\.getTotalRemainingDuration\(this\.averageFrameDuration\))\s*;")
    pat_up = re.compile(r"Math\.max\(\s*\(long\)\s*\(\s*this\.averageFrameDuration\s*\*\s*FRAME_DURATION_UPLOAD_FRACTION\s*\)\s*,\s*MIN_UPLOAD_DURATION_BUDGET\s*\)")
    if len(pat_rem.findall(s_rsm)) != 1 or len(pat_up.findall(s_rsm)) != 1:
        # keep the build compiling: hunk 1 of the patch removed this constant
        if "MIN_UPLOAD_DURATION_BUDGET =" not in s_rsm:
            s_rsm = insert_after(
                s_rsm, "private static final float MOBILE_MIN_WORK_FACTOR = 0.3f;\n",
                "    private static final long MIN_UPLOAD_DURATION_BUDGET = 2_000_000L;\n", "RSM constant fallback")
            wr(P_RSM, s_rsm)
        need(False, "RenderSectionManager: build/upload budget lines not found (slider + adaptive work will have no effect)")
    s_rsm = pat_rem.sub(
        lambda m: "long" + m.group(2) + "(long) (" + m.group(3) + " * this.mobileWorkFactor);", s_rsm, count=1)
    s_rsm = pat_up.sub(
        "Math.max((long) (this.averageFrameDuration * FRAME_DURATION_UPLOAD_FRACTION * this.mobileWorkFactor),\n"
        "                                (long) (SodiumClientMod.options().performance.mobileUploadBudgetMs * 1_000_000L * this.mobileWorkFactor))",
        s_rsm, count=1)
    wr(P_RSM, s_rsm)


for name, fn in (("core", feature_core), ("cull", feature_cull), ("lod", feature_lod)):
    try:
        fn()
        applied.append(name)
        print("APPLIED:", name)
    except Skip as e:
        print("::warning::Sodium Mobile feature '%s' SKIPPED: %s" % (name, e))
        print("SKIPPED:", name, "-", e)

with open("../applied.txt", "w") as f:
    f.write("-".join(applied))
PY_EOF
echo "Features applied: $(cat ../applied.txt)"
)

# ---- step 3: Build Fabric jar (v2.1 features, falls back step by step if one fails)
(
set -e
cat > v13.py <<'PY_EOF'
import re, sys, os

BASE = "common/src/main"
JAVA = BASE + "/java/net/caffeinemc/mods/sodium/client/"
P_OPTS = JAVA + "gui/SodiumOptions.java"
P_CFG = JAVA + "gui/SodiumConfigBuilder.java"
P_LANG = BASE + "/resources/assets/sodium/lang/en_us.json"
P_OCC = JAVA + "render/chunk/occlusion/OcclusionCuller.java"
P_DCR = JAVA + "render/chunk/DefaultChunkRenderer.java"
P_ABRC = JAVA + "render/model/AbstractBlockRenderContext.java"
P_FLUID = JAVA + "render/chunk/compile/pipeline/DefaultFluidRenderer.java"
P_TWEAKS = JAVA + "render/chunk/MobileTweaks.java"
P_LOD = JAVA + "render/chunk/MobileLod.java"
P_TASK = JAVA + "render/chunk/compile/tasks/ChunkBuilderMeshingTask.java"
P_SECTION = JAVA + "render/chunk/RenderSection.java"
P_COLLECTOR = JAVA + "render/chunk/lists/SectionCollector.java"
P_RSM = JAVA + "render/chunk/RenderSectionManager.java"

SKIP = [x.strip() for x in os.environ.get("MOBILE_V12_SKIP", "").split(",") if x.strip()]
applied = []


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def wr(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


class Skip(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise Skip(msg)


def insert_after(s, anchor, text, what):
    need(s.count(anchor) == 1, what + ": anchor not found exactly once")
    i = s.index(anchor) + len(anchor)
    return s[:i] + text + s[i:]


def replace_once(s, old, new, what):
    need(s.count(old) == 1, what + ": anchor not found exactly once")
    return s.replace(old, new, 1)


def opt_block(kind, ident, lo, hi, step, field, impact, reload_flag=False):
    head = "\n                .addOption(\n"
    if kind == "bool":
        head += '                        builder.createBooleanOption(Identifier.parse("sodium:performance.%s"))\n' % ident
    else:
        head += '                        builder.createIntegerOption(Identifier.parse("sodium:performance.%s"))\n' % ident
    head += "                                .setStorageHandler(this.sodiumStorage)\n"
    head += '                                .setName(Component.translatable("sodium.options.%s.name"))\n' % ident
    if kind == "int":
        head += '                                .setValueFormatter(ControlValueFormatterImpls.translateVariable("sodium.options.%s.value"))\n' % ident
    head += '                                .setTooltip(Component.translatable("sodium.options.%s.tooltip"))\n' % ident
    if kind == "int":
        head += "                                .setRange(%d, %d, %d)\n" % (lo, hi, step)
    head += "                                .setDefaultValue(DEFAULTS.performance.%s)\n" % field
    head += "                                .setBinding(value -> this.sodiumOpts.performance.%s = value, () -> this.sodiumOpts.performance.%s)\n" % (field, field)
    head += "                                .setImpact(OptionImpact.%s)\n" % impact
    if reload_flag:
        head += "                                .setFlags(OptionFlag.REQUIRES_RENDERER_RELOAD)\n"
    head += "                )"
    return head


def lang_lines(items):
    out = ""
    for k, v in items:
        out += '  "%s": "%s",\n' % (k, v)
    return out


def add_options(fields, blocks, lang):
    s_opts, s_cfg, s_lang = rd(P_OPTS), rd(P_CFG), rd(P_LANG)
    s_opts = insert_after(s_opts, "public boolean mobileFastTextureSampling = false;\n", fields, "SodiumOptions")
    marker = "sodium:performance.mobile_fast_texture_sampling"
    need(s_cfg.count(marker) == 1, "SodiumConfigBuilder: marker not found")
    start = s_cfg.index(marker)
    end = s_cfg.find("\n        );", start)
    need(end > 0, "SodiumConfigBuilder: end of option group not found")
    s_cfg = s_cfg[:end] + blocks + s_cfg[end:]
    m = re.search(r'^[ \t]*"sodium\.options\.mobile_fast_texture_sampling\.tooltip".*\n', s_lang, re.M)
    need(m is not None, "en_us.json: anchor not found")
    s_lang = s_lang[: m.end()] + lang + s_lang[m.end():]
    wr(P_OPTS, s_opts); wr(P_CFG, s_cfg); wr(P_LANG, s_lang)


# ------------------------------------------------------------ flat lighting
def feature_flat():
    s1 = rd(P_ABRC)
    s2 = rd(P_FLUID)
    s1 = replace_once(
        s1, "this.useAmbientOcclusion = Minecraft.useAmbientOcclusion();",
        "this.useAmbientOcclusion = Minecraft.useAmbientOcclusion() && !net.caffeinemc.mods.sodium.client.SodiumClientMod.options().performance.mobileFlatLighting;",
        "AbstractBlockRenderContext")
    s2 = replace_once(
        s2, "isWater && Minecraft.useAmbientOcclusion() ?",
        "isWater && Minecraft.useAmbientOcclusion() && !net.caffeinemc.mods.sodium.client.SodiumClientMod.options().performance.mobileFlatLighting ?",
        "DefaultFluidRenderer")
    fields = (
        "        // Sodium Mobile: flat lighting (no smooth lighting / ambient occlusion on terrain)\n"
        "        public boolean mobileFlatLighting = true;\n")
    blocks = opt_block("bool", "mobile_flat_lighting", 0, 0, 0, "mobileFlatLighting", "HIGH", True)
    lang = lang_lines([
        ("sodium.options.mobile_flat_lighting.name", "Mobile: Flat Lighting"),
        ("sodium.options.mobile_flat_lighting.tooltip",
         "Turns off smooth lighting and ambient occlusion on terrain, so chunks build faster and render with less work. Blocks look flatter."),
    ])
    add_options(fields, blocks, lang)
    wr(P_ABRC, s1); wr(P_FLUID, s2)


# ------------------------------------------------------------ quad LOD for the outer ring
LOD_JAVA_V15 = r'''package net.caffeinemc.mods.sodium.client.render.chunk;

import net.caffeinemc.mods.sodium.api.util.ColorARGB;
import net.caffeinemc.mods.sodium.client.SodiumClientMod;
import net.caffeinemc.mods.sodium.client.model.quad.properties.ModelQuadFacing;
import net.caffeinemc.mods.sodium.client.render.chunk.compile.ChunkBuildBuffers;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.material.DefaultMaterials;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.material.Material;
import net.caffeinemc.mods.sodium.client.render.chunk.vertex.format.ChunkVertexEncoder;
import net.caffeinemc.mods.sodium.client.world.LevelSlice;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.block.model.BakedQuad;
import net.minecraft.client.renderer.block.model.BlockModelPart;
import net.minecraft.client.renderer.block.BlockModelShaper;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.tags.BlockTags;
import net.minecraft.tags.FluidTags;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Heightmap;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Sodium Mobile v1.5: tiered quad LOD.
 * Codes: 0 = normal blocks, 1 = 1x1 (one quad per column), 2 = 2x2 (columns, flat 2x2 groups merged),
 * 3 = 4x4, 4 = 8x8. Where each code starts is set in chunks from the camera.
 * Ground height ignores leaves, trees are drawn as a thin canopy slab, cliff walls are layered from the real blocks.
 */
public final class MobileLod {
    private static volatile double cameraX;
    private static volatile double cameraZ;

    private static volatile int cfgStart = 6;
    private static volatile int cfg1x1 = 8;
    private static volatile int cfgT2 = 11;
    private static volatile int cfgT3 = 14;
    private static volatile int cfgMax = 3;
    private static volatile int cfgTrees = 1;
    private static volatile boolean cfgLayered = true;
    private static volatile boolean cfgWater = true;

    private static final int[][] STEPS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};

    /** code each LOD section was last built with, keyed by section position */
    private static final ConcurrentHashMap<Long, Integer> BUILT_TIER = new ConcurrentHashMap<>();

    private MobileLod() {
    }

    public static void setCamera(double x, double z) {
        cameraX = x;
        cameraZ = z;
        refreshConfig();

        if (BUILT_TIER.size() > 60000) {
            BUILT_TIER.clear();
        }
    }

    private static boolean enabled() {
        return SodiumClientMod.options().performance.mobileQuadLod;
    }

    /** presets override the individual sliders; preset 0 (custom) uses them */
    private static void refreshConfig() {
        var p = SodiumClientMod.options().performance;
        int start;
        int a;
        int b;
        int c;
        int max;
        int trees;
        boolean layered;
        boolean water;

        switch (p.mobileLodPreset) {
            case 1 -> { // potato
                start = 5;
                a = 0;
                b = 7;
                c = 9;
                max = 3;
                trees = 0;
                layered = false;
                water = false;
            }
            case 2 -> { // balanced
                start = 6;
                a = 8;
                b = 11;
                c = 14;
                max = 3;
                trees = 1;
                layered = true;
                water = true;
            }
            case 3 -> { // quality
                start = 6;
                a = 10;
                b = 13;
                c = 18;
                max = 3;
                trees = 2;
                layered = true;
                water = true;
            }
            default -> {
                start = p.mobileLodStartChunks;
                a = p.mobileLod1x1Chunks;
                b = p.mobileLodTier2Chunks;
                c = p.mobileLodTier3Chunks;
                max = p.mobileQuadLodLevel;
                trees = p.mobileLodTrees;
                layered = p.mobileLodLayeredSides;
                water = p.mobileLodWaterDepth;
            }
        }

        cfgStart = Math.max(1, start);
        cfg1x1 = Math.max(0, a);
        cfgT2 = Math.max(0, b);
        cfgT3 = Math.max(0, c);
        cfgMax = Math.max(1, Math.min(3, max));
        cfgTrees = Math.max(0, Math.min(2, trees));
        cfgLayered = layered;
        cfgWater = water;
    }

    private static long sectionKey(int x, int y, int z) {
        return (((long) (x & 0x3FFFFF)) << 42) | (((long) (z & 0x3FFFFF)) << 20) | ((long) (y & 0xFFFFF));
    }

    private static boolean canopyOk(int code) {
        int t = cfgTrees;
        if (t >= 2) {
            return code <= 3;
        }
        return t == 1 && code <= 2;
    }

    /** 0 = normal blocks, 1..4 = LOD code. Has a half-chunk hysteresis so borders do not flicker. */
    public static int tierAt(int chunkX, int chunkZ, int currentCode, double camX, double camZ) {
        if (!enabled()) {
            return 0;
        }

        double dx = chunkX - Math.floor(camX / 16.0);
        double dz = chunkZ - Math.floor(camZ / 16.0);
        double dist = Math.sqrt(dx * dx + dz * dz);
        double z1 = cfgStart;

        if (currentCode > 0) {
            if (dist < z1 - 1.0) {
                return 0;
            }
        } else if (dist < z1) {
            return 0;
        }

        double z2 = cfg1x1 > cfgStart ? cfg1x1 : z1;
        double z3 = Math.max((double) cfgT2, z2);
        double z4 = Math.max((double) cfgT3, z3);
        int maxCode = cfgMax + 1;

        int raw = dist < z2 ? 1 : (dist < z3 ? 2 : (dist < z4 ? 3 : 4));

        if (raw > maxCode) {
            raw = maxCode;
        }

        if (currentCode > 0 && currentCode != raw && currentCode <= maxCode) {
            double lo = currentCode == 1 ? z1 : (currentCode == 2 ? z2 : (currentCode == 3 ? z3 : z4));
            double hi = currentCode >= maxCode ? 1.0e9 : (currentCode == 1 ? z2 : (currentCode == 2 ? z3 : z4));

            if (hi > lo && dist >= lo - 0.5 && dist < hi + 0.5) {
                raw = currentCode;
            }
        }

        return raw;
    }

    public static boolean targetLod(int chunkX, int chunkZ, boolean currentlyLod, double camX, double camZ) {
        return tierAt(chunkX, chunkZ, currentlyLod ? 1 : 0, camX, camZ) > 0;
    }

    public static boolean targetLod(int chunkX, int chunkZ, boolean currentlyLod) {
        return targetLod(chunkX, chunkZ, currentlyLod, cameraX, cameraZ);
    }

    /** Called for every visited section; queues a rebuild when its LOD code no longer matches. */
    public static void checkRebuild(RenderSection section) {
        if (!section.isBuilt() || section.getRunningJob() != null) {
            return;
        }

        int built = 0;

        if (section.mobileLodBuilt) {
            Integer t = BUILT_TIER.get(sectionKey(section.getChunkX(), section.getChunkY(), section.getChunkZ()));
            built = t == null ? 1 : t;
        }

        int want = tierAt(section.getChunkX(), section.getChunkZ(), built, cameraX, cameraZ);

        if (want != built) {
            section.setPendingUpdate(ChunkUpdateTypes.join(section.getPendingUpdate(), ChunkUpdateTypes.REBUILD), System.nanoTime());
        }
    }

    // ------------------------------------------------------------------------------------------------------------

    private static final class Look {
        TextureAtlasSprite upSprite;
        int upColor = 0xFFFFFFFF;
        int upTint = -1;
        TextureAtlasSprite sideSprite;
        int sideColor = 0xFFFFFFFF;
        int sideTint = -1;
        Material material = DefaultMaterials.SOLID;
    }

    private static final class Quad {
        final Material material;
        final ModelQuadFacing facing;
        final TextureAtlasSprite sprite;
        final ChunkVertexEncoder.Vertex[] vertices = ChunkVertexEncoder.Vertex.uninitializedQuad();

        Quad(Material material, ModelQuadFacing facing, TextureAtlasSprite sprite) {
            this.material = material;
            this.facing = facing;
            this.sprite = sprite;
        }
    }

    private static final int LIGHT = 15 << 20;

    private static int toColor(int argb) {
        return ColorARGB.toABGR(argb);
    }

    private static int tintColor(Minecraft mc, BlockState state, LevelSlice slice, BlockPos pos, int tintIndex) {
        if (tintIndex < 0) {
            return 0xFFFFFFFF;
        }

        int rgb = mc.getBlockColors().getColor(state, slice, pos, tintIndex);
        return rgb == -1 ? 0xFFFFFFFF : (0xFF000000 | rgb);
    }

    /** colour of the top face at this position (biome tint is looked up per position so it blends smoothly) */
    private static int upColorAt(Minecraft mc, BlockState state, Look look, LevelSlice slice, BlockPos pos) {
        return look.upTint < 0 ? look.upColor : tintColor(mc, state, slice, pos, look.upTint);
    }

    private static int sideColorAt(Minecraft mc, BlockState state, Look look, LevelSlice slice, BlockPos pos) {
        return look.sideTint < 0 ? look.sideColor : tintColor(mc, state, slice, pos, look.sideTint);
    }

    private static TextureAtlasSprite firstSprite(List<BlockModelPart> parts, Direction dir) {
        for (BlockModelPart part : parts) {
            List<BakedQuad> quads = part.getQuads(dir);
            if (!quads.isEmpty()) {
                return quads.get(0).sprite();
            }
        }
        return null;
    }

    private static int firstTint(List<BlockModelPart> parts, Direction dir) {
        for (BlockModelPart part : parts) {
            List<BakedQuad> quads = part.getQuads(dir);
            if (!quads.isEmpty()) {
                return quads.get(0).tintIndex();
            }
        }
        return -1;
    }

    private static Look lookOf(Minecraft mc, BlockModelShaper shaper, LevelSlice slice, BlockState state, BlockPos pos, HashMap<BlockState, Look> cache) {
        Look cached = cache.get(state);
        if (cached != null) {
            return cached;
        }

        Look look = new Look();

        if (!state.getFluidState().isEmpty() || state.getRenderShape() != net.minecraft.world.level.block.RenderShape.MODEL) {
            // water, lava and anything without a normal model: flat colour on a plain texture
            int color = 0xFF3F76E4;
            if (state.getFluidState().is(FluidTags.LAVA)) {
                color = 0xFFFF8A1F;
            } else if (state.getFluidState().isEmpty()) {
                color = 0xFF000000 | state.getMapColor(slice, pos).col;
            }
            Look plain = plainLook(mc, shaper, slice, pos, cache);
            look.upSprite = plain.upSprite;
            look.sideSprite = plain.sideSprite;
            look.upColor = color;
            look.sideColor = color;
        } else {
            List<BlockModelPart> parts = new ArrayList<>();
            shaper.getBlockModel(state).collectParts(RandomSource.create(42L), parts);

            look.upSprite = firstSprite(parts, Direction.UP);
            look.upTint = firstTint(parts, Direction.UP);
            look.upColor = tintColor(mc, state, slice, pos, look.upTint);

            for (Direction dir : new Direction[]{Direction.NORTH, Direction.SOUTH, Direction.EAST, Direction.WEST}) {
                look.sideSprite = firstSprite(parts, dir);
                if (look.sideSprite != null) {
                    look.sideTint = firstTint(parts, dir);
                    look.sideColor = tintColor(mc, state, slice, pos, look.sideTint);
                    break;
                }
            }

            if (look.upSprite == null && look.sideSprite == null) {
                Look plain = plainLook(mc, shaper, slice, pos, cache);
                look.upSprite = plain.upSprite;
                look.sideSprite = plain.sideSprite;
                look.upTint = -1;
                look.sideTint = -1;
                look.upColor = 0xFF000000 | state.getMapColor(slice, pos).col;
                look.sideColor = look.upColor;
            } else {
                if (look.upSprite == null) {
                    look.upSprite = look.sideSprite;
                    look.upColor = look.sideColor;
                    look.upTint = look.sideTint;
                }
                if (look.sideSprite == null) {
                    look.sideSprite = look.upSprite;
                    look.sideColor = look.upColor;
                    look.sideTint = look.upTint;
                }

                // grassy blocks: use the top texture and tint on the sides too, so far cliffs have no bright green strip
                if (state.is(Blocks.GRASS_BLOCK) || state.is(Blocks.PODZOL) || state.is(Blocks.MYCELIUM)) {
                    look.sideSprite = look.upSprite;
                    look.sideColor = look.upColor;
                    look.sideTint = look.upTint;
                }

                look.material = DefaultMaterials.forBlockState(state);
                if (look.material.pass.isTranslucent()) {
                    // ice, glass: draw as a plain light colour instead
                    Look plain = plainLook(mc, shaper, slice, pos, cache);
                    look.upSprite = plain.upSprite;
                    look.sideSprite = plain.sideSprite;
                    look.upTint = -1;
                    look.sideTint = -1;
                    look.upColor = 0xFF000000 | state.getMapColor(slice, pos).col;
                    look.sideColor = look.upColor;
                    look.material = DefaultMaterials.SOLID;
                }
            }
        }

        cache.put(state, look);
        return look;
    }

    private static Look plainLook(Minecraft mc, BlockModelShaper shaper, LevelSlice slice, BlockPos pos, HashMap<BlockState, Look> cache) {
        BlockState plainState = Blocks.WHITE_CONCRETE.defaultBlockState();
        Look cached = cache.get(plainState);
        if (cached != null) {
            return cached;
        }

        Look look = new Look();
        List<BlockModelPart> parts = new ArrayList<>();
        shaper.getBlockModel(plainState).collectParts(RandomSource.create(42L), parts);
        look.upSprite = firstSprite(parts, Direction.UP);
        look.sideSprite = firstSprite(parts, Direction.NORTH);
        if (look.sideSprite == null) {
            look.sideSprite = look.upSprite;
        }
        cache.put(plainState, look);
        return look;
    }

    // ------------------------------------------------------------------------------------------------------------

    /**
     * Reads one world column. out[0] = top (first free y above the highest motion blocking block, leaves included),
     * out[1] = ground (same, but looking down through leaves, logs and plants of a tree).
     */
    private static boolean column(ClientLevel level, BlockPos.MutableBlockPos p, int x, int z, int[] out) {
        if (!level.hasChunk(x >> 4, z >> 4)) {
            return false;
        }

        int h = level.getHeight(Heightmap.Types.MOTION_BLOCKING, x, z);
        int g = h;
        boolean leaves = false;

        for (int y = h - 1; y > h - 48; y--) {
            p.set(x, y, z);
            BlockState s = level.getBlockState(p);

            if (s.isAir()) {
                if (!leaves) {
                    break;
                }
                g = y;
            } else if (s.is(BlockTags.LEAVES)) {
                leaves = true;
                g = y;
            } else if (leaves && (s.is(BlockTags.LOGS) || s.getCollisionShape(level, p).isEmpty())) {
                g = y;
            } else {
                break;
            }
        }

        out[0] = h;
        out[1] = g;
        return true;
    }

    private static void put(ChunkVertexEncoder.Vertex v, float x, float y, float z, int color, float shade, float u, float vv) {
        v.x = x;
        v.y = y;
        v.z = z;
        v.color = color;
        v.ao = shade;
        v.u = u;
        v.v = vv;
        v.light = LIGHT;
    }

    private static void topQuad(List<Quad> out, Look look, int argb, float x0, float x1, float z0, float z1, float y, float crop) {
        TextureAtlasSprite s = look.upSprite;
        Quad q = new Quad(look.material, ModelQuadFacing.POS_Y, s);
        int c = toColor(argb);
        float u0 = s.getU0(), u1 = s.getU1(), v0 = s.getV0(), v1 = s.getV1();

        if (crop < 1.0f) {
            // far away use only the middle of the texture so big quads don't show one huge magnified pattern
            float du = (u1 - u0) * (1.0f - crop) * 0.5f;
            float dv = (v1 - v0) * (1.0f - crop) * 0.5f;
            u0 += du;
            u1 -= du;
            v0 += dv;
            v1 -= dv;
        }

        put(q.vertices[0], x0, y, z0, c, 1.0f, u0, v0);
        put(q.vertices[1], x0, y, z1, c, 1.0f, u0, v1);
        put(q.vertices[2], x1, y, z1, c, 1.0f, u1, v1);
        put(q.vertices[3], x1, y, z0, c, 1.0f, u1, v0);
        out.add(q);
    }

    /** dir: 0 = +X, 1 = -X, 2 = +Z, 3 = -Z. The wall sits on the boundary plane of the cell and faces dir. */
    private static void wallQuad(List<Quad> out, Look look, int argb, int dir, float a0, float a1, float plane, float yBottom, float yTop, float crop) {
        TextureAtlasSprite s = look.sideSprite;
        int c = toColor(argb);
        float u0 = s.getU0(), u1 = s.getU1(), v0 = s.getV0(), v1 = s.getV1();

        if (crop < 1.0f) {
            float du = (u1 - u0) * (1.0f - crop) * 0.5f;
            u0 += du;
            u1 -= du;
        }

        float shade = dir < 2 ? 0.6f : 0.8f;
        ModelQuadFacing facing = switch (dir) {
            case 0 -> ModelQuadFacing.POS_X;
            case 1 -> ModelQuadFacing.NEG_X;
            case 2 -> ModelQuadFacing.POS_Z;
            default -> ModelQuadFacing.NEG_Z;
        };
        Quad q = new Quad(look.material, facing, s);
        ChunkVertexEncoder.Vertex[] w = q.vertices;

        switch (dir) {
            case 0 -> { // +X, a0..a1 along Z
                put(w[0], plane, yTop, a1, c, shade, u0, v0);
                put(w[1], plane, yBottom, a1, c, shade, u0, v1);
                put(w[2], plane, yBottom, a0, c, shade, u1, v1);
                put(w[3], plane, yTop, a0, c, shade, u1, v0);
            }
            case 1 -> { // -X
                put(w[0], plane, yTop, a0, c, shade, u0, v0);
                put(w[1], plane, yBottom, a0, c, shade, u0, v1);
                put(w[2], plane, yBottom, a1, c, shade, u1, v1);
                put(w[3], plane, yTop, a1, c, shade, u1, v0);
            }
            case 2 -> { // +Z, a0..a1 along X
                put(w[0], a0, yTop, plane, c, shade, u0, v0);
                put(w[1], a0, yBottom, plane, c, shade, u0, v1);
                put(w[2], a1, yBottom, plane, c, shade, u1, v1);
                put(w[3], a1, yTop, plane, c, shade, u1, v0);
            }
            default -> { // -Z
                put(w[0], a1, yTop, plane, c, shade, u0, v0);
                put(w[1], a1, yBottom, plane, c, shade, u0, v1);
                put(w[2], a0, yBottom, plane, c, shade, u1, v1);
                put(w[3], a0, yTop, plane, c, shade, u1, v0);
            }
        }

        out.add(q);
    }

    private static void emitBand(List<Quad> out, Look look, int color, Look fallback, int fallbackColor, int dir, float a0, float a1, float plane, int yb, int yt, int secMinY, float crop) {
        if (yt <= yb) {
            return;
        }

        if (look == null || look.sideSprite == null) {
            look = fallback;
            color = fallbackColor;
        }

        wallQuad(out, look, color, dir, a0, a1, plane, (float) (yb - secMinY), (float) (yt - secMinY), crop);
    }

    /**
     * Draws one cliff wall as layers taken from the real blocks in the sample column: the cap block (grass),
     * then dirt, then stone and so on. Layers thinner than minThick are merged into the layer above, and
     * a wall never gets more than 4 layers.
     */
    private static void wallBands(List<Quad> out, Minecraft mc, BlockModelShaper shaper, LevelSlice slice, BlockPos.MutableBlockPos pos,
                                  HashMap<BlockState, Look> looks, Look fallback, int fallbackColor, int lx, int lz, int dir,
                                  float a0, float a1, float plane, int bottom, int top, int secMinY, boolean capAtTop, int minThick, float crop) {
        BlockState cur = null;
        Look curLook = null;
        int curColor = 0;
        int runTop = top;
        int bands = 0;

        for (int y = top - 1; y >= bottom; y--) {
            BlockState s = slice.getBlockState(lx, y, lz);

            if (s.isAir()) {
                continue;
            }

            if (cur == null) {
                cur = s;
                pos.set(lx, y, lz);
                curLook = lookOf(mc, shaper, slice, s, pos, looks);
                curColor = sideColorAt(mc, s, curLook, slice, pos);
                continue;
            }

            if (s == cur) {
                continue;
            }

            int runLen = runTop - (y + 1);
            int need = (bands == 0 && capAtTop) ? 1 : minThick;

            if (runLen >= need && bands < 3) {
                emitBand(out, curLook, curColor, fallback, fallbackColor, dir, a0, a1, plane, y + 1, runTop, secMinY, crop);
                bands++;
                cur = s;
                pos.set(lx, y, lz);
                curLook = lookOf(mc, shaper, slice, s, pos, looks);
                curColor = sideColorAt(mc, s, curLook, slice, pos);
                runTop = y + 1;
            }
        }

        if (cur == null) {
            emitBand(out, fallback, fallbackColor, fallback, fallbackColor, dir, a0, a1, plane, bottom, top, secMinY, crop);
        } else {
            emitBand(out, curLook, curColor, fallback, fallbackColor, dir, a0, a1, plane, bottom, runTop, secMinY, crop);
        }
    }

    private static int shadeWater(int argb, int depth) {
        float f = Math.min(1.0f, depth / 24.0f);
        float k = 1.15f - 0.65f * f;
        int r = Math.min(255, (int) (((argb >> 16) & 255) * k));
        int g = Math.min(255, (int) (((argb >> 8) & 255) * k));
        int b = Math.min(255, (int) ((argb & 255) * k));
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    // ------------------------------------------------------------------------------------------------------------

    /**
     * Builds the LOD mesh for one section. Returns false (and adds nothing) if anything is unavailable,
     * so the caller can fall back to the normal block-by-block mesh.
     */
    public static boolean build(ChunkBuildBuffers buffers, BlockModelShaper shaper, LevelSlice slice, int originX, int originY, int originZ) {
        Minecraft mc = Minecraft.getInstance();
        ClientLevel level = mc.level;

        if (level == null) {
            return false;
        }

        long skey = sectionKey(originX >> 4, originY >> 4, originZ >> 4);
        Integer prev = BUILT_TIER.get(skey);
        int code = tierAt(originX >> 4, originZ >> 4, prev == null ? 0 : prev, cameraX, cameraZ);

        if (code < 1) {
            code = 1;
        }

        Mesher m = new Mesher(mc, level, shaper, slice, originX, originY, originZ, code);
        m.run();

        // everything computed successfully: now write to the buffers
        for (Quad q : m.quads) {
            var builder = buffers.get(q.material);
            builder.getVertexBuffer(q.facing).push(q.vertices, q.material.bits());
            builder.addSprite(q.sprite);
        }

        BUILT_TIER.put(skey, code);
        return true;
    }

    private static final class Mesher {
        final Minecraft mc;
        final ClientLevel level;
        final BlockModelShaper shaper;
        final LevelSlice slice;
        final int originX;
        final int originY;
        final int originZ;
        final int code;
        final int rs;
        final int groups;
        final int gridSize;
        final int secMinY;
        final int secMaxY;
        final int minThick;
        final float crop;
        final boolean layered;
        final boolean canopyOn;
        final boolean water;
        final boolean mergeFlat;

        final int[] gH;
        final int[] cH;
        final int[] sX;
        final int[] sZ;
        final int[] gBy;
        final int[] cBy;
        final BlockState[] gState;
        final BlockState[] cState;

        final List<Quad> quads = new ArrayList<>();
        final HashMap<BlockState, Look> looks = new HashMap<>();
        final BlockPos.MutableBlockPos pos = new BlockPos.MutableBlockPos();
        final BlockPos.MutableBlockPos wp = new BlockPos.MutableBlockPos();
        final int[] col = new int[2];
        final int[] tmp = new int[4];
        final int[] res = new int[4];

        Mesher(Minecraft mc, ClientLevel level, BlockModelShaper shaper, LevelSlice slice, int originX, int originY, int originZ, int code) {
            this.mc = mc;
            this.level = level;
            this.shaper = shaper;
            this.slice = slice;
            this.originX = originX;
            this.originY = originY;
            this.originZ = originZ;
            this.code = code;
            this.rs = code <= 2 ? 1 : (1 << (code - 1));
            this.groups = 16 / this.rs;
            this.gridSize = this.groups + 2;
            this.secMinY = originY;
            this.secMaxY = originY + 16;
            this.minThick = Math.max(2, this.rs);
            this.crop = code <= 2 ? 1.0f : (code == 3 ? 0.5f : 0.25f);
            this.layered = cfgLayered;
            this.canopyOn = canopyOk(code);
            this.water = cfgWater;
            this.mergeFlat = code == 2;

            int n = this.gridSize * this.gridSize;
            this.gH = new int[n];
            this.cH = new int[n];
            this.sX = new int[n];
            this.sZ = new int[n];
            this.gBy = new int[n];
            this.cBy = new int[n];
            this.gState = new BlockState[n];
            this.cState = new BlockState[n];
        }

        void run() {
            sampleGrid();
            prepareStates();
            emitAll();
        }

        // ---- sampling -------------------------------------------------------------------------------------------

        void sampleGrid() {
            for (int gz = -1; gz <= groups; gz++) {
                for (int gx = -1; gx <= groups; gx++) {
                    int idx = (gz + 1) * gridSize + (gx + 1);

                    if (gx < 0 || gx >= groups || gz < 0 || gz >= groups) {
                        int ex0;
                        int ex1;
                        int ez0;
                        int ez1;

                        if (gx < 0) {
                            ex0 = originX - 1;
                            ex1 = ex0;
                        } else if (gx >= groups) {
                            ex0 = originX + 16;
                            ex1 = ex0;
                        } else {
                            ex0 = originX + gx * rs;
                            ex1 = ex0 + rs - 1;
                        }

                        if (gz < 0) {
                            ez0 = originZ - 1;
                            ez1 = ez0;
                        } else if (gz >= groups) {
                            ez0 = originZ + 16;
                            ez1 = ez0;
                        } else {
                            ez0 = originZ + gz * rs;
                            ez1 = ez0 + rs - 1;
                        }

                        int g = borderGround(ex0, ex1, ez0, ez1);
                        gH[idx] = g;
                        cH[idx] = (canopyOn && g != Integer.MIN_VALUE) ? borderCanopy(ex0, ex1, ez0, ez1, g) : 0;
                        continue;
                    }

                    if (!cellSample(originX + gx * rs, originZ + gz * rs)) {
                        gH[idx] = Integer.MIN_VALUE;
                        continue;
                    }

                    gH[idx] = res[0];
                    cH[idx] = res[1];
                    sX[idx] = res[2];
                    sZ[idx] = res[3];
                }
            }
        }

        /** samples one cell (the column itself for 1x1, the average of 4 corner columns for 4x4 and 8x8) */
        boolean cellSample(int x0, int z0) {
            int n = rs == 1 ? 1 : 4;
            int far = rs - 1;
            int sumG = 0;
            int sumH = 0;
            boolean allCanopy = true;

            for (int i = 0; i < n; i++) {
                int x = x0 + ((i & 1) == 0 ? 0 : far);
                int z = z0 + ((i & 2) == 0 ? 0 : far);

                if (!column(level, wp, x, z, col)) {
                    return false;
                }

                tmp[i] = col[1];
                sumG += col[1];
                sumH += col[0];

                if (col[0] - col[1] < 3) {
                    allCanopy = false;
                }
            }

            int g = Math.round((float) sumG / n);
            int h = Math.round((float) sumH / n);

            int best = 0;
            int bd = Integer.MAX_VALUE;
            for (int i = 0; i < n; i++) {
                int d = Math.abs(tmp[i] - g);
                if (d < bd) {
                    bd = d;
                    best = i;
                }
            }

            res[2] = x0 + ((best & 1) == 0 ? 0 : far);
            res[3] = z0 + ((best & 2) == 0 ? 0 : far);

            if (canopyOn) {
                if (allCanopy) {
                    res[0] = g;
                    res[1] = h;
                } else {
                    res[0] = (h - g < 3) ? h : g;
                    res[1] = 0;
                }
            } else {
                res[0] = g;
                res[1] = 0;
            }

            return true;
        }

        int cellMin(int x0, int z0, int s, boolean canopy) {
            int far = s - 1;
            int n = s == 1 ? 1 : 4;
            int best = Integer.MAX_VALUE;

            for (int i = 0; i < n; i++) {
                int x = x0 + ((i & 1) == 0 ? 0 : far);
                int z = z0 + ((i & 2) == 0 ? 0 : far);

                if (!column(level, wp, x, z, col)) {
                    return Integer.MIN_VALUE;
                }

                int v = canopy ? (col[0] - col[1] >= 3 ? col[0] : col[1]) : col[1];

                if (v < best) {
                    best = v;
                }
            }

            return best;
        }

        int minOver(int ex0, int ex1, int ez0, int ez1, int nSize, int best, boolean canopy) {
            if (best == Integer.MIN_VALUE) {
                return best;
            }

            int mask = ~(nSize - 1);

            for (int x = ex0 & mask; x <= ex1; x += nSize) {
                for (int z = ez0 & mask; z <= ez1; z += nSize) {
                    int h = cellMin(x, z, nSize, canopy);

                    if (h == Integer.MIN_VALUE) {
                        return Integer.MIN_VALUE;
                    }

                    if (h < best) {
                        best = h;
                    }
                }
            }

            return best;
        }

        /**
         * Ground height on the far side of a section border. Takes the lowest of the real columns and of the
         * neighbour's own big cells, so a wall always reaches below whatever the neighbour draws and no gaps open between tiers.
         */
        int borderGround(int ex0, int ex1, int ez0, int ez1) {
            int ncx = ex0 >> 4;
            int ncz = ez0 >> 4;
            int fresh = tierAt(ncx, ncz, 0, cameraX, cameraZ);
            Integer mapped = BUILT_TIER.get(sectionKey(ncx, originY >> 4, ncz));

            int best = minOver(ex0, ex1, ez0, ez1, 1, Integer.MAX_VALUE, false);

            if (fresh >= 3) {
                best = minOver(ex0, ex1, ez0, ez1, 1 << (fresh - 1), best, false);
            }

            if (mapped != null && mapped >= 3 && mapped != fresh) {
                best = minOver(ex0, ex1, ez0, ez1, 1 << (Math.min(4, mapped) - 1), best, false);
            }

            return best;
        }

        /** top of the neighbour's canopy (or its ground if it draws no canopy there) */
        int borderCanopy(int ex0, int ex1, int ez0, int ez1, int groundBorder) {
            int ncx = ex0 >> 4;
            int ncz = ez0 >> 4;
            int fresh = tierAt(ncx, ncz, 0, cameraX, cameraZ);
            boolean present = fresh == 0 || canopyOk(fresh);

            if (!present) {
                return groundBorder;
            }

            int best = minOver(ex0, ex1, ez0, ez1, 1, Integer.MAX_VALUE, true);

            if (fresh >= 3) {
                best = minOver(ex0, ex1, ez0, ez1, 1 << (fresh - 1), best, true);
            }

            return best == Integer.MIN_VALUE ? groundBorder : best;
        }

        // ---- block states ---------------------------------------------------------------------------------------

        void prepareStates() {
            for (int gz = 0; gz < groups; gz++) {
                for (int gx = 0; gx < groups; gx++) {
                    int idx = (gz + 1) * gridSize + (gx + 1);

                    if (gH[idx] == Integer.MIN_VALUE) {
                        continue;
                    }

                    int lx = sX[idx];
                    int lz = sZ[idx];

                    int ly = Math.max(secMinY, Math.min(secMaxY - 1, gH[idx] - 1));
                    BlockState st = slice.getBlockState(lx, ly, lz);

                    if (st.isAir()) {
                        while (ly > secMinY && slice.getBlockState(lx, ly, lz).isAir()) {
                            ly--;
                        }
                        st = slice.getBlockState(lx, ly, lz);
                        if (st.isAir()) {
                            st = null;
                        }
                    }

                    gState[idx] = st;
                    gBy[idx] = ly;

                    if (cH[idx] > 0) {
                        int cy = Math.max(secMinY, Math.min(secMaxY - 1, cH[idx] - 1));
                        BlockState cs = slice.getBlockState(lx, cy, lz);

                        if (cs.isAir()) {
                            while (cy > secMinY && slice.getBlockState(lx, cy, lz).isAir()) {
                                cy--;
                            }
                            cs = slice.getBlockState(lx, cy, lz);
                            if (cs.isAir()) {
                                cs = null;
                            }
                        }

                        cState[idx] = cs;
                        cBy[idx] = cy;
                    }
                }
            }
        }

        // ---- water ----------------------------------------------------------------------------------------------

        int waterColor(BlockState state, int color, int x, int y, int z) {
            if (!water || !state.getFluidState().is(FluidTags.WATER)) {
                return color;
            }

            int depth = 0;

            for (int yy = y; yy > y - 40; yy--) {
                wp.set(x, yy, z);

                if (level.getBlockState(wp).getFluidState().isEmpty()) {
                    break;
                }

                depth++;
            }

            return shadeWater(color, depth);
        }

        Look lookFor(BlockState st, int lx, int by, int lz) {
            pos.set(lx, by, lz);
            Look l = lookOf(mc, shaper, slice, st, pos, looks);
            return (l.upSprite == null || l.sideSprite == null) ? null : l;
        }

        // ---- emitting -------------------------------------------------------------------------------------------

        void emitAll() {
            int n = gridSize * gridSize;
            boolean[] skipG = new boolean[n];
            boolean[] skipC = new boolean[n];

            if (mergeFlat) {
                mergeFlatTops(skipG, skipC);
            }

            for (int gz = 0; gz < groups; gz++) {
                for (int gx = 0; gx < groups; gx++) {
                    int idx = (gz + 1) * gridSize + (gx + 1);

                    if (gH[idx] == Integer.MIN_VALUE) {
                        continue;
                    }

                    emitGround(gx, gz, idx, skipG[idx]);

                    if (cH[idx] > 0 && cState[idx] != null) {
                        emitCanopy(gx, gz, idx, skipC[idx]);
                    }
                }
            }
        }

        /** 2x2 mode: where four neighbouring columns have the same height and block, draw one big top quad instead of four */
        void mergeFlatTops(boolean[] skipG, boolean[] skipC) {
            for (int gz = 0; gz + 1 < groups; gz += 2) {
                for (int gx = 0; gx + 1 < groups; gx += 2) {
                    int i0 = (gz + 1) * gridSize + (gx + 1);
                    int i1 = i0 + 1;
                    int i2 = i0 + gridSize;
                    int i3 = i2 + 1;

                    int h = gH[i0];

                    if (h != Integer.MIN_VALUE && h - 1 >= secMinY && h - 1 < secMaxY
                            && gH[i1] == h && gH[i2] == h && gH[i3] == h
                            && gState[i0] != null && gState[i1] == gState[i0] && gState[i2] == gState[i0] && gState[i3] == gState[i0]) {
                        Look look = lookFor(gState[i0], sX[i0], gBy[i0], sZ[i0]);

                        if (look != null) {
                            int color = waterColor(gState[i0], upColorAt(mc, gState[i0], look, slice, pos), sX[i0], gBy[i0], sZ[i0]);
                            topQuad(quads, look, color, gx, gx + 2, gz, gz + 2, (float) (h - secMinY), 1.0f);
                            skipG[i0] = true;
                            skipG[i1] = true;
                            skipG[i2] = true;
                            skipG[i3] = true;
                        }
                    }

                    int c = cH[i0];

                    if (c > 0 && c - 1 >= secMinY && c - 1 < secMaxY
                            && cH[i1] == c && cH[i2] == c && cH[i3] == c
                            && cState[i0] != null && cState[i1] == cState[i0] && cState[i2] == cState[i0] && cState[i3] == cState[i0]) {
                        Look look = lookFor(cState[i0], sX[i0], cBy[i0], sZ[i0]);

                        if (look != null) {
                            int color = upColorAt(mc, cState[i0], look, slice, pos);
                            topQuad(quads, look, color, gx, gx + 2, gz, gz + 2, (float) (c - secMinY), 1.0f);
                            skipC[i0] = true;
                            skipC[i1] = true;
                            skipC[i2] = true;
                            skipC[i3] = true;
                        }
                    }
                }
            }
        }

        void emitGround(int gx, int gz, int idx, boolean skipTop) {
            int h = gH[idx];
            BlockState state = gState[idx];

            if (state == null) {
                return;
            }

            boolean topHere = h - 1 >= secMinY && h - 1 < secMaxY;
            boolean wallHere = false;

            for (int[] st : STEPS) {
                int hn = gH[(gz + 1 + st[1]) * gridSize + (gx + 1 + st[0])];

                if (hn != Integer.MIN_VALUE && hn < h && Math.min(h, secMaxY) > Math.max(hn, secMinY)) {
                    wallHere = true;
                }
            }

            if (!topHere && !wallHere) {
                return;
            }

            int lx = sX[idx];
            int lz = sZ[idx];
            Look look = lookFor(state, lx, gBy[idx], lz);

            if (look == null) {
                return;
            }

            // colours are read per position, so the biome tint blends smoothly from cell to cell
            int topColor = upColorAt(mc, state, look, slice, pos);
            int sideColor = sideColorAt(mc, state, look, slice, pos);

            float x0 = gx * rs;
            float x1 = x0 + rs;
            float z0 = gz * rs;
            float z1 = z0 + rs;

            if (topHere && !skipTop) {
                topQuad(quads, look, waterColor(state, topColor, lx, gBy[idx], lz), x0, x1, z0, z1, (float) (h - secMinY), crop);
            }

            for (int dir = 0; dir < 4; dir++) {
                int[] st = STEPS[dir];
                int hn = gH[(gz + 1 + st[1]) * gridSize + (gx + 1 + st[0])];

                if (hn == Integer.MIN_VALUE || hn >= h) {
                    continue;
                }

                int bottom = Math.max(hn, secMinY);
                int top = Math.min(h, secMaxY);

                if (top <= bottom) {
                    continue;
                }

                float a0;
                float a1;
                float plane;

                switch (dir) {
                    case 0 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x1;
                    }
                    case 1 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x0;
                    }
                    case 2 -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z1;
                    }
                    default -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z0;
                    }
                }

                if (layered) {
                    wallBands(quads, mc, shaper, slice, pos, looks, look, sideColor, lx, lz, dir,
                            a0, a1, plane, bottom, top, secMinY, h <= secMaxY, minThick, crop);
                } else {
                    wallQuad(quads, look, sideColor, dir, a0, a1, plane, (float) (bottom - secMinY), (float) (top - secMinY), crop);
                }
            }
        }

        /** a tree canopy: a thin slab of leaves (up to 3 blocks) at the top of the tree, with the ground visible below it */
        void emitCanopy(int gx, int gz, int idx, boolean skipTop) {
            int c = cH[idx];
            int g = gH[idx];
            int cb = Math.max(g, c - 3);
            BlockState state = cState[idx];

            boolean topHere = c - 1 >= secMinY && c - 1 < secMaxY;
            boolean wallHere = false;

            for (int[] st : STEPS) {
                int ni = (gz + 1 + st[1]) * gridSize + (gx + 1 + st[0]);

                if (gH[ni] == Integer.MIN_VALUE) {
                    continue;
                }

                int cn = cH[ni] > 0 ? cH[ni] : gH[ni];

                if (cn < c && Math.min(c, secMaxY) > Math.max(Math.max(cn, cb), secMinY)) {
                    wallHere = true;
                }
            }

            if (!topHere && !wallHere) {
                return;
            }

            int lx = sX[idx];
            int lz = sZ[idx];
            Look look = lookFor(state, lx, cBy[idx], lz);

            if (look == null) {
                return;
            }

            int topColor = upColorAt(mc, state, look, slice, pos);
            int sideColor = sideColorAt(mc, state, look, slice, pos);

            float x0 = gx * rs;
            float x1 = x0 + rs;
            float z0 = gz * rs;
            float z1 = z0 + rs;

            if (topHere && !skipTop) {
                topQuad(quads, look, topColor, x0, x1, z0, z1, (float) (c - secMinY), crop);
            }

            for (int dir = 0; dir < 4; dir++) {
                int[] st = STEPS[dir];
                int ni = (gz + 1 + st[1]) * gridSize + (gx + 1 + st[0]);

                if (gH[ni] == Integer.MIN_VALUE) {
                    continue;
                }

                int cn = cH[ni] > 0 ? cH[ni] : gH[ni];

                if (cn >= c) {
                    continue;
                }

                int bottom = Math.max(Math.max(cn, cb), secMinY);
                int top = Math.min(c, secMaxY);

                if (top <= bottom) {
                    continue;
                }

                float a0;
                float a1;
                float plane;

                switch (dir) {
                    case 0 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x1;
                    }
                    case 1 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x0;
                    }
                    case 2 -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z1;
                    }
                    default -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z0;
                    }
                }

                wallQuad(quads, look, sideColor, dir, a0, a1, plane, (float) (bottom - secMinY), (float) (top - secMinY), crop);
            }
        }
    }
}
'''


LOD_JAVA_V20 = r'''package net.caffeinemc.mods.sodium.client.render.chunk;

import net.caffeinemc.mods.sodium.api.util.ColorARGB;
import net.caffeinemc.mods.sodium.client.SodiumClientMod;
import net.caffeinemc.mods.sodium.client.model.quad.properties.ModelQuadFacing;
import net.caffeinemc.mods.sodium.client.render.chunk.compile.ChunkBuildBuffers;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.material.DefaultMaterials;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.material.Material;
import net.caffeinemc.mods.sodium.client.render.chunk.vertex.format.ChunkVertexEncoder;
import net.caffeinemc.mods.sodium.client.world.LevelSlice;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.block.model.BakedQuad;
import net.minecraft.client.renderer.block.model.BlockModelPart;
import net.minecraft.client.renderer.block.BlockModelShaper;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.tags.BlockTags;
import net.minecraft.tags.FluidTags;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.BlockAndTintGetter;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Heightmap;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.LongPredicate;

/**
 * Sodium Mobile v2.0: tiered quad LOD.
 * Codes: 0 = normal blocks, 1 = 1x1 (one quad per column), 2 = 2x2 (columns, flat 2x2 groups merged),
 * 3 = 4x4, 4 = 8x8, 5 = 16x16 (outside LOD only). Where each code starts is set in chunks from the camera.
 * Ground height ignores leaves, trees are drawn as a thin canopy slab, cliff walls are layered from the real blocks,
 * tops and walls are shaded per vertex, and an optional low poly mode smooths slopes.
 * The world data comes through a Source, so the same mesher builds real chunks and cached outside-LOD columns.
 */
public final class MobileLod {
    private static volatile double cameraX;
    private static volatile double cameraZ;

    private static volatile int cfgStart = 6;
    private static volatile int cfg1x1 = 8;
    private static volatile int cfgT2 = 11;
    private static volatile int cfgT3 = 14;
    private static volatile int cfg16 = 24;
    private static volatile int cfgMax = 3;
    private static volatile int cfgTrees = 1;
    private static volatile int cfgShade = 1;
    private static volatile boolean cfgLowPoly = false;
    private static volatile boolean cfgLayered = true;
    private static volatile boolean cfgWater = true;
    private static volatile int cfgBudget = 16;
    private static volatile int cfgDelayMs = 300;
    private static volatile boolean cfgPauseFast = false;
    private static volatile int cfgTreesMax = 0;
    private static volatile int cfgWall = 2;
    private static volatile boolean cfgZoom = false;
    private static volatile int cfgZoomMax = 24;
    private static volatile int cfgZoomSpeed = 2;
    /** distance multiplier from zooming (1 = no zoom), changed in steps so it does not retrigger rebuilds all the time */
    private static volatile double zoomScale = 1.0;
    private static int rebuildsThisFrame = 0;
    private static long lastChunkChangeNs = 0L;
    private static int lastCamChunkX = Integer.MIN_VALUE;
    private static int lastCamChunkZ = Integer.MIN_VALUE;
    private static double lastSpeedX = 0.0;
    private static double lastSpeedZ = 0.0;
    private static long lastSpeedNs = 0L;
    private static volatile double speedBps = 0.0;
    private static volatile boolean needRevisit = false;

    private static final int[][] STEPS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};

    /** code each LOD section was last built with, keyed by section position */
    private static final ConcurrentHashMap<Long, Integer> BUILT_TIER = new ConcurrentHashMap<>();

    /** set by the outside LOD: true for columns that are drawn from the cache instead of real chunks */
    private static volatile LongPredicate fakeColumn = k -> false;

    private MobileLod() {
    }

    /** What the mesher needs to know about the world. Implemented for real chunks here and for cached columns by the outside LOD. */
    public interface Source {
        /** out[0] = top (first free y above the highest block, leaves included), out[1] = ground (same but looking through trees). False if unknown. */
        boolean column(int x, int z, int[] out);

        BlockState stateAt(int x, int y, int z);

        /** the block at the top of a tree at this column, or null */
        BlockState canopyState(int x, int z, int topY);

        /** ARGB biome tint for this block (white if it has none) */
        int tint(BlockState state, int tintIndex, int x, int y, int z, boolean canopy);

        int waterDepth(int x, int y, int z);

        /** used for map colours and tint lookups, may be null */
        BlockAndTintGetter view();
    }

    public static void setFakeColumnTest(LongPredicate test) {
        fakeColumn = test == null ? k -> false : test;
    }

    /** true once after a rebuild was postponed, so the caller marks the render graph dirty and the check runs again */
    public static boolean consumeRevisit() {
        boolean r = needRevisit;
        needRevisit = false;
        return r;
    }

    /** ratio = tan(current fov / 2) / tan(option fov / 2); below 1 means zoomed in */
    public static void setZoomRatio(double ratio) {
        double scale = 1.0;

        if (cfgZoom) {
            if (ratio < 0.30) {
                scale = 0.25;
            } else if (ratio < 0.45) {
                scale = 0.4;
            } else if (ratio < 0.65) {
                scale = 0.6;
            } else if (ratio < 0.85) {
                scale = 0.8;
            }
        }

        if (scale != zoomScale) {
            zoomScale = scale;
            needRevisit = true;
        }
    }

    /** true if this column is drawn as LOD right now (inside LOD tiers or the outside LOD) */
    public static boolean isLodColumn(int chunkX, int chunkZ) {
        if (fakeColumn.test(columnKey(chunkX, chunkZ))) {
            return true;
        }

        return tierAt(chunkX, chunkZ, 0, cameraX, cameraZ) > 0;
    }

    public static double cameraX() {
        return cameraX;
    }

    public static double cameraZ() {
        return cameraZ;
    }

    public static void setCamera(double x, double z) {
        cameraX = x;
        cameraZ = z;
        refreshConfig();
        rebuildsThisFrame = 0;

        int ccx = (int) Math.floor(x / 16.0);
        int ccz = (int) Math.floor(z / 16.0);
        long now = System.nanoTime();

        if (ccx != lastCamChunkX || ccz != lastCamChunkZ) {
            lastCamChunkX = ccx;
            lastCamChunkZ = ccz;
            lastChunkChangeNs = now;
        }

        if (now - lastSpeedNs > 250_000_000L) {
            double dt = (now - lastSpeedNs) / 1.0e9;
            double dx = x - lastSpeedX;
            double dz = z - lastSpeedZ;
            speedBps = lastSpeedNs == 0L || dt > 2.0 ? 0.0 : Math.sqrt(dx * dx + dz * dz) / dt;
            lastSpeedX = x;
            lastSpeedZ = z;
            lastSpeedNs = now;
        }

        if (BUILT_TIER.size() > 60000) {
            BUILT_TIER.clear();
        }
    }

    private static boolean enabled() {
        return SodiumClientMod.options().performance.mobileQuadLod;
    }

    /** presets override the individual sliders; preset 0 (custom) uses them */
    private static void refreshConfig() {
        var p = SodiumClientMod.options().performance;
        int start;
        int a;
        int b;
        int c;
        int max;
        int trees;
        int shade;
        boolean layered;
        boolean water;

        switch (p.mobileLodPreset) {
            case 1 -> { // potato
                start = 5;
                a = 0;
                b = 7;
                c = 9;
                max = 3;
                trees = 0;
                shade = 0;
                layered = false;
                water = false;
            }
            case 2 -> { // balanced
                start = 6;
                a = 8;
                b = 11;
                c = 14;
                max = 3;
                trees = 1;
                shade = 1;
                layered = true;
                water = true;
            }
            case 3 -> { // quality
                start = 6;
                a = 10;
                b = 13;
                c = 18;
                max = 3;
                trees = 2;
                shade = 2;
                layered = true;
                water = true;
            }
            default -> {
                start = p.mobileLodStartChunks;
                a = p.mobileLod1x1Chunks;
                b = p.mobileLodTier2Chunks;
                c = p.mobileLodTier3Chunks;
                max = p.mobileQuadLodLevel;
                trees = p.mobileLodTrees;
                shade = p.mobileLodShading;
                layered = p.mobileLodLayeredSides;
                water = p.mobileLodWaterDepth;
            }
        }

        cfgStart = Math.max(1, start);
        cfg1x1 = Math.max(0, a);
        cfgT2 = Math.max(0, b);
        cfgT3 = Math.max(0, c);
        cfg16 = Math.max(1, p.mobileLod16x16Chunks);
        cfgMax = Math.max(1, Math.min(3, max));
        cfgTrees = Math.max(0, Math.min(2, trees));
        cfgShade = Math.max(0, Math.min(2, shade));
        cfgLowPoly = p.mobileLodLowPoly;
        cfgLayered = layered;
        cfgWater = water;
        cfgBudget = Math.max(1, p.mobileLodBuildBudget);
        cfgDelayMs = Math.max(0, p.mobileLodUpdateDelay) * 100;
        cfgPauseFast = p.mobileLodPauseFast;
        cfgTreesMax = p.mobileLodTreesMaxChunks;
        cfgWall = Math.max(0, Math.min(2, p.mobileLodWallDetail));
        cfgZoom = p.mobileLodZoom;
        cfgZoomMax = Math.max(cfgStart, p.mobileLodZoomChunks);
        cfgZoomSpeed = Math.max(1, Math.min(3, p.mobileLodZoomSpeed));

        if (p.mobileLodPreset == 1) {
            cfgWall = 0;
            cfgTreesMax = 0;
        } else if (p.mobileLodPreset == 2) {
            cfgWall = 1;
        } else if (p.mobileLodPreset == 3) {
            cfgWall = 2;
        }
    }

    private static long sectionKey(int x, int y, int z) {
        return (((long) (x & 0x3FFFFF)) << 42) | (((long) (z & 0x3FFFFF)) << 20) | ((long) (y & 0xFFFFF));
    }

    private static long columnKey(int x, int z) {
        return (((long) x) << 32) ^ (z & 0xFFFFFFFFL);
    }

    private static boolean canopyOk(int code) {
        int t = cfgTrees;
        if (t >= 2) {
            return code <= 3;
        }
        return t == 1 && code <= 2;
    }

    /** 0 = normal blocks, 1..4 = LOD code. Has a half-chunk hysteresis so borders do not flicker. */
    public static int tierAt(int chunkX, int chunkZ, int currentCode, double camX, double camZ) {
        if (!enabled()) {
            return 0;
        }

        double dx = chunkX - Math.floor(camX / 16.0);
        double dz = chunkZ - Math.floor(camZ / 16.0);
        double dist = Math.sqrt(dx * dx + dz * dz);
        double z1 = cfgStart;

        if (currentCode > 0) {
            if (dist < z1 - 1.0) {
                return 0;
            }
        } else if (dist < z1) {
            return 0;
        }

        // zoomed in: pretend the chunk is closer so it gets a finer tier (but never finer than the LOD start)
        if (zoomScale < 1.0 && dist <= cfgZoomMax) {
            dist = Math.max(z1, dist * zoomScale);
        }

        double z2 = cfg1x1 > cfgStart ? cfg1x1 : z1;
        double z3 = Math.max((double) cfgT2, z2);
        double z4 = Math.max((double) cfgT3, z3);
        int maxCode = cfgMax + 1;

        int raw = dist < z2 ? 1 : (dist < z3 ? 2 : (dist < z4 ? 3 : 4));

        if (raw > maxCode) {
            raw = maxCode;
        }

        if (currentCode > 0 && currentCode != raw && currentCode <= maxCode) {
            double lo = currentCode == 1 ? z1 : (currentCode == 2 ? z2 : (currentCode == 3 ? z3 : z4));
            double hi = currentCode >= maxCode ? 1.0e9 : (currentCode == 1 ? z2 : (currentCode == 2 ? z3 : z4));

            if (hi > lo && dist >= lo - 0.5 && dist < hi + 0.5) {
                raw = currentCode;
            }
        }

        return raw;
    }

    /** LOD code for a column that is drawn from the outside LOD cache: 4x4 first, then 8x8 and 16x16 farther out */
    public static int outsideCodeAt(int chunkX, int chunkZ) {
        double dx = chunkX - Math.floor(cameraX / 16.0);
        double dz = chunkZ - Math.floor(cameraZ / 16.0);
        double dist = Math.sqrt(dx * dx + dz * dz);
        int code = 3;

        if (cfgMax >= 3 && dist >= Math.max(cfgT3, cfgT2)) {
            code = 4;
        }

        if (cfgMax >= 3 && dist >= Math.max(cfg16, cfgT3 + 1)) {
            code = 5;
        }

        return code;
    }

    private static int codeAt(int chunkX, int chunkZ, int current) {
        if (fakeColumn.test(columnKey(chunkX, chunkZ))) {
            return outsideCodeAt(chunkX, chunkZ);
        }

        return tierAt(chunkX, chunkZ, current, cameraX, cameraZ);
    }

    public static boolean targetLod(int chunkX, int chunkZ, boolean currentlyLod, double camX, double camZ) {
        return tierAt(chunkX, chunkZ, currentlyLod ? 1 : 0, camX, camZ) > 0;
    }

    public static boolean targetLod(int chunkX, int chunkZ, boolean currentlyLod) {
        return targetLod(chunkX, chunkZ, currentlyLod, cameraX, cameraZ);
    }

    /** Called for every visited section; queues a rebuild when its LOD code no longer matches. */
    public static void checkRebuild(RenderSection section) {
        if (section.mobileAir || !section.isBuilt() || section.getRunningJob() != null) {
            return;
        }

        int built = 0;
        int want;

        if (section.mobileOutside) {
            Integer t = BUILT_TIER.get(sectionKey(section.getChunkX(), section.getChunkY(), section.getChunkZ()));
            built = t == null ? 0 : t;
            want = outsideCodeAt(section.getChunkX(), section.getChunkZ());
        } else {
            if (section.mobileLodBuilt) {
                Integer t = BUILT_TIER.get(sectionKey(section.getChunkX(), section.getChunkY(), section.getChunkZ()));
                built = t == null ? 1 : t;
            }

            want = tierAt(section.getChunkX(), section.getChunkZ(), built, cameraX, cameraZ);
        }

        if (want != built) {
            // postpone tier changes while moving fast, right after crossing a chunk border, or past the per-frame cap
            long since = System.nanoTime() - lastChunkChangeNs;
            boolean hold = since < cfgDelayMs * 1_000_000L
                    || (cfgPauseFast && speedBps > 14.0)
                    || ++rebuildsThisFrame > cfgBudget * (zoomScale < 1.0 ? cfgZoomSpeed : 1);

            if (hold) {
                needRevisit = true;
                return;
            }

            section.setPendingUpdate(ChunkUpdateTypes.join(section.getPendingUpdate(), ChunkUpdateTypes.REBUILD), System.nanoTime());
        }
    }

    // ------------------------------------------------------------------------------------------------------------

    private static final class Look {
        TextureAtlasSprite upSprite;
        int upColor = 0xFFFFFFFF;
        int upTint = -1;
        TextureAtlasSprite sideSprite;
        int sideColor = 0xFFFFFFFF;
        int sideTint = -1;
        Material material = DefaultMaterials.SOLID;
    }

    private static final class Quad {
        final Material material;
        final ModelQuadFacing facing;
        final TextureAtlasSprite sprite;
        final ChunkVertexEncoder.Vertex[] vertices = ChunkVertexEncoder.Vertex.uninitializedQuad();

        Quad(Material material, ModelQuadFacing facing, TextureAtlasSprite sprite) {
            this.material = material;
            this.facing = facing;
            this.sprite = sprite;
        }
    }

    private static final int LIGHT = 15 << 20;

    private static int toColor(int argb) {
        return ColorARGB.toABGR(argb);
    }

    static int tintColor(Minecraft mc, BlockState state, BlockAndTintGetter view, BlockPos pos, int tintIndex) {
        if (tintIndex < 0) {
            return 0xFFFFFFFF;
        }

        int rgb = mc.getBlockColors().getColor(state, view, pos, tintIndex);
        return rgb == -1 ? 0xFFFFFFFF : (0xFF000000 | rgb);
    }

    private static TextureAtlasSprite firstSprite(List<BlockModelPart> parts, Direction dir) {
        for (BlockModelPart part : parts) {
            List<BakedQuad> quads = part.getQuads(dir);
            if (!quads.isEmpty()) {
                return quads.get(0).sprite();
            }
        }
        return null;
    }

    private static int firstTint(List<BlockModelPart> parts, Direction dir) {
        for (BlockModelPart part : parts) {
            List<BakedQuad> quads = part.getQuads(dir);
            if (!quads.isEmpty()) {
                return quads.get(0).tintIndex();
            }
        }
        return -1;
    }

    private static Look lookOf(Minecraft mc, BlockModelShaper shaper, BlockAndTintGetter view, BlockState state, BlockPos pos, HashMap<BlockState, Look> cache) {
        Look cached = cache.get(state);
        if (cached != null) {
            return cached;
        }

        Look look = new Look();

        if (!state.getFluidState().isEmpty() || state.getRenderShape() != net.minecraft.world.level.block.RenderShape.MODEL) {
            // water, lava and anything without a normal model: flat colour on a plain texture
            int color = 0xFF3F76E4;
            if (state.getFluidState().is(FluidTags.LAVA)) {
                color = 0xFFFF8A1F;
            } else if (state.getFluidState().isEmpty()) {
                color = 0xFF000000 | state.getMapColor(view, pos).col;
            }
            Look plain = plainLook(shaper, cache);
            look.upSprite = plain.upSprite;
            look.sideSprite = plain.sideSprite;
            look.upColor = color;
            look.sideColor = color;
        } else {
            List<BlockModelPart> parts = new ArrayList<>();
            shaper.getBlockModel(state).collectParts(RandomSource.create(42L), parts);

            look.upSprite = firstSprite(parts, Direction.UP);
            look.upTint = firstTint(parts, Direction.UP);
            look.upColor = tintColor(mc, state, view, pos, look.upTint);

            for (Direction dir : new Direction[]{Direction.NORTH, Direction.SOUTH, Direction.EAST, Direction.WEST}) {
                look.sideSprite = firstSprite(parts, dir);
                if (look.sideSprite != null) {
                    look.sideTint = firstTint(parts, dir);
                    look.sideColor = tintColor(mc, state, view, pos, look.sideTint);
                    break;
                }
            }

            if (look.upSprite == null && look.sideSprite == null) {
                Look plain = plainLook(shaper, cache);
                look.upSprite = plain.upSprite;
                look.sideSprite = plain.sideSprite;
                look.upTint = -1;
                look.sideTint = -1;
                look.upColor = 0xFF000000 | state.getMapColor(view, pos).col;
                look.sideColor = look.upColor;
            } else {
                if (look.upSprite == null) {
                    look.upSprite = look.sideSprite;
                    look.upColor = look.sideColor;
                    look.upTint = look.sideTint;
                }
                if (look.sideSprite == null) {
                    look.sideSprite = look.upSprite;
                    look.sideColor = look.upColor;
                    look.sideTint = look.upTint;
                }

                // grassy blocks: use the top texture and tint on the sides too, so far cliffs have no bright green strip
                if (state.is(Blocks.GRASS_BLOCK) || state.is(Blocks.PODZOL) || state.is(Blocks.MYCELIUM)) {
                    look.sideSprite = look.upSprite;
                    look.sideColor = look.upColor;
                    look.sideTint = look.upTint;
                }

                look.material = DefaultMaterials.forBlockState(state);
                if (look.material.pass.isTranslucent()) {
                    // ice, glass: draw as a plain light colour instead
                    Look plain = plainLook(shaper, cache);
                    look.upSprite = plain.upSprite;
                    look.sideSprite = plain.sideSprite;
                    look.upTint = -1;
                    look.sideTint = -1;
                    look.upColor = 0xFF000000 | state.getMapColor(view, pos).col;
                    look.sideColor = look.upColor;
                    look.material = DefaultMaterials.SOLID;
                }
            }
        }

        cache.put(state, look);
        return look;
    }

    private static Look plainLook(BlockModelShaper shaper, HashMap<BlockState, Look> cache) {
        BlockState plainState = Blocks.WHITE_CONCRETE.defaultBlockState();
        Look cached = cache.get(plainState);
        if (cached != null) {
            return cached;
        }

        Look look = new Look();
        List<BlockModelPart> parts = new ArrayList<>();
        shaper.getBlockModel(plainState).collectParts(RandomSource.create(42L), parts);
        look.upSprite = firstSprite(parts, Direction.UP);
        look.sideSprite = firstSprite(parts, Direction.NORTH);
        if (look.sideSprite == null) {
            look.sideSprite = look.upSprite;
        }
        cache.put(plainState, look);
        return look;
    }

    // ------------------------------------------------------------------------------------------------------------

    /**
     * Reads one world column. out[0] = top (first free y above the highest motion blocking block, leaves included),
     * out[1] = ground (same, but looking down through leaves, logs and plants of a tree).
     */
    static boolean column(ClientLevel level, BlockPos.MutableBlockPos p, int x, int z, int[] out) {
        if (!level.hasChunk(x >> 4, z >> 4)) {
            return false;
        }

        int h = level.getHeight(Heightmap.Types.MOTION_BLOCKING, x, z);
        int g = h;
        boolean leaves = false;

        for (int y = h - 1; y > h - 48; y--) {
            p.set(x, y, z);
            BlockState s = level.getBlockState(p);

            if (s.isAir()) {
                if (!leaves) {
                    break;
                }
                g = y;
            } else if (s.is(BlockTags.LEAVES)) {
                leaves = true;
                g = y;
            } else if (leaves && (s.is(BlockTags.LOGS) || s.getCollisionShape(level, p).isEmpty())) {
                g = y;
            } else {
                break;
            }
        }

        out[0] = h;
        out[1] = g;
        return true;
    }

    private static final class RealSource implements Source {
        final Minecraft mc;
        final ClientLevel level;
        final LevelSlice slice;
        final BlockPos.MutableBlockPos p = new BlockPos.MutableBlockPos();
        final BlockPos.MutableBlockPos q = new BlockPos.MutableBlockPos();

        RealSource(Minecraft mc, ClientLevel level, LevelSlice slice) {
            this.mc = mc;
            this.level = level;
            this.slice = slice;
        }

        @Override
        public boolean column(int x, int z, int[] out) {
            return MobileLod.column(this.level, this.p, x, z, out);
        }

        @Override
        public BlockState stateAt(int x, int y, int z) {
            return this.slice.getBlockState(x, y, z);
        }

        @Override
        public BlockState canopyState(int x, int z, int topY) {
            this.q.set(x, topY - 1, z);
            return this.level.getBlockState(this.q);
        }

        @Override
        public int tint(BlockState state, int tintIndex, int x, int y, int z, boolean canopy) {
            this.q.set(x, y, z);
            return tintColor(this.mc, state, this.slice, this.q, tintIndex);
        }

        @Override
        public int waterDepth(int x, int y, int z) {
            int depth = 0;

            for (int yy = y; yy > y - 40; yy--) {
                this.q.set(x, yy, z);

                if (this.level.getBlockState(this.q).getFluidState().isEmpty()) {
                    break;
                }

                depth++;
            }

            return depth;
        }

        @Override
        public BlockAndTintGetter view() {
            return this.slice;
        }
    }

    private static void put(ChunkVertexEncoder.Vertex v, float x, float y, float z, int color, float shade, float u, float vv) {
        v.x = x;
        v.y = y;
        v.z = z;
        v.color = color;
        v.ao = shade;
        v.u = u;
        v.v = vv;
        v.light = LIGHT;
    }

    private static float clampY(float y) {
        return y < 0.0f ? 0.0f : (y > 16.0f ? 16.0f : y);
    }

    /** corner order: c00 = (x0,z0), c01 = (x0,z1), c11 = (x1,z1), c10 = (x1,z0); heights are relative to the section */
    private static void topQuad(List<Quad> out, Look look, int argb, float x0, float x1, float z0, float z1,
                                float y00, float y01, float y11, float y10, float a00, float a01, float a11, float a10, float crop) {
        TextureAtlasSprite s = look.upSprite;
        Quad q = new Quad(look.material, ModelQuadFacing.POS_Y, s);
        int c = toColor(argb);
        float u0 = s.getU0(), u1 = s.getU1(), v0 = s.getV0(), v1 = s.getV1();

        if (crop < 1.0f) {
            // far away use only the middle of the texture so big quads don't show one huge magnified pattern
            float du = (u1 - u0) * (1.0f - crop) * 0.5f;
            float dv = (v1 - v0) * (1.0f - crop) * 0.5f;
            u0 += du;
            u1 -= du;
            v0 += dv;
            v1 -= dv;
        }

        put(q.vertices[0], x0, clampY(y00), z0, c, a00, u0, v0);
        put(q.vertices[1], x0, clampY(y01), z1, c, a01, u0, v1);
        put(q.vertices[2], x1, clampY(y11), z1, c, a11, u1, v1);
        put(q.vertices[3], x1, clampY(y10), z0, c, a10, u1, v0);
        out.add(q);
    }

    /** dir: 0 = +X, 1 = -X, 2 = +Z, 3 = -Z. The wall sits on the boundary plane of the cell and faces dir. */
    private static void wallQuad(List<Quad> out, Look look, int argb, int dir, float a0, float a1, float plane,
                                 float yBottom, float yTop, float aoBottom, float aoTop, float crop) {
        TextureAtlasSprite s = look.sideSprite;
        int c = toColor(argb);
        float u0 = s.getU0(), u1 = s.getU1(), v0 = s.getV0(), v1 = s.getV1();

        if (crop < 1.0f) {
            float du = (u1 - u0) * (1.0f - crop) * 0.5f;
            u0 += du;
            u1 -= du;
        }

        ModelQuadFacing facing = switch (dir) {
            case 0 -> ModelQuadFacing.POS_X;
            case 1 -> ModelQuadFacing.NEG_X;
            case 2 -> ModelQuadFacing.POS_Z;
            default -> ModelQuadFacing.NEG_Z;
        };
        Quad q = new Quad(look.material, facing, s);
        ChunkVertexEncoder.Vertex[] w = q.vertices;

        switch (dir) {
            case 0 -> { // +X, a0..a1 along Z
                put(w[0], plane, yTop, a1, c, aoTop, u0, v0);
                put(w[1], plane, yBottom, a1, c, aoBottom, u0, v1);
                put(w[2], plane, yBottom, a0, c, aoBottom, u1, v1);
                put(w[3], plane, yTop, a0, c, aoTop, u1, v0);
            }
            case 1 -> { // -X
                put(w[0], plane, yTop, a0, c, aoTop, u0, v0);
                put(w[1], plane, yBottom, a0, c, aoBottom, u0, v1);
                put(w[2], plane, yBottom, a1, c, aoBottom, u1, v1);
                put(w[3], plane, yTop, a1, c, aoTop, u1, v0);
            }
            case 2 -> { // +Z, a0..a1 along X
                put(w[0], a0, yTop, plane, c, aoTop, u0, v0);
                put(w[1], a0, yBottom, plane, c, aoBottom, u0, v1);
                put(w[2], a1, yBottom, plane, c, aoBottom, u1, v1);
                put(w[3], a1, yTop, plane, c, aoTop, u1, v0);
            }
            default -> { // -Z
                put(w[0], a1, yTop, plane, c, aoTop, u0, v0);
                put(w[1], a1, yBottom, plane, c, aoBottom, u0, v1);
                put(w[2], a0, yBottom, plane, c, aoBottom, u1, v1);
                put(w[3], a0, yTop, plane, c, aoTop, u1, v0);
            }
        }

        out.add(q);
    }

    private static int shadeWater(int argb, int depth) {
        float f = Math.min(1.0f, depth / 24.0f);
        float k = 1.15f - 0.65f * f;
        int r = Math.min(255, (int) (((argb >> 16) & 255) * k));
        int g = Math.min(255, (int) (((argb >> 8) & 255) * k));
        int b = Math.min(255, (int) ((argb & 255) * k));
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    // ------------------------------------------------------------------------------------------------------------

    /**
     * Builds the LOD mesh for one real chunk section. Returns false (and adds nothing) if anything is unavailable,
     * so the caller can fall back to the normal block-by-block mesh.
     */
    public static boolean build(ChunkBuildBuffers buffers, BlockModelShaper shaper, LevelSlice slice, int originX, int originY, int originZ) {
        Minecraft mc = Minecraft.getInstance();
        ClientLevel level = mc.level;

        if (level == null) {
            return false;
        }

        long skey = sectionKey(originX >> 4, originY >> 4, originZ >> 4);
        Integer prev = BUILT_TIER.get(skey);
        int code = tierAt(originX >> 4, originZ >> 4, prev == null ? 0 : prev, cameraX, cameraZ);

        if (code < 1) {
            code = 1;
        }

        return run(buffers, mc, shaper, new RealSource(mc, level, slice), originX, originY, originZ, code, skey);
    }

    /** Builds the LOD mesh for one section of the outside LOD, from a cached column source. */
    public static boolean buildOutside(ChunkBuildBuffers buffers, BlockModelShaper shaper, Source source, int chunkX, int chunkY, int chunkZ) {
        Minecraft mc = Minecraft.getInstance();
        long skey = sectionKey(chunkX, chunkY, chunkZ);
        int code = Math.max(3, outsideCodeAt(chunkX, chunkZ));

        return run(buffers, mc, shaper, source, chunkX << 4, chunkY << 4, chunkZ << 4, code, skey);
    }

    private static boolean run(ChunkBuildBuffers buffers, Minecraft mc, BlockModelShaper shaper, Source source,
                               int originX, int originY, int originZ, int code, long skey) {
        Mesher m = new Mesher(mc, shaper, source, originX, originY, originZ, code);
        m.run();

        // everything computed successfully: now write to the buffers
        for (Quad q : m.quads) {
            var builder = buffers.get(q.material);
            builder.getVertexBuffer(q.facing).push(q.vertices, q.material.bits());
            builder.addSprite(q.sprite);
        }

        BUILT_TIER.put(skey, code);
        return true;
    }

    private static final float LX = -0.349f;
    private static final float LY = 0.857f;
    private static final float LZ = -0.379f;

    private static final class Mesher {
        final Minecraft mc;
        final BlockModelShaper shaper;
        final Source src;
        final int originX;
        final int originY;
        final int originZ;
        final int code;
        final int rs;
        final int groups;
        final int gridSize;
        final int secMinY;
        final int secMaxY;
        final int minThick;
        final float crop;
        final boolean layered;
        final boolean canopyOn;
        final boolean carpetOn;
        final boolean water;
        final boolean mergeFlat;
        final boolean lowPoly;
        final int shadeLevel;
        final float shadeK;
        final float cornerK;
        final float wallGrad;
        final float forestK;
        final int cliffThr;

        final int[] gH;
        final int[] cH;
        final int[] sX;
        final int[] sZ;
        final int[] gBy;
        final int[] cBy;
        final int[] tree;
        final int[] tTop;
        final boolean[] borderSame;
        final boolean[] carpet;
        final BlockState[] gState;
        final BlockState[] cState;

        final List<Quad> quads = new ArrayList<>();
        final HashMap<BlockState, Look> looks = new HashMap<>();
        final BlockPos.MutableBlockPos pos = new BlockPos.MutableBlockPos();
        final int[] col = new int[2];
        final int[] tmp = new int[4];
        final int[] tmp2 = new int[4];
        final int[] res = new int[6];

        Mesher(Minecraft mc, BlockModelShaper shaper, Source src, int originX, int originY, int originZ, int code) {
            this.mc = mc;
            this.shaper = shaper;
            this.src = src;
            this.originX = originX;
            this.originY = originY;
            this.originZ = originZ;
            this.code = code;
            this.rs = code <= 2 ? 1 : (1 << (code - 1));
            this.groups = 16 / this.rs;
            this.gridSize = this.groups + 2;
            this.secMinY = originY;
            this.secMaxY = originY + 16;
            this.minThick = Math.max(2, this.rs);
            this.crop = code <= 2 ? 1.0f : (code == 3 ? 0.5f : 0.25f);
            this.layered = cfgLayered;
            double treeDist = Math.hypot((originX >> 4) - Math.floor(cameraX / 16.0), (originZ >> 4) - Math.floor(cameraZ / 16.0));
            this.canopyOn = canopyOk(code) && (cfgTreesMax <= 0 || treeDist <= cfgTreesMax);
            this.carpetOn = cfgTrees > 0 && !this.canopyOn;
            this.water = cfgWater;
            this.mergeFlat = code == 2;
            this.lowPoly = cfgLowPoly && code >= 3;
            this.shadeLevel = cfgShade;
            this.shadeK = cfgShade == 0 ? 0.0f : (cfgShade == 1 ? 0.9f : 1.5f);
            this.cornerK = cfgShade == 0 ? 0.0f : (cfgShade == 1 ? 0.06f : 0.11f);
            this.wallGrad = cfgShade == 0 ? 0.0f : (cfgShade == 1 ? 0.14f : 0.26f);
            this.forestK = cfgShade == 0 ? 0.0f : (cfgShade == 1 ? 0.05f : 0.09f);
            this.cliffThr = this.rs + (this.rs >> 2);

            int n = this.gridSize * this.gridSize;
            this.gH = new int[n];
            this.cH = new int[n];
            this.sX = new int[n];
            this.sZ = new int[n];
            this.gBy = new int[n];
            this.cBy = new int[n];
            this.tree = new int[n];
            this.tTop = new int[n];
            this.borderSame = new boolean[n];
            this.carpet = new boolean[n];
            this.gState = new BlockState[n];
            this.cState = new BlockState[n];
        }

        void run() {
            sampleGrid();
            prepareStates();
            emitAll();
        }

        // ---- sampling -------------------------------------------------------------------------------------------

        void sampleGrid() {
            for (int gz = -1; gz <= groups; gz++) {
                for (int gx = -1; gx <= groups; gx++) {
                    int idx = (gz + 1) * gridSize + (gx + 1);
                    boolean border = gx < 0 || gx >= groups || gz < 0 || gz >= groups;

                    if (border) {
                        int ncx = (originX >> 4) + (gx < 0 ? -1 : (gx >= groups ? 1 : 0));
                        int ncz = (originZ >> 4) + (gz < 0 ? -1 : (gz >= groups ? 1 : 0));
                        int nCode = codeAt(ncx, ncz, 0);

                        if (lowPoly && nCode == code && cellSample(originX + gx * rs, originZ + gz * rs)) {
                            // same tier next door: use the very same cell the neighbour builds, so smoothed slopes meet without cracks
                            gH[idx] = res[0];
                            cH[idx] = res[1];
                            borderSame[idx] = true;
                            continue;
                        }

                        int ex0;
                        int ex1;
                        int ez0;
                        int ez1;

                        if (gx < 0) {
                            ex0 = originX - 1;
                            ex1 = ex0;
                        } else if (gx >= groups) {
                            ex0 = originX + 16;
                            ex1 = ex0;
                        } else {
                            ex0 = originX + gx * rs;
                            ex1 = ex0 + rs - 1;
                        }

                        if (gz < 0) {
                            ez0 = originZ - 1;
                            ez1 = ez0;
                        } else if (gz >= groups) {
                            ez0 = originZ + 16;
                            ez1 = ez0;
                        } else {
                            ez0 = originZ + gz * rs;
                            ez1 = ez0 + rs - 1;
                        }

                        int g = borderGround(ex0, ex1, ez0, ez1);
                        gH[idx] = g;
                        cH[idx] = (canopyOn && g != Integer.MIN_VALUE) ? borderCanopy(ex0, ex1, ez0, ez1, g) : 0;
                        continue;
                    }

                    if (!cellSample(originX + gx * rs, originZ + gz * rs)) {
                        gH[idx] = Integer.MIN_VALUE;
                        continue;
                    }

                    gH[idx] = res[0];
                    cH[idx] = res[1];
                    sX[idx] = res[2];
                    sZ[idx] = res[3];
                    tree[idx] = res[4];
                    tTop[idx] = res[5];
                }
            }
        }

        /** samples one cell (the column itself for 1x1, the average of 4 corner columns for the bigger ones) */
        boolean cellSample(int x0, int z0) {
            int n = rs == 1 ? 1 : 4;
            int far = rs - 1;
            int sumG = 0;
            int sumH = 0;
            int cover = 0;

            for (int i = 0; i < n; i++) {
                int x = x0 + ((i & 1) == 0 ? 0 : far);
                int z = z0 + ((i & 2) == 0 ? 0 : far);

                if (!src.column(x, z, col)) {
                    return false;
                }

                tmp[i] = col[1];
                sumG += col[1];
                sumH += col[0];

                if (col[0] - col[1] >= 3) {
                    cover++;
                }
            }

            int g = Math.round((float) sumG / n);
            int h = Math.round((float) sumH / n);

            int best = 0;
            int bd = Integer.MAX_VALUE;
            for (int i = 0; i < n; i++) {
                int d = Math.abs(tmp[i] - g);
                if (d < bd) {
                    bd = d;
                    best = i;
                }
            }

            res[2] = x0 + ((best & 1) == 0 ? 0 : far);
            res[3] = z0 + ((best & 2) == 0 ? 0 : far);
            res[4] = cover;
            res[5] = h;

            if (canopyOn) {
                if (cover == n) {
                    res[0] = g;
                    res[1] = h;
                } else {
                    res[0] = (h - g < 3) ? h : g;
                    res[1] = 0;
                }
            } else {
                res[0] = (cover == 0 && h - g < 3) ? h : g;
                res[1] = 0;
            }

            return true;
        }

        int cellMin(int x0, int z0, int s, boolean canopy) {
            int far = s - 1;
            int n = s == 1 ? 1 : 4;
            int best = Integer.MAX_VALUE;

            for (int i = 0; i < n; i++) {
                int x = x0 + ((i & 1) == 0 ? 0 : far);
                int z = z0 + ((i & 2) == 0 ? 0 : far);

                if (!src.column(x, z, tmp2)) {
                    return Integer.MIN_VALUE;
                }

                int v = canopy ? (tmp2[0] - tmp2[1] >= 3 ? tmp2[0] : tmp2[1]) : tmp2[1];

                if (v < best) {
                    best = v;
                }
            }

            return best;
        }

        int minOver(int ex0, int ex1, int ez0, int ez1, int nSize, int best, boolean canopy) {
            if (best == Integer.MIN_VALUE) {
                return best;
            }

            int mask = ~(nSize - 1);

            for (int x = ex0 & mask; x <= ex1; x += nSize) {
                for (int z = ez0 & mask; z <= ez1; z += nSize) {
                    int h = cellMin(x, z, nSize, canopy);

                    if (h == Integer.MIN_VALUE) {
                        return Integer.MIN_VALUE;
                    }

                    if (h < best) {
                        best = h;
                    }
                }
            }

            return best;
        }

        /**
         * Ground height on the far side of a section border. Takes the lowest of the real columns and of the
         * neighbour's own big cells, so a wall always reaches below whatever the neighbour draws and no gaps open between tiers.
         */
        int borderGround(int ex0, int ex1, int ez0, int ez1) {
            int ncx = ex0 >> 4;
            int ncz = ez0 >> 4;
            int fresh = codeAt(ncx, ncz, 0);
            Integer mapped = BUILT_TIER.get(sectionKey(ncx, originY >> 4, ncz));

            int best = minOver(ex0, ex1, ez0, ez1, 1, Integer.MAX_VALUE, false);

            if (fresh >= 3) {
                best = minOver(ex0, ex1, ez0, ez1, 1 << (fresh - 1), best, false);
            }

            if (mapped != null && mapped >= 3 && mapped != fresh) {
                best = minOver(ex0, ex1, ez0, ez1, 1 << (Math.min(5, mapped) - 1), best, false);
            }

            return best;
        }

        /** top of the neighbour's canopy (or its ground if it draws no canopy there) */
        int borderCanopy(int ex0, int ex1, int ez0, int ez1, int groundBorder) {
            int ncx = ex0 >> 4;
            int ncz = ez0 >> 4;
            int fresh = codeAt(ncx, ncz, 0);
            boolean present = fresh == 0 || canopyOk(fresh);

            if (!present) {
                return groundBorder;
            }

            int best = minOver(ex0, ex1, ez0, ez1, 1, Integer.MAX_VALUE, true);

            if (fresh >= 3) {
                best = minOver(ex0, ex1, ez0, ez1, 1 << (fresh - 1), best, true);
            }

            return best == Integer.MIN_VALUE ? groundBorder : best;
        }

        // ---- block states ---------------------------------------------------------------------------------------

        void prepareStates() {
            for (int gz = 0; gz < groups; gz++) {
                for (int gx = 0; gx < groups; gx++) {
                    int idx = (gz + 1) * gridSize + (gx + 1);

                    if (gH[idx] == Integer.MIN_VALUE) {
                        continue;
                    }

                    int lx = sX[idx];
                    int lz = sZ[idx];

                    int ly = Math.max(secMinY, Math.min(secMaxY - 1, gH[idx] - 1));
                    BlockState st = src.stateAt(lx, ly, lz);

                    if (st == null || st.isAir()) {
                        while (ly > secMinY && (st == null || st.isAir())) {
                            ly--;
                            st = src.stateAt(lx, ly, lz);
                        }
                        if (st == null || st.isAir()) {
                            st = null;
                        }
                    }

                    gState[idx] = st;
                    gBy[idx] = ly;

                    if (cH[idx] > 0) {
                        int cy = Math.max(secMinY, Math.min(secMaxY - 1, cH[idx] - 1));
                        BlockState cs = src.canopyState(lx, lz, cH[idx]);

                        if (cs == null || cs.isAir()) {
                            cs = null;
                        }

                        cState[idx] = cs;
                        cBy[idx] = cy;
                    } else if (carpetOn && tree[idx] >= (rs == 1 ? 1 : 3) && st != null) {
                        // trees are not drawn at this size: paint the ground with leaves so forests stay green
                        BlockState leaf = src.canopyState(lx, lz, tTop[idx]);

                        if (leaf != null && !leaf.isAir()) {
                            gState[idx] = leaf;
                            carpet[idx] = true;
                        }
                    }
                }
            }
        }

        Look lookFor(BlockState st, int lx, int by, int lz) {
            pos.set(lx, by, lz);
            Look l = lookOf(mc, shaper, src.view(), st, pos, looks);
            return (l.upSprite == null || l.sideSprite == null) ? null : l;
        }

        int upColor(BlockState st, Look look, int x, int y, int z, boolean canopy) {
            return look.upTint < 0 ? look.upColor : src.tint(st, look.upTint, x, y, z, canopy);
        }

        int sideColor(BlockState st, Look look, int x, int y, int z, boolean canopy) {
            return look.sideTint < 0 ? look.sideColor : src.tint(st, look.sideTint, x, y, z, canopy);
        }

        int waterColor(BlockState state, int color, int x, int y, int z) {
            if (!water || !state.getFluidState().is(FluidTags.WATER)) {
                return color;
            }

            return shadeWater(color, src.waterDepth(x, y, z));
        }

        // ---- shading --------------------------------------------------------------------------------------------

        int hAt(int gx, int gz) {
            return gH[(gz + 1) * gridSize + (gx + 1)];
        }

        float lightShade(float dx, float dz) {
            if (shadeLevel == 0) {
                return 1.0f;
            }

            float inv = 1.0f / (float) Math.sqrt(dx * dx + 1.0f + dz * dz);
            float dot = (-dx * inv) * LX + inv * LY + (-dz * inv) * LZ;
            float s = 1.0f + shadeK * (dot - LY);
            return s < 0.55f ? 0.55f : (s > 1.0f ? 1.0f : s);
        }

        float slopeShade(int gx, int gz, int h) {
            int hw = hAt(gx - 1, gz);
            int he = hAt(gx + 1, gz);
            int hn = hAt(gx, gz - 1);
            int hs = hAt(gx, gz + 1);
            if (hw == Integer.MIN_VALUE) hw = h;
            if (he == Integer.MIN_VALUE) he = h;
            if (hn == Integer.MIN_VALUE) hn = h;
            if (hs == Integer.MIN_VALUE) hs = h;
            return lightShade((he - hw) / (2.0f * rs), (hs - hn) / (2.0f * rs));
        }

        /** darkens a vertex where taller terrain sits next to it, like ambient occlusion at the foot of a cliff */
        float cornerAo(int gx, int gz, int xi, int zi, int h) {
            if (cornerK == 0.0f) {
                return 1.0f;
            }

            int dx = xi == 0 ? -1 : 1;
            int dz = zi == 0 ? -1 : 1;
            int a = hAt(gx + dx, gz);
            int b = hAt(gx, gz + dz);
            int d = hAt(gx + dx, gz + dz);
            int n = 0;

            if (a != Integer.MIN_VALUE && a > h + 1) n++;
            if (b != Integer.MIN_VALUE && b > h + 1) n++;
            if (d != Integer.MIN_VALUE && d > h + 1 && n == 0) n++;

            return 1.0f - cornerK * n;
        }

        /** low poly vertex height: the average of the cells around the vertex that are joined to this cell without a cliff between them */
        float vertexHeight(int gx, int gz, int xi, int zi) {
            int dx = xi == 0 ? -1 : 1;
            int dz = zi == 0 ? -1 : 1;
            int hA = hAt(gx, gz);
            int hB = hAt(gx + dx, gz);
            int hC = hAt(gx, gz + dz);
            int hD = hAt(gx + dx, gz + dz);
            int min = Integer.MIN_VALUE;

            boolean eAB = hB != min && Math.abs(hA - hB) <= cliffThr;
            boolean eAC = hC != min && Math.abs(hA - hC) <= cliffThr;
            boolean eBD = hB != min && hD != min && Math.abs(hB - hD) <= cliffThr;
            boolean eCD = hC != min && hD != min && Math.abs(hC - hD) <= cliffThr;

            boolean rB = false;
            boolean rC = false;
            boolean rD = false;

            for (int i = 0; i < 3; i++) {
                if (eAB) rB = true;
                if (eAC) rC = true;
                if (eBD && rB) rD = true;
                if (eCD && rC) rD = true;
                if (eBD && rD) rB = true;
                if (eCD && rD) rC = true;
            }

            float sum = hA;
            int n = 1;

            if (rB) {
                sum += hB;
                n++;
            }
            if (rC) {
                sum += hC;
                n++;
            }
            if (rD) {
                sum += hD;
                n++;
            }

            return sum / n;
        }

        // ---- emitting -------------------------------------------------------------------------------------------

        void emitAll() {
            int n = gridSize * gridSize;
            boolean[] skipG = new boolean[n];
            boolean[] skipC = new boolean[n];

            if (mergeFlat) {
                mergeFlatTops(skipG, skipC);
            }

            for (int gz = 0; gz < groups; gz++) {
                for (int gx = 0; gx < groups; gx++) {
                    int idx = (gz + 1) * gridSize + (gx + 1);

                    if (gH[idx] == Integer.MIN_VALUE) {
                        continue;
                    }

                    emitGround(gx, gz, idx, skipG[idx]);

                    if (cH[idx] > 0 && cState[idx] != null) {
                        emitCanopy(gx, gz, idx, skipC[idx]);
                    }
                }
            }
        }

        /** 2x2 mode: where four neighbouring columns have the same height and block, draw one big top quad instead of four */
        void mergeFlatTops(boolean[] skipG, boolean[] skipC) {
            for (int gz = 0; gz + 1 < groups; gz += 2) {
                for (int gx = 0; gx + 1 < groups; gx += 2) {
                    int i0 = (gz + 1) * gridSize + (gx + 1);
                    int i1 = i0 + 1;
                    int i2 = i0 + gridSize;
                    int i3 = i2 + 1;

                    int h = gH[i0];

                    if (h != Integer.MIN_VALUE && h - 1 >= secMinY && h - 1 < secMaxY
                            && gH[i1] == h && gH[i2] == h && gH[i3] == h
                            && gState[i0] != null && gState[i1] == gState[i0] && gState[i2] == gState[i0] && gState[i3] == gState[i0]
                            && flatAround(gx, gz, h)) {
                        Look look = lookFor(gState[i0], sX[i0], gBy[i0], sZ[i0]);

                        if (look != null) {
                            int color = waterColor(gState[i0], upColor(gState[i0], look, sX[i0], gBy[i0], sZ[i0], carpet[i0]), sX[i0], gBy[i0], sZ[i0]);
                            float y = (float) (h - secMinY);
                            float s = slopeShade(gx, gz, h);
                            if (tree[i0] > 0) s *= 1.0f - forestK * tree[i0] * 0.5f;
                            topQuad(quads, look, color, gx, gx + 2, gz, gz + 2, y, y, y, y,
                                    s * cornerAo(gx, gz, 0, 0, h), s * cornerAo(gx, gz + 1, 0, 1, h), s * cornerAo(gx + 1, gz + 1, 1, 1, h), s * cornerAo(gx + 1, gz, 1, 0, h), 1.0f);
                            skipG[i0] = true;
                            skipG[i1] = true;
                            skipG[i2] = true;
                            skipG[i3] = true;
                        }
                    }

                    int c = cH[i0];

                    if (c > 0 && c - 1 >= secMinY && c - 1 < secMaxY
                            && cH[i1] == c && cH[i2] == c && cH[i3] == c
                            && cState[i0] != null && cState[i1] == cState[i0] && cState[i2] == cState[i0] && cState[i3] == cState[i0]) {
                        Look look = lookFor(cState[i0], sX[i0], cBy[i0], sZ[i0]);

                        if (look != null) {
                            int color = upColor(cState[i0], look, sX[i0], cBy[i0], sZ[i0], true);
                            float y = (float) (c - secMinY);
                            topQuad(quads, look, color, gx, gx + 2, gz, gz + 2, y, y, y, y, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f);
                            skipC[i0] = true;
                            skipC[i1] = true;
                            skipC[i2] = true;
                            skipC[i3] = true;
                        }
                    }
                }
            }
        }

        /** merged tops only where the slope around them is flat, so the shading of slopes stays per column */
        boolean flatAround(int gx, int gz, int h) {
            if (shadeLevel == 0) {
                return true;
            }

            for (int dz = -1; dz <= 2; dz++) {
                for (int dx = -1; dx <= 2; dx++) {
                    int v = hAt(gx + dx, gz + dz);
                    if (v != Integer.MIN_VALUE && Math.abs(v - h) > 1) {
                        return false;
                    }
                }
            }

            return true;
        }

        void emitGround(int gx, int gz, int idx, boolean skipTop) {
            int h = gH[idx];
            BlockState state = gState[idx];

            if (state == null) {
                return;
            }

            boolean topHere = h - 1 >= secMinY && h - 1 < secMaxY;
            boolean wallHere = false;

            for (int[] st : STEPS) {
                int ni = (gz + 1 + st[1]) * gridSize + (gx + 1 + st[0]);
                int hn = gH[ni];

                if (hn != Integer.MIN_VALUE && hn < h && Math.min(h, secMaxY) > Math.max(hn, secMinY)) {
                    wallHere = true;
                }
            }

            if (!topHere && !wallHere) {
                return;
            }

            int lx = sX[idx];
            int lz = sZ[idx];
            Look look = lookFor(state, lx, gBy[idx], lz);

            if (look == null) {
                return;
            }

            // colours are read per position, so the biome tint blends smoothly from cell to cell
            int topColor = upColor(state, look, lx, gBy[idx], lz, carpet[idx]);
            int sideColor = sideColor(state, look, lx, gBy[idx], lz, carpet[idx]);

            float x0 = gx * rs;
            float x1 = x0 + rs;
            float z0 = gz * rs;
            float z1 = z0 + rs;

            float c00 = h;
            float c01 = h;
            float c11 = h;
            float c10 = h;
            float shade;

            if (lowPoly) {
                c00 = vertexHeight(gx, gz, 0, 0);
                c01 = vertexHeight(gx, gz, 0, 1);
                c11 = vertexHeight(gx, gz, 1, 1);
                c10 = vertexHeight(gx, gz, 1, 0);
                shade = lightShade(((c10 + c11) - (c00 + c01)) / (2.0f * rs), ((c01 + c11) - (c00 + c10)) / (2.0f * rs));
            } else {
                shade = slopeShade(gx, gz, h);
            }

            // forest floor under (or replaced by) trees is a little darker
            if (tree[idx] > 0) {
                shade *= 1.0f - forestK * (tree[idx] > 4 ? 4 : tree[idx]) * 0.5f;
            }

            if (topHere && !skipTop) {
                float base = (float) secMinY;
                topQuad(quads, look, waterColor(state, topColor, lx, gBy[idx], lz), x0, x1, z0, z1,
                        c00 - base, c01 - base, c11 - base, c10 - base,
                        shade * cornerAo(gx, gz, 0, 0, h), shade * cornerAo(gx, gz, 0, 1, h),
                        shade * cornerAo(gx, gz, 1, 1, h), shade * cornerAo(gx, gz, 1, 0, h), crop);
            }

            for (int dir = 0; dir < 4; dir++) {
                int[] st = STEPS[dir];
                int ni = (gz + 1 + st[1]) * gridSize + (gx + 1 + st[0]);
                int hn = gH[ni];

                if (hn == Integer.MIN_VALUE) {
                    continue;
                }

                int bottom;
                int top;

                if (lowPoly) {
                    boolean inside = gx + st[0] >= 0 && gx + st[0] < groups && gz + st[1] >= 0 && gz + st[1] < groups;
                    boolean sameRing = inside || borderSame[ni];
                    boolean cliff = Math.abs(h - hn) > cliffThr;

                    if (sameRing && !cliff) {
                        continue;
                    }

                    if (!sameRing && hn >= h) {
                        continue;
                    }

                    float e0;
                    float e1;
                    float n0;
                    float n1;

                    switch (dir) {
                        case 0 -> {
                            e0 = c10;
                            e1 = c11;
                            n0 = sameRing ? vertexHeight(gx + 1, gz, 0, 0) : hn;
                            n1 = sameRing ? vertexHeight(gx + 1, gz, 0, 1) : hn;
                        }
                        case 1 -> {
                            e0 = c00;
                            e1 = c01;
                            n0 = sameRing ? vertexHeight(gx - 1, gz, 1, 0) : hn;
                            n1 = sameRing ? vertexHeight(gx - 1, gz, 1, 1) : hn;
                        }
                        case 2 -> {
                            e0 = c01;
                            e1 = c11;
                            n0 = sameRing ? vertexHeight(gx, gz + 1, 0, 0) : hn;
                            n1 = sameRing ? vertexHeight(gx, gz + 1, 1, 0) : hn;
                        }
                        default -> {
                            e0 = c00;
                            e1 = c10;
                            n0 = sameRing ? vertexHeight(gx, gz - 1, 0, 1) : hn;
                            n1 = sameRing ? vertexHeight(gx, gz - 1, 1, 1) : hn;
                        }
                    }

                    top = Math.max(h, (int) Math.ceil(Math.max(e0, e1)));
                    bottom = Math.min(hn, (int) Math.floor(Math.min(n0, n1)));

                    if (top <= bottom) {
                        continue;
                    }

                    bottom = Math.max(bottom, secMinY);
                    top = Math.min(top, secMaxY);
                } else {
                    if (hn >= h) {
                        continue;
                    }

                    bottom = Math.max(hn, secMinY);
                    top = Math.min(h, secMaxY);
                }

                if (top <= bottom) {
                    continue;
                }

                float a0;
                float a1;
                float plane;

                switch (dir) {
                    case 0 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x1;
                    }
                    case 1 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x0;
                    }
                    case 2 -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z1;
                    }
                    default -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z0;
                    }
                }

                if (layered) {
                    wallBands(look, sideColor, lx, lz, dir, a0, a1, plane, bottom, top, h, h <= secMaxY, minThick);
                } else {
                    emitWall(look, sideColor, dir, a0, a1, plane, bottom, top, h);
                }
            }
        }

        /** a tree canopy: a thin slab of leaves (up to 3 blocks) at the top of the tree, with the ground visible below it */
        void emitCanopy(int gx, int gz, int idx, boolean skipTop) {
            int c = cH[idx];
            int g = gH[idx];
            int cb = Math.max(g, c - 3);
            BlockState state = cState[idx];

            boolean topHere = c - 1 >= secMinY && c - 1 < secMaxY;
            boolean wallHere = false;

            for (int[] st : STEPS) {
                int ni = (gz + 1 + st[1]) * gridSize + (gx + 1 + st[0]);

                if (gH[ni] == Integer.MIN_VALUE) {
                    continue;
                }

                int cn = cH[ni] > 0 ? cH[ni] : gH[ni];

                if (cn < c && Math.min(c, secMaxY) > Math.max(Math.max(cn, cb), secMinY)) {
                    wallHere = true;
                }
            }

            if (!topHere && !wallHere) {
                return;
            }

            int lx = sX[idx];
            int lz = sZ[idx];
            Look look = lookFor(state, lx, cBy[idx], lz);

            if (look == null) {
                return;
            }

            int topColor = upColor(state, look, lx, cBy[idx], lz, true);
            int sideColor = sideColor(state, look, lx, cBy[idx], lz, true);

            float x0 = gx * rs;
            float x1 = x0 + rs;
            float z0 = gz * rs;
            float z1 = z0 + rs;

            if (topHere && !skipTop) {
                float y = (float) (c - secMinY);
                topQuad(quads, look, topColor, x0, x1, z0, z1, y, y, y, y, 1.0f, 1.0f, 1.0f, 1.0f, crop);
            }

            for (int dir = 0; dir < 4; dir++) {
                int[] st = STEPS[dir];
                int ni = (gz + 1 + st[1]) * gridSize + (gx + 1 + st[0]);

                if (gH[ni] == Integer.MIN_VALUE) {
                    continue;
                }

                int cn = cH[ni] > 0 ? cH[ni] : gH[ni];

                if (cn >= c) {
                    continue;
                }

                int bottom = Math.max(Math.max(cn, cb), secMinY);
                int top = Math.min(c, secMaxY);

                if (top <= bottom) {
                    continue;
                }

                float a0;
                float a1;
                float plane;

                switch (dir) {
                    case 0 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x1;
                    }
                    case 1 -> {
                        a0 = z0;
                        a1 = z1;
                        plane = x0;
                    }
                    case 2 -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z1;
                    }
                    default -> {
                        a0 = x0;
                        a1 = x1;
                        plane = z0;
                    }
                }

                emitWall(look, sideColor, dir, a0, a1, plane, bottom, top, c);
            }
        }

        // ---- walls ----------------------------------------------------------------------------------------------

        float wallAo(int dir, int yAbs, int wallTop) {
            float base = dir < 2 ? 0.6f : 0.8f;

            if (wallGrad == 0.0f) {
                return base;
            }

            float f = (wallTop - yAbs) / 24.0f;
            f = f < 0.0f ? 0.0f : (f > 1.0f ? 1.0f : f);
            return base * (1.0f - wallGrad * f);
        }

        void emitWall(Look look, int color, int dir, float a0, float a1, float plane, int yb, int yt, int wallTop) {
            if (yt <= yb) {
                return;
            }

            wallQuad(quads, look, color, dir, a0, a1, plane, (float) (yb - secMinY), (float) (yt - secMinY),
                    wallAo(dir, yb, wallTop), wallAo(dir, yt, wallTop), crop);
        }

        void emitBand(Look look, int color, Look fallback, int fallbackColor, int dir, float a0, float a1, float plane, int yb, int yt, int wallTop) {
            if (yt <= yb) {
                return;
            }

            if (look == null || look.sideSprite == null) {
                look = fallback;
                color = fallbackColor;
            }

            emitWall(look, color, dir, a0, a1, plane, yb, yt, wallTop);
        }

        /**
         * Draws one cliff wall as layers taken from the real blocks in the sample column: the cap block (grass),
         * then dirt, then stone and so on. Layers thinner than minThick are merged into the layer above, and
         * a wall never gets more than 4 layers.
         */
        void wallBands(Look fallback, int fallbackColor, int lx, int lz, int dir, float a0, float a1, float plane,
                       int bottom, int top, int wallTop, boolean capAtTop, int minThick) {
            BlockState cur = null;
            Look curLook = null;
            int curColor = 0;
            int runTop = top;
            int bands = 0;

            for (int y = top - 1; y >= bottom; y--) {
                BlockState s = src.stateAt(lx, y, lz);

                if (s == null || s.isAir()) {
                    continue;
                }

                if (cur == null) {
                    cur = s;
                    pos.set(lx, y, lz);
                    curLook = lookOf(mc, shaper, src.view(), s, pos, looks);
                    curColor = sideColor(s, curLook, lx, y, lz, false);
                    continue;
                }

                if (s == cur) {
                    continue;
                }

                int runLen = runTop - (y + 1);
                int need = (bands == 0 && capAtTop) ? 1 : minThick;

                if (runLen >= need && bands < (cfgWall == 2 ? 3 : (cfgWall == 1 ? 1 : 0))) {
                    emitBand(curLook, curColor, fallback, fallbackColor, dir, a0, a1, plane, y + 1, runTop, wallTop);
                    bands++;
                    cur = s;
                    pos.set(lx, y, lz);
                    curLook = lookOf(mc, shaper, src.view(), s, pos, looks);
                    curColor = sideColor(s, curLook, lx, y, lz, false);
                    runTop = y + 1;
                }
            }

            if (cur == null) {
                emitBand(fallback, fallbackColor, fallback, fallbackColor, dir, a0, a1, plane, bottom, top, wallTop);
            } else {
                emitBand(curLook, curColor, fallback, fallbackColor, dir, a0, a1, plane, bottom, runTop, wallTop);
            }
        }
    }
}
'''

OUTSIDE_JAVA = r'''package net.caffeinemc.mods.sodium.client.render.chunk;

import net.caffeinemc.mods.sodium.client.SodiumClientMod;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.level.BlockAndTintGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.storage.LevelResource;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

/**
 * Sodium Mobile v2.0: outside LOD.
 * Remembers a coarse summary of every chunk the player has seen (4x4 block cells) and draws it beyond the render
 * distance through Sodium's own section pipeline (fake render sections built by MobileLodTask).
 * Everything here runs on the render thread, except the cache source which is read by the chunk builder threads.
 * Any error switches the feature off for the rest of the session.
 */
public final class MobileOutsideLod {
    private static final int BYTES_PER_CHUNK = 700;
    private static final long CAPTURE_BUDGET_NANOS = 1_500_000L;
    private static final long DIRTY_DELAY_MS = 3000L;
    private static final int MAGIC = 0x4C4F4443;
    private static final int VERSION = 1;

    /** one chunk column: 4x4 cells of 4x4 blocks */
    static final class Col {
        final short[] g = new short[16];   // first free y above the ground (looking through trees)
        final short[] h = new short[16];   // first free y above everything (leaves included)
        final short[] b = new short[48];   // palette ids: 3 layers per cell
        final byte[] d = new byte[32];     // thickness of layer 0 and 1
        final int[] tg = new int[16];      // ground tint (ARGB)
        final int[] tc = new int[16];      // canopy tint (ARGB)
        final short[] cb = new short[16];  // canopy block id, 0 = none
        final byte[] wd = new byte[16];    // water depth
    }

    private static final ConcurrentHashMap<Long, Col> CACHE = new ConcurrentHashMap<>();
    /** fake columns currently shown: key -> {minSectionY, maxSectionY} */
    private static final ConcurrentHashMap<Long, int[]> FAKE = new ConcurrentHashMap<>();
    private static final HashSet<Long> REAL = new HashSet<>();
    private static final ArrayDeque<Long> CAPTURE = new ArrayDeque<>();
    private static final HashSet<Long> CAPTURE_SET = new HashSet<>();
    private static final HashMap<Long, Long> DIRTY = new HashMap<>();

    // palette (ids are shared by the cache and the disk file)
    private static volatile Block[] palette = new Block[256];
    private static int paletteSize = 1;
    private static final HashMap<Block, Integer> PALETTE_IDS = new HashMap<>();

    private static volatile boolean failed = false;
    private static volatile boolean clearRequested = false;
    private static int appliedExtra = 0;
    private static ClientLevel curLevel;
    private static String curKey = "";
    private static int frameCounter = 0;
    private static long lastSaveMs = 0;
    private static boolean dirtyDisk = false;
    private static int lastWindowFrame = -100;
    private static volatile Loaded pendingLoad;
    private static String loadingKey = "";
    private static String lastDebug = "";
    private static int lastScanned = 0;
    private static double lastCamX = 0.0;
    private static double lastCamY = 64.0;
    private static double lastCamZ = 0.0;
    private static int lastRenderChunks = 8;

    private static final class Loaded {
        String key;
        String[] names;
        HashMap<Long, Col> cols = new HashMap<>();
    }

    private MobileOutsideLod() {
    }

    static {
        palette[0] = Blocks.AIR;
        PALETTE_IDS.put(Blocks.AIR, 0);
        MobileLod.setFakeColumnTest(FAKE::containsKey);
    }

    // ------------------------------------------------------------------------------------------------------------
    // configuration

    private static boolean wanted() {
        var p = SodiumClientMod.options().performance;
        return p.mobileLodOutside && p.mobileQuadLod && !failed;
    }

    /** Called when the renderer is (re)created. Returns how many chunks the renderer distance is extended by. */
    public static int configureExtra(int renderChunks) {
        FAKE.clear();
        REAL.clear();
        CAPTURE.clear();
        CAPTURE_SET.clear();
        DIRTY.clear();

        int extra = 0;

        if (wanted()) {
            var p = SodiumClientMod.options().performance;
            // the vanilla far plane is about 4x the render distance, stay well inside it
            int room = renderChunks * 4 - 2 - renderChunks;
            extra = Math.max(0, Math.min(p.mobileLodOutsideChunks, room));
        }

        appliedExtra = extra;
        return extra;
    }

    public static int appliedExtraChunks() {
        return appliedExtra;
    }

    /** distance in chunks that the outside LOD adds to the fog end (0 when off) */
    public static int fogExtra() {
        return appliedExtra;
    }

    public static boolean isFakeColumn(int chunkX, int chunkZ) {
        return FAKE.containsKey((((long) chunkX) << 32) ^ (chunkZ & 0xFFFFFFFFL));
    }

    public static void requestClear() {
        clearRequested = true;
    }

    private static long key(int x, int z) {
        return (((long) x) << 32) ^ (z & 0xFFFFFFFFL);
    }

    private static int keyX(long k) {
        return (int) (k >> 32);
    }

    private static int keyZ(long k) {
        return (int) k;
    }

    /** called from builder threads when a fake section failed to build */
    public static void reportBuildError(Throwable t) {
        if (!failed) {
            failed = true;
            System.err.println("[Sodium Mobile] outside LOD build error, switching it off:");
            t.printStackTrace();
        }
    }

    private static void fail(RenderSectionManager mgr, Throwable t) {
        failed = true;
        System.err.println("[Sodium Mobile] outside LOD switched off after an error:");
        t.printStackTrace();

        try {
            if (mgr != null) {
                removeAllFakes(mgr);
            }
        } catch (Throwable ignored) {
        }

        appliedExtra = 0;
    }

    // ------------------------------------------------------------------------------------------------------------
    // hooks from the section manager

    public static void onRealChunkAdded(RenderSectionManager mgr, int x, int z) {
        if (appliedExtra <= 0) {
            return;
        }

        try {
            long k = key(x, z);
            REAL.add(k);

            // the fake sections of this column turn into real ones in place, so the old mesh stays until the new one is ready
            if (FAKE.remove(k) != null) {
                mgr.mobilePromoteColumn(x, z);
            }

            queueCapture(k);
        } catch (Throwable t) {
            fail(mgr, t);
        }
    }

    /** returns true if the sections were kept and turned into fake ones, so the caller must not remove them */
    public static boolean onRealChunkRemoved(RenderSectionManager mgr, int x, int z) {
        if (appliedExtra <= 0) {
            return false;
        }

        long k = key(x, z);
        REAL.remove(k);
        DIRTY.remove(k);

        try {
            ClientLevel level = curLevel;

            if (level == null || failed || !CACHE.containsKey(k)) {
                return false;
            }

            double dx = x - Math.floor(lastCamX / 16.0);
            double dz = z - Math.floor(lastCamZ / 16.0);

            if (Math.sqrt(dx * dx + dz * dz) > lastRenderChunks + appliedExtra) {
                return false;
            }

            int[] range = sectionRange(level, k);

            if (range == null) {
                return false;
            }

            int airTop = airTopFor(level, range[1]);
            mgr.mobileDemoteColumn(x, z, range[0], range[1], airTop);
            FAKE.put(k, new int[]{range[0], range[1], airTop});
            return true;
        } catch (Throwable t) {
            fail(mgr, t);
            return false;
        }
    }

    private static int airTopFor(ClientLevel level, int hi) {
        int camSec = (int) Math.floor(lastCamY / 16.0);
        return Math.min(level.getMaxSectionY(), Math.max(hi, camSec + 1));
    }

    public static void onSectionDirty(int x, int z) {
        if (appliedExtra <= 0) {
            return;
        }

        long k = key(x, z);

        if (REAL.contains(k)) {
            DIRTY.put(k, System.currentTimeMillis());
        }
    }

    private static void queueCapture(long k) {
        if (CAPTURE_SET.add(k)) {
            CAPTURE.add(k);
        }
    }

    private static void removeFake(RenderSectionManager mgr, long k) {
        int[] range = FAKE.remove(k);

        if (range != null) {
            for (int y = range[0]; y <= range[2]; y++) {
                mgr.mobileRemoveLodSection(keyX(k), y, keyZ(k));
            }
        }
    }

    private static void removeAllFakes(RenderSectionManager mgr) {
        for (Long k : new ArrayList<>(FAKE.keySet())) {
            removeFake(mgr, k);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // per frame

    public static void frame(RenderSectionManager mgr, ClientLevel level, double camX, double camY, double camZ, float yawDeg, int renderChunks) {
        if (failed && !FAKE.isEmpty()) {
            try {
                removeAllFakes(mgr);
            } catch (Throwable ignored) {
            }
            appliedExtra = 0;
        }

        if (appliedExtra <= 0 || level == null) {
            return;
        }

        try {
            frameCounter++;
            lastCamX = camX;
            lastCamY = camY;
            lastCamZ = camZ;
            lastRenderChunks = renderChunks;

            if (level != curLevel) {
                switchLevel(level);
            }

            mergeLoaded();

            if (clearRequested) {
                clearRequested = false;
                removeAllFakes(mgr);
                CACHE.clear();
                dirtyDisk = true;
                deleteFile();
                for (Long k : REAL) {
                    queueCapture(k);
                }
            }

            runCapture(level);
            runDirty();

            if (frameCounter % 150 == 0) {
                evict(camX, camZ);
            }

            window(mgr, level, camX, camZ, yawDeg, renderChunks);
            autosave();
        } catch (Throwable t) {
            fail(mgr, t);
        }
    }

    private static void switchLevel(ClientLevel level) {
        String key = worldKey(level);
        curLevel = level;

        if (!key.equals(curKey)) {
            CACHE.clear();
            curKey = key;
            dirtyDisk = false;
            lastSaveMs = System.currentTimeMillis();
            startLoad(key);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // capture

    private static void runCapture(ClientLevel level) {
        if (CAPTURE.isEmpty()) {
            return;
        }

        long end = System.nanoTime() + CAPTURE_BUDGET_NANOS;
        Minecraft mc = Minecraft.getInstance();
        BlockPos.MutableBlockPos p = new BlockPos.MutableBlockPos();
        int[] out = new int[2];

        while (!CAPTURE.isEmpty() && System.nanoTime() < end) {
            long k = CAPTURE.poll();
            CAPTURE_SET.remove(k);

            if (!REAL.contains(k)) {
                continue;
            }

            Col c = captureColumn(mc, level, p, out, keyX(k), keyZ(k));

            if (c != null) {
                CACHE.put(k, c);
                dirtyDisk = true;
            }
        }
    }

    private static void runDirty() {
        if (DIRTY.isEmpty() || frameCounter % 20 != 0) {
            return;
        }

        long now = System.currentTimeMillis();
        List<Long> ready = null;

        for (Map.Entry<Long, Long> e : DIRTY.entrySet()) {
            if (now - e.getValue() > DIRTY_DELAY_MS) {
                if (ready == null) {
                    ready = new ArrayList<>();
                }
                ready.add(e.getKey());
            }
        }

        if (ready != null) {
            for (Long k : ready) {
                DIRTY.remove(k);
                queueCapture(k);
            }
        }
    }

    private static Col captureColumn(Minecraft mc, ClientLevel level, BlockPos.MutableBlockPos p, int[] out, int cx, int cz) {
        Col c = new Col();

        for (int j = 0; j < 4; j++) {
            for (int i = 0; i < 4; i++) {
                int idx = j * 4 + i;
                int x = (cx << 4) + i * 4 + 2;
                int z = (cz << 4) + j * 4 + 2;

                if (!MobileLod.column(level, p, x, z, out)) {
                    return null;
                }

                int h = out[0];
                int g = out[1];
                c.h[idx] = (short) h;
                c.g[idx] = (short) g;
                c.tg[idx] = 0xFFFFFFFF;
                c.tc[idx] = 0xFFFFFFFF;

                // layers below the ground
                Block l0 = null;
                Block l1 = null;
                Block l2 = null;
                int d0 = 0;
                int d1 = 0;
                BlockState top = null;

                for (int y = g - 1; y > g - 25; y--) {
                    p.set(x, y, z);
                    BlockState s = level.getBlockState(p);

                    if (s.isAir()) {
                        continue;
                    }

                    Block b = s.getBlock();

                    if (l0 == null) {
                        l0 = b;
                        top = s;
                        d0 = 1;
                    } else if (l1 == null) {
                        if (b == l0) {
                            d0++;
                        } else {
                            l1 = b;
                            d1 = 1;
                        }
                    } else if (l2 == null) {
                        if (b == l1) {
                            d1++;
                        } else {
                            l2 = b;
                            break;
                        }
                    }
                }

                if (l0 == null) {
                    l0 = Blocks.STONE;
                }
                if (l1 == null) {
                    l1 = l0;
                }
                if (l2 == null) {
                    l2 = l1;
                }

                c.b[idx * 3] = (short) idOf(l0);
                c.b[idx * 3 + 1] = (short) idOf(l1);
                c.b[idx * 3 + 2] = (short) idOf(l2);
                c.d[idx * 2] = (byte) Math.min(d0, 120);
                c.d[idx * 2 + 1] = (byte) Math.min(d1, 120);

                if (top != null) {
                    p.set(x, g - 1, z);
                    c.tg[idx] = MobileLod.tintColor(mc, top, level, p, 0);

                    if (!top.getFluidState().isEmpty()) {
                        int depth = 0;

                        for (int y = g - 1; y > g - 41; y--) {
                            p.set(x, y, z);

                            if (level.getBlockState(p).getFluidState().isEmpty()) {
                                break;
                            }

                            depth++;
                        }

                        c.wd[idx] = (byte) depth;
                    }
                }

                if (h - g >= 3) {
                    p.set(x, h - 1, z);
                    BlockState cs = level.getBlockState(p);

                    if (!cs.isAir()) {
                        c.cb[idx] = (short) idOf(cs.getBlock());
                        c.tc[idx] = MobileLod.tintColor(mc, cs, level, p, 0);
                    }
                }
            }
        }

        return c;
    }

    private static int idOf(Block b) {
        Integer id = PALETTE_IDS.get(b);

        if (id != null) {
            return id;
        }

        if (paletteSize >= palette.length) {
            Block[] bigger = new Block[palette.length * 2];
            System.arraycopy(palette, 0, bigger, 0, palette.length);
            palette = bigger;
        }

        palette[paletteSize] = b;
        PALETTE_IDS.put(b, paletteSize);
        return paletteSize++;
    }

    // ------------------------------------------------------------------------------------------------------------
    // eviction

    private static void evict(double camX, double camZ) {
        int max = Math.max(256, (int) (SodiumClientMod.options().performance.mobileLodOutsideRamMb * 1048576L / BYTES_PER_CHUNK));

        if (CACHE.size() <= max) {
            return;
        }

        final int ccx = (int) Math.floor(camX / 16.0);
        final int ccz = (int) Math.floor(camZ / 16.0);
        List<long[]> far = new ArrayList<>();

        for (Long k : CACHE.keySet()) {
            if (REAL.contains(k) || FAKE.containsKey(k)) {
                continue;
            }

            long dx = keyX(k) - ccx;
            long dz = keyZ(k) - ccz;
            far.add(new long[]{dx * dx + dz * dz, k});
        }

        far.sort((a, b) -> Long.compare(b[0], a[0]));
        int over = CACHE.size() - max;

        for (int i = 0; i < far.size() && i < over + max / 20; i++) {
            CACHE.remove(far.get(i)[1]);
            dirtyDisk = true;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // the window of fake sections around the camera

    private static void window(RenderSectionManager mgr, ClientLevel level, double camX, double camZ, float yawDeg, int renderChunks) {
        var perf = SodiumClientMod.options().performance;
        int speed = Math.max(1, Math.min(3, perf.mobileLodOutsideSpeed));
        int addBudget = speed == 1 ? 2 : (speed == 2 ? 4 : 8);
        int removeBudget = addBudget * 2;

        int outer = renderChunks + appliedExtra;
        int ccx = (int) Math.floor(camX / 16.0);
        int ccz = (int) Math.floor(camZ / 16.0);
        double yaw = Math.toRadians(yawDeg);
        double fx = -Math.sin(yaw);
        double fz = Math.cos(yaw);

        // desired columns are recomputed every few frames, kept between scans
        if (frameCounter - lastWindowFrame >= 8) {
            lastWindowFrame = frameCounter;
            desired.clear();
            desiredSet.clear();
            int scanned = 0;

            for (int dz = -outer; dz <= outer; dz++) {
                for (int dx = -outer; dx <= outer; dx++) {
                    double dist = Math.sqrt((double) dx * dx + (double) dz * dz);

                    if (dist > outer) {
                        continue;
                    }

                    long k = key(ccx + dx, ccz + dz);
                    scanned++;

                    if (REAL.contains(k) || !CACHE.containsKey(k)) {
                        continue;
                    }

                    double dot = dist < 0.5 ? 0 : (dx * fx + dz * fz) / dist;
                    desired.add(new Want(dist - 3.0 * dot, k));
                    desiredSet.add(k);
                }
            }

            lastScanned = scanned;
            desired.sort((a, b) -> Double.compare(a.score, b.score));
            // remove columns that are no longer wanted
            int removed = 0;

            for (Long k : new ArrayList<>(FAKE.keySet())) {
                if (!desiredSet.contains(k) && removed < removeBudget * 4) {
                    removeFake(mgr, k);
                    removed++;
                }
            }

            addCursor = 0;

            // columns need empty air sections up to the camera height, otherwise Sodium's visibility search cannot reach them from above
            int airBudget = 96;

            for (Map.Entry<Long, int[]> e : FAKE.entrySet()) {
                int[] r = e.getValue();
                int want = airTopFor(level, r[1]);

                while (r[2] < want && airBudget > 0) {
                    r[2]++;
                    mgr.mobileAddLodSection(keyX(e.getKey()), r[2], keyZ(e.getKey()), true);
                    airBudget--;
                }
            }
        }

        int added = 0;

        while (addCursor < desired.size() && added < addBudget) {
            long k = desired.get(addCursor).key;
            addCursor++;

            if (FAKE.containsKey(k) || REAL.contains(k)) {
                continue;
            }

            int[] range = sectionRange(level, k);

            if (range == null) {
                continue;
            }

            int airTop = airTopFor(level, range[1]);
            FAKE.put(k, new int[]{range[0], range[1], airTop});

            for (int y = range[0]; y <= range[1]; y++) {
                mgr.mobileAddLodSection(keyX(k), y, keyZ(k), false);
            }

            for (int y = range[1] + 1; y <= airTop; y++) {
                mgr.mobileAddLodSection(keyX(k), y, keyZ(k), true);
            }

            added++;
        }
    }

    private static final class Want {
        final double score;
        final long key;

        Want(double score, long key) {
            this.score = score;
            this.key = key;
        }
    }

    private static final ArrayList<Want> desired = new ArrayList<>();
    private static final HashSet<Long> desiredSet = new HashSet<>();
    private static int addCursor = 0;

    private static int[] sectionRange(ClientLevel level, long k) {
        Col c = CACHE.get(k);

        if (c == null) {
            return null;
        }

        int cx = keyX(k);
        int cz = keyZ(k);
        int minG = Integer.MAX_VALUE;
        int maxH = Integer.MIN_VALUE;

        for (int i = 0; i < 16; i++) {
            minG = Math.min(minG, c.g[i]);
            maxH = Math.max(maxH, Math.max(c.h[i], c.g[i]));
        }

        for (int dz = -1; dz <= 1; dz++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dz == 0) {
                    continue;
                }

                Col n = CACHE.get(key(cx + dx, cz + dz));

                if (n != null) {
                    for (int i = 0; i < 16; i++) {
                        minG = Math.min(minG, n.g[i]);
                    }
                }
            }
        }

        int lo = Math.floorDiv(minG - 2, 16);
        int hi = Math.floorDiv(maxH, 16);
        lo = Math.max(lo, level.getMinSectionY());
        hi = Math.min(hi, level.getMaxSectionY());

        if (hi < lo) {
            return null;
        }

        return new int[]{lo, hi};
    }

    // ------------------------------------------------------------------------------------------------------------
    // source for the mesher

    public static MobileLod.Source source(ClientLevel level) {
        return new CacheSource(level);
    }

    private static final class CacheSource implements MobileLod.Source {
        final ClientLevel level;
        final Block[] pal = palette;

        CacheSource(ClientLevel level) {
            this.level = level;
        }

        private Col col(int x, int z) {
            return CACHE.get(key(x >> 4, z >> 4));
        }

        private static int cell(int x, int z) {
            return (((z & 15) >> 2) << 2) | ((x & 15) >> 2);
        }

        @Override
        public boolean column(int x, int z, int[] out) {
            Col c = col(x, z);

            if (c == null) {
                return false;
            }

            int i = cell(x, z);
            out[0] = c.h[i];
            out[1] = c.g[i];
            return true;
        }

        @Override
        public BlockState stateAt(int x, int y, int z) {
            Col c = col(x, z);

            if (c == null) {
                return null;
            }

            int i = cell(x, z);
            int g = c.g[i];

            if (y >= g) {
                return Blocks.AIR.defaultBlockState();
            }

            int d0 = c.d[i * 2];
            int d1 = c.d[i * 2 + 1];
            int layer = y >= g - d0 ? 0 : (y >= g - d0 - d1 ? 1 : 2);
            int id = c.b[i * 3 + layer];
            return this.block(id).defaultBlockState();
        }

        private Block block(int id) {
            Block b = id < this.pal.length ? this.pal[id] : palette[id];
            return b == null ? Blocks.AIR : b;
        }

        @Override
        public BlockState canopyState(int x, int z, int topY) {
            Col c = col(x, z);

            if (c == null) {
                return null;
            }

            int id = c.cb[cell(x, z)];

            if (id == 0) {
                return null;
            }

            return this.block(id).defaultBlockState();
        }

        @Override
        public int tint(BlockState state, int tintIndex, int x, int y, int z, boolean canopy) {
            Col c = col(x, z);

            if (c == null) {
                return 0xFFFFFFFF;
            }

            int i = cell(x, z);
            return canopy ? c.tc[i] : c.tg[i];
        }

        @Override
        public int waterDepth(int x, int y, int z) {
            Col c = col(x, z);
            return c == null ? 0 : c.wd[cell(x, z)];
        }

        @Override
        public BlockAndTintGetter view() {
            return this.level;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // disk

    private static File dir() {
        return new File(Minecraft.getInstance().gameDirectory, "sodiummobile-lod");
    }

    private static File fileFor(String key) {
        return new File(dir(), key + ".lodc");
    }

    private static String worldKey(ClientLevel level) {
        String world = "unknown";

        try {
            Minecraft mc = Minecraft.getInstance();
            var server = mc.getSingleplayerServer();

            if (server != null) {
                world = "sp-" + server.getWorldPath(LevelResource.ROOT).toAbsolutePath().normalize().getFileName();
            } else if (mc.getCurrentServer() != null) {
                world = "mp-" + mc.getCurrentServer().ip;
            }
        } catch (Throwable ignored) {
        }

        String dim = "dim";

        try {
            dim = level.dimension().toString();
        } catch (Throwable ignored) {
        }

        String k = (world + "_" + dim).replaceAll("[^A-Za-z0-9._-]", "_");
        return k.length() > 120 ? k.substring(0, 120) : k;
    }

    private static void deleteFile() {
        try {
            File f = fileFor(curKey);

            if (f.exists()) {
                f.delete();
            }
        } catch (Throwable ignored) {
        }
    }

    private static void startLoad(String key) {
        loadingKey = key;
        Thread t = new Thread(() -> {
            try {
                File f = fileFor(key);

                if (!f.isFile()) {
                    return;
                }

                Loaded l = new Loaded();
                l.key = key;

                try (DataInputStream in = new DataInputStream(new BufferedInputStream(new GZIPInputStream(new FileInputStream(f)), 1 << 16))) {
                    if (in.readInt() != MAGIC || in.readInt() != VERSION) {
                        return;
                    }

                    int np = in.readInt();
                    l.names = new String[np];

                    for (int i = 0; i < np; i++) {
                        l.names[i] = in.readUTF();
                    }

                    int n = in.readInt();

                    for (int i = 0; i < n; i++) {
                        long k = in.readLong();
                        Col c = new Col();

                        for (int j = 0; j < 16; j++) {
                            c.g[j] = in.readShort();
                            c.h[j] = in.readShort();
                            c.tg[j] = in.readInt();
                            c.tc[j] = in.readInt();
                            c.cb[j] = in.readShort();
                            c.wd[j] = in.readByte();
                        }

                        for (int j = 0; j < 48; j++) {
                            c.b[j] = in.readShort();
                        }

                        for (int j = 0; j < 32; j++) {
                            c.d[j] = in.readByte();
                        }

                        l.cols.put(k, c);
                    }
                }

                pendingLoad = l;
            } catch (Throwable t2) {
                System.err.println("[Sodium Mobile] could not read the LOD cache file: " + t2);
            }
        }, "SodiumMobile-LOD-load");
        t.setDaemon(true);
        t.start();
    }

    private static void mergeLoaded() {
        Loaded l = pendingLoad;

        if (l == null) {
            return;
        }

        pendingLoad = null;

        if (!l.key.equals(curKey)) {
            return;
        }

        HashMap<String, Block> byName = new HashMap<>();

        for (Block b : BuiltInRegistries.BLOCK) {
            byName.put(BuiltInRegistries.BLOCK.getKey(b).toString(), b);
        }

        int[] map = new int[l.names.length];

        for (int i = 0; i < map.length; i++) {
            Block b = byName.get(l.names[i]);
            map[i] = b == null ? 0 : idOf(b);
        }

        for (Map.Entry<Long, Col> e : l.cols.entrySet()) {
            Col c = e.getValue();

            for (int j = 0; j < 48; j++) {
                int id = c.b[j];
                c.b[j] = (short) (id >= 0 && id < map.length ? map[id] : 0);
            }

            for (int j = 0; j < 16; j++) {
                int id = c.cb[j];
                c.cb[j] = (short) (id > 0 && id < map.length ? map[id] : 0);
            }

            CACHE.putIfAbsent(e.getKey(), c);
        }
    }

    private static void autosave() {
        long now = System.currentTimeMillis();

        long every = Math.max(1, SodiumClientMod.options().performance.mobileLodSaveMinutes) * 60_000L;

        if (dirtyDisk && now - lastSaveMs > every) {
            saveAsync();
        }
    }

    /** Called when the world is left. */
    public static void onUnload() {
        try {
            if (appliedExtra > 0 && dirtyDisk) {
                saveAsync();
            }
        } catch (Throwable ignored) {
        }

        FAKE.clear();
        REAL.clear();
        CAPTURE.clear();
        CAPTURE_SET.clear();
        DIRTY.clear();
        curLevel = null;
    }

    private static void saveAsync() {
        dirtyDisk = false;
        lastSaveMs = System.currentTimeMillis();
        final String key = curKey;

        if (key.isEmpty()) {
            return;
        }

        final ArrayList<Map.Entry<Long, Col>> snapshot = new ArrayList<>(CACHE.entrySet());
        final Block[] pal = palette;
        final int palCount = paletteSize;

        Thread t = new Thread(() -> {
            try {
                File d = dir();
                d.mkdirs();
                File tmp = new File(d, key + ".tmp");

                try (DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new GZIPOutputStream(new FileOutputStream(tmp)), 1 << 16))) {
                    out.writeInt(MAGIC);
                    out.writeInt(VERSION);
                    out.writeInt(palCount);

                    for (int i = 0; i < palCount; i++) {
                        out.writeUTF(BuiltInRegistries.BLOCK.getKey(pal[i]).toString());
                    }

                    out.writeInt(snapshot.size());

                    for (Map.Entry<Long, Col> e : snapshot) {
                        Col c = e.getValue();
                        out.writeLong(e.getKey());

                        for (int j = 0; j < 16; j++) {
                            out.writeShort(c.g[j]);
                            out.writeShort(c.h[j]);
                            out.writeInt(c.tg[j]);
                            out.writeInt(c.tc[j]);
                            out.writeShort(c.cb[j]);
                            out.writeByte(c.wd[j]);
                        }

                        for (int j = 0; j < 48; j++) {
                            out.writeShort(c.b[j]);
                        }

                        for (int j = 0; j < 32; j++) {
                            out.writeByte(c.d[j]);
                        }
                    }
                }

                File f = fileFor(key);

                if (f.exists()) {
                    f.delete();
                }

                tmp.renameTo(f);
            } catch (Throwable t2) {
                System.err.println("[Sodium Mobile] could not save the LOD cache file: " + t2);
            }
        }, "SodiumMobile-LOD-save");
        t.start();
    }

    // ------------------------------------------------------------------------------------------------------------
    // debug

    public static String debugLine(RenderSectionManager mgr) {
        if (!SodiumClientMod.options().performance.mobileLodOutside) {
            return null;
        }

        if (failed) {
            return "Mobile outside LOD: OFF (error, see log)";
        }

        if (appliedExtra <= 0) {
            return "Mobile outside LOD: waiting for renderer reload";
        }

        long mb = (long) CACHE.size() * BYTES_PER_CHUNK / 1048576L;
        return "Mobile outside LOD: +" + appliedExtra + " chunks, cache " + CACHE.size() + " (" + mb + " MB), drawn " + FAKE.size()
                + ", queue " + CAPTURE.size() + ", scan " + lastScanned + ", waiting " + mgr.mobileCountUnbuilt();
    }
}
'''

TASK_JAVA = r'''package net.caffeinemc.mods.sodium.client.render.chunk.compile.tasks;

import it.unimi.dsi.fastutil.objects.Reference2ReferenceOpenHashMap;
import net.caffeinemc.mods.sodium.client.render.chunk.DefaultChunkRenderer;
import net.caffeinemc.mods.sodium.client.render.chunk.MobileLod;
import net.caffeinemc.mods.sodium.client.render.chunk.MobileOutsideLod;
import net.caffeinemc.mods.sodium.client.render.chunk.RenderSection;
import net.caffeinemc.mods.sodium.client.render.chunk.compile.ChunkBuildBuffers;
import net.caffeinemc.mods.sodium.client.render.chunk.compile.ChunkBuildContext;
import net.caffeinemc.mods.sodium.client.render.chunk.compile.ChunkBuildOutput;
import net.caffeinemc.mods.sodium.client.render.chunk.data.BuiltSectionInfo;
import net.caffeinemc.mods.sodium.client.render.chunk.data.BuiltSectionMeshParts;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.DefaultTerrainRenderPasses;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.TerrainRenderPass;
import net.caffeinemc.mods.sodium.client.render.chunk.translucent_sorting.SortBehavior;
import net.caffeinemc.mods.sodium.client.render.chunk.translucent_sorting.data.NoData;
import net.caffeinemc.mods.sodium.client.render.chunk.translucent_sorting.data.TranslucentData;
import net.caffeinemc.mods.sodium.client.util.task.CancellationToken;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.chunk.VisGraph;
import org.joml.Vector3dc;

import java.util.Map;

/**
 * Sodium Mobile v2.0: builds the mesh of a fake render section of the outside LOD from the column cache.
 * It never touches the real world, so it needs no chunk slice.
 */
public class MobileLodTask extends ChunkBuilderMeshingTask {
    private final SortBehavior mobileSort;

    public MobileLodTask(RenderSection render, int buildTime, Vector3dc absoluteCameraPos, SortBehavior sortBehavior) {
        super(render, buildTime, absoluteCameraPos, null, sortBehavior, false);
        this.mobileSort = sortBehavior;
    }

    @Override
    public ChunkBuildOutput execute(ChunkBuildContext buildContext, CancellationToken cancellationToken) {
        BuiltSectionInfo.Builder renderData = new BuiltSectionInfo.Builder();
        ChunkBuildBuffers buffers = buildContext.buffers;
        buffers.init(renderData, this.render.getSectionIndex());

        if (cancellationToken.isCancelled()) {
            return null;
        }

        try {
            ClientLevel level = Minecraft.getInstance().level;

            if (level != null) {
                MobileLod.buildOutside(buffers, buildContext.cache.getBlockModels(), MobileOutsideLod.source(level),
                        this.render.getChunkX(), this.render.getChunkY(), this.render.getChunkZ());
            }
        } catch (Throwable error) {
            MobileOutsideLod.reportBuildError(error);
        }

        if (cancellationToken.isCancelled()) {
            return null;
        }

        TranslucentData translucentData = null;

        if (this.mobileSort != SortBehavior.OFF) {
            translucentData = NoData.forEmptySection(this.render.getPosition());
        }

        Map<TerrainRenderPass, BuiltSectionMeshParts> meshes = new Reference2ReferenceOpenHashMap<>();
        var visibleSlices = DefaultChunkRenderer.getVisibleFaces(
                (int) this.absoluteCameraPos.x(), (int) this.absoluteCameraPos.y(), (int) this.absoluteCameraPos.z(),
                this.render.getChunkX(), this.render.getChunkY(), this.render.getChunkZ());

        for (TerrainRenderPass pass : DefaultTerrainRenderPasses.ALL) {
            BuiltSectionMeshParts mesh = buffers.createMesh(pass, visibleSlices, false, true);

            if (mesh != null) {
                meshes.put(pass, mesh);
                renderData.addRenderPass(pass);
            }
        }

        renderData.setOcclusionData(new VisGraph().resolve());
        return new ChunkBuildOutput(this.render, this.submitTime, translucentData, renderData.build(), meshes);
    }
}
'''


def feature_lod():
    mode20 = "v20" not in SKIP
    s_task = rd(P_TASK)
    s_sec = rd(P_SECTION)
    s_col = rd(P_COLLECTOR)
    s_rsm = rd(P_RSM)

    s_task = replace_once(
        s_task,
        "        profiler.push(\"render blocks\");\n        try {\n            for (int y = minY; y < maxY; y++) {\n",
        "        int mobileLoopMaxY = maxY;\n"
        "        {\n"
        "            boolean mobileLod = net.caffeinemc.mods.sodium.client.render.chunk.MobileLod.targetLod(\n"
        "                    this.render.getChunkX(), this.render.getChunkZ(), this.render.mobileLodBuilt,\n"
        "                    this.absoluteCameraPos.x(), this.absoluteCameraPos.z());\n"
        "            if (mobileLod) {\n"
        "                try {\n"
        "                    if (net.caffeinemc.mods.sodium.client.render.chunk.MobileLod.build(buffers, cache.getBlockModels(), slice, minX, minY, minZ)) {\n"
        "                        mobileLoopMaxY = minY;\n"
        "                    } else {\n"
        "                        mobileLod = false;\n"
        "                    }\n"
        "                } catch (Throwable mobileError) {\n"
        "                    mobileLod = false;\n"
        "                }\n"
        "            }\n"
        "            this.render.mobileLodBuilt = mobileLod;\n"
        "        }\n\n"
        "        profiler.push(\"render blocks\");\n        try {\n            for (int y = minY; y < mobileLoopMaxY; y++) {\n",
        "ChunkBuilderMeshingTask")
    s_sec = replace_once(
        s_sec, "    private boolean built = false; // merge with the flags?\n",
        "    private boolean built = false; // merge with the flags?\n"
        "    public boolean mobileLodBuilt = false; // Sodium Mobile: last build used the quad LOD mesh\n"
        "    public boolean mobileOutside = false; // Sodium Mobile: fake section of the outside LOD\n"
        "    public boolean mobileAir = false; // Sodium Mobile: empty air section kept above outside LOD columns\n",
        "RenderSection")
    s_col = replace_once(
        s_col, "        // always add to rebuild lists though, because it might just not be built yet\n",
        "        net.caffeinemc.mods.sodium.client.render.chunk.MobileLod.checkRebuild(section);\n\n"
        "        // always add to rebuild lists though, because it might just not be built yet\n",
        "SectionCollector")
    s_rsm = replace_once(
        s_rsm, "        this.cameraPosition = cameraPosition;\n    }\n\n    public void update(",
        "        net.caffeinemc.mods.sodium.client.render.chunk.MobileLod.setCamera(cameraPosition.x(), cameraPosition.z());\n"
        + ("        if (net.caffeinemc.mods.sodium.client.render.chunk.MobileLod.consumeRevisit()) {\n"
           "            this.markGraphDirty();\n"
           "        }\n" if mode20 else "")
        + "        this.cameraPosition = cameraPosition;\n    }\n\n    public void update(",
        "RenderSectionManager")
    s_swr = rd(P_SWR)
    if mode20:
        s_swr = replace_once(
            s_swr, "        this.renderSectionManager.prepareFrame(pos);\n",
            "        this.renderSectionManager.prepareFrame(pos);\n"
            "        {\n"
            "            double mobileBase = Math.tan(Math.toRadians((double) this.client.options.fov().get()) * 0.5);\n"
            "            float mobileM11 = matrices.projection().m11();\n"
            "            if (mobileM11 > 0.0f && mobileBase > 0.0) {\n"
            "                net.caffeinemc.mods.sodium.client.render.chunk.MobileLod.setZoomRatio((1.0 / mobileM11) / mobileBase);\n"
            "            }\n"
            "        }\n",
            "SodiumWorldRenderer zoom")

    fields = (
        "        // Sodium Mobile: tiered quad LOD, distances in chunks from the camera\n"
        "        public boolean mobileQuadLod = true;\n"
        "        public int mobileQuadLodLevel = 3;\n"
        "        public int mobileLodPreset = 0;\n"
        "        public int mobileLodStartChunks = 6;\n"
        "        public int mobileLod1x1Chunks = 8;\n"
        "        public int mobileLodTier2Chunks = 11;\n"
        "        public int mobileLodTier3Chunks = 14;\n"
        "        public int mobileLodTrees = 1;\n"
        "        public boolean mobileLodLayeredSides = true;\n"
        "        public boolean mobileLodWaterDepth = true;\n")
    blocks = (opt_block("bool", "mobile_quad_lod", 0, 0, 0, "mobileQuadLod", "HIGH", True)
              + opt_block("int", "mobile_lod_preset", 0, 3, 1, "mobileLodPreset", "LOW", True)
              + opt_block("int", "mobile_quad_lod_level", 1, 3, 1, "mobileQuadLodLevel", "MEDIUM", True)
              + opt_block("int", "mobile_lod_start", 2, 32, 1, "mobileLodStartChunks", "MEDIUM", True)
              + opt_block("int", "mobile_lod_1x1", 0, 32, 1, "mobileLod1x1Chunks", "MEDIUM", True)
              + opt_block("int", "mobile_lod_tier2", 2, 32, 1, "mobileLodTier2Chunks", "MEDIUM", True)
              + opt_block("int", "mobile_lod_tier3", 2, 32, 1, "mobileLodTier3Chunks", "MEDIUM", True)
              + opt_block("int", "mobile_lod_trees", 0, 2, 1, "mobileLodTrees", "MEDIUM", True)
              + opt_block("bool", "mobile_lod_layered_sides", 0, 0, 0, "mobileLodLayeredSides", "LOW", True)
              + opt_block("bool", "mobile_lod_water_depth", 0, 0, 0, "mobileLodWaterDepth", "LOW", True))
    lang = lang_lines([
        ("sodium.options.mobile_quad_lod.name", "Mobile: Quad LOD"),
        ("sodium.options.mobile_quad_lod.tooltip",
         "The outer part of your render distance is drawn as merged flat quads instead of every block. Far terrain looks simpler but costs far less."),
        ("sodium.options.mobile_lod_preset.name", "Mobile: LOD Preset"),
        ("sodium.options.mobile_lod_preset.tooltip",
         "0 = Custom (use the sliders below), 1 = Potato, 2 = Balanced, 3 = Quality. A preset replaces the LOD sliders, trees, layered cliffs, water and shading with its own values."),
        ("sodium.options.mobile_lod_preset.value", "Preset %s"),
        ("sodium.options.mobile_quad_lod_level.name", "Mobile: LOD Coarsest Size"),
        ("sodium.options.mobile_quad_lod_level.tooltip",
         "How coarse the farthest tier gets. Level 1 = stop at 2x2, level 2 = up to 4x4, level 3 = up to 8x8."),
        ("sodium.options.mobile_quad_lod_level.value", "Level %s"),
        ("sodium.options.mobile_lod_start.name", "Mobile: LOD Start"),
        ("sodium.options.mobile_lod_start.tooltip",
         "Distance in chunks where the LOD begins. Closer than this you see normal blocks. Has to be lower than your render distance to be visible."),
        ("sodium.options.mobile_lod_start.value", "%s chunks"),
        ("sodium.options.mobile_lod_1x1.name", "Mobile: 1x1 Detail Until"),
        ("sodium.options.mobile_lod_1x1.tooltip",
         "Distance in chunks where the finest tier (one quad per block column, true texture size) ends and 2x2 begins. 0 turns the 1x1 tier off."),
        ("sodium.options.mobile_lod_1x1.value", "%s chunks"),
        ("sodium.options.mobile_lod_tier2.name", "Mobile: 4x4 Starts At"),
        ("sodium.options.mobile_lod_tier2.tooltip",
         "Distance in chunks where 2x2 quads switch to 4x4. Kept in order automatically, it cannot start before the tier before it."),
        ("sodium.options.mobile_lod_tier2.value", "%s chunks"),
        ("sodium.options.mobile_lod_tier3.name", "Mobile: 8x8 Starts At"),
        ("sodium.options.mobile_lod_tier3.tooltip",
         "Distance in chunks where 4x4 quads switch to 8x8. Only used when Coarsest Size is level 3."),
        ("sodium.options.mobile_lod_tier3.value", "%s chunks"),
        ("sodium.options.mobile_lod_trees.name", "Mobile: LOD Trees"),
        ("sodium.options.mobile_lod_trees.tooltip",
         "0 = no trees, 1 = low (thin leaf canopy in the closer tiers), 2 = high (canopy up to 4x4). Terrain under trees stays smooth."),
        ("sodium.options.mobile_lod_trees.value", "Level %s"),
        ("sodium.options.mobile_lod_layered_sides.name", "Mobile: LOD Layered Cliffs"),
        ("sodium.options.mobile_lod_layered_sides.tooltip",
         "Cliff walls use the real blocks (grass cap, dirt, stone) instead of copying the top block onto the whole wall."),
        ("sodium.options.mobile_lod_water_depth.name", "Mobile: LOD Water Depth"),
        ("sodium.options.mobile_lod_water_depth.tooltip",
         "Shallow water is drawn lighter and deep water darker in the LOD."),
    ])
    if mode20:
        fields += (
            "        // Sodium Mobile v2.0: LOD shading, low poly slopes, start of the 16x16 tier (outside LOD only)\n"
            "        public int mobileLodShading = 1;\n"
            "        public boolean mobileLodLowPoly = false;\n"
            "        public int mobileLod16x16Chunks = 24;\n"
            "        // Sodium Mobile v2.1: LOD performance options\n"
            "        public int mobileLodBuildBudget = 16;\n"
            "        public int mobileLodUpdateDelay = 3;\n"
            "        public boolean mobileLodPauseFast = false;\n"
            "        public int mobileLodTreesMaxChunks = 0;\n"
            "        public int mobileLodWallDetail = 2;\n"
            "        public boolean mobileLodZoom = false;\n"
            "        public int mobileLodZoomChunks = 24;\n"
            "        public int mobileLodZoomSpeed = 2;\n")
        blocks += (opt_block("int", "mobile_lod_shading", 0, 2, 1, "mobileLodShading", "LOW", True)
                   + opt_block("bool", "mobile_lod_low_poly", 0, 0, 0, "mobileLodLowPoly", "LOW", True)
                   + opt_block("int", "mobile_lod_16x16", 8, 48, 1, "mobileLod16x16Chunks", "LOW", True)
                   + opt_block("int", "mobile_lod_build_budget", 1, 64, 1, "mobileLodBuildBudget", "LOW")
                   + opt_block("int", "mobile_lod_update_delay", 0, 20, 1, "mobileLodUpdateDelay", "LOW")
                   + opt_block("bool", "mobile_lod_pause_fast", 0, 0, 0, "mobileLodPauseFast", "LOW")
                   + opt_block("int", "mobile_lod_trees_max", 0, 48, 1, "mobileLodTreesMaxChunks", "MEDIUM", True)
                   + opt_block("int", "mobile_lod_wall_detail", 0, 2, 1, "mobileLodWallDetail", "MEDIUM", True)
                   + opt_block("bool", "mobile_lod_zoom", 0, 0, 0, "mobileLodZoom", "LOW")
                   + opt_block("int", "mobile_lod_zoom_chunks", 8, 48, 1, "mobileLodZoomChunks", "LOW")
                   + opt_block("int", "mobile_lod_zoom_speed", 1, 3, 1, "mobileLodZoomSpeed", "LOW"))
        lang += lang_lines([
            ("sodium.options.mobile_lod_shading.name", "Mobile: LOD Shading"),
            ("sodium.options.mobile_lod_shading.tooltip",
             "Distant Horizons style shading on the LOD: slopes get darker away from the sun, cliffs darken toward their base, corners and forest floors get a little darker. 0 = off, 1 = low, 2 = high."),
            ("sodium.options.mobile_lod_shading.value", "Level %s"),
            ("sodium.options.mobile_lod_low_poly.name", "Mobile: LOD Low Poly"),
            ("sodium.options.mobile_lod_low_poly.tooltip",
             "In the 4x4 tiers and beyond, slopes are drawn as smooth angled surfaces instead of stepped blocks. Cliffs stay sharp."),
            ("sodium.options.mobile_lod_16x16.name", "Mobile: 16x16 Starts At"),
            ("sodium.options.mobile_lod_16x16.tooltip",
             "Distance in chunks where the outside LOD switches from 8x8 to 16x16 quads. Only used by the outside LOD."),
            ("sodium.options.mobile_lod_16x16.value", "%s chunks"),
            ("sodium.options.mobile_lod_build_budget.name", "LOD Rebuilds Per Frame"),
            ("sodium.options.mobile_lod_build_budget.tooltip",
             "How many LOD sections may change detail level in one frame. Lower is smoother while moving, higher finishes changes faster."),
            ("sodium.options.mobile_lod_build_budget.value", "%s per frame"),
            ("sodium.options.mobile_lod_update_delay.name", "LOD Update Delay"),
            ("sodium.options.mobile_lod_update_delay.tooltip",
             "Waits this long after you cross a chunk border before LOD sections change detail level. 0 = no wait."),
            ("sodium.options.mobile_lod_update_delay.value", "%s x 0.1 s"),
            ("sodium.options.mobile_lod_pause_fast.name", "LOD Pause While Moving Fast"),
            ("sodium.options.mobile_lod_pause_fast.tooltip",
             "Holds LOD detail changes while you fly or sprint fast and applies them when you slow down. Saves CPU, but detail can lag behind."),
            ("sodium.options.mobile_lod_trees_max.name", "LOD Trees Up To"),
            ("sodium.options.mobile_lod_trees_max.tooltip",
             "Trees are only drawn as canopy up to this distance, farther out they are painted on the ground. 0 = no limit."),
            ("sodium.options.mobile_lod_trees_max.value", "%s chunks"),
            ("sodium.options.mobile_lod_wall_detail.name", "LOD Wall Detail"),
            ("sodium.options.mobile_lod_wall_detail.tooltip",
             "Cliff wall layers. 0 = one colour per wall, 1 = two layers, 2 = up to four layers."),
            ("sodium.options.mobile_lod_wall_detail.value", "Level %s"),
            ("sodium.options.mobile_lod_zoom.name", "LOD Zoom Detail"),
            ("sodium.options.mobile_lod_zoom.tooltip",
             "When you zoom in (spyglass or a zoom mod that changes the field of view), distant LOD gets finer detail, and goes back when you zoom out."),
            ("sodium.options.mobile_lod_zoom_chunks.name", "LOD Zoom Detail Distance"),
            ("sodium.options.mobile_lod_zoom_chunks.tooltip", "How far the finer detail reaches while zoomed."),
            ("sodium.options.mobile_lod_zoom_chunks.value", "%s chunks"),
            ("sodium.options.mobile_lod_zoom_speed.name", "LOD Zoom Detail Speed"),
            ("sodium.options.mobile_lod_zoom_speed.tooltip",
             "How fast finer meshes are built after zooming. 1 = smooth, 3 = fast but may stutter."),
            ("sodium.options.mobile_lod_zoom_speed.value", "Level %s"),
        ])
    add_options(fields, blocks, lang)
    wr(P_TASK, s_task); wr(P_SECTION, s_sec); wr(P_COLLECTOR, s_col); wr(P_RSM, s_rsm)
    if mode20:
        wr(P_SWR, s_swr)
    wr(P_LOD, LOD_JAVA_V20 if mode20 else LOD_JAVA_V15)


TWEAKS_JAVA = '''package net.caffeinemc.mods.sodium.client.render.chunk;

import it.unimi.dsi.fastutil.longs.Long2IntOpenHashMap;
import net.caffeinemc.mods.sodium.client.SodiumClientMod;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.levelgen.Heightmap;

/**
 * Sodium Mobile: hides chunk sections that are far below the terrain surface while the camera is outside caves.
 * Only used from the render thread.
 */
public final class MobileTweaks {
    private static final Long2IntOpenHashMap SURFACE = new Long2IntOpenHashMap();
    private static final int UNKNOWN = Integer.MIN_VALUE;

    static {
        SURFACE.defaultReturnValue(UNKNOWN);
    }

    private static Level level;
    private static boolean active;
    private static int depth;
    private static int cameraY;
    private static int frames;

    private MobileTweaks() {
    }

    public static void beginFrame(Level currentLevel, int cameraX, int cameraYIn, int cameraZ) {
        var perf = SodiumClientMod.options().performance;

        if (!perf.mobileHideUnderground || currentLevel == null) {
            active = false;
            return;
        }

        if (currentLevel != level || (++frames % 120) == 0 || SURFACE.size() > 40000) {
            SURFACE.clear();
            level = currentLevel;
        }

        depth = perf.mobileUndergroundDepthChunks * 16;
        cameraY = cameraYIn;

        // only hide things while the camera is outside caves and buildings
        int cameraSurface = currentLevel.getHeight(Heightmap.Types.WORLD_SURFACE, cameraX, cameraZ);
        active = cameraYIn >= cameraSurface - 6;
    }

    public static boolean isHiddenUnderground(int chunkX, int chunkY, int chunkZ) {
        if (!active) {
            return false;
        }

        int sectionTop = (chunkY << 4) + 16;

        // never hide anything at or above the camera
        if (sectionTop >= cameraY - 16) {
            return false;
        }

        long key = ((long) chunkX << 32) ^ (chunkZ & 0xFFFFFFFFL);
        int surface = SURFACE.get(key);

        if (surface == UNKNOWN) {
            surface = level.getHeight(Heightmap.Types.WORLD_SURFACE, (chunkX << 4) + 8, (chunkZ << 4) + 8);
            SURFACE.put(key, surface);
        }

        return sectionTop < surface - depth;
    }
}
'''


def feature_underground():
    s = rd(P_OCC)
    s = replace_once(
        s,
        "        return isWithinRenderDistance(viewport.getTransform(), section, maxDistance) && isWithinFrustum(viewport, section);",
        "        return isWithinRenderDistance(viewport.getTransform(), section, maxDistance) && isWithinFrustum(viewport, section)\n"
        "                && !net.caffeinemc.mods.sodium.client.render.chunk.MobileTweaks.isHiddenUnderground(section.getChunkX(), section.getChunkY(), section.getChunkZ());",
        "OcclusionCuller visible check")
    s = replace_once(
        s,
        "        final var queues = this.queue;\n        queues.reset();\n",
        "        final var queues = this.queue;\n        queues.reset();\n\n"
        "        {\n"
        "            var mobileCamera = viewport.getTransform();\n"
        "            net.caffeinemc.mods.sodium.client.render.chunk.MobileTweaks.beginFrame(this.level, mobileCamera.intX, mobileCamera.intY, mobileCamera.intZ);\n"
        "        }\n",
        "OcclusionCuller findVisible")
    fields = (
        "        // Sodium Mobile: hide chunk sections deeper than this many chunks below the surface (while outside caves)\n"
        "        public boolean mobileHideUnderground = true;\n"
        "        public int mobileUndergroundDepthChunks = 3;\n")
    blocks = (opt_block("bool", "mobile_hide_underground", 0, 0, 0, "mobileHideUnderground", "HIGH")
              + opt_block("int", "mobile_underground_depth", 1, 8, 1, "mobileUndergroundDepthChunks", "MEDIUM"))
    lang = lang_lines([
        ("sodium.options.mobile_hide_underground.name", "Mobile: Hide Underground"),
        ("sodium.options.mobile_hide_underground.tooltip",
         "Skips chunk sections far below the surface while you are outside caves. Saves CPU and GPU, but caves and cliff bases seen from outside can look cut off."),
        ("sodium.options.mobile_underground_depth.name", "Mobile: Underground Depth"),
        ("sodium.options.mobile_underground_depth.tooltip",
         "How many chunks below the surface terrain keeps being drawn. Lower hides more."),
        ("sodium.options.mobile_underground_depth.value", "%s chunks"),
    ])
    add_options(fields, blocks, lang)
    wr(P_OCC, s)
    tweaks = TWEAKS_JAVA
    if os.path.exists(P_LOD) and "isLodColumn" in rd(P_LOD):
        tweaks = replace_once(
            tweaks, "        int sectionTop = (chunkY << 4) + 16;\n",
            "        if (MobileLod.isLodColumn(chunkX, chunkZ)) {\n            return false;\n        }\n\n        int sectionTop = (chunkY << 4) + 16;\n",
            "MobileTweaks lod check")
    wr(P_TWEAKS, tweaks)



# ------------------------------------------------------------ outside LOD (v2.0)
P_SWR = JAVA + "render/SodiumWorldRenderer.java"
P_FOGMIX = BASE + "/java/net/caffeinemc/mods/sodium/mixin/core/render/world/FogRendererMixin.java"
P_OUT = JAVA + "render/chunk/MobileOutsideLod.java"
P_MLT = JAVA + "render/chunk/compile/tasks/MobileLodTask.java"
MOF = "net.caffeinemc.mods.sodium.client.render.chunk.MobileOutsideLod"


def clear_block():
    return ("\n                .addOption(\n"
            '                        builder.createBooleanOption(Identifier.parse("sodium:performance.mobile_lod_clear_cache"))\n'
            "                                .setStorageHandler(this.sodiumStorage)\n"
            '                                .setName(Component.translatable("sodium.options.mobile_lod_clear_cache.name"))\n'
            '                                .setTooltip(Component.translatable("sodium.options.mobile_lod_clear_cache.tooltip"))\n'
            "                                .setDefaultValue(false)\n"
            "                                .setBinding(value -> { if (value) " + MOF + ".requestClear(); }, () -> false)\n"
            "                                .setImpact(OptionImpact.LOW)\n"
            "                )")


def feature_outside():
    need("v20" not in SKIP and "quad" not in SKIP, "needs the v2.0 LOD mesher")
    need(os.path.exists(P_LOD) and "buildOutside" in rd(P_LOD), "v2.0 LOD mesher is not in the tree")
    s_rsm = rd(P_RSM)
    s_swr = rd(P_SWR)
    s_fm = rd(P_FOGMIX)

    # --- section manager
    s_rsm = replace_once(
        s_rsm, "    public void onChunkAdded(int x, int z) {\n",
        "    public void onChunkAdded(int x, int z) {\n        " + MOF + ".onRealChunkAdded(this, x, z);\n",
        "RenderSectionManager.onChunkAdded")
    s_rsm = replace_once(
        s_rsm, "    public void onChunkRemoved(int x, int z) {\n",
        "    public void onChunkRemoved(int x, int z) {\n        if (" + MOF + ".onRealChunkRemoved(this, x, z)) {\n            return;\n        }\n",
        "RenderSectionManager.onChunkRemoved")
    s_rsm = replace_once(
        s_rsm, "    public Collection<RenderSection> getSectionsWithGlobalEntities() {",
        "    // Sodium Mobile: sections of the outside LOD are fake sections drawn from the column cache\n"
        "    public void mobileAddLodSection(int x, int y, int z, boolean air) {\n"
        "        long key = SectionPos.asLong(x, y, z);\n\n"
        "        if (this.sectionByPosition.containsKey(key)) {\n"
        "            return;\n"
        "        }\n\n"
        "        RenderRegion region = this.regions.createForChunk(x, y, z);\n"
        "        RenderSection renderSection = new RenderSection(region, x, y, z);\n"
        "        renderSection.mobileOutside = true;\n"
        "        renderSection.mobileAir = air;\n"
        "        region.addSection(renderSection);\n"
        "        this.sectionByPosition.put(key, renderSection);\n\n"
        "        if (air) {\n"
        "            this.updateSectionInfo(renderSection, BuiltSectionInfo.EMPTY);\n"
        "        } else {\n"
        "            this.renderableSectionTree.add(renderSection);\n"
        "            renderSection.setPendingUpdate(ChunkUpdateTypes.INITIAL_BUILD, this.lastFrameAtTime);\n"
        "        }\n\n"
        "        this.connectNeighborNodes(renderSection);\n"
        "        this.markGraphDirty();\n"
        "    }\n\n"
        "    public void mobileRemoveLodSection(int x, int y, int z) {\n"
        "        RenderSection section = this.sectionByPosition.get(SectionPos.asLong(x, y, z));\n\n"
        "        if (section != null && section.mobileOutside) {\n"
        "            this.onSectionRemoved(x, y, z);\n"
        "        }\n"
        "    }\n\n"
        "    // a real chunk arrived where fake sections are: keep them (and their meshes) and rebuild them as real sections\n"
        "    public void mobilePromoteColumn(int x, int z) {\n"
        "        for (int y = this.level.getMinSectionY(); y <= this.level.getMaxSectionY(); y++) {\n"
        "            RenderSection section = this.sectionByPosition.get(SectionPos.asLong(x, y, z));\n\n"
        "            if (section == null || !section.mobileOutside) {\n"
        "                continue;\n"
        "            }\n\n"
        "            if (section.mobileAir) {\n"
        "                this.onSectionRemoved(x, y, z);\n"
        "                continue;\n"
        "            }\n\n"
        "            section.mobileOutside = false;\n"
        "            section.mobileLodBuilt = false;\n"
        "            this.upgradePendingUpdate(section, ChunkUpdateTypes.REBUILD);\n"
        "        }\n"
        "    }\n\n"
        "    // a real chunk is leaving: keep its sections and rebuild them from the column cache\n"
        "    public void mobileDemoteColumn(int x, int z, int lo, int hi, int airTop) {\n"
        "        for (int y = this.level.getMinSectionY(); y <= this.level.getMaxSectionY(); y++) {\n"
        "            RenderSection section = this.sectionByPosition.get(SectionPos.asLong(x, y, z));\n\n"
        "            if (section == null) {\n"
        "                continue;\n"
        "            }\n\n"
        "            if (y >= lo && y <= hi) {\n"
        "                section.mobileOutside = true;\n"
        "                section.mobileAir = false;\n"
        "                section.mobileLodBuilt = false;\n"
        "                this.renderableSectionTree.add(section);\n"
        "                this.upgradePendingUpdate(section, ChunkUpdateTypes.REBUILD);\n"
        "            } else if (y > hi && y <= airTop && !RenderSectionFlags.needsRender(section.getFlags())) {\n"
        "                section.mobileOutside = true;\n"
        "                section.mobileAir = true;\n"
        "            } else {\n"
        "                this.onSectionRemoved(x, y, z);\n"
        "            }\n"
        "        }\n"
        "    }\n\n"
        "    public int mobileCountUnbuilt() {\n"
        "        int count = 0;\n\n"
        "        for (RenderSection section : this.sectionByPosition.values()) {\n"
        "            if (section.mobileOutside && !section.mobileAir && !section.isBuilt()) {\n"
        "                count++;\n"
        "            }\n"
        "        }\n\n"
        "        return count;\n"
        "    }\n\n"
        "    public Collection<RenderSection> getSectionsWithGlobalEntities() {",
        "RenderSectionManager methods")
    s_rsm = replace_once(
        s_rsm,
        "    public @Nullable ChunkBuilderMeshingTask createRebuildTask(RenderSection render, int frame) {\n",
        "    public @Nullable ChunkBuilderMeshingTask createRebuildTask(RenderSection render, int frame) {\n"
        "        if (render.mobileOutside) {\n"
        "            var mobileTask = new net.caffeinemc.mods.sodium.client.render.chunk.compile.tasks.MobileLodTask(render, frame, this.cameraPosition, this.sortBehavior);\n"
        "            mobileTask.calculateEstimations(this.jobDurationEstimator, this.meshTaskSizeEstimator, this.jobUploadDurationEstimator);\n"
        "            return mobileTask;\n"
        "        }\n\n",
        "RenderSectionManager.createRebuildTask")
    s_rsm = replace_once(
        s_rsm, "        this.sectionCache.invalidate(x, y, z);\n",
        "        this.sectionCache.invalidate(x, y, z);\n        " + MOF + ".onSectionDirty(x, z);\n",
        "RenderSectionManager.scheduleRebuild")

    # --- world renderer
    s_swr = replace_once(
        s_swr, "        this.renderSectionManager = new RenderSectionManager(this.level, this.renderDistance, sortBehavior, commandList);\n",
        "        this.renderSectionManager = new RenderSectionManager(this.level, this.renderDistance + " + MOF + ".configureExtra(this.renderDistance), sortBehavior, commandList);\n",
        "SodiumWorldRenderer.initRenderer")
    s_swr = replace_once(
        s_swr, "        this.renderSectionManager.prepareFrame(pos);\n",
        "        this.renderSectionManager.prepareFrame(pos);\n        " + MOF + ".frame(this.renderSectionManager, this.level, pos.x, pos.y, pos.z, yaw, this.renderDistance);\n",
        "SodiumWorldRenderer.setupTerrain")
    s_swr = replace_once(
        s_swr, "    private void unloadLevel() {\n",
        "    private void unloadLevel() {\n        " + MOF + ".onUnload();\n",
        "SodiumWorldRenderer.unloadLevel")
    s_swr = replace_once(
        s_swr,
        "        return this.renderSectionManager == null ? Collections.emptyList() : this.renderSectionManager.getDebugStrings(verbose);\n",
        "        if (this.renderSectionManager == null) {\n"
        "            return Collections.emptyList();\n"
        "        }\n\n"
        "        Collection<String> mobileDebug = this.renderSectionManager.getDebugStrings(verbose);\n\n"
        "        if (SodiumClientMod.options().performance.mobileLodDebug) {\n"
        "            String mobileLine = " + MOF + ".debugLine(this.renderSectionManager);\n\n"
        "            if (mobileLine != null) {\n"
        "                mobileDebug = new java.util.ArrayList<>(mobileDebug);\n"
        "                mobileDebug.add(mobileLine);\n"
        "            }\n"
        "        }\n\n"
        "        return mobileDebug;\n",
        "SodiumWorldRenderer.getDebugStrings")

    # --- fog: stretch the fog the renderer uses to the end of the outside LOD
    s_fm = replace_once(
        s_fm,
        "        this.parameters = new FogParameters(fogColor.x, fogColor.y, fogColor.z, fogColor.w, data.environmentalStart, data.environmentalEnd, data.renderDistanceStart, data.renderDistanceEnd);\n",
        "        float mobileFar = " + MOF + ".fogExtra() * 16.0f;\n"
        "        float mobileEnvStart = data.environmentalStart;\n"
        "        float mobileEnvEnd = data.environmentalEnd;\n"
        "        if (mobileFar > 0.0f && mobileEnvEnd >= data.renderDistanceStart) {\n"
        "            if (mobileEnvStart > 0.0f) {\n"
        "                mobileEnvStart += mobileFar;\n"
        "            }\n"
        "            mobileEnvEnd += mobileFar;\n"
        "        }\n"
        "        this.parameters = new FogParameters(fogColor.x, fogColor.y, fogColor.z, fogColor.w, mobileEnvStart, mobileEnvEnd, data.renderDistanceStart + mobileFar, data.renderDistanceEnd + mobileFar);\n",
        "FogRendererMixin")

    fields = (
        "        // Sodium Mobile v2.0: outside LOD (terrain remembered from where you have been, drawn beyond the render distance)\n"
        "        public boolean mobileLodOutside = false;\n"
        "        public int mobileLodOutsideChunks = 16;\n"
        "        public int mobileLodOutsideRamMb = 64;\n"
        "        public int mobileLodOutsideSpeed = 2;\n"
        "        public int mobileLodSaveMinutes = 3;\n"
        "        public boolean mobileLodDebug = false;\n")
    blocks = (opt_block("bool", "mobile_lod_outside", 0, 0, 0, "mobileLodOutside", "HIGH", True)
              + opt_block("int", "mobile_lod_outside_chunks", 4, 48, 1, "mobileLodOutsideChunks", "MEDIUM", True)
              + opt_block("int", "mobile_lod_outside_ram", 16, 256, 8, "mobileLodOutsideRamMb", "LOW")
              + opt_block("int", "mobile_lod_outside_speed", 1, 3, 1, "mobileLodOutsideSpeed", "LOW")
              + opt_block("int", "mobile_lod_save_minutes", 1, 10, 1, "mobileLodSaveMinutes", "LOW")
              + opt_block("bool", "mobile_lod_debug", 0, 0, 0, "mobileLodDebug", "LOW")
              + clear_block())
    lang = lang_lines([
        ("sodium.options.mobile_lod_outside.name", "Mobile: Outside LOD"),
        ("sodium.options.mobile_lod_outside.tooltip",
         "Draws terrain you have seen before beyond your render distance. Chunks are remembered as small summaries, kept per world on disk and refreshed whenever you come back. Needs Quad LOD. Off by default."),
        ("sodium.options.mobile_lod_outside_chunks.name", "Mobile: Outside LOD Distance"),
        ("sodium.options.mobile_lod_outside_chunks.tooltip",
         "How many chunks past your render distance the outside LOD reaches. Limited by the game to about 3x your render distance."),
        ("sodium.options.mobile_lod_outside_chunks.value", "+%s chunks"),
        ("sodium.options.mobile_lod_outside_ram.name", "Mobile: Outside LOD Memory"),
        ("sodium.options.mobile_lod_outside_ram.tooltip",
         "Memory the remembered terrain may use. When it is full the chunks farthest from you are forgotten first."),
        ("sodium.options.mobile_lod_outside_ram.value", "%s MB"),
        ("sodium.options.mobile_lod_outside_speed.name", "Mobile: Outside LOD Speed"),
        ("sodium.options.mobile_lod_outside_speed.tooltip",
         "How fast far terrain is built. 1 = slow and smooth, 3 = fast but may stutter. Nearest and in-front chunks are built first."),
        ("sodium.options.mobile_lod_outside_speed.value", "Level %s"),
        ("sodium.options.mobile_lod_save_minutes.name", "Mobile: Outside LOD Save Interval"),
        ("sodium.options.mobile_lod_save_minutes.tooltip", "How often the remembered terrain is written to disk in the background."),
        ("sodium.options.mobile_lod_save_minutes.value", "%s min"),
        ("sodium.options.mobile_lod_debug.name", "Mobile: LOD Debug Line"),
        ("sodium.options.mobile_lod_debug.tooltip", "Shows outside LOD numbers (remembered chunks, memory, drawn chunks) in the F3 screen."),
        ("sodium.options.mobile_lod_clear_cache.name", "Mobile: Clear LOD Cache"),
        ("sodium.options.mobile_lod_clear_cache.tooltip",
         "Turn this on and press Apply to forget all remembered terrain of this world and delete its file. Nearby chunks are remembered again right away."),
    ])
    add_options(fields, blocks, lang)
    wr(P_RSM, s_rsm); wr(P_SWR, s_swr); wr(P_FOGMIX, s_fm)
    wr(P_OUT, OUTSIDE_JAVA); wr(P_MLT, TASK_JAVA)


# ------------------------------------------------------------ edge fog for the LOD
P_DSI = JAVA + "render/chunk/shader/DefaultShaderInterface.java"
P_FSH = BASE + "/resources/assets/sodium/shaders/blocks/block_layer_opaque.fsh"


def feature_fog():
    s_dsi, s_fsh = rd(P_DSI), rd(P_FSH)
    has_cull = "mobileFarCullPercent" in rd(P_OPTS)

    s_dsi = insert_after(
        s_dsi, "    private final GlUniformBool uniformFastSampling;\n",
        "    private final GlUniformFloat2v uniformMobileFog;\n", "DefaultShaderInterface field")
    s_dsi = insert_after(
        s_dsi, '        this.uniformFastSampling = context.bindUniform("u_FastSampling", GlUniformBool::new);\n',
        '        this.uniformMobileFog = context.bindUniform("u_MobileFog", GlUniformFloat2v::new);\n',
        "DefaultShaderInterface bind")
    cull = ("            if (mfp.mobileFarCullPercent < 100) {\n"
            "                mfEnd = mfEnd * (mfp.mobileFarCullPercent / 100.0f);\n"
            "            }\n") if has_cull else ""
    s_dsi = insert_after(
        s_dsi,
        "        this.uniformFastSampling.setBool(SodiumClientMod.options().performance.mobileFastTextureSampling);\n",
        "        {\n"
        "            var mfp = SodiumClientMod.options().performance;\n"
        "            float mfStart = 0.0f;\n"
        "            float mfEnd = 0.0f;\n"
        "            if (mfp.mobileLodFog && mfp.mobileQuadLod) {\n"
        "                mfEnd = Minecraft.getInstance().options.getEffectiveRenderDistance() * 16.0f;\n"
        + cull +
        "                mfStart = Math.max(16.0f, mfEnd - mfp.mobileLodFogWidth * 16.0f);\n"
        "            }\n"
        "            this.uniformMobileFog.set(new float[] { mfStart, mfEnd });\n"
        "        }\n",
        "DefaultShaderInterface set")

    need(s_fsh.count("uniform vec2 u_RenderFog; // The start and end position for border fog\n") == 1, "fsh: u_RenderFog anchor")
    need(s_fsh.count("    fragColor = _linearFog(color, v_FragDistance, u_FogColor, u_EnvironmentFog, u_RenderFog, fadeFactor);\n") == 1, "fsh: fragColor anchor")
    s_fsh = s_fsh.replace(
        "uniform vec2 u_RenderFog; // The start and end position for border fog\n",
        "uniform vec2 u_RenderFog; // The start and end position for border fog\n"
        "uniform vec2 u_MobileFog; // Sodium Mobile: LOD edge fog, start and end distance in blocks (equal = off)\n", 1)
    s_fsh = s_fsh.replace(
        "    fragColor = _linearFog(color, v_FragDistance, u_FogColor, u_EnvironmentFog, u_RenderFog, fadeFactor);\n",
        "    fragColor = _linearFog(color, v_FragDistance, u_FogColor, u_EnvironmentFog, u_RenderFog, fadeFactor);\n"
        "#ifdef USE_FOG\n"
        "    if (u_MobileFog.y > u_MobileFog.x) {\n"
        "        float mobileFog = clamp((v_FragDistance.x - u_MobileFog.x) / (u_MobileFog.y - u_MobileFog.x), 0.0, 1.0);\n"
        "        fragColor.rgb = mix(fragColor.rgb, u_FogColor.rgb, mobileFog * u_FogColor.a);\n"
        "    }\n"
        "#endif\n", 1)

    fields = (
        "        // Sodium Mobile v1.5: fade the end of the render distance into the fog colour\n"
        "        public boolean mobileLodFog = true;\n"
        "        public int mobileLodFogWidth = 3;\n")
    blocks = (opt_block("bool", "mobile_lod_fog", 0, 0, 0, "mobileLodFog", "LOW")
              + opt_block("int", "mobile_lod_fog_width", 1, 8, 1, "mobileLodFogWidth", "LOW"))
    lang = lang_lines([
        ("sodium.options.mobile_lod_fog.name", "Mobile: LOD Edge Fog"),
        ("sodium.options.mobile_lod_fog.tooltip",
         "Fades the far end of the terrain into the fog colour so the LOD blends into the sky instead of cutting off. Needs Quad LOD on."),
        ("sodium.options.mobile_lod_fog_width.name", "Mobile: LOD Fog Width"),
        ("sodium.options.mobile_lod_fog_width.tooltip", "How many chunks before the edge the fade starts."),
        ("sodium.options.mobile_lod_fog_width.value", "%s chunks"),
    ])
    add_options(fields, blocks, lang)
    wr(P_DSI, s_dsi); wr(P_FSH, s_fsh)


# ------------------------------------------------------------ mobile page + LOD page
LOD_GROUPS = (
    ("quality", ("mobile_quad_lod", "mobile_lod_preset", "mobile_lod_shading", "mobile_lod_low_poly", "mobile_lod_trees",
                 "mobile_lod_trees_max", "mobile_lod_layered_sides", "mobile_lod_wall_detail", "mobile_lod_water_depth")),
    ("distances", ("mobile_quad_lod_level", "mobile_lod_start", "mobile_lod_1x1", "mobile_lod_tier2", "mobile_lod_tier3",
                   "mobile_lod_16x16")),
    ("speed", ("mobile_lod_build_budget", "mobile_lod_update_delay", "mobile_lod_pause_fast", "mobile_lod_zoom",
               "mobile_lod_zoom_chunks", "mobile_lod_zoom_speed")),
    ("outside", ("mobile_lod_outside", "mobile_lod_outside_chunks", "mobile_lod_outside_ram", "mobile_lod_outside_speed",
                 "mobile_lod_save_minutes", "mobile_lod_clear_cache")),
    ("fog", ("mobile_lod_fog", "mobile_lod_fog_width", "mobile_lod_debug")),
)


def is_lod_ident(ident):
    return ident.startswith("mobile_quad_lod") or ident.startswith("mobile_lod_")


def feature_tab():
    s = rd(P_CFG)
    s_lang = rd(P_LANG)
    head = ('        performancePage.addOptionGroup(builder.createOptionGroup()\n'
            '                .addOption(\n'
            '                        builder.createIntegerOption(Identifier.parse("sodium:performance.mobile_upload_budget"))')
    need(s.count(head) == 1, "SodiumConfigBuilder: mobile group start not found")
    start = s.index(head)
    end_tok = "\n        );\n"
    end = s.find(end_tok, start)
    need(end > 0, "SodiumConfigBuilder: mobile group end not found")
    end += len(end_tok)
    group = s[start:end]
    rest = s[end:]
    if rest.startswith("\n"):
        end += 1
    s = s[:start] + s[end:]

    # split the group into single options and sort them: LOD options get their own page
    body = group[: -len(end_tok)]
    pieces = re.split(r"(?=\n\s*\.addOption\()", body)
    first = pieces[0]
    opts = pieces[1:]
    need(len(opts) >= 3, "mobile group: options not found")
    mobile_opts = []
    lod_by_ident = {}
    lod_other = []
    for o in opts:
        m = re.search(r'sodium:performance\.(\w+)"', o)
        need(m is not None, "option without identifier")
        ident = m.group(1)
        if is_lod_ident(ident):
            lod_by_ident[ident] = o
        else:
            mobile_opts.append(o)

    mobile_group = first + "".join(mobile_opts) + end_tok
    mobile_group = mobile_group.replace("performancePage", "mobilePage")

    lod_groups = ""
    used = set()
    for _name, idents in LOD_GROUPS:
        chunk = [lod_by_ident[i] for i in idents if i in lod_by_ident]
        used.update(i for i in idents if i in lod_by_ident)
        if chunk:
            lod_groups += ("        lodPage.addOptionGroup(builder.createOptionGroup()" + "".join(chunk) + end_tok + "\n")
    leftovers = [o for i, o in lod_by_ident.items() if i not in used]
    if leftovers:
        lod_groups += ("        lodPage.addOptionGroup(builder.createOptionGroup()" + "".join(leftovers) + end_tok + "\n")

    methods = (
        "    private OptionPageBuilder buildMobilePage(ConfigBuilder builder) {\n"
        '        var mobilePage = builder.createOptionPage().setName(Component.translatable("sodium.options.pages.mobile"));\n'
        "\n" + mobile_group + "\n"
        "        return mobilePage;\n"
        "    }\n\n")
    add_lod = bool(lod_groups)
    if add_lod:
        methods += (
            "    private OptionPageBuilder buildLodPage(ConfigBuilder builder) {\n"
            '        var lodPage = builder.createOptionPage().setName(Component.translatable("sodium.options.pages.lod"));\n'
            "\n" + lod_groups +
            "        return lodPage;\n"
            "    }\n\n")
    s = replace_once(s, "    private OptionPageBuilder buildAdvancedPage(ConfigBuilder builder) {",
                     methods + "    private OptionPageBuilder buildAdvancedPage(ConfigBuilder builder) {", "buildAdvancedPage anchor")
    pages = ".addPage(this.buildPerformancePage(builder))\n                .addPage(this.buildMobilePage(builder))"
    if add_lod:
        pages += "\n                .addPage(this.buildLodPage(builder))"
    s = replace_once(s, ".addPage(this.buildPerformancePage(builder))", pages, "addPage")
    m = re.search(r'^[ \t]*"sodium\.options\.pages\.performance".*\n', s_lang, re.M)
    need(m is not None, "en_us.json: pages.performance anchor")
    extra = '  "sodium.options.pages.mobile": "Mobile",\n'
    if add_lod:
        extra += '  "sodium.options.pages.lod": "LOD",\n'
    s_lang = s_lang[: m.end()] + extra + s_lang[m.end():]
    wr(P_CFG, s); wr(P_LANG, s_lang)


base = ""
if os.path.exists("../applied_base.txt"):
    base = open("../applied_base.txt").read().strip()

features = (("flat", feature_flat), ("quad", feature_lod), ("outside", feature_outside), ("fog", feature_fog), ("ug", feature_underground), ("tab", feature_tab))
if "all" in SKIP:
    features = ()

for name, fn in features:
    if name in SKIP:
        print("SKIPPED (by request):", name)
        continue
    # keep a copy so a half-applied feature can be rolled back
    backup = {}
    for p in (P_OPTS, P_CFG, P_LANG, P_OCC, P_ABRC, P_FLUID, P_TASK, P_SECTION, P_COLLECTOR, P_RSM, P_DSI, P_FSH, P_SWR, P_FOGMIX):
        backup[p] = rd(p)
    try:
        fn()
        applied.append(("quad15" if "v20" in SKIP else "quad21") if name == "quad" else name)
        print("APPLIED:", name)
    except Skip as e:
        for p, c in backup.items():
            wr(p, c)
        if name == "ug" and os.path.exists(P_TWEAKS):
            os.remove(P_TWEAKS)
        if name == "quad" and os.path.exists(P_LOD):
            os.remove(P_LOD)
        if name == "outside":
            for pp in (P_OUT, P_MLT):
                if os.path.exists(pp):
                    os.remove(pp)
        print("::warning::Sodium Mobile feature '%s' SKIPPED: %s" % (name, e))

tag = "-".join([t for t in [base] + applied if t])
with open("../applied.txt", "w") as f:
    f.write(tag)
print("Features applied:", tag)
PY_EOF
cp -r sodium-mc1.21.11-0.8.14 snap
cp applied.txt applied_base.txt
build_attempt() {
  echo "=== Build attempt, skipping: [$1] ==="
  rm -rf sodium-mc1.21.11-0.8.14
  cp -r snap sodium-mc1.21.11-0.8.14
  ( cd sodium-mc1.21.11-0.8.14 && MOBILE_V12_SKIP="$1" python3 ../v13.py && chmod +x gradlew && ./gradlew :fabric:build -Pbuild.release )
}
build_attempt "" || build_attempt "outside" || build_attempt "outside,v20" || build_attempt "outside,v20,fog" || build_attempt "outside,v20,fog,ug" || build_attempt "outside,v20,fog,ug,quad" || build_attempt "all"
)

# ---- step 4: Collect jar
(
set -e
mkdir out
JAR=$(ls sodium-mc1.21.11-0.8.14/build/mods/*.jar | head -1)
TAG=$(cat applied.txt)
cp "$JAR" "out/sodium-mobile-2.1-${TAG}-mc1.21.11.jar"
)
