//! Cell borders, specs/cell-border-protocol.md. The DCS identifier is
//! provisional, not registered.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const namespace = "cell-border";
pub const reply = "\x1bP1+b" ++ namespace ++ ";ok;1;pen,rect,half,center,palette,priority,style,round,outside,radius\x1b\\";

pub const Stroke = packed struct(u64) {
    /// RGB for `.rgb`, palette index in the low byte for `.palette`.
    color: u24 = 0,
    color_kind: ColorKind = .rgb,
    width: u7 = 0, // Zero means absent; otherwise 1/256 of cell width.
    centered: bool = false,
    above: bool = false,
    /// Shared-edge precedence from the `priority` extension field.
    priority: u4 = 0,
    style: Style = .solid,
    _padding: u23 = 0,

    pub const ColorKind = enum(u2) { rgb, palette, fg };
    pub const Style = enum(u2) { solid, double, dashed, dotted };
};

/// The colour filling the corner a rounded joint cuts off, from the joint
/// operations' `outside` extension field. `.default` is the terminal's default
/// background, resolved at draw time.
pub const Outside = packed struct(u32) {
    /// RGB for `.rgb`, palette index in the low byte for `.palette`.
    color: u24 = 0,
    kind: Kind = .none,
    _padding: u6 = 0,

    pub const Kind = enum(u2) { none, rgb, palette, default };
};

/// Segments in bit order and the eight joint flags; a set bit is rounded.
/// One outside colour and one radius serve all of the cell's rounded joints.
pub const Set = struct {
    strokes: [12]Stroke = @splat(.{}),
    joints: u8 = 0,
    outside: Outside = .{},
    /// Corner radius in 1/256 of cell width, 1 to 256; zero means the default.
    radius: u16 = 0,
};

/// Half the cell width, close to typical window corner radii.
pub const default_radius = 128;
pub const empty: Set = .{};

/// Right and bottom segments paired with the neighbor segment on the same
/// physical edge: right neighbor's left halves, lower neighbor's top halves.
pub const shared_right = [_][2]u4{ .{ 2, 6 }, .{ 3, 7 } };
pub const shared_below = [_][2]u4{ .{ 4, 0 }, .{ 5, 1 } };

/// Whether `first` (the left or upper cell's stroke) wins a shared edge
/// against `second`: higher priority, then wider, then the second cell.
fn firstWins(first: Stroke, second: Stroke) bool {
    if (first.priority != second.priority) return first.priority > second.priority;
    return first.width > second.width;
}

fn conflict(a: Stroke, b: Stroke) bool {
    return a.width != 0 and b.width != 0 and a.centered and b.centered;
}

/// Remove this cell's centred strokes that lose a shared edge to a
/// neighbour, so each shared edge draws once.
pub fn resolve(self: Set, left: ?Set, right: ?Set, above: ?Set, below: ?Set) [12]Stroke {
    const own = self.strokes;
    var out = own;
    for (shared_right) |pair| {
        if (right) |r| if (conflict(own[pair[0]], r.strokes[pair[1]]) and
            !firstWins(own[pair[0]], r.strokes[pair[1]]))
        {
            out[pair[0]] = .{};
        };
        if (left) |l| if (conflict(l.strokes[pair[0]], own[pair[1]]) and
            firstWins(l.strokes[pair[0]], own[pair[1]]))
        {
            out[pair[1]] = .{};
        };
    }
    for (shared_below) |pair| {
        if (below) |b| if (conflict(own[pair[0]], b.strokes[pair[1]]) and
            !firstWins(own[pair[0]], b.strokes[pair[1]]))
        {
            out[pair[0]] = .{};
        };
        if (above) |a| if (conflict(a.strokes[pair[0]], own[pair[1]]) and
            firstWins(a.strokes[pair[0]], own[pair[1]]))
        {
            out[pair[1]] = .{};
        };
    }
    return out;
}

/// IDs are stable for the terminal lifetime. This MVP does not reclaim
/// styles; the bounded table costs nothing until the first border is painted.
pub const Store = struct {
    sets: std.ArrayList(Set) = .empty,
    ids: std.AutoHashMapUnmanaged(Set, u16) = .empty,

    pub fn deinit(self: *Store, alloc: Allocator) void {
        self.sets.deinit(alloc);
        self.ids.deinit(alloc);
    }

    pub fn get(self: *const Store, id: u16) Set {
        return if (id == 0 or id > self.sets.items.len) empty else self.sets.items[id - 1];
    }

    pub fn intern(self: *Store, alloc: Allocator, value: Set) !u16 {
        if (std.meta.eql(value, empty)) return 0;
        if (self.ids.get(value)) |id| return id;
        if (self.sets.items.len == std.math.maxInt(u16)) return error.BorderStyleLimit;
        try self.sets.ensureUnusedCapacity(alloc, 1);
        try self.ids.ensureUnusedCapacity(alloc, 1);
        const id: u16 = @intCast(self.sets.items.len + 1);
        self.sets.appendAssumeCapacity(value);
        self.ids.putAssumeCapacity(value, id);
        return id;
    }

    /// Apply a change to the set `id`: replace the masked segments (an absent
    /// stroke clears them) or set the masked joints round or square, and the
    /// outside colour and radius when given.
    pub fn apply(self: *Store, alloc: Allocator, id: u16, change: Request.Change) !u16 {
        var value = self.get(id);
        switch (change) {
            .segments => |seg| for (&value.strokes, 0..) |*s, i| {
                if (seg.mask & (@as(u12, 1) << @intCast(i)) != 0) s.* = seg.stroke;
            },
            .joints => |j| {
                value.joints = if (j.round) value.joints | j.mask else value.joints & ~j.mask;
                if (j.outside) |o| value.outside = o;
                if (j.radius) |rad| value.radius = rad;
            },
        }
        return self.intern(alloc, value);
    }
};

pub const Request = union(enum) {
    query,
    /// Change the cursor pen.
    pen: Change,
    /// Change every cell of a cursor-anchored rectangle.
    paint: struct {
        change: Change,
        rows: u16,
        cols: u16,
    },

    pub const Change = union(enum) {
        segments: struct {
            mask: u12,
            stroke: Stroke, // An absent stroke clears the selected segments.
        },
        joints: struct {
            mask: u8,
            round: bool,
            outside: ?Outside = null,
            radius: ?u16 = null,
        },
    };
};

pub const Buffer = struct {
    data: [256]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *Buffer, byte: u8) !void {
        if (self.len == self.data.len) return error.CommandTooLong;
        self.data[self.len] = byte;
        self.len += 1;
    }
};

fn decimal(value: []const u8, max: u16) ?u16 {
    if (value.len == 0) return null;
    for (value) |c| if (!std.ascii.isDigit(c)) return null;
    const n = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (n <= max) n else null;
}

fn parseColor(value: []const u8) ?Stroke {
    if (std.mem.eql(u8, value, "fg")) return .{ .color_kind = .fg };
    if (value.len > 1 and value[0] == 'p') {
        const idx = decimal(value[1..], 255) orelse return null;
        return .{ .color = idx, .color_kind = .palette };
    }
    if (value.len != 6) return null;
    for (value) |c| if (!std.ascii.isHex(c)) return null;
    return .{ .color = std.fmt.parseInt(u24, value, 16) catch return null };
}

