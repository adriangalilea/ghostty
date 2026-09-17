//! Attach is the vigil backend: instead of spawning a subprocess with a pty,
//! the surface connects to a vigild session daemon over a unix socket. The
//! daemon owns the pty and the processes; this surface is a disposable
//! client. Close the surface, the processes never notice; attach again and
//! the daemon replays its backlog and resize-jiggles so TUIs repaint.
//!
//! Protocol (see vigild.zig): frames out ([1 byte type]['d' data | 'r'
//! resize][u16 le len][payload]), raw pty bytes in. Reads reuse Exec's
//! ReadThread over the socket fd — which flips the SHARED fd O_NONBLOCK,
//! so writes can hit WouldBlock whenever a burst outruns the socket
//! buffer. A frame abandoned mid-write desyncs the stream permanently, so
//! frames are written whole — but NEVER from the io thread: every frame
//! is queued and a dedicated writer thread absorbs the backpressure
//! (blocking on POLLOUT until the daemon drains, severing on any
//! unrecoverable error so the reader sees EOF). Blocking the io thread
//! on a slow drain wedged the ENTIRE APP for 100s: a claude-code scroll
//! storm (mouse-mode reports) outran the ~8KB sndbuf while claude redrew
//! slowly, the io mailbox filled behind the stuck thread, and the main
//! thread blocked pushing a focus message (Lulzx's hang report,
//! 2026-08-05).
const Attach = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const configpkg = @import("../config.zig");
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

/// The program the daemon runs as its child on create (a session API
/// birth: `vigil new -- claude`). null = the daemon's login shell. Never
/// typed into a shell: it IS the child, recorded in the daemon's spec, so
/// it survives detach, quit and reboot like the shell does.
command: ?configpkg.Command,

/// ssh alias of the Mac that owns the daemon; null = local. Remote =
/// `ssh <host> vigild proxy <id>` as a child whose stdout is our read fd
/// and stdin our write fd. The daemon is never spawned remotely.
host: ?[]const u8,

/// A stream handed in already connected (iOS: a socketpair end the app
/// pumps to its ssh channel). The transport is the embedder's; this
/// backend only speaks frames on whatever fd it is given.
given_fd: ?posix.fd_t,

/// Ownership policy: false = focus claims the pty size (a Mac surface,
/// presence beats attention); true = only `vigilClaim` does.
explicit_claim: bool,

/// Per-connection identity. A pid alone aliases different views in one app
/// and can also collide between Macs. Published in the daemon's owner hello.
client_id: u64,

alloc: Allocator,

/// Read side: the socket, or the ssh child's stdout; -1 until threadEnter.
sock_fd: posix.fd_t = -1,
/// Write side: the same socket, or the ssh child's stdin.
write_fd: posix.fd_t = -1,
/// The ssh child for a remote pane (0 = local). Severing a pipe stream
/// means killing it: a pipe has no shutdown(), and the reader only sees
/// EOF once the child is gone.
ssh_pid: posix.pid_t = 0,

/// Cached tty name of the daemon's pty (from its pidfile).
cached_tty: ?[:0]const u8 = null,

/// Last known size, sent on connect and on change.
grid_size: renderer.GridSize = .{ .columns = 80, .rows = 24 },

/// Outbound frame queue: enqueueFrame appends (io thread, never blocks),
/// the writer thread alone writes the socket. Order is total — resize and
/// data frames share the one queue.
write_mutex: std.Thread.Mutex = .{},
write_cond: std.Thread.Condition = .{},
write_buf: std.ArrayListUnmanaged(u8) = .{},
write_closed: bool = false,
write_thread: ?std.Thread = null,

/// Transport receipts only: no terminal contents or keystrokes.
transport_state: std.atomic.Value(u8) = .init(0),
pending_bytes: std.atomic.Value(u64) = .init(0),
written_bytes: std.atomic.Value(u64) = .init(0),

