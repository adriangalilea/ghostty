const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const file_load = @import("file_load.zig");
const global = @import("../global.zig");

/// Open the fork's own configuration, `$XDG_CONFIG_HOME/vigil/config`,
/// creating it (and its directory) when it does not exist yet. Vanilla
/// Ghostty configuration is independent.
/// The returned value is allocated using the provided allocator.
pub fn openPath(alloc_gpa: Allocator) ![:0]const u8 {
    // Use an arena to make memory management easier in here.
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    const config_path = try file_load.preferredDefaultFilePath(alloc_arena);

    if (std.fs.path.dirname(config_path)) |config_dir| check_dir: {
        // Check to see if dir exists.
        const dir = std.Io.Dir.cwd().openDir(global.io(), config_dir, .{ .follow_symlinks = true }) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    // Create config directory recursively. Note that this does not
                    // allow intermediate symlinks by design, see
                    // std.Io.Threaded.dirCreateDirPath for why. If some sort of
                    // complex symlink structure is needed, it will need to be created
                    // manually.
                    try std.Io.Dir.cwd().createDirPath(global.io(), config_dir);
                    break :check_dir;
                },
                else => return err,
            }
        };
        dir.close(global.io());
    }

    // Try to create file and go on if it already exists
    if (std.Io.Dir.createFileAbsolute(
        global.io(),
        config_path,
        .{ .exclusive = true },
    )) |file| {
        file.close(global.io());
    } else |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    }

    return try alloc_gpa.dupeSentinel(u8, config_path, 0);
}