fn parseStroke(fields: *std.mem.SplitIterator(u8, .scalar)) ?Stroke {
    const width = decimal(fields.next() orelse return null, 64) orelse return null;
    if (width == 0) return null;
    var result = parseColor(fields.next() orelse return null) orelse return null;
    const placement = decimal(fields.next() orelse return null, 1) orelse return null;
    const layer = decimal(fields.next() orelse return null, 1) orelse return null;
    result.width = @intCast(width);
    result.centered = placement == 1;
    result.above = layer == 1;
    return result;
}

const Extension = struct { key: []const u8, value: []const u8 };

/// The next `key=value` field, or error.Malformed when it breaks the syntax.
fn nextExtension(fields: *std.mem.SplitIterator(u8, .scalar)) error{Malformed}!?Extension {
    const field = fields.next() orelse return null;
    const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.Malformed;
    const key = field[0..eq];
    const value = field[eq + 1 ..];
    if (key.len == 0 or value.len == 0) return error.Malformed;
    for (key) |c| if (!(std.ascii.isLower(c) or c == '-')) return error.Malformed;
    for (value) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return error.Malformed;
    return .{ .key = key, .value = value };
}

/// Extension fields are `key=value`; unknown keys and values are ignored, but
/// malformed fields reject the command.
fn parseExtensions(fields: *std.mem.SplitIterator(u8, .scalar), result: *Stroke) bool {
    while (nextExtension(fields) catch return false) |ext| {
        const key = ext.key;
        const value = ext.value;
        if (std.mem.eql(u8, key, "priority")) {
            if (decimal(value, 15)) |p| result.priority = @intCast(p);
        } else if (std.mem.eql(u8, key, "style")) {
            if (std.meta.stringToEnum(Stroke.Style, value)) |s| result.style = s;
        }
    }
    return true;
}

fn parseOutside(value: []const u8) ?Outside {
    if (std.mem.eql(u8, value, "default")) return .{ .kind = .default };
    if (value.len > 1 and value[0] == 'p') {
        const idx = decimal(value[1..], 255) orelse return null;
        return .{ .color = idx, .kind = .palette };
    }
    if (value.len != 6) return null;
    for (value) |c| if (!std.ascii.isHex(c)) return null;
    return .{ .color = std.fmt.parseInt(u24, value, 16) catch return null, .kind = .rgb };
}

/// Extension fields of the joint operations, under the same rules.
fn parseJointExtensions(fields: *std.mem.SplitIterator(u8, .scalar), outside: *?Outside, radius: *?u16) bool {
    while (nextExtension(fields) catch return false) |ext| {
        if (std.mem.eql(u8, ext.key, "outside")) {
            if (parseOutside(ext.value)) |o| outside.* = o;
        } else if (std.mem.eql(u8, ext.key, "radius")) {
            if (decimal(ext.value, 256)) |v| if (v != 0) {
                radius.* = v;
            };
        }
    }
    return true;
}

fn parseMask(fields: *std.mem.SplitIterator(u8, .scalar)) ?u12 {
    const m = decimal(fields.next() orelse return null, 4095) orelse return null;
    return if (m == 0) null else @intCast(m);
}

fn parseJoints(fields: *std.mem.SplitIterator(u8, .scalar)) ?u8 {
    const m = decimal(fields.next() orelse return null, 255) orelse return null;
    return if (m == 0) null else @intCast(m);
}

fn parseSize(fields: *std.mem.SplitIterator(u8, .scalar)) ?[2]u16 {
    const rows = decimal(fields.next() orelse return null, 65535) orelse return null;
    const cols = decimal(fields.next() orelse return null, 65535) orelse return null;
    return if (rows == 0 or cols == 0) null else .{ rows, cols };
}

/// Returns null for malformed commands and for operations this terminal
/// does not implement; both are ignored.
pub fn parse(body: []const u8) ?Request {
    var fields = std.mem.splitScalar(u8, body, ';');
    if (!std.mem.eql(u8, fields.next() orelse return null, namespace)) return null;
    const op = fields.next() orelse return null;
    if (std.mem.eql(u8, op, "q")) return if (fields.next() == null) .query else null;
    if (std.mem.eql(u8, op, "pen")) {
        const m = parseMask(&fields) orelse return null;
        var s = parseStroke(&fields) orelse return null;
        if (!parseExtensions(&fields, &s)) return null;
        return .{ .pen = .{ .segments = .{ .mask = m, .stroke = s } } };
    }
    if (std.mem.eql(u8, op, "pen-clear")) {
        const m = parseMask(&fields) orelse return null;
        if (fields.next() != null) return null;
        return .{ .pen = .{ .segments = .{ .mask = m, .stroke = .{} } } };
    }
    if (std.mem.eql(u8, op, "pen-round") or std.mem.eql(u8, op, "pen-square")) {
        const m = parseJoints(&fields) orelse return null;
        var outside: ?Outside = null;
        var radius: ?u16 = null;
        if (!parseJointExtensions(&fields, &outside, &radius)) return null;
        return .{ .pen = .{ .joints = .{ .mask = m, .round = op[4] == 'r', .outside = outside, .radius = radius } } };
    }
    if (std.mem.eql(u8, op, "set")) {
        const m = parseMask(&fields) orelse return null;
        var s = parseStroke(&fields) orelse return null;
        const rc = parseSize(&fields) orelse return null;
        if (!parseExtensions(&fields, &s)) return null;
        return .{ .paint = .{ .change = .{ .segments = .{ .mask = m, .stroke = s } }, .rows = rc[0], .cols = rc[1] } };
    }
    if (std.mem.eql(u8, op, "clear")) {
        const m = parseMask(&fields) orelse return null;
        const rc = parseSize(&fields) orelse return null;
        if (fields.next() != null) return null;
        return .{ .paint = .{ .change = .{ .segments = .{ .mask = m, .stroke = .{} } }, .rows = rc[0], .cols = rc[1] } };
    }
    if (std.mem.eql(u8, op, "round") or std.mem.eql(u8, op, "square")) {
        const m = parseJoints(&fields) orelse return null;
        const rc = parseSize(&fields) orelse return null;
        var outside: ?Outside = null;
        var radius: ?u16 = null;
        if (!parseJointExtensions(&fields, &outside, &radius)) return null;
        return .{ .paint = .{ .change = .{ .joints = .{ .mask = m, .round = op[0] == 'r', .outside = outside, .radius = radius } }, .rows = rc[0], .cols = rc[1] } };
    }
    return null;
}

/// One solid rectangle of border paint, in pixels relative to the owning cell.
/// `alpha` is coverage: 255 except at anti-aliased arc edges. A rectangle with
/// an `outside` colour fills a rounded corner instead of drawing `stroke`, and
/// draws below every border layer.
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32, stroke: Stroke = .{}, alpha: u8 = 255, outside: Outside = .{} };

/// Raw border sets of the four neighbours. Lines join across cell edges, so
/// joint geometry looks at the arms of neighbouring cells too.
pub const Neighbors = struct {
    left: ?Set = null,
    right: ?Set = null,
    above: ?Set = null,
    below: ?Set = null,
};

/// Device-pixel thickness of a stroke. Double strokes need three pixels.
pub fn thickness(stroke: Stroke, cell_width: u32) i32 {
    const t: i32 = @intCast(@max(1, (cell_width * @as(u32, stroke.width) + 128) / 256));
    return if (stroke.style == .double) @max(3, t) else t;
}

const Lines = struct { n: usize, a: [2][2]i32 };

