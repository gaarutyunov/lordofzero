const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;

const math = mach.math;
const vec4 = math.vec4;
const Vec2 = math.Vec2;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const Card = @This();

pub const mach_module = .card;

pub const mach_systems = .{ .init, .cleanup, .snapshot, .render };

// TODO(card): currently not handling deinit properly

const Uniforms = extern struct {
    /// The view * orthographic projection matrix
    view_projection: gpu.Mat4x4 align(16),

    /// Total size of the card texture in pixels (xy), time (z), unused (w)
    texture_size: gpu.Vec4 align(16),
};

const BuiltPipeline = struct {
    render: *gpu.RenderPipeline,
    texture_sampler: *gpu.Sampler,
    texture_view: *gpu.TextureView,
    bind_group: *gpu.BindGroup,
    uniforms: *gpu.Buffer,

    // Storage buffers
    transforms: *gpu.Buffer,
    uv_transforms: *gpu.Buffer,
    sizes: *gpu.Buffer,

    fn deinit(p: *const BuiltPipeline) void {
        p.render.release();
        p.texture_sampler.release();
        p.texture_view.release();
        p.bind_group.release();
        p.uniforms.release();
        p.transforms.release();
        p.uv_transforms.release();
        p.sizes.release();
    }
};

/// Maximum number of cards a single pipeline can render.
const buffer_cap = 1024; // TODO(card): allow user to specify preallocation

const Objects = mach.Objects(.{ .track_fields = true }, struct {
    /// The card model transformation matrix. A card is measured in pixel units, starting from
    /// (0, 0) at the top-left corner and extending to the size of the card. By default, the world
    /// origin (0, 0) lives at the center of the window.
    ///
    /// Example: in a 500px by 500px window, a card located at (0, 0) with size (250, 250) will
    /// cover the top-right hand corner of the window.
    transform: Mat4x4,

    /// UV coordinate transformation matrix describing top-left corner / origin of card, in pixels.
    uv_transform: Mat3x3,

    /// The size of the card, in pixels.
    size: Vec2,
});

/// A card pipeline renders all cards in its `.render_list`.
const Pipelines = mach.Objects(.{ .track_fields = true }, struct {
    /// Which window (device/queue) to use. If not set, this pipeline will not be rendered.
    window: ?mach.ObjectID = null,

    /// Which render pass should be used during rendering. If not set, this pipeline will not be
    /// rendered.
    ///
    /// This is a transient GPU resource set by the render thread each frame directly on the
    /// app-side pipelines (it is read from there, not from the snapshot.)
    render_pass: ?*gpu.RenderPassEncoder = null,

    /// Time value to pass to shader program.
    time: f32 = 0,

    /// Texture to use when rendering.
    /// Must be specified for a pipeline entity to be valid. The pipeline takes a reference to it.
    texture_view: *gpu.TextureView,
    texture_view_size: math.Vec2,

    /// View*Projection matrix to use when rendering with this pipeline. This controls both
    /// the size of the 'virtual canvas' which is rendered onto, as well as the 'camera position'.
    ///
    /// By default, the size is configured to be equal to the window size in virtual pixels.
    view_projection: ?Mat4x4 = null,

    /// Shader program to use when rendering
    ///
    /// If null, defaults to card.wgsl
    shader: ?*gpu.ShaderModule = null,

    /// Whether to use linear (blurry) or nearest (pixelated) upscaling/downscaling.
    ///
    /// If null, defaults to nearest (pixelated)
    texture_sampler: ?*gpu.Sampler = null,

    /// Alpha and color blending options
    ///
    /// If null, defaults to
    /// .{
    ///   .color = .{ .operation = .add, .src_factor = .src_alpha .dst_factor = .one_minus_src_alpha },
    ///   .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .zero },
    /// }
    blend_state: ?gpu.BlendState = null,

    /// Override to enable passing additional data to your shader program.
    bind_group_layout: ?*gpu.BindGroupLayout = null,

    /// Override to enable passing additional data to your shader program.
    bind_group: ?*gpu.BindGroup = null,

    /// Override to enable custom color target state for render pipeline.
    color_target_state: ?gpu.ColorTargetState = null,

    /// Override to enable custom fragment state for render pipeline.
    fragment_state: ?gpu.FragmentState = null,

    /// Override to enable custom pipeline layout.
    layout: ?*gpu.PipelineLayout = null,

    /// Number of cards this pipeline will render.
    /// Read-only, updated as part of Card.snapshot
    num_cards: u32 = 0,

    /// The cards this pipeline will render. Add to it to render a card:
    ///
    /// ```
    /// var render_list = card.pipelines.get(pipeline_id, .render_list);
    /// try render_list.append(allocator, card_id);
    /// card.pipelines.set(pipeline_id, .render_list, render_list);
    /// ```
    ///
    /// Cards are removed from this list automatically when they are deleted (via Card.cleanup).
    render_list: std.ArrayList(mach.ObjectID) = .empty,

    /// Internal pipeline state.
    built_index: ?u32 = null,
});

