const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.config);

/// Vigil's only default config path. All readers, editors and generated
/// fragments use this directory; vanilla Ghostty configuration is independent.
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    return internal_os.xdg.config(alloc, .{ .subdir = "vigil/config" });
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}
