const std = @import("std");
const zigimg = @import("zigimg");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const dvx = mach.dvx;
const math = mach.math;
const time = mach.time;
const assets = @import("assets");

const pixi = @import("pixi.zig");
const ldtk = @import("ldtk.zig");

const vec2 = math.vec2;
const vec3 = math.vec3;
const vec4 = math.vec4;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const App = @This();

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .tick,
    .update,
    .cleanup,
    .snapshotFrame,
    .render,
    .deinit,
    .deinitApp,
    .deinit2,
    .audioStateChange,
    .pollInput,
    .cleanupSprites,
    .snapshot,
    .changeScene,
    .updateScene,
    .updateSceneStart,
    .updateSceneGame,
    .updateAnims,
    .updateSfx,
    .updateCamera,
    .renderFrame,
};

pub const mach_tags = .{
    .is_start_scene,
    .is_game_scene,
    .is_logo,
    .is_bgm,
    .is_sfx,
    .is_grimble,
    .delete_after_anim,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ mach.Audio, .init },
    .{ gfx.Sprite, .init },
    .{ gfx.Text, .init },
    .{ dvx.DevOverlay, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ App, .deinitApp },
    .{ App, .deinit2 },
    .{ mach.Audio, .deinit },
});

/// Runs in a loop on the app thread (see mach.startThread in App.init.)
pub const tick = mach.schedule(.{
    .{ App, .update },
    .{ App, .cleanup },
    .{ App, .snapshotFrame },
});

pub const update = mach.schedule(.{
    .{ App, .pollInput },
    .{ App, .updateScene },
    .{ App, .updateAnims },
    .{ App, .updateSfx },
    .{ App, .updateCamera },
    .{ dvx.DevOverlay, .update },
});

/// Frees objects deleted this tick. App sprites must be freed before gfx sprites, since they are
/// children of gfx sprites in the object graph.
pub const cleanup = mach.schedule(.{
    .{ App, .cleanupSprites },
    .{ gfx.Sprite, .cleanup },
    .{ gfx.Text, .cleanup },
    .{ mach.Audio, .cleanup },
});

/// Hands off a snapshot of the frame to the render thread.
pub const snapshotFrame = mach.schedule(.{
    .{ mach.Core, .snapshotStart },
    .{ gfx.Sprite, .snapshot },
    .{ gfx.Text, .snapshot },
    .{ App, .snapshot },
    .{ dvx.DevOverlay, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

pub const render = mach.schedule(.{
    .{ App, .renderFrame },
});

const Scene = enum {
    none,
    start,
    game,
};

const start_scale = 3.0;
const world_scale = 2.0;

// Initialized by App.init
allocator: std.mem.Allocator,
io: std.Io,
app_thread: mach.Thread,
window_id: mach.ObjectID,
direction: Vec2 = vec2(0, 0),
last_direction: Vec2 = vec2(0, 0),
last_facing_direction: Vec2 = vec2(0, 0),
player_position: Vec3 = vec3(0, 0, 0), // z == player layer
camera_position: Vec3 = vec3(0, 0, 0),
player_wants_to_attack: bool = false,
player_wants_to_run: bool = false,
attack_cooldown: f32 = 1.0,
attack_cooldown_timer: time.Timer,
is_attacking: bool = false,
delta_timer: time.Timer,
player_sprite_timer: time.Timer,
delta_time: f32 = 0,
player_anim_frame: isize = -1,
rand: std.Random.DefaultPrng,
world_time: f32 = 0,
scene: Scene = .start,
prev_scene: Scene = .none,
pending_scene: ?Scene = null,
pending_scene_timer: time.Timer = undefined,

// Decoded sound effects, copied into a fresh mach.Audio buffer each time they are played.
sfx_morning_bells: mach.Audio.Opus,
sfx_footsteps: mach.Audio.Opus,
sfx_freeze: mach.Audio.Opus,
sfx_grimble: mach.Audio.Opus,

/// Whether setupPipelines has run (app thread only.)
ready: bool = false,

/// GPU resources created by the render thread, see setupGpu. Once `gpu_ready` is set (by the
/// render thread), the app thread may read `gpu_res`. `gpu_res.rtt_texture`/`rtt_view` are only ever
/// replaced by the render thread, and the texture is handed to the app thread via `pending_rtt`.
gpu_res: Gpu = undefined,
gpu_ready: std.atomic.Value(bool) = .init(false),

/// A newly (re)created render-to-texture texture, created by the render thread on resize and handed
/// over to the app thread so that it can update the RTT sprite pipeline. Guarded by pending_rtt_mu.
pending_rtt: ?PendingRtt = null,
pending_rtt_mu: std.Io.Mutex = .init,

/// App state read by the render thread. Written only during App.snapshot (while the app thread
/// holds the render snapshot lock.)
render_state: RenderState = .{},

// Initialized by setupPipelines
player_id: mach.ObjectID = undefined,

// Game-level data associated with every sprite.
//
// Child of a gfx.Sprite, so that we can do app.sprites.getFirstChildOfType(gfx_sprite_obj) to
// quickly look up our game-level sprite given any gfx.Sprite object.
sprites: mach.Objects(.{}, struct {
    name: []const u8,
    // Animation fields (optional — only set for animated sprites)
    sprite_anim: ?pixi.Animation = null,
    sprite_timer: f32 = 0,
    flipped: bool = false,
    position: Vec3 = vec3(0, 0, 0),
    parallax: ?[2]f32 = null,
}),
rtt_pipeline_id: mach.ObjectID = undefined,
rtt_sprite_id: mach.ObjectID = undefined,
/// Size of the RTT texture currently bound to the RTT pipeline, in framebuffer pixels.
rtt_size: Vec2 = vec2(1, 1),
cloud_pipeline_id: mach.ObjectID = undefined,
sprite_pipeline_id: mach.ObjectID = undefined,
text_pipeline_id: mach.ObjectID = undefined,
parsed_atlas: pixi.ParsedAtlas = undefined,
parsed_level: ldtk.ParsedFile = undefined,
parsed_ldtk_compatibility: pixi.ParsedLDTKCompatibility = undefined,

const Gpu = struct {
    /// Sprite atlas texture. Also bound to the cloud pipeline, whose shader does not sample it but
    /// whose UV scale is derived from its dimensions.
    atlas_texture: *gpu.Texture,
    pass1_shader: *gpu.ShaderModule,
    clouds_shader: *gpu.ShaderModule,

    /// Per-frame effect parameters (time) shared by the pass1 and clouds shaders at @group(1).
    effect_uniforms: *gpu.Buffer,
    effect_bind_group_layout: *gpu.BindGroupLayout,
    effect_bind_group: *gpu.BindGroup,

    /// Render-to-texture target the scene is rendered into for post-processing. Owned by the
    /// render thread.
    rtt_texture: *gpu.Texture,
    rtt_view: *gpu.TextureView,
    rtt_width: u32,
    rtt_height: u32,
};

/// Must match `Effect` in pass1.wgsl and clouds.wgsl.
const EffectUniforms = extern struct {
    /// x = world time in seconds; yzw unused.
    params: gpu.Vec4 align(16),
};

const PendingRtt = struct {
    texture: *gpu.Texture,
    width: u32,
    height: u32,
};

const RenderState = struct {
    ready: bool = false,
    scene: Scene = .none,
    sprite_pipeline_id: mach.ObjectID = undefined,
    text_pipeline_id: mach.ObjectID = undefined,
    rtt_pipeline_id: mach.ObjectID = undefined,
    cloud_pipeline_id: mach.ObjectID = undefined,
    world_time: f32 = 0,
};

pub fn init(
    core: *mach.Core,
    core_mod: mach.Mod(mach.Core),
    audio: *mach.Audio,
    overlay: *dvx.DevOverlay,
    app: *App,
    app_mod: mach.Mod(App),
    ctx: mach.Context,
) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;
    core.on_exit = app_mod.id.deinit;

    // Configure the audio module to call our App.audioStateChange function when a sound buffer
    // finishes playing.
    audio.on_state_change = app_mod.id.audioStateChange;

    const window_id = try core.windows.new(.{
        .title = "Lord of Zero",
        .width = 1920.0 * (3.0 / 4.0),
        .height = 1080.0 * (3.0 / 4.0),
        .on_render = app_mod.id.render,
        // Make the window fullscreen before it opens, if you want:
        // .fullscreen = true,
    });
    overlay.attach(window_id);

    // Load pixi atlas file
    const parsed_atlas = try pixi.Atlas.parseSlice(ctx, assets.lordofzero_atlas);
    ctx.info("loaded sprite atlas: {} sprites, {} animations", .{
        parsed_atlas.value.sprites.len,
        parsed_atlas.value.animations.len,
    });

    app.* = .{
        .allocator = allocator,
        .io = io,
        .app_thread = undefined,
        .window_id = window_id,
        .sprites = app.sprites,
        .attack_cooldown_timer = time.Timer.start(io),
        .delta_timer = time.Timer.start(io),
        .player_sprite_timer = time.Timer.start(io),
        .rand = std.Random.DefaultPrng.init(1337),
        .parsed_atlas = parsed_atlas,
        .parsed_ldtk_compatibility = try pixi.LDTKCompatibility.parseSlice(ctx, assets.pixi_ldtk_json),
        // Preload .ldtk level file
        .parsed_level = try ldtk.File.parseSlice(ctx, assets.level_ldtk),
        .sfx_morning_bells = try mach.Audio.Opus.decodeStream(allocator, .{ .data = assets.sfx.morning_bells }),
        .sfx_footsteps = try mach.Audio.Opus.decodeStream(allocator, .{ .data = assets.sfx.footsteps }),
        .sfx_freeze = try mach.Audio.Opus.decodeStream(allocator, .{ .data = assets.sfx.freeze }),
        .sfx_grimble = try mach.Audio.Opus.decodeStream(allocator, .{ .data = assets.sfx.grimble }),
    };

    // Start the app thread last, once app state is fully initialized.
    app.app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app);
}

/// Stops the app thread. Runs first on exit, so the remaining deinit steps don't race with it.
pub fn deinitApp(app: *App, ctx: mach.Context) void {
    app.app_thread.join();

    // Log memory pool usage, to help size the budgets in main.zig.
    ctx.reportMemory();
}

pub fn deinit2(
    app: *App,
    audio: *mach.Audio,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
) void {
    // Clean up whatever scene is currently active
    clearCurrentScene(app, audio, sprite, text);

    app.allocator.free(app.sfx_morning_bells.samples);
    app.allocator.free(app.sfx_footsteps.samples);
    app.allocator.free(app.sfx_freeze.samples);
    app.allocator.free(app.sfx_grimble.samples);

    app.parsed_atlas.deinit();
    app.parsed_level.deinit();
    app.parsed_ldtk_compatibility.deinit();
    if (app.gpu_ready.load(.acquire)) {
        const g = app.gpu_res;
        g.rtt_view.release();
        g.rtt_texture.release();
        g.effect_bind_group.release();
        g.effect_bind_group_layout.release();
        g.effect_uniforms.release();
    }
}

/// Creates GPU resources. Called once on the render thread, since that is where all GPU work
/// happens. The app thread picks these up in setupPipelines once `gpu_ready` is set.
fn setupGpu(app: *App, window: anytype) !void {
    const zone = mach.tracy.initZone(@src(), .{});
    defer zone.deinit();
    // Create the texture we'll render our scene to for post-processing effects.
    // Sized to the window's framebuffer (actual pixel dimensions including DPI scaling).
    // Recreated on window resize in renderFrame.
    const rtt_texture = createRttTexture(window.device, window.framebuffer_width, window.framebuffer_height);

    // Effect parameters for our custom sprite shaders, bound at @group(1) of their pipelines
    // (gfx.Sprite owns @group(0)).
    const device: *gpu.Device = window.device;
    const effect_uniforms = device.createBuffer(&.{
        .label = "effect uniforms",
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = @sizeOf(EffectUniforms),
        .mapped_at_creation = .false,
    });
    const effect_bind_group_layout = device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .label = "effect",
        .entries = &.{
            gpu.BindGroupLayout.Entry.initBuffer(0, .{ .fragment = true }, .uniform, false, 0),
        },
    }));
    const effect_bind_group = device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
        .label = "effect",
        .layout = effect_bind_group_layout,
        .entries = &.{
            gpu.BindGroup.Entry.initBuffer(0, effect_uniforms, 0, @sizeOf(EffectUniforms), @sizeOf(EffectUniforms)),
        },
    }));

    app.gpu_res = .{
        .atlas_texture = try loadTexture(window.device, window.queue, app.allocator, assets.lordofzero_png),
        .pass1_shader = device.createShaderModuleWGSL("pass1.wgsl", @embedFile("pass1.wgsl")),
        .clouds_shader = device.createShaderModuleWGSL("clouds.wgsl", @embedFile("clouds.wgsl")),
        .effect_uniforms = effect_uniforms,
        .effect_bind_group_layout = effect_bind_group_layout,
        .effect_bind_group = effect_bind_group,
        .rtt_texture = rtt_texture,
        .rtt_view = rtt_texture.createView(null),
        .rtt_width = window.framebuffer_width,
        .rtt_height = window.framebuffer_height,
    };
    app.gpu_ready.store(true, .release);
}

