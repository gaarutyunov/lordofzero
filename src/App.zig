const std = @import("std");
const zigimg = @import("zigimg");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;
const time = mach.time;
const assets = @import("assets");

const Card = @import("Card.zig");
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
    .render,
    .deinit,
    .deinit2,
    .audioStateChange,
    .pollInput,
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
    .{ gfx.Text, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ mach.Audio, .deinit },
    .{ App, .deinit2 },
});

pub const tick = mach.schedule(.{
    .{ App, .pollInput },
    .{ App, .updateScene },
    .{ App, .updateAnims },
    .{ App, .updateSfx },
    .{ App, .updateCamera },
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
spawn_timer: time.Timer,
fps_timer: time.Timer,
player_sprite_timer: time.Timer,
delta_time: f32 = 0,
player_anim_frame: isize = -1,
frame_count: usize = 0,
fps: usize = 0,
rand: std.Random.DefaultPrng,
world_time: f32 = 0,
scene: Scene = .start,
prev_scene: Scene = .none,
pending_scene: ?Scene = null,
pending_scene_timer: time.Timer = undefined,

// Initialized by setupPipeline
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
rtt_card_pipeline_id: mach.ObjectID = undefined,
rtt_card_id: mach.ObjectID = undefined,
cloud_card_pipeline_id: mach.ObjectID = undefined,
sprite_pipeline_id: mach.ObjectID = undefined,
text_pipeline_id: mach.ObjectID = undefined,
parsed_atlas: pixi.ParsedAtlas = undefined,
parsed_level: ldtk.ParsedFile = undefined,
parsed_ldtk_compatibility: pixi.ParsedLDTKCompatibility = undefined,
rtt_texture_view: *gpu.TextureView = undefined,
// TODO: textures don't store their width, so we have to store it ourselves here.
// Mach should expose texture width as an object field.
rtt_width: u32 = 0,
rtt_height: u32 = 0,

// Text resources that need to be freed
text_segments: ?[]gfx.Text.Segment = null,
text_content: ?[]u8 = null,

pub fn init(
    core: *mach.Core,
    audio: *mach.Audio,
    app: *App,
    app_mod: mach.Mod(App),
) !void {
    core.on_tick = app_mod.id.tick;
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

    // TODO(allocator): find a better way to get an allocator here
    const allocator = std.heap.c_allocator;

    app.* = .{
        .allocator = allocator,
        .window_id = window_id,
        .sprites = app.sprites,
        .attack_cooldown_timer = try time.Timer.start(),
        .delta_timer = try time.Timer.start(),
        .spawn_timer = try time.Timer.start(),
        .fps_timer = try time.Timer.start(),
        .player_sprite_timer = try time.Timer.start(),
        .rand = std.Random.DefaultPrng.init(1337),
    };
}

pub fn deinit2(
    app: *App,
    audio: *mach.Audio,
    sprite: *gfx.Sprite,
    card: *Card,
    text: *gfx.Text,
) void {
    // Clean up whatever scene is currently active
    clearCurrentScene(app, audio, sprite, card, text);

    app.parsed_atlas.deinit();
    app.parsed_level.deinit();
    app.rtt_texture_view.release();
}

fn setupPipeline(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    sprite: *gfx.Sprite,
    card: *Card,
    text: *gfx.Text,
    window_id: mach.ObjectID,
) !void {
    const window = core.windows.getValue(window_id);

    // Load pixi atlas file
    app.parsed_atlas = try pixi.Atlas.parseSlice(app.allocator, assets.lordofzero_atlas);
    std.debug.print("loaded sprite atlas: {} sprites, {} animations\n", .{
        app.parsed_atlas.value.sprites.len,
        app.parsed_atlas.value.animations.len,
    });

    app.parsed_ldtk_compatibility = try pixi.LDTKCompatibility.parseSlice(app.allocator, assets.pixi_ldtk_json);

    // Preload .ldtk level file
    app.parsed_level = try ldtk.File.parseSlice(app.allocator, assets.level_ldtk);

    // Create the texture we'll render our scene to for post-processing effects.
    // Sized to the window's framebuffer (actual pixel dimensions including DPI scaling).
    // Recreated on window resize in updateCamera.
    app.rtt_width = window.framebuffer_width;
    app.rtt_height = window.framebuffer_height;
    const rtt_texture = window.device.createTexture(&gpu.Texture.Descriptor.init(.{
        .size = .{ .width = app.rtt_width, .height = app.rtt_height },
        .format = .bgra8_unorm,
        .usage = .{ .texture_binding = true, .copy_dst = true, .render_attachment = true },
    }));
    app.rtt_texture_view = rtt_texture.createView(null);
    rtt_texture.release(); // view retains the texture

    // Create render-to-texture card with pass1.wgsl shader (water reflections + clouds/fog)
    app.rtt_card_pipeline_id = try card.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
        .texture_view = app.rtt_texture_view,
        .texture_view_size = vec2(@floatFromInt(app.rtt_width), @floatFromInt(app.rtt_height)),
        .blend_state = gpu.BlendState{},
        .shader = window.device.createShaderModuleWGSL("pass1.wgsl", @embedFile("pass1.wgsl")),
    });
    app.rtt_card_id = try card.objects.new(.{
        .transform = Mat4x4.translate(vec3(0, 0, 0)),
        .uv_transform = Mat3x3.translate(vec2(0, 0)),
        .size = vec2(@floatFromInt(app.rtt_width), @floatFromInt(app.rtt_height)),
    });
    try card.pipelines.setParent(app.rtt_card_id, app.rtt_card_pipeline_id);

    // Create cloud card pipeline (rendered in the RTT pass on top of sprites, using card.wgsl
    // clouds-only shader). The texture_view is the sprite atlas — not sampled by the shader, but
    // its dimensions (texture_view_size) determine the UV scale that the cloud function sees.
    const cloud_texture = try loadTexture(window.device, window.queue, app.allocator, assets.lordofzero_png);
    defer cloud_texture.release();
    app.cloud_card_pipeline_id = try card.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
        .texture_view = cloud_texture.createView(null),
        .texture_view_size = vec2(@floatFromInt(cloud_texture.getWidth()), @floatFromInt(cloud_texture.getHeight())),
        // Alpha blend must preserve destination alpha so that cloud edges don't corrupt
        // the RTT texture's alpha channel (which would cause semi-transparency when the
        // RTT card renders to screen).
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

    // Create a sprite rendering pipeline
    app.sprite_pipeline_id = try sprite.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
        .texture = try loadTexture(window.device, window.queue, app.allocator, assets.lordofzero_png),
    });

    // Create a text rendering pipeline
    app.text_pipeline_id = try text.pipelines.new(.{
        .window = window_id,
        .render_pass = undefined,
    });

    // Load the initial starting screen scene (must be after pipelines are created
    // since changeScene parents objects to them)
    app_mod.call(.changeScene);
}

