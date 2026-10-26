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
//! on a slow drain wedges the ENTIRE APP: a scroll storm (mouse-mode
//! reports) outruns the ~8KB sndbuf while the program redraws slowly,
//! the io mailbox fills behind the stuck thread, and the main thread
//! blocks pushing a focus message.
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

/// VIGIL_WORKSPACE value for the daemon's environment on create.
session: ?[]const u8,

/// The program the daemon runs as its child on create (a session API
/// birth: `vigil new -- claude`). null = the daemon's login shell. Never
/// typed into a shell: it IS the child, recorded in the daemon's spec, so
/// it survives detach, quit and reboot like the shell does.
command: ?configpkg.Command,

/// The Mac that owns the daemon, by its tether root; null = local. Remote =
/// this Mac's vigil hub (vigil-agent's local socket) opening `proxy` on
/// that Mac over tether: one socket, read and written like a local one.
/// The daemon is never spawned remotely.
host: ?[]const u8,

/// A stream handed in already connected (iOS: a socketpair end the app
/// bridges to a tether stream). The transport is the embedder's; this
/// backend only speaks frames on whatever fd it is given.
given_fd: ?posix.fd_t,

/// Ownership policy: false = focus claims the pty size (a Mac surface,
/// presence beats attention); true = only `vigilClaim` does.
explicit_claim: bool,

/// Per-connection identity. A pid alone aliases different views in one app
/// and can also collide between Macs. Published in the daemon's owner hello.
client_id: u64,

alloc: Allocator,

/// Read side: the socket; -1 until threadEnter.
sock_fd: posix.fd_t = -1,
/// Write side: the same socket (a given fd may be one too).
write_fd: posix.fd_t = -1,

/// A hub dial waiting for its answer (a remote pane being dialed again):
/// teardown shuts it down so the read thread it blocks returns at once.
/// Set and cleared under the mutex, cleared before the descriptor closes,
/// so a shutdown never reaches a reused number.
dialing_mutex: std.Thread.Mutex = .{},
dialing_fd: posix.fd_t = -1,

/// Cached tty name of the daemon's pty (from its pidfile).
cached_tty: ?[:0]const u8 = null,

/// Last known size, sent on change once `viewport` is true.
grid_size: renderer.GridSize = .{ .columns = 80, .rows = 24 },

/// The embedder has declared the grid real (`vigilViewport`). Until then
/// the grid is the core's guess from the view's placeholder frame (800x600
/// at birth, 49x17 cells): sent to the daemon and claimed on focus, it
/// resized a live TUI to that guess on every mount and the program
/// reflowed its transcript into 49 columns. A size is never sent and focus
/// never claims before this, for every kind of viewport: the daemon replays
/// its screen on a client's first size, so a size sent before layout (the
/// phone's, born explicit-claim, once did) paints the screen into a guessed
/// grid whose wrapped lines never unwrap.
viewport: bool = false,

/// Focus arrived before the viewport: the passive claim waits for it.
focus_pending: bool = false,

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
/// The writer is waiting on the peer to drain (a write would block), until
/// the queue is empty again: input typed is not reaching the program yet.
stalled: std.atomic.Value(bool) = .init(false),

/// The surface's mailbox while its io thread runs: every transport change
/// (stream open or lost, a stall begun or cleared) is pushed to it as
/// `vigil_transport`, and the embedder reads `transportStatus` then.
/// Deliberate teardown reports nothing.
mailbox: ?@FieldType(termio.Termio, "surface_mailbox") = null,

pub const TransportStatus = extern struct {
    state: u8, // 0 connecting, 1 stream open, 2 disconnected
    pending_bytes: u64,
    written_bytes: u64,
    stalled: bool,
};

pub fn transportStatus(self: *const Attach) TransportStatus {
    return .{
        .state = self.transport_state.load(.acquire),
        .pending_bytes = self.pending_bytes.load(.monotonic),
        .written_bytes = self.written_bytes.load(.monotonic),
        .stalled = self.stalled.load(.acquire),
    };
}

fn setTransport(self: *Attach, state: u8) void {
    if (self.transport_state.swap(state, .acq_rel) != state) self.reportTransport();
}

fn setStalled(self: *Attach, stalled: bool) void {
    if (self.stalled.swap(stalled, .acq_rel) != stalled) self.reportTransport();
}