fn createRttTexture(device: *gpu.Device, width: u32, height: u32) *gpu.Texture {
    return device.createTexture(&gpu.Texture.Descriptor.init(.{
        .size = .{ .width = width, .height = height },
        .format = .bgra8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true, .render_attachment = true },
    }));
}

/// Creates the render pipelines and loads the initial scene. Called on the app thread once the
/// render thread has created our GPU resources.
fn setupPipelines(
    app: *App,
    app_mod: mach.Mod(App),
    sprite: *gfx.Sprite,
    text: *gfx.Text,
) !void {
    const zone = mach.tracy.initZone(@src(), .{});
    defer zone.deinit();
    const g = app.gpu_res;

    // Create a sprite rendering pipeline. Created first so it renders before (beneath) the
    // cloud pipeline whenever both are active in the same render pass.
    app.sprite_pipeline_id = try sprite.pipelines.new(.{
        .window = app.window_id,
        .texture = g.atlas_texture,
    });

    // Create the cloud/fog pipeline (rendered in the RTT pass on top of sprites, using the
    // clouds.wgsl shader). Time is passed to the shader via the @group(1) effect bind group.
    app.cloud_pipeline_id = try sprite.pipelines.new(.{
        .window = app.window_id,
        .texture = g.atlas_texture,
        .shader = g.clouds_shader,
        .user_bind_group_layout = g.effect_bind_group_layout,
        .user_bind_group = g.effect_bind_group,
        // Alpha blend must preserve destination alpha so that cloud edges don't corrupt
        // the RTT texture's alpha channel (which would cause semi-transparency when the
        // RTT sprite renders to screen).
        .blend_state = gpu.BlendState{
            .color = .{
                .operation = .add,
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
            },
            .alpha = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
            },
        },
    });

    // Create the render-to-texture pipeline with the pass1.wgsl shader (water reflections),
    // drawing the scene texture as a single fullscreen sprite.
    app.rtt_pipeline_id = try sprite.pipelines.new(.{
        .window = app.window_id,
        .texture = g.rtt_texture,
        .blend_state = gpu.BlendState{},
        .shader = g.pass1_shader,
        .user_bind_group_layout = g.effect_bind_group_layout,
        .user_bind_group = g.effect_bind_group,
    });
    app.rtt_sprite_id = try sprite.objects.new(.{
        .transform = Mat4x4.translate(vec3(0, 0, 0)),
        .uv_transform = Mat3x3.translate(vec2(0, 0)),
        .size = vec2(@floatFromInt(g.rtt_width), @floatFromInt(g.rtt_height)),
    });
    try addToRenderList(sprite, app.allocator, app.rtt_pipeline_id, app.rtt_sprite_id);
    app.rtt_size = vec2(@floatFromInt(g.rtt_width), @floatFromInt(g.rtt_height));

    // Create a text rendering pipeline
    app.text_pipeline_id = try text.pipelines.new(.{
        .window = app.window_id,
    });

    app.ready = true;

    // Load the initial starting screen scene (must be after pipelines are created
    // since changeScene registers objects with them)
    app_mod.call(.changeScene);
}

