//! SPIKE: the system-independent half of the experimental native desktop
//! hosts for `main-native.roc`. A host's root file (`native_mac.zig`,
//! `native_gtk.zig`) supplies `pub const Backend`, the handful of widget
//! operations of its toolkit, and the process entry that runs its event
//! loop. Everything else lives here, once, for every system:
//!
//! - **Host.** The allocator, the one opaque engine state between calls, the
//!   last command buffer and work record (handed back to Roc for reuse), and
//!   fault reporting. It never interprets the state.
//! - **Runtime.** Applies each command batch, in stream order, to the
//!   backend's views and routes a widget's activation back as one turn
//!   (`roc_engine_event`). Like `runtime.mjs`, it decides nothing the engine
//!   decided: it keeps only the id → view table and the listeners the
//!   commands registered.
//!
//! Only the structural commands, keyed rows (`TEMPLATE`, `INST` and their
//! holes) and the native widget vocabulary of `Native.roc` (`column`,
//! `row`, `label`, `button`, `field`; events `press` and `input`) are
//! understood. Any other command is refused loudly rather than guessed at.
const std = @import("std");
const B = @import("root").Backend;

/// A toolkit's widget, opaque here.
pub const View = ?*anyopaque;

// ---------------------------------------------------------------------------
// libc / dynamic loading

extern fn malloc(size: usize) callconv(.c) ?*anyopaque;
extern fn realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) callconv(.c) void;
extern fn exit(code: c_int) callconv(.c) noreturn;
extern fn dlopen(path: [*:0]const u8, mode: c_int) callconv(.c) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn dlerror() callconv(.c) ?[*:0]const u8;
pub extern fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8;

/// Load a system library whose symbols the backend reaches through `sym`,
/// so Roc's link of the static host names none of them.
pub fn open(path: [*:0]const u8) ?*anyopaque {
    const RTLD_NOW: c_int = 2;
    const RTLD_GLOBAL: c_int = if (@import("builtin").os.tag == .macos) 8 else 0x100;
    return dlopen(path, RTLD_NOW | RTLD_GLOBAL) orelse die("cannot load {s}: {s}", .{ path, dlerror() orelse "?" });
}

/// A function of a loaded library, typed as the caller declares it.
pub fn sym(comptime F: type, lib: ?*anyopaque, comptime name: [:0]const u8) F {
    return @ptrCast(@alignCast(dlsym(lib, name) orelse die("missing symbol {s}", .{name})));
}

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("native host: " ++ fmt ++ "\n", args);
    exit(70);
}

// ---------------------------------------------------------------------------
// Roc ABI

const RocList = extern struct {
    ptr: ?[*]u8,
    len: usize,
    cap: usize,

    const empty: RocList = .{ .ptr = null, .len = 0, .cap = 0 };

    fn bytes(self: RocList) []const u8 {
        const p = self.ptr orelse return &.{};
        return p[0..self.len];
    }
};

/// `{ cmds, state, work }`: all pointer-aligned, so alphabetical.
const Step = extern struct {
    cmds: RocList,
    state: *anyopaque,
    work: RocList,
};

extern fn roc_engine_version() callconv(.c) u32;
extern fn roc_engine_init(boot: RocList) callconv(.c) Step;
extern fn roc_engine_event(state: *anyopaque, buf: RocList, wbuf: RocList, node: u32, handler: u32, payload: RocList) callconv(.c) Step;

// Allocator: libc malloc, whose 16-byte alignment covers every Roc type.
export fn roc_alloc(size: usize, alignment: usize) callconv(.c) *anyopaque {
    if (alignment > 16) die("allocation alignment {d} is unsupported", .{alignment});
    return malloc(size) orelse die("out of memory", .{});
}

export fn roc_realloc(ptr: *anyopaque, size: usize, alignment: usize) callconv(.c) *anyopaque {
    if (alignment > 16) die("allocation alignment {d} is unsupported", .{alignment});
    return realloc(ptr, size) orelse die("out of memory", .{});
}