allocator: std.mem.Allocator,

objects: Objects,
pipelines: Pipelines,

// Internal render copy of objects and pipelines.
render_objects: Objects,
render_pipelines: Pipelines,
built_pipelines: std.ArrayList(?BuiltPipeline) = .empty,

// Per-pipeline render-side `.render_list` storage, indexed by `built_index`.
cached_render_lists: std.ArrayList(std.ArrayList(mach.ObjectID)) = .empty,

// Temporary buffers used during updatePipelineBuffers, retained to avoid re-allocation.
cp_transforms: std.ArrayList(gpu.Mat4x4) = .empty,
cp_uv_transforms: std.ArrayList(gpu.Mat4x4) = .empty,
cp_sizes: std.ArrayList(gpu.Vec2) = .empty,

pub fn init(card: *Card) !void {
    // TODO(allocator): find a better way to get an allocator here
    const allocator = std.heap.c_allocator;

    card.* = .{
        .allocator = allocator,
        .objects = card.objects,
        .pipelines = card.pipelines,
        .render_objects = card.render_objects,
        .render_pipelines = card.render_pipelines,
    };
}

/// Cleans up card objects that have been marked for deletion via `delete()`.
///
/// Each deleted card is removed from any pipeline's `.render_list` it appears in.
pub fn cleanup(card: *Card) void {
    if (card.objects.numDeleted() == 0) return;

    var pipeline_ids = card.pipelines.slice();
    while (pipeline_ids.next()) |pipeline_id| {
        var render_list = card.pipelines.get(pipeline_id, .render_list);
        var i: usize = render_list.items.len;
        while (i > 0) {
            i -= 1;
            if (card.objects.isDeleted(render_list.items[i])) _ = render_list.swapRemove(i);
        }
        card.pipelines.setRaw(pipeline_id, .render_list, render_list);
    }

    var deleted = card.objects.sliceDeleted();
    while (deleted.next()) |card_id| card.objects.free(card_id);
}

/// Snapshots app-side card state for the render thread. Must be called between
/// mach.Core.snapshotStart and mach.Core.snapshotEnd.
pub fn snapshot(card: *Card, core: *mach.Core) !void {
    const allocator = card.allocator;
    {
        var render_it = card.render_pipelines.slice();
        while (render_it.next()) |render_pid| {
            const alive = blk: {
                var app_it = card.pipelines.slice();
                while (app_it.next()) |app_pid| {
                    if (render_pid == app_pid) break :blk true;
                }
                break :blk false;
            };
            const built_idx = card.render_pipelines.get(render_pid, .built_index).?;
            if (alive) {
                card.pipelines.setRaw(render_pid, .num_cards, card.render_pipelines.get(render_pid, .num_cards));
                card.cached_render_lists.items[built_idx].clearRetainingCapacity();
            } else {
                card.cached_render_lists.items[built_idx].deinit(allocator);
                card.cached_render_lists.items[built_idx] = .empty;
                if (card.built_pipelines.items[built_idx]) |*b| b.deinit();
                card.built_pipelines.items[built_idx] = null;
            }
        }
    }

    // Ensure every app-side pipeline has a built_pipelines slot.
    {
        var app_it = card.pipelines.slice();
        while (app_it.next()) |app_pid| {
            if (card.pipelines.get(app_pid, .built_index) == null) {
                const idx: u32 = @intCast(card.built_pipelines.items.len);
                try card.built_pipelines.append(allocator, null);
                try card.cached_render_lists.append(allocator, .empty);
                card.pipelines.setRaw(app_pid, .built_index, idx);
            }
        }
    }

    try card.render_objects.copyFrom(&card.objects);
    try card.render_pipelines.copyFrom(&card.pipelines);

    // Deep-copy each pipeline's .render_list into render-side owned storage.
    var render_pipeline_ids = card.render_pipelines.slice();
    while (render_pipeline_ids.next()) |render_pipeline_id| {
        const src = card.render_pipelines.get(render_pipeline_id, .render_list);
        const built_idx = card.render_pipelines.get(render_pipeline_id, .built_index).?;
        var dst = card.cached_render_lists.items[built_idx];
        try dst.appendSlice(allocator, src.items);
        card.cached_render_lists.items[built_idx] = dst;
        card.render_pipelines.setRaw(render_pipeline_id, .render_list, dst);
    }

    card.render_objects.internal.graph = &core.render_graph;
    card.render_pipelines.internal.graph = &core.render_graph;

    // Clear app-side dirty flags; they've been copied to the render side.
    {
        var object_it = card.objects.slice();
        while (object_it.next()) |id| _ = card.objects.anyUpdated(id);
        var pipeline_it = card.pipelines.slice();
        while (pipeline_it.next()) |id| _ = card.pipelines.anyUpdated(id);
    }
}