/// The parallel lines of a stroke as offsets [start, end) across its thickness.
fn lines(stroke: Stroke, t: i32) Lines {
    if (stroke.style != .double) return .{ .n = 1, .a = .{ .{ 0, t }, .{ 0, t } } };
    const l = @max(1, @divTrunc(t + 1, 3));
    return .{ .n = 2, .a = .{ .{ 0, l }, .{ t - l, t } } };
}

/// Each segment runs between two of the cell's nine joint points, given as
/// (column, row) on a 3x3 lattice of edges and centrelines, in increasing order.
const arms = [12][2][2]i32{
    .{ .{ 0, 0 }, .{ 1, 0 } }, .{ .{ 1, 0 }, .{ 2, 0 } },
    .{ .{ 2, 0 }, .{ 2, 1 } }, .{ .{ 2, 1 }, .{ 2, 2 } },
    .{ .{ 0, 2 }, .{ 1, 2 } }, .{ .{ 1, 2 }, .{ 2, 2 } },
    .{ .{ 0, 0 }, .{ 0, 1 } }, .{ .{ 0, 1 }, .{ 0, 2 } },
    .{ .{ 0, 1 }, .{ 1, 1 } }, .{ .{ 1, 1 }, .{ 2, 1 } },
    .{ .{ 1, 0 }, .{ 1, 1 } }, .{ .{ 1, 1 }, .{ 1, 2 } },
};

/// Joint flag bit to (joint index, quadrant). Quadrant q lies between
/// directions q and q+1, with directions 0 +x, 1 +y, 2 -x, 3 -y.
const joint_flags = [8][2]u8{
    .{ 0, 0 }, .{ 2, 1 }, .{ 8, 2 }, .{ 6, 3 },
    .{ 4, 3 }, .{ 4, 0 }, .{ 4, 1 }, .{ 4, 2 },
};

fn horizontal(index: usize) bool {
    return arms[index][0][1] == arms[index][1][1];
}

/// Position of a lattice coordinate along an axis of `size` pixels.
fn nominal(k: i32, size: i32) i32 {
    return switch (k) {
        0 => 0,
        1 => @divTrunc(size, 2),
        else => size,
    };
}

/// Start of a stroke's band across its own axis, relative to the cell.
fn bandStart(index: usize, stroke: Stroke, w: i32, h: i32) i32 {
    const t = thickness(stroke, @intCast(w));
    const half = @divTrunc(t, 2);
    const horiz = horizontal(index);
    const size = if (horiz) h else w;
    return switch (arms[index][0][if (horiz) 1 else 0]) {
        1 => @divTrunc(size, 2) - half,
        0 => if (stroke.centered) -half else 0,
        else => if (stroke.centered) size - half else size - t,
    };
}

const Slot = struct { stroke: Stroke, lo: i32, t: i32, own: ?u4 };
const Joint = [4]?Slot;

fn direction(from: [2]i32, to: [2]i32) u2 {
    if (to[0] > from[0]) return 0;
    if (to[1] > from[1]) return 1;
    if (to[0] < from[0]) return 2;
    return 3;
}

/// The arms meeting at each of this cell's joints, own arms first.
fn collect(self: Set, n: Neighbors, w: i32, h: i32) [9]Joint {
    var out: [9]Joint = @splat(@splat(null));
    const cells = [_]struct { set: ?Set, dx: i32, dy: i32 }{
        .{ .set = self, .dx = 0, .dy = 0 },
        .{ .set = n.left, .dx = -1, .dy = 0 },
        .{ .set = n.right, .dx = 1, .dy = 0 },
        .{ .set = n.above, .dx = 0, .dy = -1 },
        .{ .set = n.below, .dx = 0, .dy = 1 },
    };
    for (cells, 0..) |c, ci| {
        const set = c.set orelse continue;
        for (set.strokes, 0..) |s, i| {
            if (s.width == 0) continue;
            var lo = bandStart(i, s, w, h);
            lo += if (horizontal(i)) c.dy * h else c.dx * w;
            for (0..2) |end| {
                const p = arms[i][end];
                const gx = c.dx * 2 + p[0];
                const gy = c.dy * 2 + p[1];
                if (gx < 0 or gx > 2 or gy < 0 or gy > 2) continue;
                const slot = &out[@intCast(gy * 3 + gx)][direction(p, arms[i][1 - end])];
                if (slot.* == null) slot.* = .{
                    .stroke = s,
                    .lo = lo,
                    .t = thickness(s, @intCast(w)),
                    .own = if (ci == 0) @intCast(i) else null,
                };
            }
        }
    }
    return out;
}

/// Where a line of the arm leaving `joint` in direction `d` begins. `sides`
/// are the perpendicular directions the line faces: one for each line of a
/// double stroke, both for a single line.
fn armEnd(joint: Joint, d: u2, sides: []const u2, start: i32) i32 {
    const positive = d < 2;
    const opposite = joint[d +% 2];
    var best: ?i32 = null;
    for (sides) |s| {
        const e = if (joint[s]) |p| near: {
            // Meet the perpendicular's nearer line, keeping a double interior open.
            const ls = lines(p.stroke, p.t);
            break :near if (positive) p.lo + ls.a[ls.n - 1][0] else p.lo + ls.a[0][1];
        } else if (opposite != null)
            start
        else if (joint[s +% 2]) |p|
            // An outer corner line covers the whole perpendicular.
            if (positive) p.lo else p.lo + p.t
        else
            start;
        best = if (best) |b| (if (positive) @min(b, e) else @max(b, e)) else e;
    }
    return best.?;
}

