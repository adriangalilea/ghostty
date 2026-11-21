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
const global = @import("../global.zig");
const compat_fd = @import("../lib/compat/fd.zig");
const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_attach);

/// The hub answers a dial within tether's 10 s verdict on a Mac out of
/// reach (CLAUDE.md, remote viewports); a hub silent past this is stuck.
const hub_answer_ms: i64 = 15_000;

/// Session daemon id (e.g. "vigil-myproject-0").
id: []const u8,

/// The folder the terminal starts out naming as its pwd, until the pane's
/// program reports its own.
cwd: ?[]const u8,

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

/// Guards every descriptor another thread may shut down: `dialing_fd`, and
/// `sock_fd`/`write_fd` while a reconnect replaces them. `sever` shuts
/// down under it and a descriptor is closed only under it, so a shutdown
/// never reaches a number already reused by another surface.
fd_mutex: std.Io.Mutex = .init,
/// A hub dial waiting for its answer (a remote pane being dialed again):
/// teardown shuts it down so the read thread it blocks returns at once.
dialing_fd: posix.fd_t = -1,
/// The embedder's "dial again" (`vigilRedial` writes it, the read thread
/// sleeps on it while its stream is lost). Both ends non-blocking: asks
/// made while the stream is open pile up as one dial at the next loss.
redial_pipe: [2]posix.fd_t = .{ -1, -1 },

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
write_mutex: std.Io.Mutex = .init,
write_cond: std.Io.Condition = .init,
write_buf: std.ArrayListUnmanaged(u8) = .empty,
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
mailbox: ?apprt.surface.Mailbox = null,

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
    host: ?[]const u8 = null,
    /// A pre-connected stream (the embedder's transport); overrides both
    /// the local socket and the hub.
    fd: ?posix.fd_t = null,
    explicit_claim: bool = false,
};

pub fn init(alloc: Allocator, cfg: Config) !Attach {
    const explicit_claim = cfg.explicit_claim or (if (cfg.host) |host| host.len > 0 else false);
    var client_id: u64 = undefined;
    global.io().random(std.mem.asBytes(&client_id));
    return .{
        .alloc = alloc,
        .id = try alloc.dupe(u8, cfg.id),
        .cwd = if (cfg.cwd) |v| try alloc.dupe(u8, v) else null,
        .host = if (cfg.host) |v| if (v.len > 0) try alloc.dupe(u8, v) else null else null,
        .given_fd = cfg.fd,
        .explicit_claim = explicit_claim,
        .client_id = client_id,
    };
}