pub const TransportStatus = extern struct {
    state: u8, // 0 connecting, 1 stream open, 2 disconnected
    pending_bytes: u64,
    written_bytes: u64,
};

pub fn transportStatus(self: *const Attach) TransportStatus {
    return .{
        .state = self.transport_state.load(.acquire),
        .pending_bytes = self.pending_bytes.load(.monotonic),
        .written_bytes = self.written_bytes.load(.monotonic),
    };
}

pub const Config = struct {
    id: []const u8,
    cwd: ?[]const u8 = null,
    session: ?[]const u8 = null,
    command: ?configpkg.Command = null,
    host: ?[]const u8 = null,
    /// A pre-connected stream (the embedder's transport); overrides both
    /// the local socket and ssh.
    fd: ?posix.fd_t = null,
    explicit_claim: bool = false,
};

pub fn init(alloc: Allocator, cfg: Config) !Attach {
    return .{
        .alloc = alloc,
        .id = try alloc.dupe(u8, cfg.id),
        .cwd = if (cfg.cwd) |v| try alloc.dupe(u8, v) else null,
        .session = if (cfg.session) |v| try alloc.dupe(u8, v) else null,
        .command = if (cfg.command) |v| try v.clone(alloc) else null,
        .host = if (cfg.host) |v| if (v.len > 0) try alloc.dupe(u8, v) else null else null,
        .given_fd = cfg.fd,
        .explicit_claim = cfg.explicit_claim or (if (cfg.host) |host| host.len > 0 else false),
        .client_id = std.crypto.random.int(u64),
    };
}

