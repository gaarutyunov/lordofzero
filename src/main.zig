const std = @import("std");
const mach = @import("mach");
const Pool = @import("Pool.zig");

// The set of Mach modules our application may use.
const Modules = mach.Modules(.{
    mach.Core,
    mach.gfx.Sprite,
    mach.gfx.Text,
    mach.Audio,
    @import("App.zig"),
});

/// Memory budgets for modules with their own preallocated pool. Modules not listed here (e.g.
/// mach.Core, which also owns GPU backend state) use `global_allocator`.
///
/// Sized from the high-water marks logged on exit (see `reportMemory`), with headroom. Measured
/// high-water marks playing through the start scene into the game scene:
///
/// - app: 12.5 MiB (atlas/level parsing, texture decode at startup)
/// - mach_gfx_sprite: 4.2 MiB
/// - mach_gfx_text: 4.0 MiB
/// - mach_audio: 208 MiB, during the scene change: the start scene's bgm is still alive while the
///   game scene's bgm is decoded. ~98 MiB steady state in the game scene.
const budgets = .{
    .app = 32 * mib,
    .mach_gfx_sprite = 16 * mib,
    .mach_gfx_text = 16 * mib,
    .mach_audio = 320 * mib,
};
const mib = 1024 * 1024;

/// General-purpose fallback allocator for modules without a pool.
const global_allocator = std.heap.smp_allocator;

var pools: struct {
    app: Pool,
    mach_gfx_sprite: Pool,
    mach_gfx_text: Pool,
    mach_audio: Pool,
} = undefined;

/// Logs usage of every pool. Called by App on exit.
pub fn reportMemory() void {
    inline for (@typeInfo(@TypeOf(pools)).@"struct".field_names) |name| @field(pools, name).report();
}

// TODO: move this to a mach "entrypoint" zig module which handles nuances like WASM requires.
pub fn main() !void {
    var io_threaded = std.Io.Threaded.init(global_allocator, .{});
    const io = io_threaded.io();

    // Reserve one block for all pools up front. Pages are committed lazily by the OS as pools
    // first touch them, so unused budget costs address space, not RAM.
    var total: usize = 0;
    inline for (@typeInfo(@TypeOf(budgets)).@"struct".field_names) |name| total += @field(budgets, name);
    const block = try std.heap.page_allocator.alloc(u8, total);

    var offset: usize = 0;
    inline for (@typeInfo(@TypeOf(budgets)).@"struct".field_names) |name| {
        const size = @field(budgets, name);
        @field(pools, name) = Pool.init(name, block[offset..][0..size], io);
        offset += size;
    }

    var mods: Modules = undefined;
    try mods.initOptions(global_allocator, io, .{ .allocators = .{
        .app = pools.app.allocator(),
        .mach_gfx_sprite = pools.mach_gfx_sprite.allocator(),
        .mach_gfx_text = pools.mach_gfx_text.allocator(),
        .mach_audio = pools.mach_audio.allocator(),
    } });
    // TODO: enable mods.deinit(allocator); for allocator leak detection
    // defer mods.deinit(allocator);

    const app = mods.get(.app);
    app.run(.main);
}

test {
    _ = Pool;
}