pub fn deinit(self: *Attach) void {
    self.alloc.free(self.id);
    if (self.cwd) |v| self.alloc.free(v);
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

/// vigil's one folder, as VigilWire's `VigilPaths.root` resolves it
/// (`VIGIL_STATE` moves it); `buf` holds it unless the variable does.
fn stateRoot(buf: []u8) ![]const u8 {
    if (sys.env("VIGIL_STATE")) |root| return root;
    return std.mem.print(buf, "{s}/.local/state/vigil", .{sys.env("HOME") orelse return error.NoHome});
}

/// This pane's daemon file `<id>.<ext>` in the root's `panes/`
/// (`VigilPaths.panes`).
fn panePath(self: *Attach, buf: []u8, ext: []const u8) ![]const u8 {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    return std.mem.print(buf, "{s}/panes/{s}.{s}", .{ try stateRoot(&root_buf), self.id, ext });
}

fn sockPath(self: *Attach, buf: []u8) ![]const u8 {
    return self.panePath(buf, "sock");
}

fn connectSock(self: *Attach) !posix.fd_t {
    var buf: [512]u8 = undefined;
    const path = try self.sockPath(&buf);
    const fd = try sys.unixSocket();
    errdefer sys.close(fd);
    try sys.connect(fd, path);
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
    const fd = try sys.unixSocket();
    errdefer sys.close(fd);
    // Runs before the errdefer close (defers unwind in reverse).
    self.setDialing(fd);
    defer self.setDialing(-1);
    // Teardown marks the transport closed before it severs: seen here, it
    // came before this dial was registered and would not cut it.
    if (self.transport_state.load(.acquire) == 2) return error.Closing;
    try sys.connect(fd, path);

    var req_buf: [512]u8 = undefined;
    const request = try std.mem.print(&req_buf, "{{\"kind\":\"open\",\"device\":\"{s}\",\"open\":{{\"op\":\"proxy\",\"pane\":\"{s}\"}}}}\n", .{ host, self.id });
    var written: usize = 0;
    while (written < request.len) written += try sys.write(fd, request[written..]);

    var ack_buf: [1024]u8 = undefined;
    const len = try sys.readLine(fd, &ack_buf, std.Io.Timestamp.now(global.io(), .awake), hub_answer_ms);
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

/// The hub's socket, as VigilWire's `VigilPaths.hub` names it (in
/// `VIGIL_AGENT_STATE`, else the root's `agent/`).
fn hubPath(buf: []u8) ![]const u8 {
    if (sys.env("VIGIL_AGENT_STATE")) |agent| return std.mem.print(buf, "{s}/hub.sock", .{agent});
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    return std.mem.print(buf, "{s}/agent/hub.sock", .{try stateRoot(&root_buf)});
}

fn setDialing(self: *Attach, fd: posix.fd_t) void {
    self.fd_mutex.lockUncancelable(global.io());
    defer self.fd_mutex.unlock(global.io());
    self.dialing_fd = fd;
}

/// The stream's socket, read and written from now on (a reconnect's).
fn setStream(self: *Attach, fd: posix.fd_t) void {
    self.fd_mutex.lockUncancelable(global.io());
    defer self.fd_mutex.unlock(global.io());
    self.sock_fd = fd;
    self.write_fd = fd;
}

/// Cut the stream so the reader sees EOF, and a hub dial in flight with it.
fn sever(self: *Attach) void {
    self.setTransport(2);
    self.fd_mutex.lockUncancelable(global.io());
    defer self.fd_mutex.unlock(global.io());
    if (self.sock_fd >= 0) sys.shutdown(self.sock_fd);
    if (self.dialing_fd >= 0) sys.shutdown(self.dialing_fd);
}

/// Hello: who this client is, for the daemon's receipts.
fn sendHello(self: *Attach, kind: []const u8) void {
    var buf: [64]u8 = undefined;
    // "mirror" tells the daemon this client never adopts the size unowned:
    // it renders whatever grid the owner has and claims only explicitly.
    // "replies": this terminal's own words come as 'a' frames, apart from
    // keystrokes (queueReply), so vigild takes them from one viewer.
    const hello = std.mem.print(&buf, "{s} ghostty:{d}/{x} replies{s}", .{ kind, std.c.getpid(), self.client_id, if (self.explicit_claim) " mirror" else "" }) catch return;
    self.enqueueFrame('h', hello);
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

    // Attach: to the pane's daemon here, or through this Mac's hub to
    // another Mac's. A view creates nothing: a pane's daemon is its home's
    // to start (the app's `PaneLife`), and a view that finds none says so
    // (transport 2) and dials when told to (`vigilRedial`).
    if (self.given_fd) |given| {
        self.sock_fd = given;
        self.write_fd = given;
        log.info("attach: {s} on a given fd {d}", .{ self.id, given });
    } else if (self.host) |host| {
        // A Mac out of reach at mount (asleep, its hub restarting) is no
        // ended pane: the read thread dials it again, as after any loss
        // (reconnect), and the view shows "connecting" until then.
        const fd = self.connectHub(host) catch |err| fd: {
            log.warn("attach: remote {s} on {s} not reached at mount ({}); dialing it again", .{ self.id, host, err });
            break :fd -1;
        };
        self.sock_fd = fd;
        self.write_fd = fd;
    } else {
        // No daemon yet (a pane just made, or one whose daemon is gone):
        // the read thread stands not connected and waits to be told.
        const fd = self.connectSock() catch -1;
        self.sock_fd = fd;
        self.write_fd = fd;
    }
    const fd = self.sock_fd;
    errdefer {
        if (fd >= 0) sys.close(fd);
        if (self.write_fd != fd and self.write_fd >= 0) sys.close(self.write_fd);
        self.sock_fd = -1;
        self.write_fd = -1;
    }

    if (fd >= 0) {
        // The writer: sole owner of stream writes. Born before the first
        // frame so nothing ever writes inline.
        self.write_closed = false;
        const write_thread = try std.Thread.spawn(.{}, writeThreadMain, .{self});
        write_thread.setName(global.io(), "io-writer") catch {};
        self.write_thread = write_thread;

        // Hello, then our size once it is real. The size is RECORDED by the
        // daemon; it is applied to the pty only while this client owns the
        // size (claimed on focus, or adopted when nobody owns it yet).
        self.sendHello(if (self.given_fd != null) "app" else if (self.host != null) "remote" else "surface");
        self.sendResize(.connect);
    }
    // Runs before the descriptor's errdefer above: the writer may hold the
    // number already, so it is retired before the number can be reused.
    errdefer {
        if (self.write_thread) |t| {
            self.closeQueue();
            t.join();
            self.write_thread = null;
        }
    }

    // Quit pipe + read thread, exactly Exec's shape: the ReadThread just
    // reads an fd and feeds processOutput; a socket fd is an fd.
    const pipe = try internal_os.pipe();
    errdefer sys.close(pipe[0]);
    errdefer sys.close(pipe[1]);

    self.redial_pipe = try internal_os.pipe();
    errdefer {
        sys.close(self.redial_pipe[0]);
        sys.close(self.redial_pipe[1]);
        self.redial_pipe = .{ -1, -1 };
    }
    try sys.nonblocking(self.redial_pipe[0]);
    try sys.nonblocking(self.redial_pipe[1]);

    const closing = try alloc_state: {
        break :alloc_state self.alloc.create(std.atomic.Value(bool));
    };
    closing.* = .init(false);
    errdefer self.alloc.destroy(closing);

    const read_thread = try std.Thread.spawn(
        .{},
        readThreadMain,
        .{ self, fd, io, pipe[0], closing },
    );
    read_thread.setName(global.io(), "io-reader") catch {};
    if (fd >= 0 and self.transport_state.cmpxchgStrong(0, 1, .release, .monotonic) == null) self.reportTransport();

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

    _ = sys.write(attach.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };
    self.sever();
    attach.read_thread.join();
    // The writer: close the queue, wake it, join BEFORE the fd closes (a
    // writer blocked in POLLOUT sees the sever as writable-then-EPIPE
    // and severs its way out; it must never touch a closed fd).
    self.closeQueue();
    if (self.write_thread) |t| {
        t.join();
        self.write_thread = null;
    }
    // The read thread's CURRENT socket, never the one recorded at enter: a
    // reconnect replaced it, and the number may be another surface's by now.
    if (self.write_fd != self.sock_fd and self.write_fd >= 0) sys.close(self.write_fd);
    if (self.sock_fd >= 0) sys.close(self.sock_fd);
    self.sock_fd = -1;
    self.write_fd = -1;
    // After the join: the read thread is the pipe's only reader.
    const redial = self.redial_pipe;
    self.redial_pipe = .{ -1, -1 };
    if (redial[0] >= 0) sys.close(redial[0]);
    if (redial[1] >= 0) sys.close(redial[1]);
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
    self.sendResize(.viewport);
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
        self.sendResize(.claim);
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
    // Another pixel layout at the same grid adds no pty resize.
    try attach.resize(.{ .columns = 153, .rows = 53 }, undefined);
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
    const pipe = try compat_fd.pipe();
    defer sys.close(pipe[0]);
    defer sys.close(pipe[1]);
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
        const n = sys.write(fd, data[off..]) catch |err| switch (err) {
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
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    if (self.write_closed) return;
    if (self.write_buf.items.len > 4 << 20) {
        log.warn("attach write queue past 4MB -> sever", .{});
        self.sever();
        self.write_closed = true;
        self.write_cond.signal(global.io());
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
        self.write_cond.signal(global.io());
        return;
    };
    self.write_buf.appendSliceAssumeCapacity(&hdr);
    self.write_buf.appendSliceAssumeCapacity(payload);
    _ = self.pending_bytes.fetchAdd(hdr.len + payload.len, .monotonic);
    self.write_cond.signal(global.io());
}

/// Close the outbound queue and wake the writer, which drains what it
/// holds and returns.
fn closeQueue(self: *Attach) void {
    self.write_mutex.lockUncancelable(global.io());
    defer self.write_mutex.unlock(global.io());
    self.write_closed = true;
    self.write_cond.signal(global.io());
}

fn writeThreadMain(self: *Attach) void {
    var local: std.ArrayListUnmanaged(u8) = .empty;
    defer local.deinit(self.alloc);
    while (true) {
        self.write_mutex.lockUncancelable(global.io());
        while (self.write_buf.items.len == 0 and !self.write_closed) {
            self.write_cond.waitUncancelable(global.io(), &self.write_mutex);
        }
        if (self.write_buf.items.len == 0) {
            // Closed and drained: done.
            self.write_mutex.unlock(global.io());
            return;
        }
        // Swap and drain OUTSIDE the lock: enqueue never waits on a write.
        std.mem.swap(std.ArrayListUnmanaged(u8), &local, &self.write_buf);
        self.write_mutex.unlock(global.io());

        if (!self.writeAll(local.items)) {
            // Severed: everything still queued is dead bytes.
            self.write_mutex.lockUncancelable(global.io());
            self.write_closed = true;
            self.write_buf.clearAndFree(self.alloc);
            self.write_mutex.unlock(global.io());
            return;
        }
        local.clearRetainingCapacity();
    }
}

/// Why a size frame goes to the daemon, named in its receipt.
const SizeWhy = enum {
    /// The stream opened: hello, then the grid.
    connect,
    /// The stream came back in place after its daemon or path was lost.
    reconnect,
    /// The embedder declared the viewport laid out.
    viewport,
    /// An explicit claim declared the viewport with its grid.
    claim,
    /// The io thread's coalesced resize reached the backend.
    grid,
};

/// Every 'r' frame sent writes one receipt naming the pane, this client
/// (the daemon's log names it by the same `ghostty:<pid>/<id>`), the grid
/// as rows x cols (the daemon's order) and why, so each pty resize in a
/// pane's log is matched to the app's reason for it. warn, not info: the
/// receipt must reach the unified log in a release build.
fn sendResize(self: *Attach, why: SizeWhy) void {
    if (self.write_fd < 0 or !self.viewport) return;
    const rows: u16 = @intCast(self.grid_size.rows);
    const cols: u16 = @intCast(self.grid_size.columns);
    const payload: [4]u8 = .{
        @intCast(rows & 0xff), @intCast((rows >> 8) & 0xff),
        @intCast(cols & 0xff), @intCast((cols >> 8) & 0xff),
    };
    self.enqueueFrame('r', &payload);
    log.warn("attach: {s} ghostty:{d}/{x} size {d}x{d} sent: {s}", .{ self.id, std.c.getpid(), self.client_id, rows, cols, @tagName(why) });
}

pub fn resize(
    self: *Attach,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = screen_size;
    if (std.meta.eql(self.grid_size, grid_size)) return;
    self.grid_size = grid_size;
    self.sendResize(.grid);
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
    self.queueFrames('d', data, linefeed);
}

/// The terminal's own words (an answer to a query, a report a mode asked
/// for) as 'a' frames: vigild types them only from the pane's size owner,
/// so a pane on several screens answers once (PROTOCOL.md).
pub fn queueReply(self: *Attach, data: []const u8, linefeed: bool) void {
    self.queueFrames('a', data, linefeed);
}

/// `data` as frames of `typ`, each at most a frame's payload.
fn queueFrames(self: *Attach, typ: u8, data: []const u8, linefeed: bool) void {
    if (self.write_fd < 0) return;

    if (!linefeed) {
        var i: usize = 0;
        while (i < data.len) {
            const end = @min(data.len, i + 0xffff);
            self.enqueueFrame(typ, data[i..end]);
            i = end;
        }
        return;
    }

    // Linefeed mode: \r becomes \r\n (bracketed paste path).
    var buf: [512]u8 = undefined;
    var buf_i: usize = 0;
    for (data) |ch| {
        if (buf_i >= buf.len - 1) {
            self.enqueueFrame(typ, buf[0..buf_i]);
            buf_i = 0;
        }
        buf[buf_i] = ch;
        buf_i += 1;
        if (ch == '\r') {
            buf[buf_i] = '\n';
            buf_i += 1;
        }
    }
    if (buf_i > 0) self.enqueueFrame(typ, buf[0..buf_i]);
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
            // Read each time: a daemon respawned under this surface (a
            // reconnect in place) has a new pty. The copy is kept so the
            // name handed out stays valid until it changes.
            const data = self.readPidfile() orelse return null;
            defer self.alloc.free(data);
            var lines = std.mem.splitScalar(u8, data, '\n');
            _ = lines.next() orelse return null;
            const tty = lines.next() orelse return null;
            if (tty.len == 0) return null;
            if (self.cached_tty) |v| {
                if (std.mem.eql(u8, v, tty)) return v;
                self.alloc.free(v);
                self.cached_tty = null;
            }
            self.cached_tty = self.alloc.dupeSentinel(u8, tty, 0) catch return null;
            return self.cached_tty;
        },
    }
}

fn readPidfile(self: *Attach) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = self.panePath(&buf, "pid") catch return null;
    return std.Io.Dir.cwd().readFileAlloc(global.io(), path, self.alloc, .limited(256)) catch null;
}

