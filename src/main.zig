const std = @import("std");
const mach = @import("mach");

// The set of Mach modules our application may use.
const Modules = mach.Modules(.{
    mach.Core,
    mach.gfx.Sprite,
    mach.gfx.Text,
    mach.dvx.DevOverlay,
    mach.Audio,
    @import("App.zig"),
});

const mib = 1024 * 1024;

/// Memory budgets for modules with their own preallocated pool. Modules not listed here (e.g.
/// mach.Core, which also owns GPU backend state) use `global_allocator`.
///
/// Sized from the high-water marks logged on exit (see App.deinitApp), with headroom; the dev
/// overlay (Ctrl+Alt+Shift+D) shows live usage, peaks and a suggested budget per module. Both need
/// a build with -Dmetrics. Measured
/// high-water marks playing through the start scene into the game scene:
///
/// - app: 12.5 MiB (atlas/level parsing, texture decode at startup)
/// - mach_gfx_sprite: 4.2 MiB
/// - mach_gfx_text: 4.0 MiB
/// - mach_audio: 208 MiB, during the scene change: the start scene's bgm is still alive while the
///   game scene's bgm is decoded. ~98 MiB steady state in the game scene.
const budgets: Modules.InitOptions = .{ .budgets = .{
    .app = 32 * mib,
    .mach_gfx_sprite = 16 * mib,
    .mach_gfx_text = 16 * mib,
    .mach_audio = 320 * mib,
} };

// TODO: move this to a mach "entrypoint" zig module which handles nuances like WASM requires.
pub fn main() !void {
    mach.tracy.setThreadName("main");

    // General-purpose allocator for modules without a budget. With -Dtracy, reported to Tracy as
    // the "global" memory pool (budgeted modules show up as their own pools).
    var global_tracing = mach.tracy.TracingAllocator.initNamed("global", std.heap.smp_allocator);
    const global_allocator = if (mach.tracy_enabled) global_tracing.allocator() else std.heap.smp_allocator;

    var io_threaded = std.Io.Threaded.init(global_allocator, .{});
    const io = io_threaded.io();

    var mods: Modules = undefined;
    try mods.initOptions(global_allocator, io, budgets);
    // TODO: enable mods.deinit(allocator); for allocator leak detection
    // defer mods.deinit(allocator);

    const app = mods.get(.app);
    app.run(.main);
}
