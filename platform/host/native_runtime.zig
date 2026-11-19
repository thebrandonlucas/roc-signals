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
//! Only the structural commands and the native widget vocabulary of
//! `Native.roc` (`column`, `row`, `label`, `button`; event `press`) are
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
    nodes.put(gpa, 0, .{ .kind = .root, .view = root, .parent = 0 }) catch die("out of memory", .{});
    const step = roc_engine_init(RocList.empty);
    state = step.state;
    cmds = step.cmds;
    work = step.work;
    apply(cmds.bytes());
}

/// A button's activation: one turn for its `press` listener, if any.
pub fn press(n: u32) void {
    const handler = (nodes.getPtr(n) orelse return).press orelse return;
    turn(n, handler, &.{});
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

// ---------------------------------------------------------------------------
// Runtime: the id → view table the commands keep.

pub const gpa = std.heap.c_allocator;
const native_ns = "urn:roc-signals:native";

const Kind = enum { root, column, row, label, button, text };

const Node = struct {
    kind: Kind,
    /// The toolkit's widget; a text node has none and writes its parent's.
    view: View,
    parent: u32,
    children: std.ArrayList(u32) = .empty,
    /// A text node's text.
    text: []u8 = &.{},
    /// The handler number of a `press` listener, if any.
    press: ?u32 = null,
};

var nodes: std.AutoHashMapUnmanaged(u32, Node) = .empty;

fn node(n: u32) *Node {
    return nodes.getPtr(n) orelse die("command names unknown node {d}", .{n});
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
};

/// Apply one command batch in stream order.
fn apply(batch: []const u8) void {
    if (batch.len == 0) return;
    var r: Reader = .{ .bytes = batch };
    if (r.byte() != 0) die("view-transition batches are not supported natively", .{});
    var acknowledge = false;
    while (r.at < batch.len) {
        const op = r.byte();
        switch (op) {
            4 => { // MOVE node before
                const n = r.word();
                const before = r.word();
                const p = node(n).parent;
                detach(n);
                attach(n, p, before);
            },
            5 => { // REMOVE node
                const n = r.word();
                detach(n);
                forget(n);
            },
            8 => { // ELEM node parent before name container
                const n = r.word();
                const parent = r.word();
                const before = r.word();
                const name = r.expanded();
                _ = r.byte();
                if (name.ns_tag != 4 or !std.mem.eql(u8, name.ns, native_ns))
                    die("<{s}> is not a native widget: only the {s} namespace is drawn natively", .{ name.local, native_ns });
                create(n, parent, before, name.local);
            },
            9 => { // ATTR: no native widget reads attributes yet
                _ = r.word();
                _ = r.expanded();
                if (r.byte() == 1) _ = r.str();
            },
            10 => { // TEXTNODE node parent before text
                const n = r.word();
                const parent = r.word();
                const before = r.word();
                const text = gpa.dupe(u8, r.str()) catch die("out of memory", .{});
                nodes.put(gpa, n, .{ .kind = .text, .view = null, .parent = parent, .text = text }) catch die("out of memory", .{});
                attach(n, parent, before);
            },
            11 => { // LISTEN node handler type kind policies
                const n = r.word();
                const handler = r.word();
                const kind = r.str();
                _ = r.byte();
                _ = r.word();
                if (!std.mem.eql(u8, kind, "press")) die("event {s} has no native source", .{kind});
                node(n).press = handler;
            },
            12 => { // SETTEXT node text
                const t = node(r.word());
                gpa.free(t.text);
                t.text = gpa.dupe(u8, r.str()) catch die("out of memory", .{});
                refreshText(t.parent);
            },
            23 => _ = r.word(), // RELEASE: no observations natively
            28 => { // STARTUP mode entry
                _ = r.byte();
                _ = r.word();
            },
            29 => acknowledge = true, // STARTUP_ACK
            30 => {}, // STARTUP_COMPLETE
            else => die("command {d} is not supported by the native host yet", .{op}),
        }
    }
    // The cold batch is applied whole; acknowledge it as the browser does.
    if (acknowledge) turn(0xffffffff, 0, &.{254});
}

fn create(n: u32, parent: u32, before: u32, local: []const u8) void {
    const kind: Kind = if (std.mem.eql(u8, local, "column")) .column else if (std.mem.eql(u8, local, "row")) .row else if (std.mem.eql(u8, local, "label")) .label else if (std.mem.eql(u8, local, "button")) .button else die("no native widget named {s}", .{local});
    const view: View = switch (kind) {
        .column => B.stack(true),
        .row => B.stack(false),
        .label => B.label(),
        .button => B.button(n),
        .root, .text => unreachable,
    };
    nodes.put(gpa, n, .{ .kind = kind, .view = view, .parent = parent }) catch die("out of memory", .{});
    attach(n, parent, before);
}

/// Put `n` among `parent`'s children before `before` (0: at the end).
fn attach(n: u32, parent: u32, before: u32) void {
    const p = node(parent);
    const index: usize = if (before == 0) p.children.items.len else std.mem.indexOfScalar(u32, p.children.items, before) orelse die("node {d} is not a child of {d}", .{ before, parent });
    p.children.insert(gpa, index, n) catch die("out of memory", .{});
    node(n).parent = parent;
    const child = node(n);
    if (child.kind == .text) return refreshText(parent);
    switch (p.kind) {
        .root, .column, .row => {
            // Text children have no view, so place among the views only.
            var view_index: usize = 0;
            var previous: View = null;
            for (p.children.items[0..index]) |c| {
                if (node(c).kind != .text) {
                    view_index += 1;
                    previous = node(c).view;
                }
            }
            B.insert(p.view, child.view, view_index, previous);
        },
        else => die("a {s} cannot hold widgets", .{@tagName(p.kind)}),
    }
}

fn detach(n: u32) void {
    const child = node(n);
    const p = node(child.parent);
    if (std.mem.indexOfScalar(u32, p.children.items, n)) |i| _ = p.children.orderedRemove(i);
    if (child.kind == .text) return refreshText(child.parent);
    B.remove(p.view, child.view);
}

/// A removed subtree leaves the table, and its views are let go.
fn forget(n: u32) void {
    var gone = nodes.fetchRemove(n) orelse return;
    for (gone.value.children.items) |c| forget(c);
    gone.value.children.deinit(gpa);
    gpa.free(gone.value.text);
    if (gone.value.view != null) B.release(gone.value.view);
}

/// A label's or button's text is its text children's, in order.
fn refreshText(n: u32) void {
    const p = node(n);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (p.children.items) |c| text.appendSlice(gpa, node(c).text) catch die("out of memory", .{});
    switch (p.kind) {
        .label => B.setLabel(p.view, text.items),
        .button => B.setButton(p.view, text.items),
        else => die("text directly inside a {s}: wrap it in a label", .{@tagName(p.kind)}),
    }
}

// ---------------------------------------------------------------------------
// Self-test: `ROC_NATIVE_SCRIPT="+,+,-"` clicks the buttons with those
// titles in order through the toolkit's own activation, prints the widget
// tree the toolkit holds, renders the window to `ROC_NATIVE_SNAPSHOT` when
// set (macOS), and quits unless `ROC_NATIVE_STAY` is set. It drives only what a user could.

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
    while (steps.next()) |title| {
        if (title.len == 0) continue;
        B.click(buttonTitled(title) orelse die("script: no button titled {s}", .{title}));
        std.debug.print("clicked {s}\n", .{title});
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
