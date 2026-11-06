/// Data types for parsing Pixi .atlas JSON files
const std = @import("std");
const mach = @import("mach");
const testing = std.testing;

pub const ParsedAtlas = std.json.Parsed(Atlas);
pub const ParsedLDTKCompatibility = std.json.Parsed(LDTKCompatibility);

pub const LDTKCompatibility = struct {
    /// Helper to parse a file given its bytes.
    ///
    /// The caller is responsible for calling deinit() when done with the result.
    pub fn parseSlice(ctx: mach.Context, bytes: []const u8) !ParsedLDTKCompatibility {
        const zone = mach.tracy.initZone(@src(), .{});
        defer zone.deinit();
        const allocator = ctx.allocator;
        var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        return std.json.parseFromTokenSource(LDTKCompatibility, allocator, &scanner, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
        }) catch |err| {
            ctx.err("parsing .json file failed at line {d} column {d}: {s}", .{ diagnostics.getLine(), diagnostics.getColumn(), @errorName(err) });
            return err;
        };
    }

    tilesets: []LDTKTileset,

    pub fn findSpriteByLayerSrc(self: LDTKCompatibility, layer_path: []const u8, sprite_src: [2]i64) ?LDTKSprite {
        for (self.tilesets) |tileset| {
            for (tileset.layer_paths) |current_layer_path| {
                // TODO: for some reason current_layer_path can have spaces instead of underscores
                // in layer name:
                //
                //         layer_path=pixi-ldtk/src/tiles/tileset_64x320__Layer_0.png
                // current_layer_path=pixi-ldtk/src/tiles/tileset_64x320__Layer 0.png
                if (eqlSpaceAsUnderscore(layer_path, current_layer_path)) {
                    for (tileset.sprites) |current_sprite| {
                        if (sprite_src[0] == current_sprite.src[0] and sprite_src[1] == current_sprite.src[1]) {
                            return current_sprite;
                        }
                    }
                }
            }
        }
        return null;
    }
};

/// Like std.mem.eql, but treats ' ' in `b` as equal to '_' in `a`.
fn eqlSpaceAsUnderscore(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != (if (cb == ' ') '_' else cb)) return false;
    }
    return true;
}

pub const LDTKSprite = struct {
    name: [:0]const u8,
    src: [2]u32,
};

pub const LDTKTileset = struct {
    layer_paths: [][:0]const u8,
    sprite_size: [2]u32,
    sprites: []LDTKSprite,
};

/// This is the root of a pixi .atlas JSON file
pub const Atlas = struct {
    /// Helper to parse a file given its bytes.
    ///
    /// The caller is responsible for calling deinit() when done with the result.
    pub fn parseSlice(ctx: mach.Context, bytes: []const u8) !ParsedAtlas {
        const zone = mach.tracy.initZone(@src(), .{});
        defer zone.deinit();
        const allocator = ctx.allocator;
        var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        return std.json.parseFromTokenSource(Atlas, allocator, &scanner, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
        }) catch |err| {
            ctx.err("parsing .ldtk file failed at line {d} column {d}: {s}", .{ diagnostics.getLine(), diagnostics.getColumn(), @errorName(err) });
            return err;
        };

        // TODO: replace this function with std.json.parseFromSlice usage once that API supports
        // diagnostics: https://github.com/ziglang/zig/compare/master...json-diagnostics
        //
        // return try std.json.parseFromSlice(
        //     File,
        //     allocator,
        //     bytes,
        //     .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = true },
        // );
    }

    sprites: []Sprite,
    animations: []Animation,

    pub fn findSpriteIndex(self: Atlas, name: [:0]const u8) ?usize {
        for (self.sprites, 0..) |sprite, i| {
            if (std.mem.startsWith(u8, sprite.name, name)) {
                return i;
            }
        }
        return null;
    }
};

pub const Sprite = struct {
    name: [:0]const u8,
    source: [4]u32,
    origin: [2]i32,
};

pub const Animation = struct {
    name: [:0]const u8,
    start: usize,
    length: usize,
    fps: usize,
};

test {
    testing.refAllDeclsRecursive(@This());
}