/// Registers an object with a gfx.Sprite or gfx.Text pipeline's render list.
fn addToRenderList(module: anytype, allocator: std.mem.Allocator, pipeline_id: mach.ObjectID, object_id: mach.ObjectID) !void {
    var render_list = module.pipelines.get(pipeline_id, .render_list);
    try render_list.append(allocator, object_id);
    module.pipelines.set(pipeline_id, .render_list, render_list);
}

/// Plays a decoded sound effect, by copying its samples into a new mach.Audio buffer (which
/// mach.Audio.cleanup frees once the buffer is deleted.)
fn playSfx(app: *App, audio: *mach.Audio, sfx: mach.Audio.Opus, volume: f32, scene_tag: ?Scene) !void {
    const zone = mach.tracy.initZone(@src(), .{});
    defer zone.deinit();
    const samples = try audio.allocSamples(sfx.samples.len);
    @memcpy(samples, sfx.samples);

    audio.buffers.lock();
    defer audio.buffers.unlock();
    const sfx_entity = try audio.buffers.new(.{
        .samples = samples,
        .channels = sfx.channels,
        .playing = true,
        .volume = volume,
    });
    try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);
    if (scene_tag) |scene| try setSceneTag(audio, sfx_entity, scene);
    _ = app;
}

/// Decodes and plays looping background music for the given scene.
fn playBgm(audio: *mach.Audio, opus_data: []const u8, scene: Scene) !void {
    const zone = mach.tracy.initZone(@src(), .{});
    defer zone.deinit();
    // Decode using the audio allocator, since mach.Audio.cleanup frees the samples.
    const bgm = try mach.Audio.Opus.decodeStream(audio.allocator, .{ .data = opus_data });

    audio.buffers.lock();
    defer audio.buffers.unlock();
    const bgm_entity = try audio.buffers.new(.{
        .samples = bgm.samples,
        .channels = bgm.channels,
        .playing = true,
    });
    try setSceneTag(audio, bgm_entity, scene);
    try audio.buffers.setTag(bgm_entity, App, .is_bgm, null);
}

fn setSceneTag(audio: *mach.Audio, buffer_id: mach.ObjectID, scene: Scene) !void {
    switch (scene) {
        .none => {},
        .start => try audio.buffers.setTag(buffer_id, App, .is_start_scene, null),
        .game => try audio.buffers.setTag(buffer_id, App, .is_game_scene, null),
    }
}

/// Frees app sprites that were deleted (either directly, or by cascade when their parent
/// gfx.Sprite was deleted.)
pub fn cleanupSprites(app: *App) void {
    var deleted = app.sprites.sliceDeleted();
    while (deleted.next()) |id| app.sprites.free(id);
}

/// Copies the app state the render thread needs. Runs while the app thread holds the render
/// snapshot lock, so the render thread is not reading render_state concurrently.
pub fn snapshot(app: *App) void {
    if (!app.ready) return;
    app.render_state = .{
        .ready = true,
        .scene = app.scene,
        .sprite_pipeline_id = app.sprite_pipeline_id,
        .text_pipeline_id = app.text_pipeline_id,
        .rtt_pipeline_id = app.rtt_pipeline_id,
        .cloud_pipeline_id = app.cloud_pipeline_id,
        .world_time = app.world_time,
    };
}

/// Called on the high-priority audio OS thread when the audio driver needs more audio samples, so
/// this callback should be fast to respond.
pub fn audioStateChange(audio: *mach.Audio) !void {
    audio.buffers.lock();
    defer audio.buffers.unlock();

    // Find audio objects that are no longer playing
    var buffers = audio.buffers.slice();
    while (buffers.next()) |buf_id| {
        if (audio.buffers.get(buf_id, .playing)) continue;

        if (audio.buffers.hasTag(buf_id, App, .is_bgm)) {
            // Repeat background music
            audio.buffers.set(buf_id, .index, 0);
            audio.buffers.set(buf_id, .playing, true);
        } else {
            // Remove the audio buffer that is no longer playing (mach.Audio.cleanup frees it.)
            audio.buffers.delete(buf_id);
        }
    }
}

/// Remove all entities (sprites, text, audio, app sprites) that belong to the current scene.
/// Resets app.scene to .none afterwards.
fn clearCurrentScene(
    app: *App,
    audio: *mach.Audio,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
) void {
    const zone = mach.tracy.initZone(@src(), .{});
    defer zone.deinit();
    switch (app.scene) {
        .none => {},
        .start => {
            // Remove start scene sprites (including cloud sprites)
            var sprite_iter = sprite.objects.slice();
            while (sprite_iter.next()) |id| {
                if (sprite.objects.hasTag(id, App, .is_start_scene)) {
                    sprite.objects.delete(id);
                }
            }
            // Remove start scene text
            var text_iter = text.objects.slice();
            while (text_iter.next()) |id| {
                if (text.objects.hasTag(id, App, .is_start_scene)) {
                    text.objects.delete(id);
                }
            }
            // Remove start scene audio buffers
            {
                audio.buffers.lock();
                defer audio.buffers.unlock();
                var buf_iter = audio.buffers.slice();
                while (buf_iter.next()) |id| {
                    if (audio.buffers.hasTag(id, App, .is_start_scene)) audio.buffers.delete(id);
                }
            }
            // Remove start scene app sprites
            var app_sprite_iter = app.sprites.slice();
            while (app_sprite_iter.next()) |id| {
                if (app.sprites.hasTag(id, App, .is_start_scene)) {
                    app.sprites.delete(id);
                }
            }
        },
        .game => {
            // Remove game scene sprites (including cloud sprites)
            var sprite_iter = sprite.objects.slice();
            while (sprite_iter.next()) |id| {
                if (sprite.objects.hasTag(id, App, .is_game_scene)) {
                    sprite.objects.delete(id);
                }
            }
            // Remove game scene audio buffers
            {
                audio.buffers.lock();
                defer audio.buffers.unlock();
                var buf_iter = audio.buffers.slice();
                while (buf_iter.next()) |id| {
                    if (audio.buffers.hasTag(id, App, .is_game_scene)) audio.buffers.delete(id);
                }
            }
            // Remove game scene app sprites
            var app_sprite_iter = app.sprites.slice();
            while (app_sprite_iter.next()) |id| {
                if (app.sprites.hasTag(id, App, .is_game_scene)) {
                    app.sprites.delete(id);
                }
            }
        },
    }
    app.scene = .none;
}