/// Renders all card pipelines which currently have a `.render_pass` set. Called on the render
/// thread.
pub fn render(card: *Card, core: *mach.Core) !void {
    var pipelines = card.render_pipelines.slice();
    while (pipelines.next()) |pipeline_id| {
        var pipeline = card.render_pipelines.getValue(pipeline_id);
        if (pipeline.window == null) continue;
        std.debug.assert(pipeline.built_index != null);

        // render_pass is a transient GPU resource set by the render thread each frame directly
        // on the app-side pipelines — read it from there, not the snapshot.
        const render_pass = card.pipelines.get(pipeline_id, .render_pass) orelse continue;

        // Changing these fields shouldn't trigger a pipeline rebuild, so clear their update values:
        _ = card.render_pipelines.updated(pipeline_id, .window);
        _ = card.render_pipelines.updated(pipeline_id, .render_pass);
        _ = card.render_pipelines.updated(pipeline_id, .view_projection);
        _ = card.render_pipelines.updated(pipeline_id, .num_cards);
        _ = card.render_pipelines.updated(pipeline_id, .time);
        _ = card.render_pipelines.updated(pipeline_id, .built_index);
        _ = card.render_pipelines.updated(pipeline_id, .render_list);

        const needs_rebuild = card.built_pipelines.items[pipeline.built_index.?] == null or
            card.render_pipelines.anyUpdated(pipeline_id);
        if (needs_rebuild) rebuildPipeline(core, card, pipeline_id);

        const render_list = card.render_pipelines.get(pipeline_id, .render_list).items;

        const any_cards_updated = needs_rebuild or blk: {
            for (render_list) |card_id| {
                if (!card.render_objects.is(card_id)) continue;
                if (card.render_objects.anyUpdated(card_id)) break :blk true;
            }
            break :blk false;
        };
        if (any_cards_updated) try updatePipelineBuffers(card, core, pipeline_id, render_list);

        pipeline = card.render_pipelines.getValue(pipeline_id);
        if (pipeline.num_cards == 0) continue;

        renderPipeline(card, core, pipeline_id, render_pass);
    }
}