export fn roc_dealloc(ptr: *anyopaque, _: usize) callconv(.c) void {
    free(ptr);
}

export fn roc_dbg(ptr: [*]const u8, len: usize) callconv(.c) void {
    std.debug.print("[dbg] {s}\n", .{ptr[0..len]});
}

export fn roc_expect_failed(ptr: [*]const u8, len: usize) callconv(.c) void {
    die("expect failed: {s}", .{ptr[0..len]});
}

export fn roc_crashed(ptr: [*]const u8, len: usize) callconv(.c) void {
    die("the app crashed (the instance is poisoned): {s}", .{ptr[0..len]});
}

// ---------------------------------------------------------------------------
// Host: the engine state and the buffers between calls.

var state: ?*anyopaque = null;
var cmds: RocList = RocList.empty;
var work: RocList = RocList.empty;

/// Mount the app into `root`, the backend's top-level column (node 0), and
/// apply the mount batch.
pub fn mount(root: View) void {
    std.debug.print("roc-signals native host, protocol {d}\n", .{roc_engine_version()});
    nodes.put(gpa, 0, .{ .kind = .root, .view = root, .parent = 0 }) catch oom();
    const step = roc_engine_init(RocList.empty);
    state = step.state;
    cmds = step.cmds;
    work = step.work;
    apply(cmds.bytes());
}

/// A button's activation: one turn for its `press` listener, if any. `key`
/// is the one the backend was given when it made the button.
pub fn press(key: Key) void {
    const route = (nodes.getPtr(key) orelse return).press orelse return;
    turn(route.node, route.handler, &.{});
}

/// An edit of a field: one turn for its `input` listener with the field's
/// whole text. A change the runtime itself makes while applying a batch is
/// not the user's and raises no event, as a DOM `value` write raises none.
pub fn input(key: Key, text: []const u8) void {
    if (applying) return;
    const route = (nodes.getPtr(key) orelse return).input orelse return;
    turn(route.node, route.handler, text);
}

/// One turn: the state and both buffers move into Roc, and what Roc returns
/// replaces them. Slots are cleared before the call, as in `host.zig`.
fn turn(at: u32, handler: u32, payload: []const u8) void {
    const owned = state orelse die("event before mount", .{});
    const buf = cmds;
    const wbuf = work;
    state = null;
    cmds = RocList.empty;
    work = RocList.empty;
    const step = roc_engine_event(owned, buf, wbuf, at, handler, ownedBytes(payload));
    state = step.state;
    cmds = step.cmds;
    work = step.work;
    apply(cmds.bytes());
}

/// A fresh `List(U8)` laid out as Roc expects (refcount 1 before the
/// elements, capacity shifted left by one), owned by Roc once passed in.
fn ownedBytes(payload: []const u8) RocList {
    if (payload.len == 0) return RocList.empty;
    const base: [*]u8 = @ptrCast(roc_alloc(payload.len + @sizeOf(usize), @alignOf(usize)));
    const rc: *isize = @ptrCast(@alignCast(base));
    rc.* = 1;
    const data = base + @sizeOf(usize);
    @memcpy(data[0..payload.len], payload);
    return .{ .ptr = data, .len = payload.len, .cap = payload.len << 1 };
}

fn oom() noreturn {
    die("out of memory", .{});
}

// ---------------------------------------------------------------------------
// Runtime: the node table the commands keep.
//
// A node is keyed by its engine id, or, for a node inside a row that the
// engine never names, by a key of the runtime's own above 2^32. An engine id
// a row assigns to a node inside it (a nested site's placeholder) is an alias
// of that node, released with the row, as `runtime.mjs` keeps `__aliases`.

pub const gpa = std.heap.c_allocator;
const native_ns = "urn:roc-signals:native";