/// The read thread body: Exec's loop over the socket fd, for as long as
/// the view lives. A stream that ends WITHOUT a deliberate teardown is
/// reported as a transport fact and made again (`reconnect`); it is never
/// told to the surface as a child's exit. This thread sees a socket, not
/// a program: `.child_exited` from here set the surface's exited flag for
/// good, its next key closed it, the close buried the pane and the
/// burial's reap killed a daemon nobody had asked to end (2026-11-16,
/// twice). How a program ended is its daemon's record (`<pane>.ended`),
/// and closing the pane on it is the app's.
fn readThreadMain(
    self: *Attach,
    fd: posix.fd_t,
    io: *termio.Termio,
    quit: posix.fd_t,
    closing: *std.atomic.Value(bool),
) void {
    // Exec's loop closes the quit descriptor it is given on return; each
    // stream gets a dup, and the pipe itself (its bytes shared by every
    // dup, so a quit written mid-reconnect is still readable) lives as
    // long as this thread.
    defer sys.close(quit);
    // -1: nothing reached at mount (a remote Mac out of reach, a pane with
    // no daemon yet), dialed from the start.
    var current_fd = fd;
    while (true) {
        if (current_fd >= 0) {
            // No dup, no reader: the stream is lost to this view, said so
            // and dialed again below, never passed off as open.
            if (sys.dup(quit)) |quit_dup| {
                termio.Exec.ReadThread.threadMainPosix(current_fd, io, quit_dup);
            } else |err| {
                log.err("attach: {s} cannot dup the quit pipe err={}", .{ self.id, err });
            }
            if (closing.load(.acquire)) return;
            self.setTransport(2);
            // The phone's stream is the embedder's: it is told the stream
            // is lost and makes another view on a new one.
            if (self.given_fd != null) return;
        }
        // The quit pipe stays armed throughout, so a teardown mid-redial
        // returns at once.
        current_fd = self.reconnect(closing, quit) orelse return;
    }
}