pub fn deinit(self: *Attach) void {
    self.alloc.free(self.id);
    if (self.cwd) |v| self.alloc.free(v);
    if (self.session) |v| self.alloc.free(v);
    if (self.command) |v| v.deinit(self.alloc);
    if (self.host) |v| self.alloc.free(v);
    if (self.cached_tty) |v| self.alloc.free(v);
    self.write_buf.deinit(self.alloc);
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
    // Never inherited by spawned daemons: a leaked attach fd in a sibling
    // daemon holds this connection open past its owner, so the daemon
    // never sees EOF and EOF-driven detach detection silently breaks.
    _ = try posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
    var addr: std.net.Address = try .initUnix(path);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

/// The remote transport: `ssh <host> vigild proxy <id>` as a child, its
/// stdout our read fd, its stdin our write fd. Everything about the
/// network (LAN, tailnet, jump host, keys) is the user's ssh config.
/// `vigild` must be on the remote's non-interactive PATH; a missing
/// binary surfaces as the child's immediate EOF (a failed launch).
fn connectSSH(self: *Attach, host: []const u8) !void {
    const argv = [_][]const u8{ "/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-T", host, "vigild", "proxy", self.id };
    var child = std.process.Child.init(&argv, self.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdin = child.stdin.?;
    const stdout = child.stdout.?;
    // Never inherited by anything we spawn later.
    _ = try posix.fcntl(stdin.handle, posix.F.SETFD, posix.FD_CLOEXEC);
    const flags = try posix.fcntl(stdin.handle, posix.F.GETFL, 0);
    _ = try posix.fcntl(stdin.handle, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    _ = try posix.fcntl(stdout.handle, posix.F.SETFD, posix.FD_CLOEXEC);
    self.sock_fd = stdout.handle;
    self.write_fd = stdin.handle;
    self.ssh_pid = child.id;
    log.info("attach: remote {s} via ssh {s} (pid {d})", .{ self.id, host, child.id });
}

/// Cut the stream so the reader sees EOF: shutdown for a socket, kill
/// the ssh child for a pipe (a pipe cannot be shut down).
fn sever(self: *Attach) void {
    self.transport_state.store(2, .release);
    if (self.ssh_pid != 0) {
        posix.kill(self.ssh_pid, posix.SIG.TERM) catch {};
        return;
    }
    if (self.sock_fd >= 0) posix.shutdown(self.sock_fd, .both) catch {};
}

/// Hello: who this client is, for the daemon's receipts.
fn sendHello(self: *Attach, kind: []const u8) void {
    var buf: [64]u8 = undefined;
    // "mirror" tells the daemon this client never adopts the size unowned:
    // it renders whatever grid the owner has and claims only explicitly.
    const hello = std.fmt.bufPrint(&buf, "{s} ghostty:{d}/{x}{s}", .{ kind, std.c.getpid(), self.client_id, if (self.explicit_claim) " mirror" else "" }) catch return;
    self.enqueueFrame('h', hello);
}

/// Spawn `vigild new <id> [-c cmd | -- argv]` to bring the daemon up. No
/// command = the daemon's login shell; a command is the daemon's CHILD
/// (`<login shell> -lc` for a shell string, verbatim for `direct:` argv),
/// so the spec records it and `vigild restore` respawns it after a reboot.
/// Env carries VIGIL_SESSION so claude hooks feed the attention queue
/// from birth.
fn spawnDaemon(self: *Attach) !void {
    var env = try internal_os.getEnvMap(self.alloc);
    defer env.deinit();
    // The surface config's env does NOT flow here by itself (this is the
    // APP's environment): anything the daemon must inherit is plumbed
    // explicitly. Program-state resurrection is NOT plumbed: the daemon
    // reads its own `<id>.resume`, so it works on every spawn path.
    if (self.session) |s| try env.put("VIGIL_SESSION", s);

    const home = posix.getenv("HOME") orelse return error.NoHome;
    const bin = try std.fmt.allocPrint(self.alloc, "{s}/.local/bin/vigild", .{home});
    defer self.alloc.free(bin);

    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(self.alloc);
    try argv.appendSlice(self.alloc, &.{ bin, "new", self.id });
    if (self.command) |cmd| switch (cmd) {
        // The daemon picks the login shell for a shell string (it owns
        // shell identity; /bin/sh -l never sees a fish login's PATH).
        .shell => |v| try argv.appendSlice(self.alloc, &.{ "-c", v }),
        .direct => |v| {
            try argv.append(self.alloc, "--");
            for (v) |arg| try argv.append(self.alloc, arg);
        },
    };

    var child = std.process.Child.init(argv.items, self.alloc);
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
    errdefer self.transport_state.store(2, .release);

    // Attach: locally, creating the daemon on first contact; remotely,
    // through an ssh child (never creating anything).
    if (self.given_fd) |given| {
        self.sock_fd = given;
        self.write_fd = given;
        log.info("attach: {s} on a given fd {d}", .{ self.id, given });
    } else if (self.host) |host| {
        try self.connectSSH(host);
    } else {
        const fd = self.connectSock() catch fd: {
            try self.spawnDaemon();
            break :fd try self.connectSock();
        };
        self.sock_fd = fd;
        self.write_fd = fd;
    }
    const fd = self.sock_fd;
    errdefer {
        posix.close(fd);
        if (self.write_fd != fd) posix.close(self.write_fd);
        self.sock_fd = -1;
        self.write_fd = -1;
    }

    // The writer: sole owner of stream writes. Born before the first
    // frame so nothing ever writes inline.
    self.write_closed = false;
    const write_thread = try std.Thread.spawn(.{}, writeThreadMain, .{self});
    write_thread.setName("io-writer") catch {};
    self.write_thread = write_thread;

    // Hello, then our size. The size is RECORDED by the daemon; it is
    // applied to the pty only while this client owns the size (claimed
    // on focus, or adopted when nobody owns it yet).
    self.sendHello(if (self.given_fd != null) "app" else if (self.host != null) "remote" else "surface");
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
        .{ self, fd, io, pipe[0], closing, std.time.milliTimestamp() },
    );
    read_thread.setName("io-reader") catch {};
    _ = self.transport_state.cmpxchgStrong(0, 1, .release, .monotonic);

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
    self.transport_state.store(2, .release);

    _ = posix.write(attach.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };
    self.sever();
    attach.read_thread.join();
    // The writer: close the queue, wake it, join BEFORE the fd closes (a
    // writer blocked in POLLOUT sees the sever as writable-then-EPIPE
    // and severs its way out; it must never touch a closed fd).
    self.write_mutex.lock();
    self.write_closed = true;
    self.write_cond.signal();
    self.write_mutex.unlock();
    if (self.write_thread) |t| {
        t.join();
        self.write_thread = null;
    }
    // The read thread's CURRENT socket, never the one recorded at enter: a
    // reconnect replaced it, and the number may be another surface's by now.
    if (self.write_fd != self.sock_fd and self.write_fd >= 0) posix.close(self.write_fd);
    if (self.sock_fd >= 0) posix.close(self.sock_fd);
    if (self.ssh_pid != 0) {
        _ = posix.waitpid(self.ssh_pid, 0);
        self.ssh_pid = 0;
    }
    self.sock_fd = -1;
    self.write_fd = -1;
}

/// The ownership chokepoint: the focused surface is the one being looked
/// at, so it claims the pty size ('o'). Presence beats attention, applied
/// to the grid: a mirror, a remote viewport or a silently materialized
/// tab records its size and gets it applied only when focused. A
/// viewport whose focus is not a sizing fact (`explicit_claim`: the phone
/// mirroring the Mac's grid) never claims here; it claims and yields
/// through `vigilClaim` alone.
pub fn focusGained(
    self: *Attach,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = td;
    if (!focused or self.explicit_claim or self.write_fd < 0) return;
    self.enqueueFrame('o', "");
}

/// Explicit ownership: 'o' claims the pty size for this client, 'y'
/// yields it (the daemon hands the size to the first sized survivor).
pub fn vigilClaim(self: *Attach, claim: bool) void {
    if (self.write_fd < 0) return;
    self.enqueueFrame(if (claim) 'o' else 'y', if (claim) "intent" else "");
}

test "Vigil remote focus cannot claim; only input intent can" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test", .host = "m4" });
    defer attach.deinit();
    attach.write_fd = 1; // Inspect the queue; no writer is started.
    var td: termio.Termio.ThreadData = undefined;
    try attach.focusGained(&td, true);
    try std.testing.expectEqual(@as(usize, 0), attach.write_buf.items.len);
    attach.vigilClaim(true);
    attach.vigilClaim(false);
    try std.testing.expectEqualSlices(u8, "o\x06\x00intenty\x00\x00", attach.write_buf.items);
}

test "Vigil phone focus cannot claim and hello identifies a mirror" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test", .fd = 1, .explicit_claim = true });
    defer attach.deinit();
    attach.write_fd = 1;
    var td: termio.Termio.ThreadData = undefined;
    try attach.focusGained(&td, true);
    try std.testing.expectEqual(@as(usize, 0), attach.write_buf.items.len);
    attach.sendHello("app");
    try std.testing.expect(std.mem.endsWith(u8, attach.write_buf.items, " mirror"));
    try std.testing.expect(std.mem.indexOfScalar(u8, attach.write_buf.items, '/') != null);
}