/// A node's key: an engine id, or a runtime key above 2^32.
pub const Key = u64;
var next_own_key: Key = 1 << 32;

const Kind = enum { root, column, row, label, button, field, text, comment };

/// Where a listener's event goes: the engine node that routes it (the
/// element's own id, or the row's for a template's event hole) and the
/// handler number.
const Route = struct { node: u32, handler: u32 };

const Node = struct {
    kind: Kind,
    /// The toolkit's widget; text and comments have none.
    view: View,
    parent: Key,
    children: std.ArrayList(Key) = .empty,
    /// A text node's text.
    text: []u8 = &.{},
    press: ?Route = null,
    input: ?Route = null,
};

/// What a row instance keeps: its hole targets, resolved once at `INST`,
/// its template site, and the engine ids it aliased.
const Row = struct {
    site: u32,
    holes: []Key,
    aliases: std.ArrayList(u32) = .empty,
};

var nodes: std.AutoHashMapUnmanaged(Key, Node) = .empty;
var aliases: std.AutoHashMapUnmanaged(u32, Key) = .empty;
var rows: std.AutoHashMapUnmanaged(Key, Row) = .empty;
var templates: std.AutoHashMapUnmanaged(u32, Template) = .empty;

/// Whether a batch is being applied: events the toolkit raises meanwhile are
/// the runtime's own writes, not the user's.
var applying = false;

/// The node an engine id names, through a row's alias if it has one.
fn lookup(id: u32) Key {
    return aliases.get(id) orelse id;
}

fn node(key: Key) *Node {
    return nodes.getPtr(key) orelse die("command names unknown node {d}", .{key});
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn need(r: *Reader, n: usize) []const u8 {
        if (r.at + n > r.bytes.len) die("truncated command batch", .{});
        const s = r.bytes[r.at .. r.at + n];
        r.at += n;
        return s;
    }
    fn byte(r: *Reader) u8 {
        return r.need(1)[0];
    }
    fn word(r: *Reader) u32 {
        return std.mem.readInt(u32, r.need(4)[0..4], .little);
    }
    fn str(r: *Reader) []const u8 {
        return r.need(r.word());
    }
    /// `namespace:u8 [uri:str] prefix:str local:str`.
    fn expanded(r: *Reader) struct { ns: []const u8, ns_tag: u8, local: []const u8 } {
        const tag = r.byte();
        const ns: []const u8 = if (tag == 4) r.str() else "";
        _ = r.str(); // prefix
        return .{ .ns = ns, .ns_tag = tag, .local = r.str() };
    }
    /// An element's name, which must be a native widget's.
    fn widget(r: *Reader) []const u8 {
        const name = r.expanded();
        if (name.ns_tag != 4 or !std.mem.eql(u8, name.ns, native_ns))
            die("<{s}> is not a native widget: only the {s} namespace is drawn natively", .{ name.local, native_ns });
        return name.local;
    }
    /// An attribute's name, which no native widget namespaces.
    fn attribute(r: *Reader) []const u8 {
        const name = r.expanded();
        if (name.ns_tag != 3 and name.ns_tag != 0) die("attribute {s} has a namespace no native widget reads", .{name.local});
        return name.local;
    }
};