/// Emit the solid rectangles that draw one cell's borders: `raw` is the
/// cell's border set, `drawn` its strokes after shared-edge resolution.
/// `sink.rect(Rect)` receives each rectangle in paint order.
pub fn geometry(
    sink: anytype,
    raw: Set,
    drawn: [12]Stroke,
    neighbors: Neighbors,
    cell_width: u32,
    cell_height: u32,
) !void {
    const w: i32 = @intCast(cell_width);
    const h: i32 = @intCast(cell_height);
    const joints = collect(raw, neighbors, w, h);

    // A rounded quadrant counts only when this cell draws both of its arms.
    var rounded: [9]u4 = @splat(0);
    for (joint_flags, 0..) |jf, bit| {
        if ((raw.joints >> @intCast(bit)) & 1 == 0) continue;
        const q: u2 = @intCast(jf[1]);
        const a = joints[jf[0]][q] orelse continue;
        const b = joints[jf[0]][q +% 1] orelse continue;
        const ai = a.own orelse continue;
        const bi = b.own orelse continue;
        if (drawn[ai].width == 0 or drawn[bi].width == 0) continue;
        rounded[jf[0]] |= @as(u4, 1) << q;
    }

    var arcs: [8]Arc = undefined;
    var n_arcs: usize = 0;
    for (rounded, 0..) |mask, j| {
        for (0..4) |qi| {
            if ((mask >> @intCast(qi)) & 1 == 0) continue;
            arcs[n_arcs] = planArc(joints, drawn, j, @intCast(qi), w, h, raw.radius);
            n_arcs += 1;
        }
    }

    for (drawn, 0..) |s, i| {
        if (s.width == 0) continue;
        const t = thickness(s, cell_width);
        const lo = bandStart(i, s, w, h);
        const pa = arms[i][0];
        const pb = arms[i][1];
        const d = direction(pa, pb);
        const horiz = horizontal(i);
        const axis: usize = if (horiz) 0 else 1;
        const size = if (horiz) w else h;
        const na = nominal(pa[axis], size);
        const nb = nominal(pb[axis], size);
        const ja: usize = @intCast(pa[1] * 3 + pa[0]);
        const jb: usize = @intCast(pb[1] * 3 + pb[0]);
        const ls = lines(s, t);
        const both = if (horiz) [2]u2{ 3, 1 } else [2]u2{ 2, 0 };
        for (0..ls.n) |k| {
            const sides: []const u2 = if (ls.n == 1) &both else both[k .. k + 1];
            const full: [2]i32 = switch (s.style) {
                .solid, .double => .{
                    armEnd(joints[ja], d, sides, na),
                    armEnd(joints[jb], d +% 2, sides, nb),
                },
                .dashed => .{ na + @divTrunc(nb - na, 4), nb - @divTrunc(nb - na, 4) },
                .dotted => dot: {
                    const a = @divTrunc(na + nb, 2) - @divTrunc(t, 2);
                    break :dot .{ a, a + t };
                },
            };
            var cut = full;
            for (arcs[0..n_arcs]) |a| for (a.arms) |arm| {
                if (arm.segs[0] != i and arm.segs[1] != i) continue;
                if (arm.positive) cut[0] = @max(cut[0], arm.cut) else cut[1] = @min(cut[1], arm.cut);
            };
            const span = cut;
            if (span[1] <= span[0]) continue;
            const across = [2]i32{ lo + ls.a[k][0], ls.a[k][1] - ls.a[k][0] };
            try sink.rect(if (horiz)
                Rect{ .x = span[0], .y = across[0], .w = span[1] - span[0], .h = across[1], .stroke = s }
            else
                Rect{ .x = across[0], .y = span[0], .w = across[1], .h = span[1] - span[0], .stroke = s });
        }
    }

    if (raw.outside.kind != .none) for (arcs[0..n_arcs]) |a| try fill(sink, a, raw.outside, w, h);
    for (arcs[0..n_arcs]) |a| try arc(sink, a);
}

/// A rounded quadrant: the arms it shortens and the ring it draws.
const Arc = struct {
    hs: Slot,
    vs: Slot,
    hd: u2,
    vd: u2,
    r: i32,
    stroke: Stroke,
    /// Horizontal then vertical arm: up to two collinear segments of this
    /// cell that the arc replaces up to `cut`, unless a line runs straight
    /// through the joint.
    arms: [2]struct { segs: [2]?usize = .{ null, null }, cut: i32 = 0, positive: bool = true },
};

/// The radius is `radius` (or the default) in 1/256 of the cell width, at most
/// the smaller cell dimension. It may reach into the next collinear half
/// segment when the cell draws it with the same stroke, and shrinks to fit
/// the arms otherwise.
fn planArc(joints: [9]Joint, drawn: [12]Stroke, j: usize, q: u2, w: i32, h: i32, radius: u16) Arc {
    const hd = if (q % 2 == 0) q else q +% 1;
    const vd = if (q % 2 == 0) q +% 1 else q;
    const hs = joints[j][hd].?;
    const vs = joints[j][vd].?;
    var out: Arc = .{ .hs = hs, .vs = vs, .hd = hd, .vd = vd, .r = @min(@min(w, h), @divTrunc(w * @as(i32, if (radius == 0) default_radius else radius) + 128, 256)), .stroke = drawn[hs.own.?], .arms = .{ .{}, .{} } };
    const point = [2]i32{ @intCast(j % 3), @intCast(j / 3) };
    for ([2]u2{ hd, vd }, [2]Slot{ hs, vs }, [2]Slot{ vs, hs }, 0..) |d, s, perp, k| {
        const seg = s.own.?;
        const axis: usize = if (k == 0) 0 else 1;
        const size = if (k == 0) w else h;
        // The far end of the arm, extended by an identical continuation.
        var far = arms[seg][if (std.meta.eql(arms[seg][0], point)) 1 else 0];
        var cont: ?usize = null;
        if (far[axis] == 1) {
            if (joints[@intCast(far[1] * 3 + far[0])][d]) |c| if (c.own) |ci| {
                if (std.meta.eql(drawn[ci], drawn[seg])) {
                    cont = ci;
                    far[axis] += if (d < 2) 1 else -1;
                }
            };
        }
        // Twice the distance from the perpendicular's centreline to the far end.
        const centre2 = 2 * perp.lo + perp.t;
        const avail2 = @as(i32, @intCast(@abs(2 * nominal(far[axis], size) - centre2)));
        out.r = @min(out.r, @divTrunc(avail2, 2));
        if (joints[j][d +% 2] == null) out.arms[k] = .{ .segs = .{ seg, cont }, .positive = d < 2 };
    }
    out.r = @max(out.r, 1);
    for (&out.arms, [2]Slot{ vs, hs }) |*arm, perp| {
        // Cover the tangent pixel fully; the arc's partial pixel sits on it.
        const twice = 2 * perp.lo + perp.t + if (arm.positive) 2 * out.r else -2 * out.r;
        arm.cut = if (arm.positive) @divFloor(twice, 2) else -@divFloor(-twice, 2);
    }
    return out;
}

/// Draw an anti-aliased quarter ring tangent to a horizontal and a vertical
/// arm, using the horizontal arm's stroke. Coverage comes from 4x4 samples per
/// pixel; fully covered runs merge into one rectangle per row.
fn arc(sink: anytype, a: Arc) !void {
    const pi: f32 = std.math.pi;
    const hs = a.hs;
    const sx: f32 = if (a.hd == 0) 1 else -1;
    const sy: f32 = if (a.vd == 1) 1 else -1;
    const rf: f32 = @floatFromInt(a.r);
    const ox = @as(f32, @floatFromInt(2 * a.vs.lo + a.vs.t)) / 2 + sx * rf;
    const oy = @as(f32, @floatFromInt(2 * hs.lo + hs.t)) / 2 + sy * rf;
    // Angles run from the horizontal arm (0) to the vertical arm (pi/2).
    const window: [2]f32 = switch (a.stroke.style) {
        .solid, .double => .{ 0, pi / 2 },
        .dashed => .{ pi / 8, 3 * pi / 8 },
        .dotted => dot: {
            const half = @as(f32, @floatFromInt(hs.t)) / 2 / @max(rf, 1);
            break :dot .{ pi / 4 - half, pi / 4 + half };
        },
    };
    const ls = lines(a.stroke, hs.t);
    for (0..ls.n) |k| {
        const y0: f32 = @floatFromInt(hs.lo + ls.a[k][0]);
        const y1: f32 = @floatFromInt(hs.lo + ls.a[k][1]);
        const rin = @min(@abs(y0 - oy), @abs(y1 - oy));
        const rout = @max(@abs(y0 - oy), @abs(y1 - oy));
        const xs = [2]f32{ ox, ox - sx * rout };
        const ys = [2]f32{ oy, oy - sy * rout };
        const left: i32 = @intFromFloat(@floor(@min(xs[0], xs[1])));
        const right: i32 = @intFromFloat(@ceil(@max(xs[0], xs[1])));
        const top: i32 = @intFromFloat(@floor(@min(ys[0], ys[1])));
        const bottom: i32 = @intFromFloat(@ceil(@max(ys[0], ys[1])));
        var y = top;
        while (y < bottom) : (y += 1) {
            var run: ?i32 = null;
            var x = left;
            while (x <= right) : (x += 1) {
                const alpha = if (x < right) coverage(x, y, ox, oy, sx, sy, rin, rout, window) else 0;
                if (alpha == 255) {
                    if (run == null) run = x;
                    continue;
                }
                if (run) |x0| try sink.rect(Rect{ .x = x0, .y = y, .w = x - x0, .h = 1, .stroke = a.stroke });
                run = null;
                if (alpha != 0) try sink.rect(Rect{ .x = x, .y = y, .w = 1, .h = 1, .stroke = a.stroke, .alpha = alpha });
            }
        }
    }
}

