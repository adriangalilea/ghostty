//! Attach is the vigil backend: instead of spawning a subprocess with a pty,
//! the surface connects to a vigild session daemon over a unix socket. The
//! daemon owns the pty and the processes; this surface is a disposable
//! client. Close the surface, the processes never notice; attach again and
//! the daemon replays its backlog and resize-jiggles so TUIs repaint.
//!
//! Protocol (see vigild.zig): frames out ([1 byte type]['d' data | 'r'
//! resize][u16 le len][payload]), raw pty bytes in. Reads reuse Exec's
//! ReadThread over the socket fd. Writes are direct blocking writes on the
//! io thread: keystroke-sized, local socket, and sequential syscalls keep
//! the frame protocol uncorruptible by construction.
const Attach = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_attach);

/// Session daemon id (e.g. "vigil-myproject-0").
id: []const u8,

/// Working directory for the daemon's command when we create it.
cwd: ?[]const u8,

/// VIGIL_SESSION value for the daemon's environment on create.
session: ?[]const u8,

/// VIGILD_RESUME line for the daemon on create: typed into the session
/// once the shell truly booted (first attach + quiescence). The in-place
/// upgrade rides this to replay frozen content and resume the program.
resume_line: ?[]const u8,

alloc: Allocator,

/// Connected socket; -1 until threadEnter.
sock_fd: posix.fd_t = -1,

/// Cached tty name of the daemon's pty (from its pidfile).
cached_tty: ?[:0]const u8 = null,

/// Last known size, sent on connect and on change.
grid_size: renderer.GridSize = .{ .columns = 80, .rows = 24 },

pub const Config = struct {
    id: []const u8,
    cwd: ?[]const u8 = null,
    session: ?[]const u8 = null,
    resume_line: ?[]const u8 = null,
};

pub fn init(alloc: Allocator, cfg: Config) !Attach {
    return .{
        .alloc = alloc,
        .id = try alloc.dupe(u8, cfg.id),
        .cwd = if (cfg.cwd) |v| try alloc.dupe(u8, v) else null,
        .session = if (cfg.session) |v| try alloc.dupe(u8, v) else null,
        .resume_line = if (cfg.resume_line) |v| try alloc.dupe(u8, v) else null,
    };
}

pub fn deinit(self: *Attach) void {
    self.alloc.free(self.id);
    if (self.cwd) |v| self.alloc.free(v);
    if (self.session) |v| self.alloc.free(v);
    if (self.resume_line) |v| self.alloc.free(v);
    if (self.cached_tty) |v| self.alloc.free(v);
}

pub fn initTerminal(self: *Attach, term: *terminal.Terminal) void {
    if (self.cwd) |cwd| term.setPwd(cwd) catch |err| {
        log.warn("error setting initial pwd err={}", .{err});
    };
    self.grid_size = .{ .columns = term.cols, .rows = term.rows };
}

fn sockPath(self: *Attach, buf: []u8) ![]const u8 {
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.bufPrint(buf, "{s}/.local/state/vigild/{s}.sock", .{ home, self.id });
}

fn connectSock(self: *Attach) !posix.fd_t {
    var buf: [512]u8 = undefined;
    const path = try self.sockPath(&buf);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    var addr: std.net.Address = try .initUnix(path);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// Spawn `vigild new <id>` to bring the daemon up. The daemon's command
/// defaults to $SHELL inside vigild; env carries VIGIL_SESSION so claude
/// hooks feed the attention queue from birth.
fn spawnDaemon(self: *Attach) !void {
    var env = try internal_os.getEnvMap(self.alloc);
    defer env.deinit();
    if (self.session) |s| try env.put("VIGIL_SESSION", s);
    // The surface config's env does NOT flow here by itself (this is the
    // APP's environment): anything the daemon must inherit is plumbed
    // explicitly. Found live: VIGILD_RESUME set on the surface never
    // reached the daemon and upgrades came back as bare shells.
    if (self.resume_line) |r| try env.put("VIGILD_RESUME", r);

    const home = posix.getenv("HOME") orelse return error.NoHome;
    const bin = try std.fmt.allocPrint(self.alloc, "{s}/.local/bin/vigild", .{home});
    defer self.alloc.free(bin);

    var child = std.process.Child.init(&.{ bin, "new", self.id }, self.alloc);
    child.env_map = &env;
    child.cwd = self.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.DaemonSpawnFailed,
        else => return error.DaemonSpawnFailed,
    }
}

pub fn threadEnter(
    self: *Attach,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Attach, creating the daemon on first contact.
    const fd = self.connectSock() catch fd: {
        try self.spawnDaemon();
        break :fd try self.connectSock();
    };
    errdefer posix.close(fd);
    self.sock_fd = fd;

    // First frame is our size: the daemon applies it (and jiggles on
    // reattach so full-screen TUIs repaint).
    self.sendResize();

    // Quit pipe + read thread, exactly Exec's shape: the ReadThread just
    // reads an fd and feeds processOutput; a socket fd is an fd.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    const closing = try alloc_state: {
        break :alloc_state self.alloc.create(std.atomic.Value(bool));
    };
    closing.* = .init(false);
    errdefer self.alloc.destroy(closing);

    const read_thread = try std.Thread.spawn(
        .{},
        readThreadMain,
        .{ fd, io, pipe[0], closing },
    );
    read_thread.setName("io-reader") catch {};

    td.backend = .{ .attach = .{
        .sock_fd = fd,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .closing = closing,
    } };
}