/// Runs on the read thread after EOF. Returns the new socket, wired into
/// this Attach with a fresh writer, hello and size (the daemon replays its
/// screen to a fresh client over a clear, so nothing else is owed); null
/// when the end was deliberate, the teardown began, or the daemon never
/// came back within the window.
///
/// A stream that ended is a stream that ended: whether the pane's program
/// did is its daemon's to state (`<pane>.ended`, vigild) and its home's to
/// act on, never this thread's to infer. So this only makes the stream
/// again, and returns the new socket, or null when the view is being torn
/// down. A remote pane is dialed through the hub with a pause that grows
/// to 2 s, whatever ended it (the Mac asleep, its hub restarted, this
/// Mac's network): no event on this Mac says the other is back. A local
/// pane is dialed once, at once (a stream dropped under a live daemon
/// comes back here), and when that finds no daemon the view stands "not
/// connected" and this thread waits, asleep, for the embedder to say dial
/// again (`vigilRedial`: the app saw the pane's daemon start, or the
/// person asked). It starts no daemon: a view owns no pane's life.
fn reconnect(self: *Attach, closing: *std.atomic.Value(bool), quit: posix.fd_t) ?posix.fd_t {
    if (self.host) |host| {
        log.warn("attach: remote {s} on {s} stream ended; dialing it again through the hub", .{ self.id, host });
    } else {
        log.warn("attach: {s} has no stream; dialing its daemon once", .{self.id});
    }
    // Retire the writer (it may have severed itself on the dead socket
    // already) before the descriptor closes; a new one is born per socket.
    // Only then is the transport "connecting": a writer severing after it
    // would mark it closed, and every hub dial would refuse itself.
    self.closeQueue();
    if (self.write_thread) |t| {
        t.join();
        self.write_thread = null;
    }
    {
        self.fd_mutex.lockUncancelable(global.io());
        defer self.fd_mutex.unlock(global.io());
        if (self.sock_fd >= 0) sys.close(self.sock_fd);
        self.sock_fd = -1;
        self.write_fd = -1;
    }

    const began = std.Io.Timestamp.now(global.io(), .awake);
    // Remote: a pause that grows to 2 s between dials (a dial to a Mac out
    // of reach itself takes up to tether's 10 s to say so).
    var pause_ms: u64 = 200;
    while (true) {
        if (closing.load(.acquire)) return null;
        self.setTransport(0);
        const dialed = if (self.host) |host| self.connectHub(host) else self.connectSock();
        if (dialed) |nfd| {
            self.write_mutex.lockUncancelable(global.io());
            self.write_closed = false;
            self.write_buf.clearRetainingCapacity();
            self.pending_bytes.store(0, .monotonic);
            self.write_mutex.unlock(global.io());
            const t = std.Thread.spawn(.{}, writeThreadMain, .{self}) catch |err| {
                // No writer, no stream: not connected, and dialed again
                // when asked (never read as the pane's end).
                log.warn("attach: {s} reconnect writer failed err={}", .{ self.id, err });
                sys.close(nfd);
                self.setTransport(2);
                if (!self.awaitRedial(quit, null)) return null;
                continue;
            };
            t.setName(global.io(), "io-writer") catch {};
            self.write_thread = t;
            self.setStream(nfd);
            self.sendHello(if (self.host != null) "remote" else "surface");
            self.sendResize(.reconnect);
            self.setTransport(1);
            // warn, not info: the receipt must reach the unified log in a
            // release build; "I saw no overlay" is not a fact.
            log.warn("attach: {s} reattached in place after {d}ms", .{ self.id, sys.since(began) });
            return nfd;
        } else |err| if (self.host != null) {
            log.info("attach: remote {s} not reached yet ({}); again in {d}ms", .{ self.id, err, pause_ms });
            // Woken at once by teardown or by an asked redial.
            if (!self.awaitRedial(quit, pause_ms)) return null;
            pause_ms = @min(pause_ms * 2, 2_000);
        } else {
            log.warn("attach: {s} has no daemon to dial ({}); not connected until asked to dial again", .{ self.id, err });
            self.setTransport(2);
            if (!self.awaitRedial(quit, null)) return null;
        }
    }
}