pub fn changeScene(
    app: *App,
    audio: *mach.Audio,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    ctx: mach.Context,
) !void {
    if (app.prev_scene == app.scene) return;
    ctx.info("changing scene: {s} -> {s}", .{ @tagName(app.prev_scene), @tagName(app.scene) });

    // Clean up the previously active scene
    const next_scene = app.scene;
    app.scene = app.prev_scene;
    clearCurrentScene(app, audio, sprite, text);
    app.scene = next_scene;
    app.prev_scene = app.scene;

    switch (app.scene) {
        .none => {},
        .start => {
            // Load our "prelude" background music
            try playBgm(audio, assets.bgm.prelude, .start);

            // Create text style
            const text_style_id = try text.styles.new(.{
                .font_size = 48.0,
                .color = vec4(1, 1, 1, 1.0),
                // .color = vec4(0.604, 0.584, 0.525, 1.0),
            });

            // Create the text object (its memory is managed by gfx.Text)
            const text_id = try text.createFmt(Mat4x4.translate(vec3(-100, -360, 0)), .{
                .{ text_style_id, "Press any key to start", .{} },
            });
            try addToRenderList(text, app.allocator, app.text_pipeline_id, text_id);
            try text.objects.setTag(text_id, App, .is_start_scene, null);

            // Create the "Lord of Zero" logo sprite
            {
                var z_layer: f32 = 0;
                const atlas = app.parsed_atlas.value;
                for (atlas.sprites) |sprite_info| {
                    if (!std.mem.startsWith(u8, sprite_info.name, "logo_0_")) continue;

                    const position = vec3(
                        0,
                        0,
                        z_layer,
                    );
                    z_layer += 1;

                    const logo_sprite = try sprite.objects.new(.{
                        .transform = undefined,
                        .size = undefined,
                        .uv_transform = undefined,
                    });
                    try addToRenderList(sprite, app.allocator, app.sprite_pipeline_id, logo_sprite);
                    try sprite.objects.setTag(logo_sprite, App, .is_logo, null);
                    const app_sprite = try app.sprites.new(.{ .name = sprite_info.name });
                    try app.sprites.setParent(app_sprite, logo_sprite);
                    try app.sprites.setTag(app_sprite, App, .is_start_scene, null);
                    try SpriteCalc.apply(sprite, logo_sprite, .{
                        .sprite_info = sprite_info,
                        .pos = position,
                        .scale = Vec3.splat(start_scale),
                        .flipped = false,
                    });
                    try sprite.objects.setTag(logo_sprite, App, .is_start_scene, null);
                }
            }

            // Create cloud/fog sprite for the start scene
            {
                const clouds = try sprite.objects.new(.{
                    .transform = Mat4x4.translate(vec3(-1920 / 2, -1080 / 2, 0)),
                    .uv_transform = Mat3x3.translate(vec2(0, 0)),
                    .size = vec2(1920, 1080),
                });
                try addToRenderList(sprite, app.allocator, app.cloud_pipeline_id, clouds);
                try sprite.objects.setTag(clouds, App, .is_start_scene, null);
            }
        },
        .game => {
            // Load our "Night Falls" background music
            try playBgm(audio, assets.bgm.night_falls, .game);

            // Find the LDTK level "Level_0"
            const level = blk: {
                for (app.parsed_level.value.worlds[0].levels) |level| {
                    if (std.mem.eql(u8, level.identifier, "Level_0")) break :blk level;
                }
                @panic("could not find level");
            };

            // Create the "Wrench" player sprite
            app.player_position = blk: {
                var z_layer: f32 = 0;
                for (level.layerInstances.?) |layer| {
                    for (layer.entityInstances) |layer_entity| {
                        for (layer_entity.__tags) |tag| {
                            if (!std.mem.eql(u8, tag, "player_start")) continue;

                            // TODO: account for optional layer offsets, if they exist
                            const entity_pos_x: f32 = @floatFromInt(layer_entity.px[0]);
                            const entity_pos_y: f32 = @floatFromInt(layer_entity.px[1]);
                            const entity_width: f32 = @floatFromInt(layer_entity.width);
                            const entity_height: f32 = @floatFromInt(layer_entity.height);
                            break :blk vec3(
                                (entity_pos_x + (entity_width / 2.0)) * world_scale,
                                -((entity_pos_y) + entity_height) * world_scale,
                                z_layer,
                            );
                        }
                    }
                    z_layer += 10000;
                }
                @panic("could not find entity in level tagged 'player_start'");
            };
            const atlas: pixi.Atlas = app.parsed_atlas.value;
            const pixi_ldtk: pixi.LDTKCompatibility = app.parsed_ldtk_compatibility.value;
            for (atlas.sprites) |sprite_info| {
                if (!std.mem.startsWith(u8, sprite_info.name, "wrench_idle")) continue;

                app.player_id = try sprite.objects.new(.{
                    .transform = undefined,
                    .size = undefined,
                    .uv_transform = undefined,
                });
                try addToRenderList(sprite, app.allocator, app.sprite_pipeline_id, app.player_id);
                try SpriteCalc.apply(sprite, app.player_id, .{
                    .sprite_info = sprite_info,
                    .pos = app.player_position,
                    .scale = Vec3.splat(world_scale),
                    .flipped = false,
                });
                try sprite.objects.setTag(app.player_id, App, .is_game_scene, null);
                break;
            }

            ctx.info("loading level: {s} {}x{}px, layers: {}", .{ level.identifier, level.pxWid, level.pxHei, level.layerInstances.?.len });
            const level_zone = mach.tracy.initZone(@src(), .{ .name = "load level" });
            defer level_zone.deinit();
            var z_layer: f32 = 0.0;
            for (level.layerInstances.?) |layer| {
                ctx.debug("layer: {s}, type={s}, visible={}, grid_size={}px, {}x{} (grid-based size)", .{
                    layer.__identifier,
                    @tagName(layer.__type),
                    layer.visible,
                    layer.__gridSize,
                    layer.__cWid,
                    layer.__cHei,
                });
                ctx.debug("layer: {s}, pxTotalOffset={},{}, entities={}, grid_tiles={}, tileset={?s}", .{
                    layer.__identifier,
                    layer.__pxTotalOffsetX,
                    layer.__pxTotalOffsetY,
                    layer.entityInstances.len,
                    layer.gridTiles.len,
                    layer.__tilesetRelPath,
                });
                if (!layer.visible) continue;
                if (layer.__pxTotalOffsetX != 0 or layer.__pxTotalOffsetY != 0) {
                    @panic("layer offsets not supported yet");
                }

                const parallax: ?[2]f32 = blk: {
                    for (app.parsed_level.value.defs.layers) |layer_def| {
                        if (layer_def.uid == layer.layerDefUid) {
                            if (layer_def.parallaxFactorX == 0 and layer_def.parallaxFactorY == 0) break :blk null;
                            if (layer_def.parallaxScaling) std.debug.panic("parallax /scaling/ is not supported, found enabled on layer: {s}", .{layer.__identifier});
                            break :blk .{ layer_def.parallaxFactorX, layer_def.parallaxFactorY };
                        }
                    }
                    break :blk null;
                };

                // Create a cloud/fog sprite for parallax layers (a world-space quad covering the
                // entire layer area)
                if (parallax != null) {
                    const layer_width: f32 = @floatFromInt(layer.__gridSize * layer.__cWid);
                    const layer_height: f32 = @floatFromInt(layer.__gridSize * layer.__cHei);

                    const clouds = try sprite.objects.new(.{
                        .transform = Mat4x4.translate(vec3(0, -layer_height * world_scale, 0)),
                        .uv_transform = Mat3x3.translate(vec2(0, 0)),
                        .size = vec2(layer_width * world_scale, layer_height * world_scale),
                    });
                    try addToRenderList(sprite, app.allocator, app.cloud_pipeline_id, clouds);
                    try sprite.objects.setTag(clouds, App, .is_game_scene, null);
                }

                building_tiles: for (layer.gridTiles) |tile| {
                    // Find the pixi sprite corresponding to this tile
                    if (pixi_ldtk.findSpriteByLayerSrc(layer.__tilesetRelPath.?, tile.src)) |ldtk_sprite| {
                        if (atlas.findSpriteIndex(ldtk_sprite.name)) |sprite_index| {
                            const pos = vec3(
                                @as(f32, @floatFromInt(tile.px[0])) * world_scale,
                                -@as(f32, @floatFromInt(tile.px[1])) * world_scale,
                                z_layer,
                            );
                            z_layer -= 1;

                            const anim_info = animationBySpriteIndex(atlas, sprite_index);
                            const anim_frame = if (anim_info) |anim| app.rand.random().uintLessThan(usize, @min(2, anim.length)) else 0;
                            const sprite_info = if (anim_info) |anim| atlas.sprites[(anim.start + anim_frame)] else atlas.sprites[sprite_index];

                            const tile_sprite = try sprite.objects.new(.{
                                .transform = undefined,
                                .size = undefined,
                                .uv_transform = undefined,
                            });
                            try addToRenderList(sprite, app.allocator, app.sprite_pipeline_id, tile_sprite);
                            try SpriteCalc.apply(sprite, tile_sprite, .{
                                .sprite_info = sprite_info,
                                .pos = pos,
                                .scale = Vec3.splat(world_scale),
                                .flipped = false,
                            });
                            try sprite.objects.setTag(tile_sprite, App, .is_game_scene, null);

                            const app_sprite = try app.sprites.new(.{
                                .name = sprite_info.name,
                                .position = pos,
                            });
                            try app.sprites.setParent(app_sprite, tile_sprite);
                            try app.sprites.setTag(app_sprite, App, .is_game_scene, null);
                            if (anim_info) |anim| {
                                app.sprites.set(app_sprite, .sprite_anim, anim);
                                app.sprites.set(app_sprite, .sprite_timer, @as(f32, @floatFromInt(anim_frame)) / @as(f32, @floatFromInt(anim.fps)));
                            }
                            if (parallax) |p| app.sprites.set(app_sprite, .parallax, p);
                        }
                    } else {
                        // std.debug.panic("failed to find sprite for tile: {}\n", .{tile});
                    }
                    continue :building_tiles;
                }

                building_entities: for (layer.entityInstances) |entity_instance| {
                    const tile = entity_instance.__tile orelse continue :building_entities;

                    for (entity_instance.__tags) |tag| {
                        if (std.mem.eql(u8, tag, "player_start") or std.mem.eql(u8, tag, "peasant_start") or std.mem.eql(u8, tag, "hidden")) {
                            continue :building_entities;
                        }
                    }

                    const is_grimble = blk: {
                        for (entity_instance.__tags) |tag| {
                            if (std.mem.eql(u8, tag, "grimble")) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };

                    const tilesetRelPath = blk: {
                        for (app.parsed_level.value.defs.tilesets) |tileset_def| {
                            if (tileset_def.uid != tile.tilesetUid) continue;
                            break :blk tileset_def.relPath;
                        }
                        @panic("failed to find tileset for entity");
                    };

                    // Find the pixi sprite corresponding to the entity tile
                    const tile_src: [2]i64 = .{ tile.x, tile.y };
                    if (pixi_ldtk.findSpriteByLayerSrc(tilesetRelPath.?, tile_src)) |ldtk_sprite| {
                        if (atlas.findSpriteIndex(ldtk_sprite.name)) |sprite_index| {
                            const pos = vec3(
                                @as(f32, @floatFromInt(entity_instance.px[0])) * world_scale,
                                -@as(f32, @floatFromInt(entity_instance.px[1])) * world_scale,
                                z_layer,
                            );
                            z_layer -= 1;

                            const anim_info = animationBySpriteIndex(atlas, sprite_index);
                            const anim_frame = if (anim_info) |anim| app.rand.random().uintLessThan(
                                usize,
                                if (is_grimble)
                                    // Grimble animations are very out of sync with eachother
                                    anim.length
                                else
                                    // Other animations are only slightly out of sync with eachother
                                    @min(2, anim.length),
                            ) else 0;
                            const sprite_info = if (anim_info) |anim| atlas.sprites[(anim.start + anim_frame)] else atlas.sprites[sprite_index];

                            const entity_sprite = try sprite.objects.new(.{
                                .transform = undefined,
                                .size = undefined,
                                .uv_transform = undefined,
                            });
                            try addToRenderList(sprite, app.allocator, app.sprite_pipeline_id, entity_sprite);
                            try SpriteCalc.apply(sprite, entity_sprite, .{
                                .sprite_info = sprite_info,
                                .pos = pos,
                                .scale = Vec3.splat(world_scale),
                                .flipped = false,
                            });
                            try sprite.objects.setTag(entity_sprite, App, .is_game_scene, null);

                            const app_sprite = try app.sprites.new(.{
                                .name = sprite_info.name,
                                .position = pos,
                            });
                            try app.sprites.setParent(app_sprite, entity_sprite);
                            try app.sprites.setTag(app_sprite, App, .is_game_scene, null);
                            if (is_grimble) try app.sprites.setTag(app_sprite, App, .is_grimble, null);
                            if (anim_info) |anim| {
                                app.sprites.set(app_sprite, .sprite_anim, anim);
                                app.sprites.set(app_sprite, .sprite_timer, if (is_grimble)
                                    app.rand.random().float(f32) * 10.0
                                else
                                    @as(f32, @floatFromInt(anim_frame)) / @as(f32, @floatFromInt(anim.fps)));
                            }
                        }
                    } else {
                        std.debug.panic("failed to find sprite for entity tile: {}\n", .{tile});
                    }
                }

                z_layer += 10000;
            }
        },
    }
}

pub fn updateAnims(
    sprite: *gfx.Sprite,
    app: *App,
    audio: *mach.Audio,
) !void {
    if (!app.ready) return;
    const atlas = app.parsed_atlas.value;

    var sprites_iter = app.sprites.slice();
    while (sprites_iter.next()) |app_sprite_id| {
        const anim = app.sprites.get(app_sprite_id, .sprite_anim) orelse continue;
        const flip = app.sprites.get(app_sprite_id, .flipped);
        const position = app.sprites.get(app_sprite_id, .position);
        const anim_fps: f32 = @floatFromInt(anim.fps);

        var timer = app.sprites.get(app_sprite_id, .sprite_timer);
        timer += app.delta_time;

        var frame = @as(usize, @intFromFloat(timer * anim_fps));
        if (frame >= anim.length - 1) {
            frame = if (anim.length - 1 == 0) 0 else frame % (anim.length - 1);

            // Find the gfx.Sprite object this app sprite is parented to
            const gfx_sprite_id = (app.sprites.getParent(app_sprite_id) catch null) orelse continue;

            if (app.sprites.hasTag(app_sprite_id, App, .delete_after_anim)) {
                sprite.objects.delete(gfx_sprite_id);
                app.sprites.delete(app_sprite_id);
                continue;
            } else if (timer > 1.0 and app.sprites.hasTag(app_sprite_id, App, .is_grimble)) {
                timer -= 1.0;

                // Load our "grimble" sfx, with volume based on distance to player
                const player_pos = vec2(app.player_position.x(), 0);
                const sound_pos = vec2(position.x(), 0);
                const dist = player_pos.dist(&sound_pos);
                const spatial_volume = 0.2 * (1.0 - @min(@as(f32, 1.0), dist / 1500.0));

                try app.playSfx(audio, app.sfx_grimble, spatial_volume, .game);
            }
        }

        app.sprites.set(app_sprite_id, .sprite_timer, timer);

        // Update the gfx sprite with the current animation frame
        const gfx_sprite_id = (app.sprites.getParent(app_sprite_id) catch null) orelse continue;
        const sprite_info = atlas.sprites[anim.start + frame];
        try SpriteCalc.apply(sprite, gfx_sprite_id, .{
            .sprite_info = sprite_info,
            .pos = position,
            .scale = Vec3.splat(world_scale),
            .flipped = flip,
        });
    }
}

pub fn updateSfx(
    sprite: *gfx.Sprite,
    app: *App,
) !void {
    if (!app.ready) return;
    // Update grimble positions — grimbles face and move toward the player
    const atlas = app.parsed_atlas.value;
    var sprites_iter = app.sprites.slice();
    while (sprites_iter.next()) |app_sprite_id| {
        if (!app.sprites.hasTag(app_sprite_id, App, .is_grimble)) continue;

        // Grimble faces toward the player
        const flipped = app.player_position.x() < app.sprites.get(app_sprite_id, .position).x();
        app.sprites.set(app_sprite_id, .flipped, flipped);

        // Grimble moves toward the player
        const flip_float: f32 = if (flipped) -1.0 else 1.0;
        const position = app.sprites.get(app_sprite_id, .position).add(
            &vec3(flip_float * 250.0 * app.delta_time, 0, 0),
        );
        app.sprites.set(app_sprite_id, .position, position);

        // Update the gfx sprite with the new position and flip
        const gfx_sprite_id = (app.sprites.getParent(app_sprite_id) catch null) orelse continue;
        const name = app.sprites.get(app_sprite_id, .name);
        const sprite_info = blk: {
            for (atlas.sprites) |s| if (std.mem.eql(u8, s.name, name)) break :blk s;
            continue;
        };
        try SpriteCalc.apply(sprite, gfx_sprite_id, .{
            .sprite_info = sprite_info,
            .pos = position,
            .scale = Vec3.splat(world_scale),
            .flipped = flipped,
        });
    }
}

pub fn pollInput(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    sprite: *gfx.Sprite,
    audio: *mach.Audio,
    text: *gfx.Text,
    overlay: *dvx.DevOverlay,
) !void {
    var direction = app.direction;
    var player_wants_to_attack = app.player_wants_to_attack;
    var player_wants_to_run = app.player_wants_to_run;
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                // The dev overlay's toggle chord must not e.g. start the game.
                if (overlay.handleKey(ev)) continue;
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => player_wants_to_attack = true,
                    .left_shift => player_wants_to_run = true,
                    else => {},
                }
                if (app.ready and app.scene == .start and app.pending_scene == null) {
                    // Play our "Morning bells" sfx
                    try app.playSfx(audio, app.sfx_morning_bells, 1.0, null);

                    // Schedule scene change after the sfx finishes playing
                    app.pending_scene = .game;
                    app.pending_scene_timer = time.Timer.start(app.io);
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] += 1,
                    .right => direction.v[0] -= 1,
                    .up => direction.v[1] -= 1,
                    .down => direction.v[1] += 1,
                    .space => player_wants_to_attack = false,
                    .left_shift => player_wants_to_run = false,
                    else => {},
                }
            },
            .close => core.exit(),
            else => {},
        }
    }

    // Once the render thread has created our GPU resources, create our pipelines and scene.
    if (!app.ready and app.gpu_ready.load(.acquire)) {
        try setupPipelines(app, app_mod, sprite, text);
    }
    app.last_direction = app.direction;
    app.direction = direction;
    app.player_wants_to_attack = player_wants_to_attack;
    app.player_wants_to_run = player_wants_to_run;

    const dt = app.delta_timer.lap();
    app.delta_time = dt;
    app.world_time += dt;
    mach.tracy.plot(f32, "app tick ms", dt * 1000);
}