pub fn threadExit(self: *Attach, td: *termio.Termio.ThreadData) void {
    assert(td.backend == .attach);
    const attach = &td.backend.attach;

    // Deliberate teardown: the EOF the read thread is about to see is not
    // a session death.
    attach.closing.store(true, .release);

    _ = posix.write(attach.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };
    posix.shutdown(attach.sock_fd, .both) catch {};
    attach.read_thread.join();
    posix.close(attach.sock_fd);
    self.sock_fd = -1;
}

pub fn focusGained(
    self: *Attach,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

fn writeAll(fd: posix.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = posix.write(fd, data[off..]) catch |err| {
            log.warn("attach write failed err={}", .{err});
            return;
        };
        off += n;
    }
}

fn sendFrame(fd: posix.fd_t, typ: u8, payload: []const u8) void {
    assert(payload.len <= 0xffff);
    const hdr: [3]u8 = .{
        typ,
        @intCast(payload.len & 0xff),
        @intCast((payload.len >> 8) & 0xff),
    };
    writeAll(fd, &hdr);
    writeAll(fd, payload);
}

fn sendResize(self: *Attach) void {
    if (self.sock_fd < 0) return;
    const rows: u16 = @intCast(self.grid_size.rows);
    const cols: u16 = @intCast(self.grid_size.columns);
    const payload: [4]u8 = .{
        @intCast(rows & 0xff), @intCast((rows >> 8) & 0xff),
        @intCast(cols & 0xff), @intCast((cols >> 8) & 0xff),
    };
    sendFrame(self.sock_fd, 'r', &payload);
}

pub fn resize(
    self: *Attach,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;
    self.grid_size = grid_size;
    self.sendResize();
}

pub fn queueWrite(
    self: *Attach,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = alloc;
    _ = td;
    if (self.sock_fd < 0) return;

    if (!linefeed) {
        var i: usize = 0;
        while (i < data.len) {
            const end = @min(data.len, i + 0xffff);
            sendFrame(self.sock_fd, 'd', data[i..end]);
            i = end;
        }
        return;
    }

    // Linefeed mode: \r becomes \r\n (bracketed paste path).
    var buf: [512]u8 = undefined;
    var buf_i: usize = 0;
    for (data) |ch| {
        if (buf_i >= buf.len - 1) {
            sendFrame(self.sock_fd, 'd', buf[0..buf_i]);
            buf_i = 0;
        }
        buf[buf_i] = ch;
        buf_i += 1;
        if (ch == '\r') {
            buf[buf_i] = '\n';
            buf_i += 1;
        }
    }
    if (buf_i > 0) sendFrame(self.sock_fd, 'd', buf[0..buf_i]);
}

pub fn childExitedAbnormally(
    self: *Attach,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
}

/// Answered from the daemon's pidfile:
/// "<daemon> <child>\n<ttyname>\n<foreground pid>". Line 3 is the DEEP
/// foreground process (the daemon tcgetpgrp's its own pty and rewrites the
/// line on change); the session leader on line 1 is the fallback.
pub fn getProcessInfo(self: *Attach, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    switch (info) {
        .foreground_pid => {
            const data = self.readPidfile() orelse return null;
            defer self.alloc.free(data);
            var lines = std.mem.splitScalar(u8, data, '\n');
            const first = lines.next() orelse return null;
            _ = lines.next(); // tty
            if (lines.next()) |fg_line| {
                const trimmed = std.mem.trim(u8, fg_line, " \r");
                if (std.fmt.parseInt(u64, trimmed, 10) catch null) |fg| return fg;
            }
            var toks = std.mem.tokenizeScalar(u8, first, ' ');
            _ = toks.next() orelse return null;
            const child = toks.next() orelse return null;
            return std.fmt.parseInt(u64, child, 10) catch null;
        },
        .tty_name => {
            if (self.cached_tty) |v| return v;
            const data = self.readPidfile() orelse return null;
            defer self.alloc.free(data);
            var lines = std.mem.splitScalar(u8, data, '\n');
            _ = lines.next() orelse return null;
            const tty = lines.next() orelse return null;
            if (tty.len == 0) return null;
            self.cached_tty = self.alloc.dupeZ(u8, tty) catch return null;
            return self.cached_tty;
        },
    }
}

fn readPidfile(self: *Attach) ?[]u8 {
    const home = posix.getenv("HOME") orelse return null;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.local/state/vigild/{s}.pid", .{ home, self.id }) catch return null;
    return std.fs.cwd().readFileAlloc(self.alloc, path, 256) catch null;
}

/// The read thread body: Exec's loop over the socket fd, plus a death
/// notice. Reaching EOF WITHOUT a deliberate teardown means the daemon
/// died under us (external `vigild kill`, crash): tell the surface so it
/// shows the session ended instead of freezing mute.
fn readThreadMain(
    fd: posix.fd_t,
    io: *termio.Termio,
    quit: posix.fd_t,
    closing: *std.atomic.Value(bool),
) void {
    termio.Exec.ReadThread.threadMainPosix(fd, io, quit);
    if (closing.load(.acquire)) return;
    _ = io.surface_mailbox.push(.{
        .child_exited = .{ .exit_code = 1, .runtime_ms = 0 },
    }, .{ .forever = {} });
}

/// Thread-local state: the socket and the reader.
pub const ThreadData = struct {
    sock_fd: posix.fd_t,
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    closing: *std.atomic.Value(bool),

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);
        alloc.destroy(self.closing);
    }
};