/// Sleeps until the embedder asks for a dial (`vigilRedial`), teardown
/// writes the quit pipe, or `within_ms` passes (null: no clock, an event
/// only). False when it is teardown: the caller returns without a word.
fn awaitRedial(self: *Attach, quit: posix.fd_t, within_ms: ?u64) bool {
    var pfds = [2]posix.pollfd{
        .{ .fd = quit, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = self.redial_pipe[0], .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&pfds, if (within_ms) |ms| @intCast(ms) else -1) catch |err| {
        // A wait that cannot be made must not become a spin: say so and
        // stand not connected until teardown.
        log.err("attach: {s} cannot wait for a redial err={}", .{ self.id, err });
        return false;
    };
    if (pfds[0].revents != 0) return false;
    // Every ask so far is this one dial (the pipe does not block).
    var drain: [64]u8 = undefined;
    while (true) {
        const n = posix.read(self.redial_pipe[0], &drain) catch break;
        if (n < drain.len) break;
    }
    return true;
}

/// The embedder asks for the stream to be dialed again now (its pane's
/// daemon started, or the person pressed Reconnect). Nothing while the
/// stream is open. Any thread; never blocks.
pub fn vigilRedial(self: *Attach) void {
    if (self.redial_pipe[1] < 0) return;
    _ = sys.write(self.redial_pipe[1], "r") catch {};
}

/// Thread-local state: the socket and the reader.
pub const ThreadData = struct {
    sock_fd: posix.fd_t,
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    closing: *std.atomic.Value(bool),

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        sys.close(self.read_thread_pipe);
        alloc.destroy(self.closing);
    }
};