/// Apply one command batch in stream order.
fn apply(batch: []const u8) void {
    if (batch.len == 0) return;
    applying = true;
    var r: Reader = .{ .bytes = batch };
    if (r.byte() != 0) die("view-transition batches are not supported natively", .{});
    var acknowledge = false;
    while (r.at < batch.len) {
        const op = r.byte();
        switch (op) {
            1 => instantiate(&r), // INST
            2 => { // TEXT node hole text
                const row = rowOf(r.word());
                const target = row.holes[r.byte()];
                setText(target, r.str());
            },
            3 => { // HATTR node hole presence [value]
                const row = rowOf(r.word());
                const index = r.byte();
                const hole = templates.getPtr(row.site).?.holes.items[index];
                if (hole.kind != 2) die("HATTR names a hole that is not an attribute", .{});
                const present = r.byte() == 1;
                setAttr(row.holes[index], hole.name, present, if (present) r.str() else "");
            },
            4 => { // MOVE node before
                const n = lookup(r.word());
                const before = r.word();
                const p = node(n).parent;
                detach(n);
                attach(n, p, if (before == 0) null else lookup(before));
            },
            5 => { // REMOVE node
                const n = lookup(r.word());
                detach(n);
                forget(n);
            },
            6 => { // CLEAR parent site: every child of parent goes
                const p = lookup(r.word());
                _ = r.word();
                while (node(p).children.items.len > 0) {
                    const c = node(p).children.items[node(p).children.items.len - 1];
                    detach(c);
                    forget(c);
                }
            },
            7 => { // TEMPLATE tpl len bytes
                const tpl = r.word();
                var t: Reader = .{ .bytes = r.str() };
                templates.put(gpa, tpl, parseTemplate(&t)) catch oom();
            },
            8 => { // ELEM node parent before name container
                const n = r.word();
                const parent = lookup(r.word());
                const before = r.word();
                const local = r.widget();
                if (r.byte() != 0) die("a native widget has no template content", .{});
                create(n, local, parent, if (before == 0) null else lookup(before));
            },
            9 => { // ATTR node name presence [value]
                const n = lookup(r.word());
                const name = r.attribute();
                const present = r.byte() == 1;
                setAttr(n, name, present, if (present) r.str() else "");
            },
            10 => { // TEXTNODE node parent before text
                const n = r.word();
                const parent = lookup(r.word());
                const before = r.word();
                textNode(n, .text, r.str(), parent, if (before == 0) null else lookup(before));
            },
            11 => { // LISTEN node handler type kind policies
                const id = r.word();
                const handler = r.word();
                const kind = r.str();
                _ = r.byte();
                _ = r.word();
                listen(lookup(id), kind, .{ .node = id, .handler = handler });
            },
            12 => { // SETTEXT node text
                const n = lookup(r.word());
                setText(n, r.str());
            },
            23 => _ = r.word(), // RELEASE: no observations natively
            26 => { // COMMENT node parent before data
                const n = r.word();
                const parent = lookup(r.word());
                const before = r.word();
                textNode(n, .comment, r.str(), parent, if (before == 0) null else lookup(before));
            },
            28 => { // STARTUP mode entry
                _ = r.byte();
                _ = r.word();
            },
            29 => acknowledge = true, // STARTUP_ACK
            30 => {}, // STARTUP_COMPLETE
            else => die("command {d} is not supported by the native host yet", .{op}),
        }
    }
    applying = false;
    // The cold batch is applied whole; acknowledge it as the browser does.
    if (acknowledge) turn(0xffffffff, 0, &.{254});
}

fn rowOf(id: u32) *Row {
    return rows.getPtr(lookup(id)) orelse die("node {d} is not a row", .{id});
}

fn create(key: Key, local: []const u8, parent: Key, before: ?Key) void {
    const kind: Kind = if (std.mem.eql(u8, local, "column")) .column else if (std.mem.eql(u8, local, "row")) .row else if (std.mem.eql(u8, local, "label")) .label else if (std.mem.eql(u8, local, "button")) .button else if (std.mem.eql(u8, local, "field")) .field else die("no native widget named {s}", .{local});
    const view: View = switch (kind) {
        .column => B.stack(true),
        .row => B.stack(false),
        .label => B.label(),
        .button => B.button(key),
        .field => B.field(key),
        .root, .text, .comment => unreachable,
    };
    nodes.put(gpa, key, .{ .kind = kind, .view = view, .parent = parent }) catch oom();
    attach(key, parent, before);
}