fn rebuildPipeline(
    core: *mach.Core,
    card: *Card,
    pipeline_id: mach.ObjectID,
) void {
    // Destroy the current pipeline, if built.
    var pipeline = card.render_pipelines.getValue(pipeline_id);
    const built_idx = pipeline.built_index.?;
    if (card.built_pipelines.items[built_idx]) |built| built.deinit();

    // Reference any user-provided objects.
    pipeline.texture_view.reference(); // released by BuiltPipeline.deinit
    if (pipeline.shader) |v| v.reference();
    if (pipeline.texture_sampler) |v| v.reference();
    if (pipeline.bind_group_layout) |v| v.reference();
    if (pipeline.bind_group) |v| v.reference();
    if (pipeline.layout) |v| v.reference();

    const window = core.windows.getValue(pipeline.window.?);
    const device = window.device;

    const label = @tagName(mach_module) ++ ".rebuildPipeline";

    // Storage buffers
    const transforms = device.createBuffer(&.{
        .label = label ++ " transforms",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(gpu.Mat4x4) * buffer_cap,
        .mapped_at_creation = .false,
    });
    const uv_transforms = device.createBuffer(&.{
        .label = label ++ " uv_transforms",
        .usage = .{ .storage = true, .copy_dst = true },
        // TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
        .size = @sizeOf(gpu.Mat4x4) * buffer_cap,
        .mapped_at_creation = .false,
    });
    const sizes = device.createBuffer(&.{
        .label = label ++ " sizes",
        .usage = .{ .storage = true, .copy_dst = true },
        .size = @sizeOf(gpu.Vec2) * buffer_cap,
        .mapped_at_creation = .false,
    });

    const texture_sampler = pipeline.texture_sampler orelse device.createSampler(&.{
        .label = label ++ " sampler",
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    const uniforms = device.createBuffer(&.{
        .label = label ++ " uniforms",
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(Uniforms),
        .mapped_at_creation = .false,
    });
    const bind_group_layout = pipeline.bind_group_layout orelse device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor.init(.{
            .label = label,
            .entries = &.{
                gpu.BindGroupLayout.Entry.initBuffer(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
                gpu.BindGroupLayout.Entry.initBuffer(1, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.initBuffer(2, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.initBuffer(3, .{ .vertex = true }, .read_only_storage, false, 0),
                gpu.BindGroupLayout.Entry.initSampler(4, .{ .fragment = true }, .filtering),
                gpu.BindGroupLayout.Entry.initTexture(5, .{ .fragment = true }, .float, .dimension_2d, false),
            },
        }),
    );
    defer bind_group_layout.release();

    const bind_group = pipeline.bind_group orelse device.createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .label = label,
            .layout = bind_group_layout,
            .entries = &.{
                gpu.BindGroup.Entry.initBuffer(0, uniforms, 0, @sizeOf(Uniforms), @sizeOf(Uniforms)),
                gpu.BindGroup.Entry.initBuffer(1, transforms, 0, @sizeOf(gpu.Mat4x4) * buffer_cap, @sizeOf(gpu.Mat4x4)),
                gpu.BindGroup.Entry.initBuffer(2, uv_transforms, 0, @sizeOf(gpu.Mat4x4) * buffer_cap, @sizeOf(gpu.Mat4x4)),
                gpu.BindGroup.Entry.initBuffer(3, sizes, 0, @sizeOf(gpu.Vec2) * buffer_cap, @sizeOf(gpu.Vec2)),
                gpu.BindGroup.Entry.initSampler(4, texture_sampler),
                gpu.BindGroup.Entry.initTextureView(5, pipeline.texture_view),
            },
        }),
    );

    const blend_state = pipeline.blend_state orelse gpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .zero,
        },
    };

    const shader_module = pipeline.shader orelse device.createShaderModuleWGSL("card.wgsl", @embedFile("card.wgsl"));
    defer shader_module.release();

    const color_target = pipeline.color_target_state orelse gpu.ColorTargetState{
        .format = window.framebuffer_format,
        .blend = &blend_state,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = pipeline.fragment_state orelse gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "fragMain",
        .targets = &.{color_target},
    });

    const bind_group_layouts = [_]*gpu.BindGroupLayout{bind_group_layout};
    const pipeline_layout = pipeline.layout orelse device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
        .label = label,
        .bind_group_layouts = &bind_group_layouts,
    }));
    defer pipeline_layout.release();
    const render_pipeline = device.createRenderPipeline(&gpu.RenderPipeline.Descriptor{
        .label = label,
        .fragment = &fragment,
        .layout = pipeline_layout,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertMain",
        },
    });

    card.built_pipelines.items[built_idx] = BuiltPipeline{
        .render = render_pipeline,
        .texture_sampler = texture_sampler,
        .texture_view = pipeline.texture_view,
        .bind_group = bind_group,
        .uniforms = uniforms,
        .transforms = transforms,
        .uv_transforms = uv_transforms,
        .sizes = sizes,
    };
    pipeline.num_cards = 0;
    card.render_pipelines.setValueRaw(pipeline_id, pipeline);
}