pub fn updateScene(
    app: *App,
    app_mod: mach.Mod(App),
    overlay: *dvx.DevOverlay,
) !void {
    if (!app.ready) return;
    if (overlay.visible) {
        var app_sprites: usize = 0;
        var it = app.sprites.slice();
        while (it.next()) |_| app_sprites += 1;
        overlay.setAppInfo("scene: {s}   player x={d:.0}   app sprites: {d}", .{
            @tagName(app.scene), app.player_position.x(), app_sprites,
        });
    }
    // Check if a pending scene change is ready (e.g. waiting for sfx to finish)
    if (app.pending_scene) |next_scene| {
        if (app.pending_scene_timer.read() >= 2.0) {
            app.scene = next_scene;
            app.pending_scene = null;
            app_mod.call(.changeScene);
        }
    }

    switch (app.scene) {
        .none => {},
        .start => app_mod.call(.updateSceneStart),
        .game => app_mod.call(.updateSceneGame),
    }
}

pub fn updateSceneStart(
    app: *App,
    sprite: *gfx.Sprite,
) !void {
    // Make the logo sprites (there are multiple, one for each 'sprite layer' in pixi) bounce up and down slowly
    const atlas = app.parsed_atlas.value;
    for (sprite.pipelines.get(app.sprite_pipeline_id, .render_list).items) |sprite_id| {
        if (!sprite.objects.is(sprite_id) or sprite.objects.isDeleted(sprite_id)) continue;
        if (!sprite.objects.hasTag(sprite_id, App, .is_logo)) continue;
        const sprite_info = pixiSpriteInfo(app, atlas, sprite_id) orelse continue;

        const pos = vec3(
            0,
            (10 * math.sin((app.world_time / 8.0) * 2 * std.math.pi)),
            sprite.objects.get(sprite_id, .transform).translation().z(),
        );
        const calc = SpriteCalc.init(.{
            .sprite_info = sprite_info,
            .pos = pos,
            .scale = Vec3.splat(start_scale),
            .flipped = false,
        });
        sprite.objects.set(sprite_id, .transform, calc.transform);
    }
}

