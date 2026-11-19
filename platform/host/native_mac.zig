//! SPIKE: the macOS backend of the experimental native host
//! (`native_runtime.zig` holds everything that is not AppKit). Widgets are
//! AppKit views: `NSStackView` for a column or row, `NSTextField` labels and
//! `NSButton`s. AppKit is reached through the Objective-C runtime, loaded
//! with `dlopen`, so Roc's link of the static host needs no framework flags.
const std = @import("std");
const rt = @import("native_runtime.zig");

const View = rt.View;
const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const NSEdgeInsets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

// ---------------------------------------------------------------------------
// Objective-C runtime

var objc_getClass: *const fn ([*:0]const u8) callconv(.c) Class = undefined;
var sel_registerName: *const fn ([*:0]const u8) callconv(.c) SEL = undefined;
var objc_allocateClassPair: *const fn (Class, [*:0]const u8, usize) callconv(.c) Class = undefined;
var objc_registerClassPair: *const fn (Class) callconv(.c) void = undefined;
var class_addMethod: *const fn (Class, SEL, *const anyopaque, [*:0]const u8) callconv(.c) bool = undefined;
var objc_autoreleasePoolPush: *const fn () callconv(.c) ?*anyopaque = undefined;
var msg_send: *const anyopaque = undefined;

fn loadRuntime() void {
    const objc = rt.open("/usr/lib/libobjc.A.dylib");
    _ = rt.open("/System/Library/Frameworks/AppKit.framework/AppKit");
    objc_getClass = rt.sym(@TypeOf(objc_getClass), objc, "objc_getClass");
    sel_registerName = rt.sym(@TypeOf(sel_registerName), objc, "sel_registerName");
    objc_allocateClassPair = rt.sym(@TypeOf(objc_allocateClassPair), objc, "objc_allocateClassPair");
    objc_registerClassPair = rt.sym(@TypeOf(objc_registerClassPair), objc, "objc_registerClassPair");
    class_addMethod = rt.sym(@TypeOf(class_addMethod), objc, "class_addMethod");
    objc_autoreleasePoolPush = rt.sym(@TypeOf(objc_autoreleasePoolPush), objc, "objc_autoreleasePoolPush");
    msg_send = rt.sym(*const anyopaque, objc, "objc_msgSend");
}

fn cls(name: [*:0]const u8) id {
    return objc_getClass(name) orelse rt.die("no Objective-C class {s}", .{name});
}

fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// `objc_msgSend` cast to the exact signature of one call, as arm64 requires.
fn send(comptime Ret: type, receiver: id, selector: [*:0]const u8, args: anytype) Ret {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    switch (fields.len) {
        0 => {
            const f: *const fn (id, SEL) callconv(.c) Ret = @ptrCast(@alignCast(msg_send));
            return f(receiver, sel(selector));
        },
        1 => {
            const f: *const fn (id, SEL, fields[0]) callconv(.c) Ret = @ptrCast(@alignCast(msg_send));
            return f(receiver, sel(selector), args[0]);
        },
        2 => {
            const f: *const fn (id, SEL, fields[0], fields[1]) callconv(.c) Ret = @ptrCast(@alignCast(msg_send));
            return f(receiver, sel(selector), args[0], args[1]);
        },
        3 => {
            const f: *const fn (id, SEL, fields[0], fields[1], fields[2]) callconv(.c) Ret = @ptrCast(@alignCast(msg_send));
            return f(receiver, sel(selector), args[0], args[1], args[2]);
        },
        4 => {
            const f: *const fn (id, SEL, fields[0], fields[1], fields[2], fields[3]) callconv(.c) Ret = @ptrCast(@alignCast(msg_send));
            return f(receiver, sel(selector), args[0], args[1], args[2], args[3]);
        },
        else => @compileError("too many message arguments"),
    }
}

/// An autoreleased `NSString` of UTF-8 text.
fn nsString(text: []const u8) id {
    const s = send(id, send(id, cls("NSString"), "alloc", .{}), "initWithBytes:length:encoding:", .{ @as(?*const anyopaque, text.ptr), @as(usize, text.len), @as(usize, 4) });
    return send(id, s, "autorelease", .{});
}

fn utf8(s: id) []const u8 {
    return std.mem.span(send(?[*:0]const u8, s, "UTF8String", .{}) orelse "");
}

// ---------------------------------------------------------------------------
// The widget operations the runtime calls. Each view the runtime holds is
// retained once, and released when the runtime lets it go.

var target: id = null;
var window: id = null;

