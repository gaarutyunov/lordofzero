const std = @import("std");

const SysgpuBackend = enum {
    default,
    webgpu,
    d3d12,
    metal,
    vulkan,
    opengl,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sysgpu_backend = b.option(SysgpuBackend, "sysgpu_backend", "sysgpu API backend") orelse .default;
    const tracy = b.option(bool, "tracy", "Enable Tracy profiling (zones, allocations; per-module memory plots need -Dmetrics)") orelse false;
    const metrics = b.option(bool, "metrics", "Calculate metrics, shown by the dev overlay") orelse false;

    const assets = b.addModule("assets", .{
        .root_source_file = b.path("assets/main.zig"),
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("assets", assets);

    const exe = b.addExecutable(.{
        .name = "lordofzero",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Add Mach dependency
    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
        .sysgpu_backend = sysgpu_backend,
        .tracy = tracy,
        .metrics = metrics,
    });
    exe_mod.addImport("mach", mach_dep.module("mach"));

    // Add zigimg dependency
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigimg", zigimg_dep.module("zigimg"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