pub fn updateSceneGame(
    app: *App,
    sprite: *gfx.Sprite,
    audio: *mach.Audio,
) !void {
    const can_attack = app.attack_cooldown_timer.read() > app.attack_cooldown;
    const begin_moving = !app.is_attacking and app.last_direction.eql(&vec2(0, 0)) and !app.direction.eql(&vec2(0, 0));
    const begin_attack = !app.is_attacking and can_attack and app.player_wants_to_attack;

    if (begin_attack) {
        app.attack_cooldown_timer.reset();
        app.is_attacking = true;
    }
    if (begin_moving or begin_attack) {
        app.player_sprite_timer.reset();
        app.player_anim_frame = -1;
    }

    const animation_name = if (app.is_attacking)
        "wrench_attack_main"
    else if (app.direction.eql(&vec2(0, 0)))
        "wrench_upgrade_main"
    else
        "wrench_walk_main";

    // Render the next animation frame for Wrench
    const atlas = app.parsed_atlas.value;
    const animation_info = animationByName(atlas, animation_name).?;

    var end_attack: bool = false;

    // Determine the next player animation frame
    var animation_fps: f32 = @floatFromInt(animation_info.fps);
    if (app.player_wants_to_run) animation_fps *= 2;
    var i: usize = @intFromFloat(app.player_sprite_timer.read() * animation_fps);
    if (i >= animation_info.length) {
        app.player_sprite_timer.reset();
        i = 0;

        if (app.is_attacking) {
            app.is_attacking = false;
            end_attack = true;
        }
    }

    // Player moves in the direction of the keyboard input
    const dir = if (app.is_attacking) app.direction.mulScalar(0.5) else app.direction;
    if (!dir.eql(&vec2(0, 0))) {
        app.last_facing_direction = dir;
    }
    const base_speed = 250.0;
    const speed: f32 = if (app.player_wants_to_run) base_speed * 10.0 else base_speed;
    const pos = app.player_position.add(
        &vec3(dir.v[0], 0, 0).mulScalar(speed).mulScalar(app.delta_time),
    );
    app.player_position = pos;

    // If the player is moving left instead of right, then flip the sprite so it renders
    // facing the left instead of its natural right-facing direction.
    const flipped: bool = app.last_facing_direction.v[0] < 0;
    try SpriteCalc.apply(sprite, app.player_id, .{
        .sprite_info = atlas.sprites[animation_info.start + i],
        .pos = pos,
        .scale = Vec3.splat(world_scale),
        .flipped = flipped,
    });

    if (end_attack) {
        const anim_info = animationByName(atlas, "ground_attack_main").?;

        const z_layer: f32 = 0;
        const position: Vec3 = vec3(
            if (app.last_facing_direction.v[0] >= 0) pos.v[0] - (48.0 * world_scale) else pos.v[0] + (48.0 * world_scale),
            pos.v[1] + (256.0 * world_scale),
            z_layer,
        );

        const sprite_info = atlas.sprites[anim_info.start];
        const attack_fx = try sprite.objects.new(.{
            .transform = undefined,
            .size = undefined,
            .uv_transform = undefined,
        });
        try addToRenderList(sprite, app.allocator, app.sprite_pipeline_id, attack_fx);
        try SpriteCalc.apply(sprite, attack_fx, .{
            .sprite_info = sprite_info,
            .pos = position,
            .scale = Vec3.splat(world_scale),
            .flipped = flipped,
        });
        try sprite.objects.setTag(attack_fx, App, .is_game_scene, null);

        const app_sprite = try app.sprites.new(.{
            .name = sprite_info.name,
            .sprite_anim = animationByName(atlas, "ground_attack_main"),
            .sprite_timer = 0,
            .flipped = flipped,
            .position = position,
        });
        try app.sprites.setParent(app_sprite, attack_fx);
        try app.sprites.setTag(app_sprite, App, .delete_after_anim, null);
    }

    if (i != app.player_anim_frame) {
        // Player animation frame has changed
        app.player_anim_frame = @intCast(i);

        // If walking, play footstep sfx every 2nd frame
        if (!app.is_attacking and !dir.eql(&vec2(0, 0)) and
            ((app.player_wants_to_run and i % 1 == 0) or (!app.player_wants_to_run and i % 2 == 0)))
        {
            // Play our "footsteps" sfx
            try app.playSfx(audio, app.sfx_footsteps, 3.3, .game);
        }

        // If attacking, play attack noise on first frame
        if (app.is_attacking and i == 0) {
            // Play our "freeze" sfx
            try app.playSfx(audio, app.sfx_freeze, 0.6, .game);
        }
    }
}

