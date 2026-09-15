const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const file_load = @import("file_load.zig");

/// Open the fork's own configuration, `$XDG_CONFIG_HOME/vigil/config`.
/// Vanilla Ghostty configuration is independent.
/// The returned value is allocated using the provided allocator.
pub fn openPath(alloc_gpa: Allocator) ![:0]const u8 {
    // Use an arena to make memory management easier in here.
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Get the path we should open
    const config_path = try file_load.preferredDefaultFilePath(alloc_arena);

    // Create config directory recursively.
    if (std.fs.path.dirname(config_path)) |config_dir| {
        try std.fs.cwd().makePath(config_dir);
    }

    // Try to create file and go on if it already exists
    if (std.fs.createFileAbsolute(
        config_path,
        .{ .exclusive = true },
    )) |file| {
        file.close();
    } else |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    }

    return try alloc_gpa.dupeZ(u8, config_path);
}