/// The system calls this file makes, over libc. Zig 0.17 removed
/// `std.posix`'s wrappers; these keep their contract where this file
/// relied on it (EINTR retried, EAGAIN as `error.WouldBlock`, EPIPE as
/// `error.BrokenPipe`), the way ghostty's own code now calls
/// `posix.system` and reads `posix.errno`.
const sys = struct {
    const c = std.c;

    fn close(fd: posix.fd_t) void {
        compat_fd.close(fd);
    }

    /// The process's environment variable, as libc holds it.
    fn env(name: [*:0]const u8) ?[]const u8 {
        return std.mem.span(c.getenv(name) orelse return null);
    }

    /// A unix stream socket, close-on-exec: never inherited by spawned
    /// daemons, since a leaked attach fd in a sibling daemon holds this
    /// connection open past its owner, so the daemon never sees EOF and
    /// EOF-driven detach detection silently breaks.
    fn unixSocket() !posix.fd_t {
        const rc = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (rc < 0) return unexpected("socket");
        errdefer close(rc);
        try cloexec(rc);
        return rc;
    }

    fn cloexec(fd: posix.fd_t) !void {
        if (posix.errno(c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC))) != .SUCCESS) return unexpected("fcntl");
    }

    fn nonblocking(fd: posix.fd_t) !void {
        const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        if (flags < 0) return unexpected("fcntl F_GETFL");
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
        if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return unexpected("fcntl F_SETFL");
    }

    fn connect(fd: posix.fd_t, path: []const u8) !void {
        var addr: c.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..path.len], path);
        while (true) switch (posix.errno(c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .CONNREFUSED => return error.ConnectionRefused,
            else => return unexpected("connect"),
        };
    }

    fn write(fd: posix.fd_t, bytes: []const u8) !usize {
        while (true) {
            const rc = c.write(fd, bytes.ptr, bytes.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE => return error.BrokenPipe,
                else => return unexpected("write"),
            }
        }
    }

    /// A duplicate, close-on-exec like every descriptor this file opens.
    fn dup(fd: posix.fd_t) !posix.fd_t {
        const rc = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (rc < 0) return unexpected("fcntl F_DUPFD_CLOEXEC");
        return rc;
    }

    /// One line from `fd`, read byte by byte (what follows it is not
    /// ours), its newline excluded, within `budget_ms` of `began`: every
    /// wait on a peer here is bounded, since the thread waiting is one a
    /// teardown joins.
    fn readLine(fd: posix.fd_t, buf: []u8, began: std.Io.Timestamp, budget_ms: i64) !usize {
        var len: usize = 0;
        while (true) {
            if (len == buf.len) return error.LineTooLong;
            const left = budget_ms - since(began);
            if (left <= 0) return error.Timeout;
            var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&pfd, @intCast(left)) == 0) return error.Timeout;
            const n = try posix.read(fd, buf[len .. len + 1]);
            if (n == 0) return error.Closed;
            if (buf[len] == '\n') return len;
            len += 1;
        }
    }

    fn shutdown(fd: posix.fd_t) void {
        _ = c.shutdown(fd, c.SHUT.RDWR);
    }

    /// Milliseconds since `began` on the monotonic clock.
    fn since(began: std.Io.Timestamp) i64 {
        return began.untilNow(global.io(), .awake).toMilliseconds();
    }

    fn sleep(ms: u64) void {
        std.Io.sleep(global.io(), .fromMilliseconds(@intCast(ms)), .awake) catch {};
    }

    /// Called right after the failing call, before anything can change
    /// errno.
    fn unexpected(comptime call: []const u8) error{Unexpected} {
        const err = posix.errno(@as(c_int, -1));
        log.warn(call ++ " failed errno={}", .{err});
        return error.Unexpected;
    }
};