/// Fill the corner a rounded quadrant cuts off: the square between the arc's
/// centre and its outer edge, beyond that edge, clipped to the cell. Edge
/// pixels use the arc's 4x4 sampling so the fill meets the arc smoothly.
fn fill(sink: anytype, a: Arc, outside: Outside, w: i32, h: i32) !void {
    const sx: f32 = if (a.hd == 0) 1 else -1;
    const sy: f32 = if (a.vd == 1) 1 else -1;
    const rf: f32 = @floatFromInt(a.r);
    const ox = @as(f32, @floatFromInt(2 * a.vs.lo + a.vs.t)) / 2 + sx * rf;
    const oy = @as(f32, @floatFromInt(2 * a.hs.lo + a.hs.t)) / 2 + sy * rf;
    const edges = [2]f32{ @floatFromInt(a.hs.lo), @floatFromInt(a.hs.lo + a.hs.t) };
    const rout = @max(@abs(edges[0] - oy), @abs(edges[1] - oy));
    const xs = [2]f32{ ox, ox - sx * rout };
    const ys = [2]f32{ oy, oy - sy * rout };
    const left = @max(0, @as(i32, @intFromFloat(@floor(@min(xs[0], xs[1])))));
    const right = @min(w, @as(i32, @intFromFloat(@ceil(@max(xs[0], xs[1])))));
    const top = @max(0, @as(i32, @intFromFloat(@floor(@min(ys[0], ys[1])))));
    const bottom = @min(h, @as(i32, @intFromFloat(@ceil(@max(ys[0], ys[1])))));
    var y = top;
    while (y < bottom) : (y += 1) {
        var run: ?i32 = null;
        var x = left;
        while (x <= right) : (x += 1) {
            const alpha = if (x < right) beyond(x, y, ox, oy, sx, sy, rout) else 0;
            if (alpha == 255) {
                if (run == null) run = x;
                continue;
            }
            if (run) |x0| try sink.rect(Rect{ .x = x0, .y = y, .w = x - x0, .h = 1, .outside = outside });
            run = null;
            if (alpha != 0) try sink.rect(Rect{ .x = x, .y = y, .w = 1, .h = 1, .alpha = alpha, .outside = outside });
        }
    }
}

/// Share of pixel (x, y) in the corner square but beyond radius `rout`.
fn beyond(x: i32, y: i32, ox: f32, oy: f32, sx: f32, sy: f32, rout: f32) u8 {
    const n = 4;
    var hits: u32 = 0;
    for (0..n) |iy| for (0..n) |ix| {
        const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(ix)) + 0.5) / n;
        const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(iy)) + 0.5) / n;
        const u = (ox - px) * sx;
        const v = (oy - py) * sy;
        if (u < 0 or v < 0 or u > rout or v > rout) continue;
        if (u * u + v * v <= rout * rout) continue;
        hits += 1;
    };
    return @intCast((hits * 255 + n * n / 2) / (n * n));
}

/// Share of pixel (x, y) inside the quarter ring, from 0 to 255.
fn coverage(x: i32, y: i32, ox: f32, oy: f32, sx: f32, sy: f32, rin: f32, rout: f32, window: [2]f32) u8 {
    const n = 4;
    var hits: u32 = 0;
    for (0..n) |iy| for (0..n) |ix| {
        const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(ix)) + 0.5) / n;
        const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(iy)) + 0.5) / n;
        const u = (ox - px) * sx;
        const v = (oy - py) * sy;
        if (u < 0 or v < 0) continue;
        const d2 = u * u + v * v;
        if (d2 < rin * rin or d2 > rout * rout) continue;
        const angle = std.math.atan2(u, v);
        if (angle < window[0] or angle > window[1]) continue;
        hits += 1;
    };
    return @intCast((hits * 255 + n * n / 2) / (n * n));
}

test "borders parse and independent half segments" {
    const testing = std.testing;
    const req = parse("cell-border;set;3;16;80c5b7;0;1;1;20").?.paint;
    const seg = req.change.segments;
    try testing.expectEqual(@as(u12, 3), seg.mask);
    try testing.expectEqual(@as(u24, 0x80c5b7), seg.stroke.color);
    try testing.expectEqual(@as(u16, 20), req.cols);
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const full = try store.apply(testing.allocator, 0, req.change);
    const half = try store.apply(testing.allocator, full, .{ .segments = .{ .mask = 1, .stroke = .{} } });
    try testing.expect(full != half);
    try testing.expectEqual(seg.stroke, store.get(half).strokes[1]);
    try testing.expectEqual(full, try store.intern(testing.allocator, store.get(full)));
    try testing.expectEqual(@as(u16, 0), try store.intern(testing.allocator, empty));
    for ([_][]const u8{
        "cell-border;set;3;0;80c5b7;0;1;1;20",
        "cell-border;clear;4096;1;1",
        "cell-border;clear;1;0;1",
        "cell-border;clear;+1;1;1",
        "cell-border;q;extra",
        "cell-border;set;1;16;xxxxxx;0;1;1;1",
        "cell-border;set;1;16;p256;0;1;1;1",
        "cell-border;pen;1;16;fg;0;1;Style=double",
        "cell-border;pen;1;16;fg;0;1;style",
        "cell-border;pen-clear;1;1",
        "cell-border;round;1;1",
        "cell-border;round;256;1;1",
        "cell-border;round;0;1;1",
        "cell-border;pen-round;0",
        "cell-border;pen-square;1;1",
        "cell-border;square;1;1;0",
        "cell-border;pen-round;1;outside",
        "cell-border;pen-round;1;outside=FF0000",
        "cell-border;round;1;1;1;outside=",
        "ghostty-border;q",
    }) |bad| try testing.expect(parse(bad) == null);
}

test "borders parse styles and joint operations" {
    const testing = std.testing;
    const Style = Stroke.Style;
    try testing.expectEqual(Style.double, parse("cell-border;pen;3;16;fg;0;1;style=double").?.pen.segments.stroke.style);
    try testing.expectEqual(Style.dotted, parse("cell-border;set;3;16;fg;0;1;1;1;style=dotted").?.paint.change.segments.stroke.style);
    try testing.expectEqual(Style.dashed, parse("cell-border;pen;3;16;fg;0;1;priority=2;style=dashed").?.pen.segments.stroke.style);
    try testing.expectEqual(Style.solid, parse("cell-border;pen;3;16;fg;0;1;style=wavy").?.pen.segments.stroke.style);

    const round = parse("cell-border;pen-round;15").?.pen.joints;
    try testing.expectEqual(@as(u8, 15), round.mask);
    try testing.expect(round.round);
    try testing.expect(!parse("cell-border;pen-square;240").?.pen.joints.round);
    const rect = parse("cell-border;round;255;2;3").?.paint;
    try testing.expect(rect.change.joints.round);
    try testing.expectEqual(@as(u16, 3), rect.cols);
    try testing.expect(!parse("cell-border;square;1;1;1").?.paint.change.joints.round);

    // Joints are part of the interned set and survive segment changes.
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const rounded = try store.apply(testing.allocator, 0, .{ .joints = .{ .mask = 5, .round = true } });
    try testing.expect(rounded != 0);
    const lined = try store.apply(testing.allocator, rounded, .{ .segments = .{ .mask = 3, .stroke = .{ .width = 16 } } });
    try testing.expectEqual(@as(u8, 5), store.get(lined).joints);
    const squared = try store.apply(testing.allocator, rounded, .{ .joints = .{ .mask = 1, .round = false } });
    try testing.expectEqual(@as(u8, 4), store.get(squared).joints);
    try testing.expectEqual(@as(u16, 0), try store.apply(testing.allocator, squared, .{ .joints = .{ .mask = 4, .round = false } }));
}