/// Never blocks (the mailbox drops rather than park a worker thread).
fn reportTransport(self: *Attach) void {
    // Tests run on apprt `none`, whose app has no mailbox wakeup to compile against.
    if (comptime builtin.is_test) return;
    const mailbox = self.mailbox orelse return;
    _ = mailbox.push(.{ .vigil_transport = {} }, .{ .instant = {} });
}

pub const Config = struct {
    id: []const u8,
    cwd: ?[]const u8 = null,
    session: ?[]const u8 = null,
    command: ?configpkg.Command = null,
    host: ?[]const u8 = null,
    /// A pre-connected stream (the embedder's transport); overrides both
    /// the local socket and the hub.
    fd: ?posix.fd_t = null,
    explicit_claim: bool = false,
};

pub fn init(alloc: Allocator, cfg: Config) !Attach {
    const explicit_claim = cfg.explicit_claim or (if (cfg.host) |host| host.len > 0 else false);
    return .{
        .alloc = alloc,
        .id = try alloc.dupe(u8, cfg.id),
        .cwd = if (cfg.cwd) |v| try alloc.dupe(u8, v) else null,
        .session = if (cfg.session) |v| try alloc.dupe(u8, v) else null,
        .command = if (cfg.command) |v| try v.clone(alloc) else null,
        .host = if (cfg.host) |v| if (v.len > 0) try alloc.dupe(u8, v) else null else null,
        .given_fd = cfg.fd,
        .explicit_claim = explicit_claim,
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
    return std.fmt.bufPrint(buf, "{s}/.local/state/vigil/panes/{s}.sock", .{ home, self.id });
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

/// The remote transport: this Mac's vigil hub (vigil-agent, VigilWire's
/// `Local`), which opens `proxy <id>` on the owning Mac over tether. One
/// request line, one Ack line read byte by byte (what follows is the
/// stream's), then the socket IS the remote stream. The hub answers this
/// app alone (code signature), and pairing is the only grant across Macs.
fn connectHub(self: *Attach, host: []const u8) !posix.fd_t {
    // Both are vigil-minted (a hex tether root, a pane id): never quoted.
    for (host) |c| if (!std.ascii.isAlphanumeric(c)) return error.InvalidHost;
    for (self.id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidPane;

    var path_buf: [512]u8 = undefined;
    const path = try hubPath(&path_buf);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    // Runs before the errdefer close (defers unwind in reverse).
    self.setDialing(fd);
    defer self.setDialing(-1);
    // Teardown marks the transport closed before it severs: seen here, it
    // came before this dial was registered and would not cut it.
    if (self.transport_state.load(.acquire) == 2) return error.Closing;
    _ = try posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
    var addr: std.net.Address = try .initUnix(path);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    var req_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(&req_buf, "{{\"kind\":\"open\",\"device\":\"{s}\",\"open\":{{\"op\":\"proxy\",\"pane\":\"{s}\"}}}}\n", .{ host, self.id });
    var written: usize = 0;
    while (written < request.len) written += try posix.write(fd, request[written..]);

    var ack_buf: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (len == ack_buf.len) return error.HubAnswerTooLong;
        const n = try posix.read(fd, ack_buf[len .. len + 1]);
        if (n == 0) return error.HubClosed;
        if (ack_buf[len] == '\n') break;
        len += 1;
    }
    const Ack = struct { ok: bool, @"error": ?[]const u8 = null };
    const parsed = try std.json.parseFromSlice(Ack, self.alloc, ack_buf[0..len], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!parsed.value.ok) {
        log.warn("attach: remote {s} refused by the hub: {s}", .{ self.id, parsed.value.@"error" orelse "no reason" });
        return error.HubRefused;
    }
    log.info("attach: remote {s} on {s} through the hub", .{ self.id, host });
    return fd;
}

/// The hub's socket, as VigilWire's `VigilPaths.hub` names it
/// (`VIGIL_AGENT_STATE` moves it).
fn hubPath(buf: []u8) ![]const u8 {
    return if (posix.getenv("VIGIL_AGENT_STATE")) |root|
        try std.fmt.bufPrint(buf, "{s}/hub.sock", .{root})
    else
        try std.fmt.bufPrint(buf, "{s}/.local/state/vigil/agent/hub.sock", .{posix.getenv("HOME") orelse return error.NoHome});
}

fn setDialing(self: *Attach, fd: posix.fd_t) void {
    self.dialing_mutex.lock();
    defer self.dialing_mutex.unlock();
    self.dialing_fd = fd;
}

/// Cut the stream so the reader sees EOF, and a hub dial in flight with it.
fn sever(self: *Attach) void {
    self.setTransport(2);
    if (self.sock_fd >= 0) posix.shutdown(self.sock_fd, .both) catch {};
    self.dialing_mutex.lock();
    defer self.dialing_mutex.unlock();
    if (self.dialing_fd >= 0) posix.shutdown(self.dialing_fd, .both) catch {};
}

/// Hello: who this client is, for the daemon's receipts.
fn sendHello(self: *Attach, kind: []const u8) void {
    var buf: [64]u8 = undefined;
    // "mirror" tells the daemon this client never adopts the size unowned:
    // it renders whatever grid the owner has and claims only explicitly.
    const hello = std.fmt.bufPrint(&buf, "{s} ghostty:{d}/{x}{s}", .{ kind, std.c.getpid(), self.client_id, if (self.explicit_claim) " mirror" else "" }) catch return;
    self.enqueueFrame('h', hello);
}

/// Spawn `vigild new <id> [-c cmd | -- argv]` to bring the daemon up, this
/// app its birth authority (`birth`). No
/// command = the daemon's login shell; a command is the daemon's CHILD
/// (`<login shell> -lc` for a shell string, verbatim for `direct:` argv),
/// so the spec records it and `vigild restore` respawns it after a reboot.
/// Env carries VIGIL_WORKSPACE so claude hooks feed the attention queue
/// from birth.
fn spawnDaemon(self: *Attach) !void {
    var env = try internal_os.getEnvMap(self.alloc);
    defer env.deinit();
    // The surface config's env does NOT flow here by itself (this is the
    // APP's environment): anything the daemon must inherit is plumbed
    // explicitly. Program-state resurrection is NOT plumbed: the daemon
    // reads its own `<id>.resume`, so it works on every spawn path.
    if (self.session) |s| try env.put("VIGIL_WORKSPACE", s);

    const home = posix.getenv("HOME") orelse return error.NoHome;
    const bin = try std.fmt.allocPrint(self.alloc, "{s}/.local/bin/vigild", .{home});
    defer self.alloc.free(bin);

    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer argv.deinit(self.alloc);
    try argv.appendSlice(self.alloc, &.{ bin, "new", self.id });
    // The folder is vigild's to resolve (a missing one falls back to its
    // nearest existing parent): a spawn in a folder that is gone fails.
    if (self.cwd) |cwd| try argv.appendSlice(self.alloc, &.{ "--cwd", cwd });
    if (self.command) |cmd| switch (cmd) {
        // The daemon picks the login shell for a shell string (it owns
        // shell identity; /bin/sh -l never sees a fish login's PATH).
        .shell => |v| try argv.appendSlice(self.alloc, &.{ "-c", v }),
        .direct => |v| {
            try argv.append(self.alloc, "--");
            for (v) |arg| try argv.append(self.alloc, arg);
        },
    };

    // The app is the birth's authority (`birth`): vigild alone may create
    // no pane.
    if (try birth(self.alloc, argv.items, &env) != 0) return error.DaemonSpawnFailed;
}

pub fn threadEnter(
    self: *Attach,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    // Set before any thread that reports is born; never changes after.
    self.mailbox = io.surface_mailbox;
    errdefer self.setTransport(2);

    // Attach: locally, creating the daemon on first contact; remotely,
    // through this Mac's hub (never creating anything).
    if (self.given_fd) |given| {
        self.sock_fd = given;
        self.write_fd = given;
        log.info("attach: {s} on a given fd {d}", .{ self.id, given });
    } else if (self.host) |host| {
        const fd = try self.connectHub(host);
        self.sock_fd = fd;
        self.write_fd = fd;
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

    // Hello, then our size once it is real. The size is RECORDED by the
    // daemon; it is applied to the pty only while this client owns the
    // size (claimed on focus, or adopted when nobody owns it yet).
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
    if (self.transport_state.cmpxchgStrong(0, 1, .release, .monotonic) == null) self.reportTransport();

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
    if (self.explicit_claim) return;
    self.focus_pending = focused and !self.viewport;
    if (!focused or !self.viewport or self.write_fd < 0) return;
    self.enqueueFrame('o', "");
}

/// The embedder's grid is real: send it (the daemon answers a client's
/// first size with its screen, so the replay lands in this grid), then
/// any focus claim that arrived before it.
pub fn vigilViewport(self: *Attach) void {
    if (self.viewport) return;
    self.viewport = true;
    self.sendResize();
    if (self.write_fd < 0) return;
    if (self.focus_pending) self.enqueueFrame('o', "");
    self.focus_pending = false;
}

/// Explicit ownership: 'o' claims the pty size for this client, 'y'
/// yields it (the daemon hands the size to the first sized survivor).
/// The embedder claims only with a laid-out grid, so a claim declares
/// the viewport too.
pub fn vigilClaim(self: *Attach, claim: bool) void {
    if (self.write_fd < 0) return;
    if (claim and !self.viewport) {
        self.viewport = true;
        self.focus_pending = false;
        self.sendResize();
    }
    self.enqueueFrame(if (claim) 'o' else 'y', if (claim) "intent" else "");
}

test "Vigil remote focus cannot claim; only input intent can" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test", .host = "19a204d11b9198077eb1feb2eae429bf81d6d269df9b790ed38bdcc4035fcaa5" });
    defer attach.deinit();
    attach.write_fd = 1; // Inspect the queue; no writer is started.
    var td: termio.Termio.ThreadData = undefined;
    try attach.focusGained(&td, true);
    try std.testing.expectEqual(@as(usize, 0), attach.write_buf.items.len);
    // A claim declares the viewport: its size first, then the claim.
    attach.vigilClaim(true);
    attach.vigilClaim(false);
    try std.testing.expectEqualSlices(u8, "r\x04\x00\x18\x00\x50\x00o\x06\x00intenty\x00\x00", attach.write_buf.items);
}

test "Vigil phone mirror sends no size before its viewport is laid out" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test", .fd = 1, .explicit_claim = true });
    defer attach.deinit();
    attach.write_fd = 1;
    // Born in a placeholder frame: its guessed grid is never sent (the
    // daemon would replay the screen into it).
    try attach.resize(.{ .columns = 49, .rows = 17 }, undefined);
    try std.testing.expectEqual(@as(usize, 0), attach.write_buf.items.len);
    try attach.resize(.{ .columns = 120, .rows = 40 }, undefined);
    attach.vigilViewport();
    try std.testing.expectEqualSlices(u8, "r\x04\x00\x28\x00\x78\x00", attach.write_buf.items);
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
    attach.vigilViewport();
    attach.write_buf.clearRetainingCapacity();
    var td: termio.Termio.ThreadData = undefined;
    try attach.focusGained(&td, false);
    try attach.focusGained(&td, true);
    try std.testing.expectEqualSlices(u8, "o\x00\x00", attach.write_buf.items);
}

test "Vigil local surface sends no size and claims nothing before its viewport" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test" });
    defer attach.deinit();
    attach.write_fd = 1;
    var td: termio.Termio.ThreadData = undefined;
    // The placeholder frame's grid, then focus: both held.
    try attach.resize(.{ .columns = 49, .rows = 17 }, undefined);
    try attach.focusGained(&td, true);
    try std.testing.expectEqual(@as(usize, 0), attach.write_buf.items.len);
    // Layout lands: the real grid, then the claim focus asked for.
    try attach.resize(.{ .columns = 153, .rows = 53 }, undefined);
    attach.vigilViewport();
    try std.testing.expectEqualSlices(u8, "r\x04\x00\x35\x00\x99\x00o\x00\x00", attach.write_buf.items);
}