test "Vigil local focus remains an implicit claim" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test" });
    defer attach.deinit();
    attach.write_fd = 1;
    var td: termio.Termio.ThreadData = undefined;
    try attach.focusGained(&td, false);
    try attach.focusGained(&td, true);
    try std.testing.expectEqualSlices(u8, "o\x00\x00", attach.write_buf.items);
}

test "Vigil transport receipts count queued and written frames without contents" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test", .host = "m4" });
    defer attach.deinit();
    attach.write_fd = pipe[1];
    attach.enqueueFrame('d', "abc");
    try std.testing.expectEqual(@as(u64, 6), attach.transportStatus().pending_bytes);
    try std.testing.expect(attach.writeAll(attach.write_buf.items));
    try std.testing.expectEqual(@as(u64, 0), attach.transportStatus().pending_bytes);
    try std.testing.expectEqual(@as(u64, 6), attach.transportStatus().written_bytes);
    var frame: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try posix.read(pipe[0], &frame));
    try std.testing.expectEqualSlices(u8, "d\x03\x00abc", &frame);
    attach.sever();
    try std.testing.expectEqual(@as(u8, 2), attach.transportStatus().state);
}

/// 'q': the daemon re-sends the exact screen over a clear.
pub fn vigilDump(self: *Attach) void {
    if (self.write_fd < 0) return;
    self.enqueueFrame('q', "");
}