test "borders parse and store the outside colour" {
    const testing = std.testing;
    try testing.expectEqual(Outside{ .kind = .default }, parse("cell-border;pen-round;15;outside=default").?.pen.joints.outside.?);
    const rect = parse("cell-border;round;255;2;3;outside=1a2b3c").?.paint;
    try testing.expectEqual(Outside{ .color = 0x1a2b3c, .kind = .rgb }, rect.change.joints.outside.?);
    try testing.expectEqual(@as(u16, 3), rect.cols);
    try testing.expectEqual(Outside{ .color = 7, .kind = .palette }, parse("cell-border;pen-round;1;outside=p7").?.pen.joints.outside.?);
    // Unknown keys and values are ignored; the last value wins.
    try testing.expect(parse("cell-border;pen-round;1;outside=fg;shape=x").?.pen.joints.outside == null);
    try testing.expect(parse("cell-border;pen-round;1;outside=p256").?.pen.joints.outside == null);
    try testing.expectEqual(Outside.Kind.default, parse("cell-border;square;1;1;1;outside=p1;outside=default").?.paint.change.joints.outside.?.kind);

    // The colour is shared by the set's joints and kept when they turn square.
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const blue: Outside = .{ .color = 0x0000ff, .kind = .rgb };
    const rounded = try store.apply(testing.allocator, 0, .{ .joints = .{ .mask = 1, .round = true, .outside = blue } });
    try testing.expectEqual(blue, store.get(rounded).outside);
    const more = try store.apply(testing.allocator, rounded, .{ .joints = .{ .mask = 2, .round = true } });
    try testing.expectEqual(blue, store.get(more).outside);
    try testing.expectEqual(@as(u8, 3), store.get(more).joints);
    const squared = try store.apply(testing.allocator, more, .{ .joints = .{ .mask = 255, .round = false } });
    try testing.expectEqual(@as(u8, 0), store.get(squared).joints);
    try testing.expectEqual(blue, store.get(squared).outside);
}

test "borders parse and store the radius" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 64), parse("cell-border;pen-round;15;radius=64").?.pen.joints.radius.?);
    try testing.expectEqual(@as(u16, 256), parse("cell-border;round;1;2;3;outside=default;radius=256").?.paint.change.joints.radius.?);
    // Absent, zero, out of range and malformed values leave it unchanged.
    try testing.expect(parse("cell-border;pen-round;1").?.pen.joints.radius == null);
    try testing.expect(parse("cell-border;pen-round;1;radius=0").?.pen.joints.radius == null);
    try testing.expect(parse("cell-border;pen-round;1;radius=257").?.pen.joints.radius == null);
    try testing.expect(parse("cell-border;pen-round;1;radius=x").?.pen.joints.radius == null);
    try testing.expectEqual(@as(u16, 32), parse("cell-border;round;1;1;1;radius=300;radius=32").?.paint.change.joints.radius.?);

    // Stored per set and kept by joint changes without the field.
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const rounded = try store.apply(testing.allocator, 0, .{ .joints = .{ .mask = 1, .round = true, .radius = 96 } });
    try testing.expectEqual(@as(u16, 96), store.get(rounded).radius);
    const more = try store.apply(testing.allocator, rounded, .{ .joints = .{ .mask = 2, .round = true } });
    try testing.expectEqual(@as(u16, 96), store.get(more).radius);
    try testing.expect(more != (try store.apply(testing.allocator, more, .{ .joints = .{ .mask = 2, .round = true, .radius = 128 } })));
}

test "borders parse pen, colours and ignored extensions" {
    const testing = std.testing;
    const pen = parse("cell-border;pen;192;8;p4;1;0;style=double;future-key=x1").?.pen.segments;
    try testing.expectEqual(@as(u12, 192), pen.mask);
    try testing.expectEqual(Stroke.ColorKind.palette, pen.stroke.color_kind);
    try testing.expectEqual(@as(u24, 4), pen.stroke.color);
    try testing.expect(pen.stroke.centered);
    try testing.expect(!pen.stroke.above);
    const fg = parse("cell-border;set;3;8;fg;0;1;2;2").?.paint;
    try testing.expectEqual(Stroke.ColorKind.fg, fg.change.segments.stroke.color_kind);
    const clear = parse("cell-border;pen-clear;4095").?.pen.segments;
    try testing.expectEqual(@as(u7, 0), clear.stroke.width);
    try testing.expect(parse("cell-border;q").? == .query);
}

test "borders shared edges resolve by priority, width, then right and bottom" {
    const testing = std.testing;
    const plain: Stroke = .{ .width = 16, .centered = true };
    var hot = plain;
    hot.priority = 1;
    var wide = plain;
    wide.width = 24;
    var right_edge = empty;
    right_edge.strokes[2] = plain;
    right_edge.strokes[3] = plain;
    var left_edge = empty;
    left_edge.strokes[6] = plain;
    left_edge.strokes[7] = plain;

    // Tie: the right cell wins.
    try testing.expectEqual(@as(u7, 0), resolve(right_edge, null, left_edge, null, null)[2].width);
    try testing.expectEqual(@as(u7, 16), resolve(left_edge, right_edge, null, null, null)[6].width);

    // Priority beats position: a highlighted left pane keeps its edge.
    var hot_right = right_edge;
    hot_right.strokes[2] = hot;
    hot_right.strokes[3] = hot;
    try testing.expectEqual(@as(u4, 1), resolve(hot_right, null, left_edge, null, null)[2].priority);
    try testing.expectEqual(@as(u7, 0), resolve(left_edge, hot_right, null, null, null)[6].width);

    // Width beats position; inside strokes never merge.
    var wide_bottom = empty;
    wide_bottom.strokes[4] = wide;
    var top = empty;
    top.strokes[0] = plain;
    try testing.expectEqual(@as(u7, 24), resolve(wide_bottom, null, null, null, top)[4].width);
    try testing.expectEqual(@as(u7, 0), resolve(top, null, null, wide_bottom, null)[0].width);
    var inside = top;
    inside.strokes[0].centered = false;
    try testing.expectEqual(@as(u7, 16), resolve(inside, null, null, wide_bottom, null)[0].width);

    const parsed = parse("cell-border;pen;3;16;fg;1;1;priority=3").?.pen.segments;
    try testing.expectEqual(@as(u4, 3), parsed.stroke.priority);
    try testing.expectEqual(@as(u4, 0), parse("cell-border;pen;3;16;fg;1;1;priority=99").?.pen.segments.stroke.priority);
}