fn updatePipelineBuffers(
    card: *Card,
    core: *mach.Core,
    pipeline_id: mach.ObjectID,
    render_list: []const mach.ObjectID,
) !void {
    const pipeline = card.render_pipelines.getValue(pipeline_id);
    const built = card.built_pipelines.items[pipeline.built_index.?].?;
    const window = core.windows.getValue(pipeline.window.?);
    const device = window.device;

    const label = @tagName(mach_module) ++ ".updatePipelineBuffers";
    const encoder = device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    card.cp_transforms.clearRetainingCapacity();
    card.cp_uv_transforms.clearRetainingCapacity();
    card.cp_sizes.clearRetainingCapacity();

    for (render_list) |card_id| {
        if (!card.render_objects.is(card_id)) continue;
        if (card.cp_transforms.items.len == buffer_cap) break; // TODO(card): grow GPU buffers
        const s = card.render_objects.getValue(card_id);

        try card.cp_transforms.append(card.allocator, s.transform.gpu());
        // TODO(d3d12): uv_transform should be a Mat3x3 but our D3D12/HLSL backend cannot handle it.
        try card.cp_uv_transforms.append(card.allocator, s.uv_transform.mat4x4().gpu());
        try card.cp_sizes.append(card.allocator, s.size.gpu());
    }

    const count: u32 = @intCast(card.cp_transforms.items.len);

    // Sort cards back-to-front for draw order, alpha blending
    const Context = struct {
        transforms: []gpu.Mat4x4,
        uv_transforms: []gpu.Mat4x4,
        sizes: []gpu.Vec2,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const a_z = ctx.transforms[a].math().translation().z();
            const b_z = ctx.transforms[b].math().translation().z();
            // Greater z values are further away, and thus should render/sort before those with lesser z values.
            return a_z > b_z;
        }

        pub fn swap(ctx: @This(), a: usize, b: usize) void {
            std.mem.swap(gpu.Mat4x4, &ctx.transforms[a], &ctx.transforms[b]);
            std.mem.swap(gpu.Mat4x4, &ctx.uv_transforms[a], &ctx.uv_transforms[b]);
            std.mem.swap(gpu.Vec2, &ctx.sizes[a], &ctx.sizes[b]);
        }
    };
    std.sort.pdqContext(0, count, Context{
        .transforms = card.cp_transforms.items,
        .uv_transforms = card.cp_uv_transforms.items,
        .sizes = card.cp_sizes.items,
    });

    card.render_pipelines.set(pipeline_id, .num_cards, count);
    if (count > 0) {
        encoder.writeBuffer(built.transforms, 0, card.cp_transforms.items);
        encoder.writeBuffer(built.uv_transforms, 0, card.cp_uv_transforms.items);
        encoder.writeBuffer(built.sizes, 0, card.cp_sizes.items);

        var command = encoder.finish(&.{ .label = label });
        defer command.release();
        window.queue.submit(&[_]*gpu.CommandBuffer{command});
    }
}

fn renderPipeline(
    card: *Card,
    core: *mach.Core,
    pipeline_id: mach.ObjectID,
    render_pass: *gpu.RenderPassEncoder,
) void {
    const pipeline = card.render_pipelines.getValue(pipeline_id);
    const built = card.built_pipelines.items[pipeline.built_index.?].?;
    const window = core.windows.getValue(pipeline.window.?);
    const device = window.device;

    const label = @tagName(mach_module) ++ ".renderPipeline";
    const encoder = device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Update uniform buffer
    const view_projection = pipeline.view_projection orelse blk: {
        const width_px: f32 = @floatFromInt(window.width);
        const height_px: f32 = @floatFromInt(window.height);
        break :blk math.Mat4x4.projection2D(.{
            .left = -width_px / 2,
            .right = width_px / 2,
            .bottom = -height_px / 2,
            .top = height_px / 2,
            .near = -0.1,
            .far = 100000,
        });
    };
    const uniforms = Uniforms{
        .view_projection = view_projection.gpu(),
        // Pack texture_size (xy), time (z), unused (w) into a single vec4
        .texture_size = vec4(
            pipeline.texture_view_size.x(),
            pipeline.texture_view_size.y(),
            pipeline.time,
            0,
        ).gpu(),
    };
    encoder.writeBuffer(built.uniforms, 0, &[_]Uniforms{uniforms});
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});

    // Draw the card batch
    const total_vertices = pipeline.num_cards * 6;
    render_pass.setPipeline(built.render);
    // TODO(card): can we remove unused dynamic offsets?
    render_pass.setBindGroup(0, built.bind_group, &.{});
    render_pass.draw(total_vertices, 1, 0, 0);
}