test "Vigil focus lost before the viewport leaves no pending claim" {
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test" });
    defer attach.deinit();
    attach.write_fd = 1;
    var td: termio.Termio.ThreadData = undefined;
    try attach.focusGained(&td, true);
    try attach.focusGained(&td, false);
    attach.vigilViewport();
    try std.testing.expectEqual(@as(u8, 'r'), attach.write_buf.items[0]);
    try std.testing.expectEqual(@as(usize, 7), attach.write_buf.items.len);
}

test "Vigil transport receipts count queued and written frames without contents" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);
    var attach = try Attach.init(std.testing.allocator, .{ .id = "test", .host = "19a204d11b9198077eb1feb2eae429bf81d6d269df9b790ed38bdcc4035fcaa5" });
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
                self.setStalled(true);
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
        if (self.pending_bytes.fetchSub(n, .monotonic) == n) self.setStalled(false);
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
    if (self.write_fd < 0 or !self.viewport) return;
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
    const path = std.fmt.bufPrint(&buf, "{s}/.local/state/vigil/panes/{s}.pid", .{ home, self.id }) catch return null;
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
        self.setTransport(2);
        // The phone's stream is the embedder's; it reconnects on its own.
        if (self.given_fd != null) break;
        // A local daemon ended under a live surface. Its spec decides what
        // that meant: a deliberate end (shell exit, `vigild kill`) unlinks
        // the spec before the socket goes, a machine-death class end (a
        // logout's SIGTERM, a crash, a kill by hand) leaves it, and then the
        // daemon comes back under the same id: reattach in place, never
        // paint the exit overlay over a live program. The quit pipe stays
        // armed throughout, so a teardown
        // mid-reconnect returns at the next check.
        current_fd = self.reconnect(closing) orelse {
            // A view torn down mid-redial is no ended program: told one,
            // the surface closes on the next key, and a released view that
            // kept first responder closed whatever tab was in front.
            if (closing.load(.acquire)) return;
            break;
        };
    }
    // NEVER a blocking push: a surface mid-release drains no mailbox, and
    // a .forever push parks this thread exactly when threadExit is about
    // to join it — reader waits on the mailbox futex, the io thread waits
    // on the reader, the main thread waits on the io thread: the whole
    // app wedges. A dropped child_exited on a
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
    const path = std.fmt.bufPrint(&buf, "{s}/.local/state/vigil/panes/{s}.spec", .{ home, self.id }) catch return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// `vigild restore <id>`: THIS pane respawns if its spec stands and no