/// Rasterizes geometry into a small bitmap for tests: the highest coverage
/// painted on each pixel.
const TestCanvas = struct {
    const w = 16;
    const h = 32;
    px: [h][w]u8 = @splat(@splat(0)),
    count: usize = 0,

    fn rect(self: *TestCanvas, r: Rect) !void {
        self.count += 1;
        var y = @max(r.y, 0);
        while (y < @min(r.y + r.h, h)) : (y += 1) {
            var x = @max(r.x, 0);
            while (x < @min(r.x + r.w, w)) : (x += 1) {
                const p = &self.px[@intCast(y)][@intCast(x)];
                p.* = @max(p.*, r.alpha);
            }
        }
    }

    fn at(self: *const TestCanvas, x: usize, y: usize) bool {
        return self.px[y][x] >= 128;
    }

    fn draw(set: Set) !TestCanvas {
        var c: TestCanvas = .{};
        try geometry(&c, set, set.strokes, .{}, w, h);
        return c;
    }
};

fn testSet(mask: u12, stroke: Stroke, joints: u8) Set {
    var set: Set = .{ .joints = joints };
    for (&set.strokes, 0..) |*s, i| {
        if (mask & (@as(u12, 1) << @intCast(i)) != 0) s.* = stroke;
    }
    return set;
}

test "borders geometry joins solid arms without gaps" {
    const testing = std.testing;
    // A centre cross, 2px: every pixel of both centrelines is painted.
    const c = try TestCanvas.draw(testSet(0xf00, .{ .width = 32 }, 0));
    for (0..TestCanvas.w) |x| try testing.expect(c.at(x, 15) and c.at(x, 16));
    for (0..TestCanvas.h) |y| try testing.expect(c.at(7, y) and c.at(8, y));
    try testing.expect(!c.at(0, 0));
    // Equal widths look equally thick on non-square cells.
    try testing.expectEqual(thickness(.{ .width = 32 }, 16), 2);
}

test "borders geometry draws double lines with open junctions" {
    const testing = std.testing;
    const double: Stroke = .{ .width = 48, .style = .double }; // 3px: 1 + 1 + 1.
    // ╬: both lines run to the edges, the interior stays open.
    const cross = try TestCanvas.draw(testSet(0xf00, double, 0));
    try testing.expect(cross.at(0, 15) and cross.at(0, 17) and !cross.at(0, 16));
    try testing.expect(cross.at(7, 0) and cross.at(9, 0) and !cross.at(8, 0));
    try testing.expect(!cross.at(8, 16));
    try testing.expect(!cross.at(8, 10) and !cross.at(3, 16));
    // ═ through: lines continue across the centre.
    const through = try TestCanvas.draw(testSet(0x300, double, 0));
    for (0..TestCanvas.w) |x| try testing.expect(through.at(x, 15) and through.at(x, 17) and !through.at(x, 16));
    // ╔ at the top-left inside corner: outer lines meet, inner lines meet.
    const corner = try TestCanvas.draw(testSet(1 | 2 | 64 | 128, double, 0));
    try testing.expect(corner.at(0, 0) and corner.at(2, 2) and !corner.at(1, 1));
    try testing.expect(!corner.at(1, 5) and !corner.at(5, 1));
    // A single stem meeting a double line stops at its nearer line: ╥.
    var tee = testSet(0x300, double, 0);
    tee.strokes[11] = .{ .width = 16 };
    const t = try TestCanvas.draw(tee);
    try testing.expect(t.at(8, 18) and t.at(8, 17) and !t.at(8, 16));
}

test "borders geometry dashes and dots per half segment" {
    const testing = std.testing;
    const dashed = try TestCanvas.draw(testSet(0x300, .{ .width = 32, .style = .dashed }, 0));
    try testing.expectEqual(@as(usize, 2), dashed.count);
    try testing.expect(!dashed.at(0, 15) and dashed.at(2, 15) and dashed.at(5, 15) and !dashed.at(7, 15));
    try testing.expect(dashed.at(10, 15) and !dashed.at(15, 15));
    const dotted = try TestCanvas.draw(testSet(0x300, .{ .width = 32, .style = .dotted }, 0));
    try testing.expectEqual(@as(usize, 2), dotted.count);
    try testing.expect(dotted.at(3, 15) and dotted.at(4, 16) and !dotted.at(2, 15) and !dotted.at(5, 15));
}

test "borders geometry rounds corners and forks" {
    const testing = std.testing;
    const stroke: Stroke = .{ .width = 32 };
    // ╭ at the centre: arms shortened by the radius (8px), arc between them.
    const corner = try TestCanvas.draw(testSet(512 | 2048, stroke, 32));
    try testing.expect(!corner.at(8, 16) and !corner.at(9, 15));
    try testing.expect(corner.at(15, 15) and corner.at(8, 31));
    try testing.expect(corner.count > 2);
    // Square without the flag.
    const square = try TestCanvas.draw(testSet(512 | 2048, stroke, 0));
    try testing.expect(square.at(8, 16) and square.count == 2);
    // A flag whose arms are missing has no effect.
    const missing = try TestCanvas.draw(testSet(512, stroke, 32));
    try testing.expectEqual(@as(usize, 1), missing.count);
    // Fork ┬ with one rounded quadrant: the line stays straight, the stem
    // starts below the line and curves into it.
    const fork = try TestCanvas.draw(testSet(0x300 | 2048, stroke, 32));
    for (0..TestCanvas.w) |x| try testing.expect(fork.at(x, 15));
    try testing.expect(!fork.at(7, 18) and fork.at(7, 31));
    // Rounded inside corner at the cell's top-left.
    const tl = try TestCanvas.draw(testSet(1 | 2 | 64 | 128, stroke, 1));
    try testing.expect(!tl.at(0, 0) and tl.at(15, 0) and tl.at(0, 31));
}

/// Records corner fills and strokes separately.
const FillCanvas = struct {
    fill: [TestCanvas.h][TestCanvas.w]u8 = @splat(@splat(0)),
    stroke: TestCanvas = .{},
    out_of_cell: bool = false,

    fn rect(self: *FillCanvas, r: Rect) !void {
        if (r.outside.kind == .none) return self.stroke.rect(r);
        if (r.x < 0 or r.y < 0 or r.x + r.w > TestCanvas.w or r.y + r.h > TestCanvas.h) self.out_of_cell = true;
        var y = r.y;
        while (y < r.y + r.h) : (y += 1) {
            var x = r.x;
            while (x < r.x + r.w) : (x += 1) self.fill[@intCast(y)][@intCast(x)] = r.alpha;
        }
    }

    fn draw(set: Set) !FillCanvas {
        var c: FillCanvas = .{};
        try geometry(&c, set, set.strokes, .{}, TestCanvas.w, TestCanvas.h);
        return c;
    }
};