fn textNode(key: Key, kind: Kind, text: []const u8, parent: Key, before: ?Key) void {
    const owned = gpa.dupe(u8, text) catch oom();
    nodes.put(gpa, key, .{ .kind = kind, .view = null, .parent = parent, .text = owned }) catch oom();
    attach(key, parent, before);
}

fn setText(key: Key, text: []const u8) void {
    const t = node(key);
    if (t.kind != .text) die("text written to a {s}", .{@tagName(t.kind)});
    gpa.free(t.text);
    t.text = gpa.dupe(u8, text) catch oom();
    refreshText(t.parent);
}

/// The one attribute a native widget reads: a field's `value`, written only
/// when it differs from what the field shows, so an echo of the user's own
/// typing never moves the caret.
fn setAttr(key: Key, name: []const u8, present: bool, value: []const u8) void {
    const n = node(key);
    if (n.kind != .field or !std.mem.eql(u8, name, "value"))
        die("attribute {s} on a {s} is not drawn natively", .{ name, @tagName(n.kind) });
    const text = if (present) value else "";
    if (!std.mem.eql(u8, B.fieldText(n.view), text)) B.setField(n.view, text);
}

fn listen(key: Key, kind: []const u8, route: Route) void {
    const n = node(key);
    if (std.mem.eql(u8, kind, "press") and n.kind == .button) {
        n.press = route;
    } else if (std.mem.eql(u8, kind, "input") and n.kind == .field) {
        n.input = route;
    } else die("a {s} raises no native {s} event", .{ @tagName(n.kind), kind });
}

/// Put `key` among `parent`'s children before `before` (null: at the end).
fn attach(key: Key, parent: Key, before: ?Key) void {
    const p = node(parent);
    const index: usize = if (before) |b| std.mem.indexOfScalar(Key, p.children.items, b) orelse die("node {d} is not a child of {d}", .{ b, parent }) else p.children.items.len;
    p.children.insert(gpa, index, key) catch oom();
    const child = node(key);
    child.parent = parent;
    if (child.view == null) return refreshText(parent);
    switch (p.kind) {
        .root, .column, .row => {
            // Text and comments have no view, so place among the views only.
            var view_index: usize = 0;
            var previous: View = null;
            for (p.children.items[0..index]) |c| {
                if (node(c).view != null) {
                    view_index += 1;
                    previous = node(c).view;
                }
            }
            B.insert(p.view, child.view, view_index, previous);
        },
        else => die("a {s} cannot hold widgets", .{@tagName(p.kind)}),
    }
}

fn detach(key: Key) void {
    const child = node(key);
    const p = node(child.parent);
    if (std.mem.indexOfScalar(Key, p.children.items, key)) |i| _ = p.children.orderedRemove(i);
    if (child.view == null) return refreshText(child.parent);
    B.remove(p.view, child.view);
}

/// A removed subtree leaves the table, with the rows it held and their
/// aliases, and its views are let go.
fn forget(key: Key) void {
    var gone = nodes.fetchRemove(key) orelse return;
    for (gone.value.children.items) |c| forget(c);
    gone.value.children.deinit(gpa);
    gpa.free(gone.value.text);
    if (rows.fetchRemove(key)) |row| {
        var r = row.value;
        for (r.aliases.items) |id| _ = aliases.remove(id);
        r.aliases.deinit(gpa);
        gpa.free(r.holes);
    }
    if (gone.value.view != null) B.release(gone.value.view);
}

/// A label's or button's text is its text children's, in order. A stack may
/// hold empty text (a site's placeholder) but never shows text of its own.
fn refreshText(key: Key) void {
    const p = node(key);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (p.children.items) |c| {
        if (node(c).kind == .text) text.appendSlice(gpa, node(c).text) catch oom();
    }
    switch (p.kind) {
        .label => B.setLabel(p.view, text.items),
        .button => B.setButton(p.view, text.items),
        else => if (text.items.len > 0) die("text \"{s}\" directly inside a {s}: wrap it in a label", .{ text.items, @tagName(p.kind) }),
    }
}