/// daemon holds its lock. Under a running app nobody else respawns a
/// daemon that died, so the surface that lost it does, and only its own:
/// vigild serializes restores and a pane's lock admits one daemon, however
/// many surfaces ask at once.
fn restoreDaemons(self: *Attach) void {
    const home = posix.getenv("HOME") orelse return;
    const bin = std.fmt.allocPrint(self.alloc, "{s}/.local/bin/vigild", .{home}) catch return;
    defer self.alloc.free(bin);
    _ = birth(self.alloc, &.{ bin, "restore", self.id }, null) catch |err| log.warn("attach: {s} vigild restore failed err={}", .{ self.id, err });
}

extern "c" fn posix_spawn_file_actions_init(actions: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(actions: *?*anyopaque, fd: c_int, target: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addopen(actions: *?*anyopaque, fd: c_int, path: [*:0]const u8, flags: c_int, mode: std.c.mode_t) c_int;
extern "c" fn posix_spawn(pid: *posix.pid_t, path: [*:0]const u8, actions: *const ?*anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn socketpair(domain: c_int, kind: c_int, protocol: c_int, fds: *[2]c_int) c_int;

/// A daemon's birth question (`birth <id> <nonce> <spec> <old|-> <old
/// seal|-> <resume|-> <resume seal|->`, vigild's authorizeBirth) answered
/// through vigil-agent, the one holder of the pane key (VigilWire's
/// `Local.Request.vouch`; this app has no keychain group): `born <id>
/// <nonce> <seal>`, or `refused <id> <nonce> <why>` when it says no or does
/// not answer. Null for a line that is no question (the daemon then
/// refuses itself). Every word is checked to its alphabet first, so none
/// needs quoting in the request.
fn vouchBirth(alloc: Allocator, question: []const u8, out: []u8) ?[]const u8 {
    var words: [8][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, question, ' ');
    var count: usize = 0;
    while (it.next()) |word| : (count += 1) {
        if (count == words.len) return null;
        words[count] = word;
    }
    if (count != words.len or !std.mem.eql(u8, words[0], "birth")) return null;
    const id = words[1];
    const nonce = words[2];
    if (id.len == 0 or nonce.len != 16) return null;
    for (id) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return null;
    for (nonce) |ch| if (!std.ascii.isHex(ch)) return null;
    // Digests are 64 lowercase hex, seals 44 base64; "-" is none.
    for ([_]usize{ 3, 4, 6 }) |i| {
        if (i != 3 and std.mem.eql(u8, words[i], "-")) continue;
        if (words[i].len != 64) return null;
        for (words[i]) |ch| if (!(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'))) return null;
    }
    for ([_]usize{ 5, 7 }) |i| {
        if (std.mem.eql(u8, words[i], "-")) continue;
        if (words[i].len != 44) return null;
        for (words[i]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '/' or ch == '=')) return null;
    }

    const why: []const u8 = why: {
        var request = std.ArrayList(u8){};
        request.print(alloc, "{{\"kind\":\"vouch\",\"birth\":{{\"pane\":\"{s}\",\"spec\":\"{s}\"", .{ id, words[3] }) catch break :why "out of memory";
        const fields = [_]struct { name: []const u8, at: usize }{
            .{ .name = "old", .at = 4 },    .{ .name = "oldSeal", .at = 5 },
            .{ .name = "resume", .at = 6 }, .{ .name = "resumeSeal", .at = 7 },
        };
        for (fields) |field| {
            if (std.mem.eql(u8, words[field.at], "-")) continue;
            request.print(alloc, ",\"{s}\":\"{s}\"", .{ field.name, words[field.at] }) catch break :why "out of memory";
        }
        request.appendSlice(alloc, "}}\n") catch break :why "out of memory";

        var path_buf: [512]u8 = undefined;
        const path = hubPath(&path_buf) catch break :why "vigil-agent's hub has no path here";
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch break :why "no socket for vigil-agent's hub";
        defer posix.close(fd);
        _ = posix.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC) catch {};
        var addr = std.net.Address.initUnix(path) catch break :why "vigil-agent's hub has no address";
        posix.connect(fd, &addr.any, addr.getOsSockLen()) catch break :why "vigil-agent's hub does not answer (is vigil-agent running?)";
        var written: usize = 0;
        while (written < request.items.len) written += posix.write(fd, request.items[written..]) catch break :why "vigil-agent's hub did not take the question";

        var reply: [2048]u8 = undefined;
        var got: usize = 0;
        while (true) {
            if (got == reply.len) break :why "vigil-agent's hub answered too much";
            const n = posix.read(fd, reply[got .. got + 1]) catch break :why "vigil-agent's hub left";
            if (n == 0) break :why "vigil-agent's hub left";
            if (reply[got] == '\n') break;
            got += 1;
        }
        // CallResult: `output` is the seal's bytes, base64 again (JSON Data).
        const Reply = struct { ok: bool, output: ?[]const u8 = null, @"error": ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(Reply, alloc, reply[0..got], .{ .ignore_unknown_fields = true }) catch break :why "vigil-agent's hub answered something else";
        if (!parsed.value.ok) break :why (alloc.dupe(u8, parsed.value.@"error" orelse "vigil-agent refused it") catch "vigil-agent refused it");
        const encoded = parsed.value.output orelse break :why "vigil-agent answered with no seal";
        var seal: [64]u8 = undefined;
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch break :why "vigil-agent answered with no seal";
        if (size != 44) break :why "vigil-agent answered with no seal";
        std.base64.standard.Decoder.decode(seal[0..size], encoded) catch break :why "vigil-agent answered with no seal";
        return std.fmt.bufPrint(out, "born {s} {s} {s}\n", .{ id, nonce, seal[0..size] }) catch null;
    };
    // One line, within what the daemon reads.
    var said: [300]u8 = undefined;
    const why_len = @min(why.len, said.len);
    @memcpy(said[0..why_len], why[0..why_len]);
    for (said[0..why_len]) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    return std.fmt.bufPrint(out, "refused {s} {s} {s}\n", .{ id, nonce, said[0..why_len] }) catch null;
}

/// vigild `new`/`restore` with this app as their birth authority: a daemon
/// is born only for the Vigil app or vigil-agent (vigild's authorizeBirth,
/// judged by code signature). vigild's stdin is one end of a socketpair;
/// this process answers `born <id> <nonce>` on the other for every daemon
/// vigild spawns, until vigild and every daemon have let go of it, then
/// reaps vigild. Its exit code. posix_spawn, never fork: this is a
/// threaded process.
fn birth(alloc: Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap) !u8 {
    // Daemons live on a Mac; a phone's panes are always another device's.
    if (comptime builtin.os.tag != .macos) return error.Unsupported;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_z[i] = (try arena.dupeZ(u8, arg)).ptr;
    const envp: [*:null]const ?[*:0]const u8 = if (env) |map|
        (try std.process.createNullDelimitedEnvMap(arena, map)).ptr
    else
        @ptrCast(std.c.environ);

    var pair: [2]c_int = undefined;
    if (socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SocketPair;
    defer posix.close(pair[0]);
    // Both ends close-on-exec: dup2 onto stdin clears it for vigild's copy
    // alone, and no other child of this app ever holds either end.
    _ = try posix.fcntl(pair[0], posix.F.SETFD, posix.FD_CLOEXEC);
    _ = try posix.fcntl(pair[1], posix.F.SETFD, posix.FD_CLOEXEC);
    var actions: ?*anyopaque = null;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        posix.close(pair[1]);
        return error.SpawnActions;
    }
    defer _ = posix_spawn_file_actions_destroy(&actions);
    _ = posix_spawn_file_actions_adddup2(&actions, pair[1], 0);
    const write_only: c_int = @bitCast(posix.O{ .ACCMODE = .WRONLY });
    _ = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", write_only, 0);
    _ = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", write_only, 0);
    var pid: posix.pid_t = 0;
    const rc = posix_spawn(&pid, argv_z[0].?, &actions, null, argv_z.ptr, envp);
    posix.close(pair[1]);
    if (rc != 0) return error.SpawnFailed;

    var line: [1024]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = posix.read(pair[0], line[len .. len + 1]) catch break;
        if (n == 0) break;
        if (line[len] != '\n') {
            len += 1;
            if (len == line.len) break;
            continue;
        }
        const question = line[0..len];
        len = 0;
        var answer: [1024]u8 = undefined;
        const said = vouchBirth(arena, question, &answer) orelse continue;
        var written: usize = 0;
        while (written < said.len) written += posix.write(pair[0], said[written..]) catch break;
    }
    const waited = posix.waitpid(pid, 0);
    return if (posix.W.IFEXITED(waited.status)) posix.W.EXITSTATUS(waited.status) else 255;
}

/// Runs on the read thread after EOF. Returns the new socket, wired into
/// this Attach with a fresh writer, hello and size (the daemon replays its
/// screen to a fresh client over a clear, so nothing else is owed); null
/// when the end was deliberate, the teardown began, or the daemon never
/// came back within the window.
///
/// A local pane's deliberate end is its spec gone. A remote pane's truth
/// is its home Mac's directory, which this side does not read: when the
/// pane really ends it leaves the directory and the app closes this view
/// (teardown sets `closing`). Until then the stream is dialed again
/// through the hub, whatever ended it (the Mac asleep, its hub restarted,
/// this Mac's network), so a lost remote pane comes back by itself and
/// never waits on a button.
fn reconnect(self: *Attach, closing: *std.atomic.Value(bool)) ?posix.fd_t {
    if (self.given_fd != null) return null; // the embedder owns that transport
    if (self.host == null and !self.specExists()) return null;
    if (self.host) |host| {
        log.warn("attach: remote {s} on {s} stream ended; dialing it again through the hub", .{ self.id, host });
    } else {
        log.warn("attach: {s} stream ended with its spec on disk; reconnecting", .{self.id});
    }
    // Retire the writer (it may have severed itself on the dead socket
    // already) before the descriptor closes; a new one is born per socket.
    // Only then is the transport "connecting": a writer severing after it
    // would mark it closed, and every hub dial would refuse itself.
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
    self.setTransport(0);

    const began = std.time.milliTimestamp();
    var restored = false;
    // Remote: a pause that grows to 2 s between dials (a dial to a Mac out
    // of reach itself takes up to tether's 10 s to say so).
    var pause_ms: u64 = 200;
    while (self.host != null or std.time.milliTimestamp() - began < 30_000) {
        if (closing.load(.acquire)) return null;
        const dialed = if (self.host) |host| self.connectHub(host) else self.connectSock();
        if (dialed) |nfd| {
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
            self.sendHello(if (self.host != null) "remote" else "surface");
            self.sendResize();
            self.setTransport(1);
            // warn, not info: the receipt must reach the unified log in a
            // release build; "I saw no overlay" is not a fact.
            log.warn("attach: {s} reattached in place after {d}ms", .{ self.id, std.time.milliTimestamp() - began });
            return nfd;
        } else |err| if (self.host != null) {
            log.info("attach: remote {s} not reached yet ({}); again in {d}ms", .{ self.id, err, pause_ms });
            // In slices: teardown joins this thread and must not wait on it.
            var slept: u64 = 0;
            while (slept < pause_ms and !closing.load(.acquire)) : (slept += 50) std.Thread.sleep(50 * std.time.ns_per_ms);
            pause_ms = @min(pause_ms * 2, 2_000);
            continue;
        }
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