/// Runs ONLY on the writer thread. Blocking on POLLOUT here is the whole
/// design: this thread exists to absorb the stall the io thread must
/// never feel. Returns false when the stream was severed.
fn writeAll(self: *Attach, data: []const u8) bool {
    const fd = self.write_fd;
    var off: usize = 0;
    while (off < data.len) {
        const n = posix.write(fd, data[off..]) catch |err| switch (err) {
            error.WouldBlock => {
                // A drain stall is survivable for as long as the queue
                // holds (a TUI chewing a storm reads slowly, not never).
                // A full 10s with ZERO progress means the stream is dead
                // — sever it rather than leave a half-written frame.
                var pfds = [1]posix.pollfd{.{
                    .fd = fd,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                const ready = posix.poll(&pfds, 10_000) catch 0;
                if (ready == 0) {
                    log.warn("attach write stalled 10s -> sever", .{});
                    self.sever();
                    return false;
                }
                continue;
            },
            else => {
                log.warn("attach write failed err={} -> sever", .{err});
                self.sever();
                return false;
            },
        };
        if (n == 0) {
            self.sever();
            return false;
        }
        _ = self.written_bytes.fetchAdd(n, .monotonic);
        _ = self.pending_bytes.fetchSub(n, .monotonic);
        off += n;
    }
    return true;
}

/// Queue one whole frame (header + payload contiguous, order total).
/// Never blocks beyond the mutex. A queue past 4MB means the daemon
/// stopped draining for real: sever loudly rather than grow forever.
fn enqueueFrame(self: *Attach, typ: u8, payload: []const u8) void {
    assert(payload.len <= 0xffff);
    self.write_mutex.lock();
    defer self.write_mutex.unlock();
    if (self.write_closed) return;
    if (self.write_buf.items.len > 4 << 20) {
        log.warn("attach write queue past 4MB -> sever", .{});
        self.sever();
        self.write_closed = true;
        self.write_cond.signal();
        return;
    }
    const hdr: [3]u8 = .{
        typ,
        @intCast(payload.len & 0xff),
        @intCast((payload.len >> 8) & 0xff),
    };
    self.write_buf.ensureUnusedCapacity(self.alloc, hdr.len + payload.len) catch {
        self.sever();
        self.write_closed = true;
        self.write_cond.signal();
        return;
    };
    self.write_buf.appendSliceAssumeCapacity(&hdr);
    self.write_buf.appendSliceAssumeCapacity(payload);
    _ = self.pending_bytes.fetchAdd(hdr.len + payload.len, .monotonic);
    self.write_cond.signal();
}

fn writeThreadMain(self: *Attach) void {
    var local: std.ArrayListUnmanaged(u8) = .{};
    defer local.deinit(self.alloc);
    while (true) {
        self.write_mutex.lock();
        while (self.write_buf.items.len == 0 and !self.write_closed) {
            self.write_cond.wait(&self.write_mutex);
        }
        if (self.write_buf.items.len == 0) {
            // Closed and drained: done.
            self.write_mutex.unlock();
            return;
        }
        // Swap and drain OUTSIDE the lock: enqueue never waits on a write.
        std.mem.swap(std.ArrayListUnmanaged(u8), &local, &self.write_buf);
        self.write_mutex.unlock();

        if (!self.writeAll(local.items)) {
            // Severed: everything still queued is dead bytes.
            self.write_mutex.lock();
            self.write_closed = true;
            self.write_buf.clearAndFree(self.alloc);
            self.write_mutex.unlock();
            return;
        }
        local.clearRetainingCapacity();
    }
}

fn sendResize(self: *Attach) void {
    if (self.write_fd < 0) return;
    const rows: u16 = @intCast(self.grid_size.rows);
    const cols: u16 = @intCast(self.grid_size.columns);
    const payload: [4]u8 = .{
        @intCast(rows & 0xff), @intCast((rows >> 8) & 0xff),
        @intCast(cols & 0xff), @intCast((cols >> 8) & 0xff),
    };
    self.enqueueFrame('r', &payload);
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
    if (self.write_fd < 0) return;

    if (!linefeed) {
        var i: usize = 0;
        while (i < data.len) {
            const end = @min(data.len, i + 0xffff);
            self.enqueueFrame('d', data[i..end]);
            i = end;
        }
        return;
    }

    // Linefeed mode: \r becomes \r\n (bracketed paste path).
    var buf: [512]u8 = undefined;
    var buf_i: usize = 0;
    for (data) |ch| {
        if (buf_i >= buf.len - 1) {
            self.enqueueFrame('d', buf[0..buf_i]);
            buf_i = 0;
        }
        buf[buf_i] = ch;
        buf_i += 1;
        if (ch == '\r') {
            buf[buf_i] = '\n';
            buf_i += 1;
        }
    }
    if (buf_i > 0) self.enqueueFrame('d', buf[0..buf_i]);
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
/// ended under us (shell `exit`, external `vigild kill`, crash): tell the
/// surface so it closes instead of freezing mute. runtime_ms carries the
/// attach's TRUE age: the surface treats a sub-threshold exit as a failed
/// launch (correct for a spawn that dies on contact) and anything older as
/// a normal process exit, so a shell `exit` closes the pane exactly like
/// vanilla ghostty instead of wearing the failed-to-launch screen.
fn readThreadMain(
    self: *Attach,
    fd: posix.fd_t,
    io: *termio.Termio,
    quit: posix.fd_t,
    closing: *std.atomic.Value(bool),
    birth_ms: i64,
) void {
    // Exec's loop closes the quit descriptor it is given on return; each
    // stream gets a dup, and the pipe itself (its bytes shared by every
    // dup, so a quit written mid-reconnect is still readable) lives as
    // long as this thread.
    defer posix.close(quit);
    var current_fd = fd;
    while (true) {
        const quit_dup = posix.dup(quit) catch |err| {
            log.err("attach: {s} cannot dup the quit pipe err={}", .{ self.id, err });
            return;
        };
        termio.Exec.ReadThread.threadMainPosix(current_fd, io, quit_dup);
        if (closing.load(.acquire)) return;
        self.transport_state.store(2, .release);
        // SSH EOF says nothing about the home process. Keep its last screen;
        // the Mac viewport shows connection loss and offers an explicit reconnect.
        if (self.host != null) return;
        // The phone's stream is the embedder's; it reconnects on its own.
        if (self.given_fd != null) break;
        // A local daemon ended under a live surface. Its spec decides what
        // that meant: a deliberate end (shell exit, `vigild kill`) unlinks
        // the spec before the socket goes, a machine-death class end (a
        // logout's SIGTERM, a crash, a kill by hand) leaves it, and then the
        // daemon comes back under the same id: reattach in place, never
        // paint the exit overlay (the sentinel's view was lost to it,
        // 2026-09-15). The quit pipe stays armed throughout, so a teardown
        // mid-reconnect returns at the next check.
        current_fd = self.reconnect(closing) orelse break;
    }
    // NEVER a blocking push: a surface mid-release drains no mailbox, and
    // a .forever push parks this thread exactly when threadExit is about
    // to join it — reader waits on the mailbox futex, the io thread waits
    // on the reader, the main thread waits on the io thread: the whole
    // app wedges (sampled live 2026-08-03). A dropped child_exited on a
    // dying surface costs nothing; a live surface's mailbox has room.
    const pushed = io.surface_mailbox.push(.{
        .child_exited = .{
            .exit_code = 1,
            .runtime_ms = @intCast(@max(0, std.time.milliTimestamp() - birth_ms)),
        },
    }, .{ .instant = {} });
    if (pushed == 0) log.warn("attach child_exited dropped (mailbox full or dying)", .{});
}

fn specExists(self: *Attach) bool {
    const home = posix.getenv("HOME") orelse return false;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.local/state/vigild/{s}.spec", .{ home, self.id }) catch return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// `vigild restore`: every spec with no live daemon respawns, exactly what
/// the login agent and the app's launch do. Under a running app nobody
/// else respawns a daemon that died, so the surface that lost it does.
fn restoreDaemons(self: *Attach) void {
    const home = posix.getenv("HOME") orelse return;
    const bin = std.fmt.allocPrint(self.alloc, "{s}/.local/bin/vigild", .{home}) catch return;
    defer self.alloc.free(bin);
    var child = std.process.Child.init(&.{ bin, "restore" }, self.alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch |err| log.warn("attach: {s} vigild restore failed err={}", .{ self.id, err });
}

/// Runs on the read thread after EOF. Returns the new socket, wired into
/// this Attach with a fresh writer, hello and size (the daemon replays its
/// screen to a fresh client over a clear, so nothing else is owed); null
/// when the end was deliberate, the teardown began, or the daemon never
/// came back within the window.
fn reconnect(self: *Attach, closing: *std.atomic.Value(bool)) ?posix.fd_t {
    if (!self.specExists()) return null;
    log.warn("attach: {s} stream ended with its spec on disk; reconnecting", .{self.id});
    self.transport_state.store(0, .release);
    // Retire the writer (it may have severed itself on the dead socket
    // already) before the descriptor closes; a new one is born per socket.
    self.write_mutex.lock();
    self.write_closed = true;
    self.write_cond.signal();
    self.write_mutex.unlock();
    if (self.write_thread) |t| {
        t.join();
        self.write_thread = null;
    }
    const old = self.sock_fd;
    self.sock_fd = -1;
    self.write_fd = -1;
    if (old >= 0) posix.close(old);

    const began = std.time.milliTimestamp();
    var restored = false;
    while (std.time.milliTimestamp() - began < 30_000) {
        if (closing.load(.acquire)) return null;
        if (self.connectSock()) |nfd| {
            self.write_mutex.lock();
            self.write_closed = false;
            self.write_buf.clearRetainingCapacity();
            self.pending_bytes.store(0, .monotonic);
            self.write_mutex.unlock();
            const t = std.Thread.spawn(.{}, writeThreadMain, .{self}) catch |err| {
                log.warn("attach: {s} reconnect writer failed err={}", .{ self.id, err });
                posix.close(nfd);
                return null;
            };
            t.setName("io-writer") catch {};
            self.write_thread = t;
            self.sock_fd = nfd;
            self.write_fd = nfd;
            self.sendHello("surface");
            self.sendResize();
            self.transport_state.store(1, .release);
            // warn, not info: the receipt must reach the unified log in a
            // release build; "I saw no overlay" is not a fact.
            log.warn("attach: {s} reattached in place after {d}ms", .{ self.id, std.time.milliTimestamp() - began });
            return nfd;
        } else |_| {}
        if (!self.specExists()) {
            log.info("attach: {s} spec gone while reconnecting; a deliberate end", .{self.id});
            return null;
        }
        // One beat for a respawn already in flight (the login agent, the
        // app's launch restore); then respawn it from here.
        if (!restored and std.time.milliTimestamp() - began >= 1_000) {
            restored = true;
            self.restoreDaemons();
        }
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    log.warn("attach: {s} daemon did not come back in 30s", .{self.id});
    return null;
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