// ---------------------------------------------------------------------------
// Row templates (design.md, Appendix B, "Template encoding").

const TNode = struct {
    tag: u8, // 1 element, 2 text, 3 comment
    /// An element's local name, or a text's or comment's data.
    data: []const u8,
    attrs: std.ArrayList(struct { name: []const u8, value: []const u8 }) = .empty,
    children: std.ArrayList(u32) = .empty,
};

const Hole = struct {
    kind: u8,
    path: []const u8,
    /// An attribute hole's name, or an event hole's type.
    name: []const u8 = "",
    handler: u32 = 0,
};

const Template = struct {
    nodes: std.ArrayList(TNode) = .empty,
    holes: std.ArrayList(Hole) = .empty,
};

/// Parse a template's node tree and hole table. The bytes live in the
/// command buffer, which the next call reuses, so everything kept is copied.
fn parseTemplate(r: *Reader) Template {
    var t: Template = .{};
    _ = parseTNode(r, &t);
    const n = r.byte();
    for (0..n) |_| {
        const kind = r.byte();
        const depth = r.byte();
        const path = gpa.alloc(u8, depth) catch oom();
        for (0..depth) |i| {
            if (r.byte() != 0) die("a native widget has no template content", .{});
            path[i] = r.byte();
        }
        var hole: Hole = .{ .kind = kind, .path = path };
        switch (kind) {
            1, 4, 5 => {},
            2 => hole.name = copy(r.attribute()),
            3 => {
                hole.handler = r.byte();
                hole.name = copy(r.str());
                _ = r.byte();
                _ = r.word();
            },
            6 => _ = r.byte(),
            else => die("unknown template hole kind {d}", .{kind}),
        }
        t.holes.append(gpa, hole) catch oom();
    }
    if (r.at != r.bytes.len) die("trailing template bytes", .{});
    return t;
}

fn copy(bytes: []const u8) []const u8 {
    return gpa.dupe(u8, bytes) catch oom();
}

fn parseTNode(r: *Reader, t: *Template) u32 {
    const index: u32 = @intCast(t.nodes.items.len);
    const tag = r.byte();
    switch (tag) {
        1 => {
            t.nodes.append(gpa, .{ .tag = 1, .data = copy(r.widget()) }) catch oom();
            if (r.byte() != 0) die("a native widget has no template content", .{});
            const nattr = r.byte();
            for (0..nattr) |_| {
                const name = copy(r.attribute());
                const value = copy(r.str());
                t.nodes.items[index].attrs.append(gpa, .{ .name = name, .value = value }) catch oom();
            }
            const nchild = r.byte();
            for (0..nchild) |_| {
                const c = parseTNode(r, t);
                t.nodes.items[index].children.append(gpa, c) catch oom();
            }
        },
        2, 3 => t.nodes.append(gpa, .{ .tag = tag, .data = copy(r.str()) }) catch oom(),
        else => die("unknown template node tag {d}", .{tag}),
    }
    return index;
}

/// INST node parent before site, then each hole's operand in order.
fn instantiate(r: *Reader) void {
    const id = r.word();
    const parent = lookup(r.word());
    const before_id = r.word();
    const site = r.word();
    const t = templates.getPtr(site) orelse die("INST names unknown template {d}", .{site});
    const made = gpa.alloc(Key, t.nodes.items.len) catch oom();
    defer gpa.free(made);
    build(t, 0, id, parent, if (before_id == 0) null else lookup(before_id), made);

    // Hole targets are resolved once, here, as `runtime.mjs` does.
    var row: Row = .{ .site = site, .holes = gpa.alloc(Key, t.holes.items.len) catch oom() };
    for (t.holes.items, 0..) |hole, i| {
        var at: u32 = 0;
        for (hole.path) |step| at = t.nodes.items[at].children.items[step];
        const target = made[at];
        row.holes[i] = target;
        switch (hole.kind) {
            1 => setText(target, r.str()),
            2 => {
                const present = r.byte() == 1;
                setAttr(target, hole.name, present, if (present) r.str() else "");
            },
            3 => listen(target, hole.name, .{ .node = id, .handler = hole.handler }),
            4, 5 => {
                const alias = r.word();
                aliases.put(gpa, alias, target) catch oom();
                row.aliases.append(gpa, alias) catch oom();
            },
            6 => die("no native widget has a property", .{}),
            else => unreachable,
        }
    }
    rows.put(gpa, id, row) catch oom();
}