/// Called on the high-priority audio OS thread when the audio driver needs more audio samples, so
/// this callback should be fast to respond.
pub fn audioStateChange(audio: *mach.Audio, app: *App) !void {
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
            // Remove the audio buffer that is no longer playing
            const samples = audio.buffers.get(buf_id, .samples);
            audio.buffers.delete(buf_id);
            app.allocator.free(samples);
        }
    }
}

/// Remove all entities (sprites, text, audio, app sprites) that belong to the current scene.
/// Resets app.scene to .none afterwards.
fn clearCurrentScene(
    app: *App,
    audio: *mach.Audio,
    sprite: *gfx.Sprite,
    card: *Card,
    text: *gfx.Text,
) void {
    switch (app.scene) {
        .none => {},
        .start => {
            // Remove start scene sprites
            var sprite_iter = sprite.objects.slice();
            while (sprite_iter.next()) |id| {
                if (sprite.objects.hasTag(id, App, .is_start_scene)) {
                    sprite.pipelines.removeChild(app.sprite_pipeline_id, id) catch {};
                    sprite.objects.delete(id);
                }
            }
            // Remove start scene text
            var text_iter = text.objects.slice();
            while (text_iter.next()) |id| {
                if (text.objects.hasTag(id, App, .is_start_scene)) {
                    text.pipelines.removeChild(app.text_pipeline_id, id) catch {};
                    text.objects.delete(id);
                }
            }
            // Free allocated text resources
            if (app.text_content) |content| {
                app.allocator.free(content);
                app.text_content = null;
            }
            if (app.text_segments) |segments| {
                app.allocator.free(segments);
                app.text_segments = null;
            }
            // Remove start scene card objects (cloud cards)
            var card_iter = card.objects.slice();
            while (card_iter.next()) |id| {
                if (card.objects.hasTag(id, App, .is_start_scene)) {
                    card.pipelines.removeChild(app.cloud_card_pipeline_id, id) catch {};
                    card.objects.delete(id);
                }
            }
            // Remove start scene audio buffers
            {
                audio.buffers.lock();
                defer audio.buffers.unlock();
                var buf_iter = audio.buffers.slice();
                while (buf_iter.next()) |id| {
                    if (audio.buffers.hasTag(id, App, .is_start_scene)) {
                        const samples = audio.buffers.get(id, .samples);
                        audio.buffers.delete(id);
                        app.allocator.free(samples);
                    }
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
            // Remove game scene sprites
            var sprite_iter = sprite.objects.slice();
            while (sprite_iter.next()) |id| {
                if (sprite.objects.hasTag(id, App, .is_game_scene)) {
                    sprite.pipelines.removeChild(app.sprite_pipeline_id, id) catch {};
                    sprite.objects.delete(id);
                }
            }
            // Remove game scene card objects (cloud cards)
            var card_iter = card.objects.slice();
            while (card_iter.next()) |id| {
                if (card.objects.hasTag(id, App, .is_game_scene)) {
                    card.pipelines.removeChild(app.cloud_card_pipeline_id, id) catch {};
                    card.objects.delete(id);
                }
            }
            // Remove game scene audio buffers
            {
                audio.buffers.lock();
                defer audio.buffers.unlock();
                var buf_iter = audio.buffers.slice();
                while (buf_iter.next()) |id| {
                    if (audio.buffers.hasTag(id, App, .is_game_scene)) {
                        const samples = audio.buffers.get(id, .samples);
                        audio.buffers.delete(id);
                        app.allocator.free(samples);
                    }
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
    card: *Card,
    text: *gfx.Text,
) !void {
    if (app.prev_scene == app.scene) return;

    // Clean up the previously active scene
    const next_scene = app.scene;
    app.scene = app.prev_scene;
    clearCurrentScene(app, audio, sprite, card, text);
    app.scene = next_scene;
    app.prev_scene = app.scene;

    switch (app.scene) {
        .none => {},
        .start => {
            // Load our "prelude" background music
            const bgm_fbs = std.io.fixedBufferStream(assets.bgm.prelude);
            const bgm_sound_stream = std.io.StreamSource{ .const_buffer = bgm_fbs };
            const bgm = try mach.Audio.Opus.decodeStream(app.allocator, bgm_sound_stream);

            // Create an audio entity to play our background music
            const bgm_entity = try audio.buffers.new(.{
                .samples = bgm.samples,
                .channels = bgm.channels,
                .playing = true,
            });
            try audio.buffers.setTag(bgm_entity, App, .is_start_scene, null);
            try audio.buffers.setTag(bgm_entity, App, .is_bgm, null);

            // Create text style
            const text_style_id = try text.styles.new(.{
                .font_size = 48.0,
                .color = vec4(1, 1, 1, 1.0),
                // .color = vec4(0.604, 0.584, 0.525, 1.0),
            });

            // Allocate the text segment in persistent memory
            app.text_content = try app.allocator.dupe(u8, "Press any key to start");
            app.text_segments = try app.allocator.alloc(gfx.Text.Segment, 1);
            app.text_segments.?[0] = .{
                .text = app.text_content.?,
                .style = text_style_id,
            };

            // Create the text object with allocated segments
            const text_id = try text.objects.new(.{
                .transform = Mat4x4.translate(vec3(-100, -360, 0)),
                .segments = app.text_segments.?,
            });
            try text.pipelines.setParent(text_id, app.text_pipeline_id);
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
                    try sprite.pipelines.setParent(logo_sprite, app.sprite_pipeline_id);
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

            // Create cloud/fog card for the start scene
            {
                const bg_card = try card.objects.new(.{
                    .transform = Mat4x4.translate(vec3(-1920 / 2, -1080 / 2, 0)),
                    .uv_transform = Mat3x3.translate(vec2(0, 0)),
                    .size = vec2(1920, 1080),
                });
                try card.pipelines.setParent(bg_card, app.cloud_card_pipeline_id);
                try card.objects.setTag(bg_card, App, .is_start_scene, null);
                // Explicitly mark a field as updated so Card.tick refreshes pipeline buffers
                card.objects.set(bg_card, .size, vec2(1920, 1080));
            }
        },
        .game => {
            // Load our "Morning Breaks" background music
            const bgm_fbs = std.io.fixedBufferStream(assets.bgm.night_falls);
            const bgm_sound_stream = std.io.StreamSource{ .const_buffer = bgm_fbs };
            const bgm = try mach.Audio.Opus.decodeStream(app.allocator, bgm_sound_stream);

            // Create an audio entity to play our background music
            const bgm_entity = try audio.buffers.new(.{
                .samples = bgm.samples,
                .channels = bgm.channels,
                .playing = true,
            });
            try audio.buffers.setTag(bgm_entity, App, .is_game_scene, null);
            try audio.buffers.setTag(bgm_entity, App, .is_bgm, null);

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
                try sprite.pipelines.setParent(app.player_id, app.sprite_pipeline_id);
                try SpriteCalc.apply(sprite, app.player_id, .{
                    .sprite_info = sprite_info,
                    .pos = app.player_position,
                    .scale = Vec3.splat(world_scale),
                    .flipped = false,
                });
                try sprite.objects.setTag(app.player_id, App, .is_game_scene, null);
                break;
            }

            std.debug.print("loading level: {s} {}x{}px, layers: {}\n", .{ level.identifier, level.pxWid, level.pxHei, level.layerInstances.?.len });
            var z_layer: f32 = 0.0;
            for (level.layerInstances.?) |layer| {
                std.debug.print(" layer: {s}, type={s}, visible={}, grid_size={}px, {}x{} (grid-based size)\n", .{
                    layer.__identifier,
                    @tagName(layer.__type),
                    layer.visible,
                    layer.__gridSize,
                    layer.__cWid,
                    layer.__cHei,
                });
                std.debug.print("        pxTotalOffset={},{}, entities={}, grid_tiles={}, tileset={?s}\n", .{
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

                // Create a cloud/fog card for parallax layers (matches old behavior where
                // cloud cards were world-space cards covering the entire layer area)
                if (parallax != null) {
                    const layer_width: f32 = @floatFromInt(layer.__gridSize * layer.__cWid);
                    const layer_height: f32 = @floatFromInt(layer.__gridSize * layer.__cHei);

                    const bg_card = try card.objects.new(.{
                        .transform = Mat4x4.translate(vec3(0, -layer_height * world_scale, 0)),
                        .uv_transform = Mat3x3.translate(vec2(0, 0)),
                        .size = vec2(layer_width * world_scale, layer_height * world_scale),
                    });
                    try card.pipelines.setParent(bg_card, app.cloud_card_pipeline_id);
                    try card.objects.setTag(bg_card, App, .is_game_scene, null);
                    // Explicitly mark a field as updated so Card.tick refreshes pipeline buffers
                    card.objects.set(bg_card, .size, vec2(layer_width * world_scale, layer_height * world_scale));
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
                            try sprite.pipelines.setParent(tile_sprite, app.sprite_pipeline_id);
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
                            try sprite.pipelines.setParent(entity_sprite, app.sprite_pipeline_id);
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
                try sprite.pipelines.removeChild(app.sprite_pipeline_id, gfx_sprite_id);
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

                const sfx_fbs = std.io.fixedBufferStream(assets.sfx.grimble);
                const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
                const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);
                const sfx_entity = try audio.buffers.new(.{
                    .samples = sfx.samples,
                    .channels = sfx.channels,
                    .playing = true,
                    .volume = spatial_volume,
                });
                try audio.buffers.setTag(sfx_entity, App, .is_game_scene, null);
                try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);
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
    card: *Card,
    text: *gfx.Text,
) !void {
    var direction = app.direction;
    var player_wants_to_attack = app.player_wants_to_attack;
    var player_wants_to_run = app.player_wants_to_run;
    while (core.nextEvent()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => player_wants_to_attack = true,
                    .left_shift => player_wants_to_run = true,
                    else => {},
                }
                if (app.scene == .start and app.pending_scene == null) {
                    // Load our "Morning bells" sfx
                    const sfx_fbs = std.io.fixedBufferStream(assets.sfx.morning_bells);
                    const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
                    const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

                    // Create an audio entity to play our sfx
                    const sfx_entity = try audio.buffers.new(.{
                        .samples = sfx.samples,
                        .channels = sfx.channels,
                        .playing = true,
                        .volume = 1.0,
                    });
                    try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);

                    // Schedule scene change after the sfx finishes playing
                    app.pending_scene = .game;
                    app.pending_scene_timer = try time.Timer.start();
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
            .window_open => |ev| try setupPipeline(core, app, app_mod, sprite, card, text, ev.window_id),
            .close => core.exit(),
            else => {},
        }
    }
    app.last_direction = app.direction;
    app.direction = direction;
    app.player_wants_to_attack = player_wants_to_attack;
    app.player_wants_to_run = player_wants_to_run;

    const dt = app.delta_timer.lap();
    app.delta_time = dt;
    app.world_time += dt;
}

pub fn updateScene(
    app: *App,
    app_mod: mach.Mod(App),
) !void {
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
    var pipeline_children = try sprite.pipelines.getChildren(app.sprite_pipeline_id);
    defer pipeline_children.deinit();
    for (pipeline_children.items) |sprite_id| {
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
        try sprite.pipelines.setParent(attack_fx, app.sprite_pipeline_id);
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
            // Load our "footsteps" sfx
            // TODO: load sound effects somewhere and store them, so that we don't decode on every footstep :)
            const sfx_fbs = std.io.fixedBufferStream(assets.sfx.footsteps);
            const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
            const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

            // Create an audio buffer to play our sfx
            const sfx_entity = try audio.buffers.new(.{
                .samples = sfx.samples,
                .channels = sfx.channels,
                .playing = true,
                .volume = 3.3,
            });
            try audio.buffers.setTag(sfx_entity, App, .is_game_scene, null);
            try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);
        }

        // If attacking, play attack noise on first frame
        if (app.is_attacking and i == 0) {
            // Load our "freeze" sfx
            // TODO: load sound effects somewhere and store them, so that we don't decode on every footstep :)
            const sfx_fbs = std.io.fixedBufferStream(assets.sfx.freeze);
            const sfx_sound_stream = std.io.StreamSource{ .const_buffer = sfx_fbs };
            const sfx = try mach.Audio.Opus.decodeStream(app.allocator, sfx_sound_stream);

            // Create an audio buffer to play our sfx
            const sfx_entity = try audio.buffers.new(.{
                .samples = sfx.samples,
                .channels = sfx.channels,
                .playing = true,
                .volume = 0.6,
            });
            try audio.buffers.setTag(sfx_entity, App, .is_game_scene, null);
            try audio.buffers.setTag(sfx_entity, App, .is_sfx, null);
        }
    }
}

pub fn updateCamera(
    core: *mach.Core,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    app: *App,
    card: *Card,
) !void {
    // Our aim will be for our virtual canvas to be two thirds 1920x1080px. For our game, we do not
    // want the player to see more or less horizontally, as that may give an unfair advantage, but
    // they can see more or less vertically as that will only be more clouds or ground texture. As
    // such, we make the width fixed and dynamically adjust the height of our virtual canvas to be
    // whatever is needed to match the actual window aspect ratio without any stretching.
    const window_width_px: f32 = @floatFromInt(core.windows.get(app.window_id, .width));
    const window_height_px: f32 = @floatFromInt(core.windows.get(app.window_id, .height));
    const width_px: f32 = 1920.0 * (3.0 / 4.0);
    const height_px: f32 = width_px * (window_height_px / window_width_px);

    // Recreate RTT texture if the framebuffer size changed.
    // Note: we do NOT release the old texture_view here — the card pipeline's rebuildPipeline
    // will release it via built.deinit() when it rebuilds with the new texture_view.
    const fb_width: u32 = core.windows.get(app.window_id, .framebuffer_width);
    const fb_height: u32 = core.windows.get(app.window_id, .framebuffer_height);
    if (fb_width != app.rtt_width or fb_height != app.rtt_height) {
        app.rtt_width = fb_width;
        app.rtt_height = fb_height;
        const device = core.windows.get(app.window_id, .device);
        const rtt_texture = device.createTexture(&gpu.Texture.Descriptor.init(.{
            .size = .{ .width = fb_width, .height = fb_height },
            .format = .bgra8_unorm,
            .usage = .{ .texture_binding = true, .copy_dst = true, .render_attachment = true },
        }));
        app.rtt_texture_view = rtt_texture.createView(null);
        rtt_texture.release(); // view retains the texture
        card.pipelines.set(app.rtt_card_pipeline_id, .texture_view, app.rtt_texture_view);
        card.pipelines.set(app.rtt_card_pipeline_id, .texture_view_size, vec2(@floatFromInt(fb_width), @floatFromInt(fb_height)));
        card.objects.set(app.rtt_card_id, .size, vec2(@floatFromInt(fb_width), @floatFromInt(fb_height)));
    }
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

    // Cloud cards use the same camera view_projection as sprites (they're in world space)
    card.pipelines.set(app.cloud_card_pipeline_id, .view_projection, view_projection);
    card.pipelines.set(app.cloud_card_pipeline_id, .time, app.world_time);

    // The RTT card uses projection only (no camera view) since it's a fullscreen quad.
    // We scale the card from framebuffer pixels to virtual canvas pixels, and position it
    // to fill the screen (centered at origin).
    const scale_x = width_px / @as(f32, @floatFromInt(fb_width));
    const scale_y = height_px / @as(f32, @floatFromInt(fb_height));
    card.pipelines.set(app.rtt_card_pipeline_id, .view_projection, projection);
    card.objects.set(app.rtt_card_id, .transform, Mat4x4.translate(vec3(
        -width_px / 2,
        -height_px / 2,
        0,
    )).mul(&Mat4x4.scale(vec3(scale_x, scale_y, 1))));

    // Apply parallax offset to sprites on parallax layers — they scroll slower than the camera
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

pub fn renderFrame(
    core: *mach.Core,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
    card: *Card,
    card_mod: mach.Mod(Card),
    app: *App,
) !void {
    const label = @tagName(mach_module) ++ ".renderFrame";
    const window = core.windows.getValue(app.window_id);
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
            .view = app.rtt_texture_view,
            .clear_value = switch (app.scene) {
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

        // Render sprites
        sprite.pipelines.set(app.sprite_pipeline_id, .render_pass, render_pass);
        sprite_mod.call(.tick);

        // Render cloud/fog cards (on top of sprites, in world space)
        // Only the cloud pipeline should render here — ensure the RTT pipeline is disabled.
        card.pipelines.set(app.rtt_card_pipeline_id, .render_pass, @as(?*gpu.RenderPassEncoder, null));
        card.pipelines.set(app.cloud_card_pipeline_id, .render_pass, render_pass);
        card_mod.call(.tick);

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

        // Render the RTT card (post-processing: water reflections)
        // Only the RTT pipeline should render here — ensure the cloud pipeline is disabled.
        card.pipelines.set(app.cloud_card_pipeline_id, .render_pass, @as(?*gpu.RenderPassEncoder, null));
        card.pipelines.set(app.rtt_card_pipeline_id, .render_pass, render_pass);
        card.pipelines.set(app.rtt_card_pipeline_id, .time, app.world_time);
        card_mod.call(.tick);

        // Render text on top of everything (so it's not affected by water reflections)
        text.pipelines.set(app.text_pipeline_id, .render_pass, render_pass);
        text_mod.call(.tick);

        // Finish render pass
        render_pass.end();
        render_pass.release();
    }

    // Finish the frame
    {
        var command = encoder.finish(&.{ .label = label });
        window.queue.submit(&[_]*gpu.CommandBuffer{command});
        command.release();

        app.frame_count += 1;

        // Every second, update the window title with the FPS
        if (app.fps_timer.read() >= 1.0) {
            app.fps_timer.reset();
            app.fps = app.frame_count;
            app.frame_count = 0;
        }
    }
}

// TODO(sprite): don't require users to copy / write this helper themselves
fn loadTexture(device: *gpu.Device, queue: *gpu.Queue, allocator: std.mem.Allocator, png_bytes: []const u8) !*gpu.Texture {
    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, png_bytes);
    defer img.deinit();
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