test "borders geometry fills outside rounded corners" {
    const testing = std.testing;
    const stroke: Stroke = .{ .width = 32 }; // 2px; radius 16px.
    var set = testSet(1 | 2 | 64 | 128, stroke, 1);
    set.outside = .{ .kind = .default };
    set.radius = 256;
    const c = try FillCanvas.draw(set);
    // The corner beyond the arc is filled, solid at the corner pixel.
    try testing.expectEqual(@as(u8, 255), c.fill[0][0]);
    try testing.expectEqual(@as(u8, 255), c.fill[2][2]);
    // Inside the arc and along the straight edges nothing is filled.
    try testing.expectEqual(@as(u8, 0), c.fill[8][8]);
    try testing.expectEqual(@as(u8, 0), c.fill[0][15]);
    try testing.expectEqual(@as(u8, 0), c.fill[31][0]);
    // Fill and arc meet without a gap: every pixel beyond the arc's inner
    // edge (centre 16,16, radius 15 shrunk to fit the arms, inner edge 14)
    // is covered by one or the other.
    for (0..16) |y| for (0..16) |x| {
        const dx = 15.5 - @as(f32, @floatFromInt(x));
        const dy = 15.5 - @as(f32, @floatFromInt(y));
        if (dx * dx + dy * dy < 15 * 15) continue;
        try testing.expect(@as(u32, c.fill[y][x]) + c.stroke.px[y][x] >= 200);
    };
    try testing.expect(!c.out_of_cell);
    // No fill without the colour, nor without a drawn arc.
    set.outside = .{};
    try testing.expectEqual(@as(u8, 0), (try FillCanvas.draw(set)).fill[0][0]);
    var square = testSet(1 | 2 | 64 | 128, stroke, 0);
    square.outside = .{ .kind = .default };
    try testing.expectEqual(@as(u8, 0), (try FillCanvas.draw(square)).fill[0][0]);
    // Centred corners fill only within the cell.
    var centred = testSet(1 | 2 | 64 | 128, .{ .width = 32, .centered = true }, 1);
    centred.outside = .{ .kind = .default };
    centred.radius = 256;
    const cc = try FillCanvas.draw(centred);
    try testing.expect(!cc.out_of_cell);
    try testing.expectEqual(@as(u8, 0), cc.fill[8][8]);
    // The stroke straddles the cell edge, so the fill covers the cell's
    // corner beyond the arc up to the edge, meeting the arc without a gap.
    try testing.expectEqual(@as(u8, 255), cc.fill[0][0]);
    try testing.expectEqual(@as(u8, 255), cc.fill[1][1]);
    for (0..8) |y| for (0..8) |x| {
        const dx = 15.0 - @as(f32, @floatFromInt(x));
        const dy = 15.0 - @as(f32, @floatFromInt(y));
        if (dx * dx + dy * dy < 15 * 15) continue;
        try testing.expect(@as(u32, cc.fill[y][x]) + cc.stroke.px[y][x] >= 200);
    };
}

test "borders geometry joins lines with neighbouring cells" {
    const testing = std.testing;
    const double: Stroke = .{ .width = 48, .style = .double, .centered = true };
    // A top edge whose left neighbour carries the shared vertical edge: the
    // top lines meet that edge instead of running through its interior.
    const own = testSet(1 | 2, double, 0);
    const left = testSet(4 | 8, double, 0);
    var c: TestCanvas = .{};
    try geometry(&c, own, own.strokes, .{ .left = left }, TestCanvas.w, TestCanvas.h);
    try testing.expect(c.at(1, 1) and !c.at(0, 1) and c.at(5, 1));
}

test "borders geometry arcs reach into the next half segment" {
    const testing = std.testing;
    const stroke: Stroke = .{ .width = 32 };
    // Rounded inside top-left box corner, 2px lines on a 16x32 cell: the
    // full-width radius (15px) runs through TOP_RIGHT and halfway down
    // LEFT_BOTTOM.
    var box = testSet(1 | 2 | 64 | 128, stroke, 1);
    box.radius = 256;
    const tl = try TestCanvas.draw(box);
    try testing.expect(!tl.at(0, 10) and !tl.at(8, 4) and tl.at(0, 16) and tl.at(0, 31));
    try testing.expect(tl.at(12, 0) and tl.at(5, 4));
    // A different stroke on TOP_RIGHT clamps the radius to the half cell.
    var mixed = box;
    mixed.strokes[1].color = 0xff0000;
    const clamped = try TestCanvas.draw(mixed);
    try testing.expect(clamped.at(0, 10) and clamped.at(12, 0) and clamped.at(15, 1));
    try testing.expect(!clamped.at(0, 2));
}

test "borders geometry sizes arcs by the radius" {
    const testing = std.testing;
    const stroke: Stroke = .{ .width = 32 };
    // The default is half the cell width: on a 16x32 cell the inside
    // top-left arc leaves the edges about 8px from the corner.
    var box = testSet(1 | 2 | 64 | 128, stroke, 1);
    const def = try TestCanvas.draw(box);
    try testing.expect(!def.at(0, 4) and !def.at(4, 0) and def.at(0, 10) and def.at(10, 0));
    box.radius = default_radius;
    try testing.expectEqualDeep(def.px, (try TestCanvas.draw(box)).px);
    // A quarter-width radius stays tighter still; the full width reaches past
    // the half cell.
    box.radius = 64;
    const small = try TestCanvas.draw(box);
    try testing.expect(!small.at(0, 0) and small.at(0, 4) and small.at(4, 0) and !def.at(1, 2));
    box.radius = 256;
    const full = try TestCanvas.draw(box);
    try testing.expect(!full.at(0, 10) and !full.at(10, 0));
    // The outside fill follows the arc.
    box.radius = 0;
    box.outside = .{ .kind = .default };
    const fd = try FillCanvas.draw(box);
    try testing.expectEqual(@as(u8, 255), fd.fill[0][0]);
    try testing.expectEqual(@as(u8, 0), fd.fill[4][4]);
    try testing.expectEqual(@as(u8, 0), fd.fill[0][10]);
    box.radius = 256;
    try testing.expectEqual(@as(u8, 255), (try FillCanvas.draw(box)).fill[2][2]);
}

test "borders geometry anti-aliases arcs" {
    const testing = std.testing;
    const Probe = struct {
        partial: usize = 0,
        full: usize = 0,
        fn rect(self: *@This(), r: Rect) !void {
            if (r.alpha == 255) {
                self.full += 1;
            } else {
                try testing.expect(r.alpha > 0 and r.w == 1 and r.h == 1);
                self.partial += 1;
            }
        }
    };
    var p: Probe = .{};
    const corner = testSet(512 | 2048, .{ .width = 64 }, 32);
    try geometry(&p, corner, corner.strokes, .{}, TestCanvas.w, TestCanvas.h);
    try testing.expect(p.partial > 4 and p.full > 2);
    // Straight lines stay opaque; the diagonal of the ring is partly covered.
    const c = try TestCanvas.draw(corner);
    try testing.expectEqual(@as(u8, 255), c.px[31][8]);
    try testing.expectEqual(@as(u8, 255), c.px[16][15]);
    var edge: usize = 0;
    for (c.px) |row| for (row) |v| {
        if (v > 0 and v < 255) edge += 1;
    };
    try testing.expect(edge > 4);
}

test "borders parse widths up to a quarter cell" {
    const testing = std.testing;
    try testing.expectEqual(@as(u7, 64), parse("cell-border;pen;3;64;fg;0;1").?.pen.segments.stroke.width);
    try testing.expect(parse("cell-border;pen;3;65;fg;0;1") == null);
    try testing.expectEqual(@as(i32, 4), thickness(.{ .width = 64 }, 16));
    // A wide double line keeps a visible gap.
    const ls = lines(.{ .style = .double }, 8);
    try testing.expect(ls.a[1][0] - ls.a[0][1] >= 2);
}