/// Build template node `index` under `parent`: the root takes the row's
/// engine id, every other node a key of the runtime's own.
fn build(t: *Template, index: u32, root_id: u32, parent: Key, before: ?Key, made: []Key) void {
    const key: Key = if (index == 0) root_id else blk: {
        next_own_key += 1;
        break :blk next_own_key;
    };
    made[index] = key;
    const tn = t.nodes.items[index];
    switch (tn.tag) {
        1 => {
            create(key, tn.data, parent, before);
            for (tn.attrs.items) |a| setAttr(key, a.name, true, a.value);
            for (tn.children.items) |c| build(t, c, root_id, key, null, made);
        },
        2 => textNode(key, .text, tn.data, parent, before),
        else => textNode(key, .comment, tn.data, parent, before),
    }
}

// ---------------------------------------------------------------------------
// Self-test: `ROC_NATIVE_SCRIPT="type:milk,Add,+"` runs steps in order
// through the toolkit's own paths: `type:TEXT` sets the first field's text
// as typing does, raising its edit event; any other step clicks the button
// with that title. It prints the widget tree the toolkit holds before and
// after, renders the window to `ROC_NATIVE_SNAPSHOT` when set (macOS), and
// quits unless `ROC_NATIVE_STAY` is set.

/// Whether a script was given; the backend then calls `runScript` once its
/// window is shown.
pub fn scripted() bool {
    return getenv("ROC_NATIVE_SCRIPT") != null;
}

pub fn runScript() void {
    const script = std.mem.span(getenv("ROC_NATIVE_SCRIPT") orelse return);
    std.debug.print("-- mounted\n", .{});
    B.dump();
    var steps = std.mem.splitScalar(u8, script, ',');
    while (steps.next()) |step| {
        if (step.len == 0) continue;
        if (std.mem.startsWith(u8, step, "type:")) {
            const text = step["type:".len..];
            B.typeInto(firstOf(.field) orelse die("script: no field to type into", .{}), text);
            std.debug.print("typed {s}\n", .{text});
        } else {
            B.click(buttonTitled(step) orelse die("script: no button titled {s}", .{step}));
            std.debug.print("clicked {s}\n", .{step});
        }
    }
    std.debug.print("-- after script\n", .{});
    B.dump();
    if (getenv("ROC_NATIVE_SNAPSHOT")) |path| {
        B.snapshot(path);
        std.debug.print("snapshot written to {s}\n", .{path});
    }
    // `ROC_NATIVE_STAY` keeps the window open, for a screenshot from outside.
    if (getenv("ROC_NATIVE_STAY") == null) B.quit();
}

fn firstOf(kind: Kind) View {
    var it = nodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.kind == kind) return e.value_ptr.view;
    }
    return null;
}

/// Find a button by the title the toolkit shows, not the table's text.
fn buttonTitled(title: []const u8) View {
    var it = nodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.kind == .button and std.mem.eql(u8, B.buttonText(e.value_ptr.view), title)) return e.value_ptr.view;
    }
    return null;
}

/// Print one line of the toolkit's widget tree.
pub fn dumpLine(depth: usize, comptime fmt: []const u8, args: anytype) void {
    for (0..depth) |_| std.debug.print("  ", .{});
    std.debug.print(fmt ++ "\n", args);
}