pub fn updateCamera(
    core: *mach.Core,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    app: *App,
) !void {
    if (!app.ready) return;

    // Our aim will be for our virtual canvas to be two thirds 1920x1080px. For our game, we do not
    // want the player to see more or less horizontally, as that may give an unfair advantage, but
    // they can see more or less vertically as that will only be more clouds or ground texture. As
    // such, we make the width fixed and dynamically adjust the height of our virtual canvas to be
    // whatever is needed to match the actual window aspect ratio without any stretching.
    const window_width_px: f32, const window_height_px: f32 = blk: {
        core.windows.lockShared();
        defer core.windows.unlockShared();
        break :blk .{
            @floatFromInt(core.windows.get(app.window_id, .width)),
            @floatFromInt(core.windows.get(app.window_id, .height)),
        };
    };
    const width_px: f32 = 1920.0 * (3.0 / 4.0);
    const height_px: f32 = width_px * (window_height_px / window_width_px);

    // If the render thread recreated the RTT texture (framebuffer resized), point the RTT pipeline
    // at the new texture. The pipeline holds its own reference to the old texture until it rebuilds.
    {
        app.pending_rtt_mu.lockUncancelable(app.io);
        defer app.pending_rtt_mu.unlock(app.io);
        if (app.pending_rtt) |rtt| {
            app.pending_rtt = null;
            app.rtt_size = vec2(@floatFromInt(rtt.width), @floatFromInt(rtt.height));
            sprite.pipelines.set(app.rtt_pipeline_id, .texture, rtt.texture);
            sprite.objects.set(app.rtt_sprite_id, .size, app.rtt_size);
            rtt.texture.release(); // our hand-off reference; the pipeline references it on rebuild
        }
    }
    const rtt_size = app.rtt_size;
    const projection = math.Mat4x4.projection2D(.{
        .left = -width_px / 2,
        .right = width_px / 2,
        .bottom = -height_px / 2,
        .top = height_px / 2,
        .near = -0.1,
        .far = 100000,
    });
    // Smooth camera following
    const map_left = 800;
    const map_right = 18950 * 3;
    const camera_target = switch (app.scene) {
        .none => vec3(0, 0, 0),
        .start => vec3(0, 0, 0),
        .game => vec3(
            math.clamp(app.player_position.x(), map_left, map_right),
            app.player_position.y() + (height_px / 4),
            0,
        ),
    };
    const camera_target_diff = camera_target.sub(&app.camera_position);
    const camera_lag_seconds = 0.5;
    app.camera_position = app.camera_position.add(&camera_target_diff.mulScalar(app.delta_time / camera_lag_seconds));

    const view = Mat4x4.translate(app.camera_position.mulScalar(-1));
    const view_projection = projection.mul(&view);
    sprite.pipelines.set(app.sprite_pipeline_id, .view_projection, view_projection);
    text.pipelines.set(app.text_pipeline_id, .view_projection, view_projection);

    // Cloud sprites use the same camera view_projection as regular sprites (they're in world space)
    sprite.pipelines.set(app.cloud_pipeline_id, .view_projection, view_projection);

    // The RTT sprite uses projection only (no camera view) since it's a fullscreen quad.
    // We scale the sprite from framebuffer pixels to virtual canvas pixels, and position it
    // to fill the screen (centered at origin).
    const scale_x = width_px / rtt_size.x();
    const scale_y = height_px / rtt_size.y();
    sprite.pipelines.set(app.rtt_pipeline_id, .view_projection, projection);
    sprite.objects.set(app.rtt_sprite_id, .transform, Mat4x4.translate(vec3(
        -width_px / 2,
        -height_px / 2,
        0,
    )).mul(&Mat4x4.scale(vec3(scale_x, scale_y, 1))));

    // Apply parallax offset to sprites on parallax layers — they scroll slower than the camera
    const parallax_zone = mach.tracy.initZone(@src(), .{ .name = "parallax" });
    defer parallax_zone.deinit();
    const atlas = app.parsed_atlas.value;
    var sprites_iter = app.sprites.slice();
    while (sprites_iter.next()) |app_sprite_id| {
        const p = app.sprites.get(app_sprite_id, .parallax) orelse continue;
        const position = app.sprites.get(app_sprite_id, .position);
        const flip = app.sprites.get(app_sprite_id, .flipped);
        const gfx_sprite_id = (app.sprites.getParent(app_sprite_id) catch null) orelse continue;
        const name = app.sprites.get(app_sprite_id, .name);
        const sprite_info = blk: {
            for (atlas.sprites) |s| if (std.mem.eql(u8, s.name, name)) break :blk s;
            continue;
        };
        const parallax_offset = app.camera_position.mul(&vec3(p[0], p[1], 1));
        try SpriteCalc.apply(sprite, gfx_sprite_id, .{
            .sprite_info = sprite_info,
            .pos = position.sub(&parallax_offset),
            .scale = Vec3.splat(world_scale),
            .flipped = flip,
        });
    }
}