pub const Backend = struct {
    pub fn stack(vertical: bool) View {
        const s = send(id, send(id, cls("NSStackView"), "alloc", .{}), "init", .{});
        send(void, s, "setOrientation:", .{@as(isize, if (vertical) 1 else 0)});
        send(void, s, "setSpacing:", .{@as(f64, 8)});
        // NSLayoutAttributeLeading (5) for a column, CenterY (12) for a row.
        send(void, s, "setAlignment:", .{@as(isize, if (vertical) 5 else 12)});
        return s;
    }

    pub fn label() View {
        return send(id, send(id, cls("NSTextField"), "labelWithString:", .{nsString("")}), "retain", .{});
    }

    pub fn button(n: u32) View {
        const b = send(id, cls("NSButton"), "buttonWithTitle:target:action:", .{ nsString(""), target, sel("press:") });
        send(void, b, "setTag:", .{@as(isize, n)});
        return send(id, b, "retain", .{});
    }

    pub fn insert(parent: View, child: View, index: usize, _: View) void {
        send(void, parent, "insertArrangedSubview:atIndex:", .{ child, @as(isize, @intCast(index)) });
    }

    pub fn remove(_: View, child: View) void {
        send(void, child, "removeFromSuperview", .{});
    }

    pub fn release(view: View) void {
        send(void, view, "release", .{});
    }

    pub fn setLabel(view: View, text: []const u8) void {
        send(void, view, "setStringValue:", .{nsString(text)});
    }

    pub fn setButton(view: View, text: []const u8) void {
        send(void, view, "setTitle:", .{nsString(text)});
    }

    pub fn buttonText(view: View) []const u8 {
        return utf8(send(id, view, "title", .{}));
    }

    /// A click as a user makes it, through the button's own action.
    pub fn click(view: View) void {
        send(void, view, "performClick:", .{@as(id, null)});
    }

    pub fn dump() void {
        dumpView(send(id, window, "contentView", .{}), 0);
    }

    pub fn snapshot(path: [*:0]const u8) void {
        const view = send(id, window, "contentView", .{});
        // Light appearance, so dark mode's white text shows on the page.
        send(void, view, "setAppearance:", .{send(id, cls("NSAppearance"), "appearanceNamed:", .{nsString("NSAppearanceNameAqua")})});
        send(void, view, "layoutSubtreeIfNeeded", .{});
        const bounds = send(NSRect, view, "bounds", .{});
        // Vector capture draws text that an offscreen bitmap cache can miss.
        const pdf = send(id, view, "dataWithPDFInsideRect:", .{bounds});
        if (!send(bool, pdf, "writeToFile:atomically:", .{ nsString(std.mem.span(path)), true })) rt.die("cannot write {s}", .{path});
    }

    pub fn quit() void {
        send(void, send(id, cls("NSApplication"), "sharedApplication", .{}), "terminate:", .{@as(id, null)});
    }
};

/// Print the tree as AppKit holds it, reading each control's own text.
fn dumpView(view: id, depth: usize) void {
    const class_name = utf8(send(id, view, "className", .{}));
    if (std.mem.eql(u8, class_name, "NSButton")) {
        rt.dumpLine(depth, "button \"{s}\"", .{utf8(send(id, view, "title", .{}))});
    } else if (std.mem.eql(u8, class_name, "NSTextField")) {
        rt.dumpLine(depth, "label \"{s}\"", .{utf8(send(id, view, "stringValue", .{}))});
    } else if (std.mem.eql(u8, class_name, "NSStackView")) {
        rt.dumpLine(depth, "{s}", .{if (send(isize, view, "orientation", .{}) == 1) "column" else "row"});
        const subs = send(id, view, "arrangedSubviews", .{});
        for (0..send(usize, subs, "count", .{})) |i| dumpView(send(id, subs, "objectAtIndex:", .{i}), depth + 1);
    } else rt.dumpLine(depth, "{s}", .{class_name});
}

// ---------------------------------------------------------------------------
// The object AppKit calls: a button's action, the script and the delegate.

fn pressed(_: id, _: SEL, sender: id) callconv(.c) void {
    rt.press(@intCast(send(isize, sender, "tag", .{})));
}

fn script(_: id, _: SEL, _: id) callconv(.c) void {
    rt.runScript();
}

fn quitAfterLastWindow(_: id, _: SEL, _: id) callconv(.c) bool {
    return true;
}

fn makeTarget() id {
    const c = objc_allocateClassPair(cls("NSObject"), "RocSignalsTarget", 0) orelse rt.die("cannot define the target class", .{});
    _ = class_addMethod(c, sel("press:"), @ptrCast(&pressed), "v@:@");
    _ = class_addMethod(c, sel("script:"), @ptrCast(&script), "v@:@");
    _ = class_addMethod(c, sel("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&quitAfterLastWindow), "B@:@");
    objc_registerClassPair(c);
    return send(id, send(id, c, "alloc", .{}), "init", .{});
}

// ---------------------------------------------------------------------------
// Process entry

fn cMain(_: c_int, _: [*]const [*:0]const u8) callconv(.c) c_int {
    loadRuntime();
    _ = objc_autoreleasePoolPush();

    const app = send(id, cls("NSApplication"), "sharedApplication", .{});
    send(void, app, "setActivationPolicy:", .{@as(isize, 0)});
    target = makeTarget();
    send(void, app, "setDelegate:", .{target});

    // Titled | closable | miniaturizable | resizable; buffered backing.
    window = send(id, send(id, cls("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ NSRect{ .x = 200, .y = 200, .w = 420, .h = 160 }, @as(usize, 15), @as(usize, 2), false });
    send(void, window, "setTitle:", .{nsString("Roc Signals")});

    // The mount root (node 0) is a column that fills the window.
    const root = Backend.stack(true);
    send(void, root, "setEdgeInsets:", .{NSEdgeInsets{ .top = 20, .left = 20, .bottom = 20, .right = 20 }});
    send(void, window, "setContentView:", .{root});
    rt.mount(root);

    send(void, window, "makeKeyAndOrderFront:", .{@as(id, null)});
    send(void, app, "activateIgnoringOtherApps:", .{true});
    if (rt.scripted()) send(void, target, "performSelector:withObject:afterDelay:", .{ sel("script:"), @as(id, null), @as(f64, 0.2) });
    send(void, app, "run", .{});
    return 0;
}

comptime {
    @export(&cMain, .{ .name = "main" });
}