/// Called on the render thread. Reads only the render snapshot (app.render_state and the
/// render-side copies of gfx objects), never live app state.
pub fn renderFrame(
    core: *mach.Core,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
    overlay: *dvx.DevOverlay,
    app: *App,
) !void {
    const label = @tagName(mach_module) ++ ".renderFrame";
    const window = core.windows.getValue(core.window);

    // GPU resources are created here on the render thread; the app thread then sets up pipelines.
    if (!app.gpu_ready.load(.acquire)) {
        try app.setupGpu(window);
        return;
    }
    const rs = app.render_state;
    if (!rs.ready) return;

    // Recreate the RTT texture if the framebuffer size changed, and hand it to the app thread
    // so it can update the RTT sprite pipeline.
    if (window.framebuffer_width != app.gpu_res.rtt_width or window.framebuffer_height != app.gpu_res.rtt_height) {
        app.gpu_res.rtt_view.release();
        app.gpu_res.rtt_texture.release();
        app.gpu_res.rtt_texture = createRttTexture(window.device, window.framebuffer_width, window.framebuffer_height);
        app.gpu_res.rtt_view = app.gpu_res.rtt_texture.createView(null);
        app.gpu_res.rtt_width = window.framebuffer_width;
        app.gpu_res.rtt_height = window.framebuffer_height;

        app.pending_rtt_mu.lockUncancelable(app.io);
        defer app.pending_rtt_mu.unlock(app.io);
        if (app.pending_rtt) |stale| stale.texture.release();
        app.gpu_res.rtt_texture.reference(); // hand-off reference, released by the app thread
        app.pending_rtt = .{
            .texture = app.gpu_res.rtt_texture,
            .width = app.gpu_res.rtt_width,
            .height = app.gpu_res.rtt_height,
        };
    }

    // Update per-frame effect parameters for the pass1 and clouds shaders.
    window.queue.writeBuffer(app.gpu_res.effect_uniforms, 0, &[_]EffectUniforms{.{
        .params = vec4(rs.world_time, 0, 0, 0).gpu(),
    }});

    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Grab the back buffer of the swapchain once per frame (can only be called once)
    // TODO(core): this wouldn't exist in browser
    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    // First render pass
    {
        const dark_gray = gpu.Color{ .r = 0.106, .g = 0.11, .b = 0.118, .a = 1 };
        const sky_blue = gpu.Color{ .r = 0.529, .g = 0.808, .b = 0.922, .a = 1 };
        _ = sky_blue;

        // Begin a render pass that will render our scene to a texture (rtt == render to texture)
        const rtt_color_attachments = [_]gpu.RenderPassColorAttachment{.{
            .view = app.gpu_res.rtt_view,
            .clear_value = switch (rs.scene) {
                .none => dark_gray,
                .start => dark_gray,
                .game => dark_gray,
            },
            .load_op = .clear,
            .store_op = .store,
        }};
        const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .label = label,
            .color_attachments = &rtt_color_attachments,
        }));

        // Render sprites, then cloud/fog sprites on top (in world space). The RTT pipeline must
        // not render here, since it samples the texture this pass renders into.
        sprite.pipelines.setRaw(rs.rtt_pipeline_id, .render_pass, null);
        sprite.pipelines.setRaw(rs.sprite_pipeline_id, .render_pass, render_pass);
        sprite.pipelines.setRaw(rs.cloud_pipeline_id, .render_pass, render_pass);
        sprite_mod.call(.render);

        // Finish render pass
        render_pass.end();
        render_pass.release();
    }

    // Second render pass
    {
        // Begin second render pass
        const color_attachments = [_]gpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .clear_value = std.mem.zeroes(gpu.Color),
            .load_op = .clear,
            .store_op = .store,
        }};

        const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
            .label = label,
            .color_attachments = &color_attachments,
        }));

        // Render the RTT sprite (post-processing: water reflections). Only the RTT pipeline
        // should render here.
        sprite.pipelines.setRaw(rs.sprite_pipeline_id, .render_pass, null);
        sprite.pipelines.setRaw(rs.cloud_pipeline_id, .render_pass, null);
        sprite.pipelines.setRaw(rs.rtt_pipeline_id, .render_pass, render_pass);
        sprite_mod.call(.render);

        // Render text on top of everything (so it's not affected by water reflections)
        text.pipelines.setRaw(rs.text_pipeline_id, .render_pass, render_pass);
        text_mod.call(.render);

        // Finish render pass
        render_pass.end();
        render_pass.release();
    }

    // Clear the transient render pass pointers, since the passes have been released.
    sprite.pipelines.setRaw(rs.rtt_pipeline_id, .render_pass, null);
    text.pipelines.setRaw(rs.text_pipeline_id, .render_pass, null);

    // Draw the dev overlay (if shown) on top of everything.
    overlay.render(core, encoder, back_buffer_view, sprite, sprite_mod, text, text_mod);

    // Finish the frame
    var command = encoder.finish(&.{ .label = label });
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();

    // Update the window title with the frame rate
    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(app.window_id, "Lord of Zero [ {d}fps ] [ Input {d}hz ]", .{
            core.frame.rate, core.input.rate,
        });
    }
}

// TODO(sprite): don't require users to copy / write this helper themselves
fn loadTexture(device: *gpu.Device, queue: *gpu.Queue, allocator: std.mem.Allocator, png_bytes: []const u8) !*gpu.Texture {
    const zone = mach.tracy.initZone(@src(), .{});
    defer zone.deinit();
    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, png_bytes);
    defer img.deinit(allocator);
    const img_size = gpu.Extent3D{ .width = @as(u32, @intCast(img.width)), .height = @as(u32, @intCast(img.height)) };

    // Create a GPU texture
    const label = @tagName(mach_module) ++ ".loadTexture";
    const texture = device.createTexture(&.{
        .label = label,
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
        },
    });
    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(img.width * 4)),
        .rows_per_image = @as(u32, @intCast(img.height)),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(allocator, pixels);
            defer data.deinit(allocator);
            queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }
    return texture;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}

fn pixiSpriteInfo(app: *App, atlas: pixi.Atlas, sprite_id: mach.ObjectID) ?pixi.Sprite {
    const app_sprite = (app.sprites.getFirstChildOfType(sprite_id) catch return null) orelse return null;
    const name = app.sprites.get(app_sprite, .name);
    for (atlas.sprites) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn animationByName(atlas: pixi.Atlas, anim_name: []const u8) ?pixi.Animation {
    for (atlas.animations) |anim| if (std.mem.eql(u8, anim.name, anim_name)) return anim;
    return null;
}

fn animationBySpriteIndex(atlas: pixi.Atlas, sprite_index: usize) ?pixi.Animation {
    for (atlas.animations) |anim| {
        if (sprite_index >= anim.start and sprite_index <= (anim.start + anim.length - 1)) return anim;
    }
    return null;
}

const SpriteCalc = struct {
    transform: Mat4x4,
    uv_transform: Mat3x3,
    size: Vec2,

    pub const Input = struct {
        sprite_info: pixi.Sprite,
        pos: Vec3,
        scale: Vec3,
        flipped: bool,
    };

    fn init(in: Input) SpriteCalc {
        const x: f32 = @floatFromInt(in.sprite_info.source[0]);
        const y: f32 = @floatFromInt(in.sprite_info.source[1]);
        const width: f32 = @floatFromInt(in.sprite_info.source[2]);
        const height: f32 = @floatFromInt(in.sprite_info.source[3]);
        const origin_x: f32 = @floatFromInt(in.sprite_info.origin[0]);
        const origin_y: f32 = @floatFromInt(in.sprite_info.origin[1]);

        const origin = Mat4x4.translate(vec3(
            if (!in.flipped) -origin_x else -width + origin_x,
            -height + origin_y,
            0,
        ));
        const scale = Mat4x4.scale(in.scale);
        const translate = Mat4x4.translate(in.pos);

        var uv_transform = Mat3x3.translate(vec2(x, y));
        if (in.flipped) {
            const uv_flip_horizontally = Mat3x3.scale(vec2(-1, 1));
            const uv_origin_shift = Mat3x3.translate(vec2(width, 0));
            const uv_translate = Mat3x3.translate(vec2(x, y));
            uv_transform = uv_origin_shift.mul(&uv_translate).mul(&uv_flip_horizontally);
        }

        return .{
            .transform = translate.mul(&scale).mul(&origin),
            .uv_transform = uv_transform,
            .size = vec2(width, height),
        };
    }

    fn apply(sprite: *gfx.Sprite, object_id: mach.ObjectID, in: Input) !void {
        const calc = SpriteCalc.init(in);
        sprite.objects.set(object_id, .transform, calc.transform);
        sprite.objects.set(object_id, .uv_transform, calc.uv_transform);
        sprite.objects.set(object_id, .size, calc.size);
    }
};
