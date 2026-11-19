//! SPIKE: the Linux backend of the experimental native host
//! (`native_runtime.zig` holds everything that is not GTK). Widgets are
//! GTK 4 widgets: `GtkBox` for a column or row, `GtkLabel`s and
//! `GtkButton`s. GTK is loaded with `dlopen` (`libgtk-4.so.1`), so Roc's
//! link of the static host needs only glibc, and a missing GTK is a clear
//! message at start rather than a loader failure.
const std = @import("std");
const rt = @import("native_runtime.zig");

const View = rt.View;
const Ptr = ?*anyopaque;
const Str = [*:0]const u8;

const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
const GTK_ORIENTATION_VERTICAL: c_int = 1;
const GTK_ALIGN_START: c_int = 1;
const GTK_ALIGN_CENTER: c_int = 3;

// ---------------------------------------------------------------------------
// GTK, GObject and GLib, as the functions this backend calls.

const Gtk = struct {
    init: *const fn () callconv(.c) void,
    window_new: *const fn () callconv(.c) Ptr,
    window_set_title: *const fn (Ptr, Str) callconv(.c) void,
    window_set_default_size: *const fn (Ptr, c_int, c_int) callconv(.c) void,
    window_set_child: *const fn (Ptr, Ptr) callconv(.c) void,
    window_present: *const fn (Ptr) callconv(.c) void,
    box_new: *const fn (c_int, c_int) callconv(.c) Ptr,
    box_insert_child_after: *const fn (Ptr, Ptr, Ptr) callconv(.c) void,
    box_remove: *const fn (Ptr, Ptr) callconv(.c) void,
    label_new: *const fn (?Str) callconv(.c) Ptr,
    label_set_text: *const fn (Ptr, Str) callconv(.c) void,
    label_get_text: *const fn (Ptr) callconv(.c) ?Str,
    button_new_with_label: *const fn (Str) callconv(.c) Ptr,
    button_set_label: *const fn (Ptr, Str) callconv(.c) void,
    button_get_label: *const fn (Ptr) callconv(.c) ?Str,
    widget_set_halign: *const fn (Ptr, c_int) callconv(.c) void,
    widget_set_valign: *const fn (Ptr, c_int) callconv(.c) void,
    widget_set_margin_start: *const fn (Ptr, c_int) callconv(.c) void,
    widget_set_margin_end: *const fn (Ptr, c_int) callconv(.c) void,
    widget_set_margin_top: *const fn (Ptr, c_int) callconv(.c) void,
    widget_set_margin_bottom: *const fn (Ptr, c_int) callconv(.c) void,
    widget_get_first_child: *const fn (Ptr) callconv(.c) Ptr,
    widget_get_next_sibling: *const fn (Ptr) callconv(.c) Ptr,
    orientable_get_orientation: *const fn (Ptr) callconv(.c) c_int,
    g_type_name_from_instance: *const fn (Ptr) callconv(.c) Str,
    g_object_ref_sink: *const fn (Ptr) callconv(.c) Ptr,
    g_object_unref: *const fn (Ptr) callconv(.c) void,
    g_signal_emit_by_name: *const fn (Ptr, Str) callconv(.c) void,
    g_signal_connect_data: *const fn (Ptr, Str, *const anyopaque, Ptr, Ptr, c_int) callconv(.c) c_ulong,
    g_main_context_iteration: *const fn (Ptr, bool) callconv(.c) bool,
    g_main_context_wakeup: *const fn (Ptr) callconv(.c) void,
    g_timeout_add: *const fn (c_uint, *const anyopaque, Ptr) callconv(.c) c_uint,
};

var gtk: Gtk = undefined;

fn load() void {
    const lib = rt.open("libgtk-4.so.1");
    inline for (@typeInfo(Gtk).@"struct".field_names, @typeInfo(Gtk).@"struct".field_types) |name, T| {
        const symbol = comptime if (std.mem.startsWith(u8, name, "g_") or std.mem.startsWith(u8, name, "gdk_") or std.mem.startsWith(u8, name, "gsk_")) name else "gtk_" ++ name;
        @field(gtk, name) = rt.sym(T, lib, symbol);
    }
}

/// A NUL-terminated copy for GTK, freed by the caller.
fn cstr(text: []const u8) [:0]u8 {
    return rt.gpa.dupeSentinel(u8, text, 0) catch rt.die("out of memory", .{});
}

// ---------------------------------------------------------------------------
// The widget operations the runtime calls. The runtime holds one reference
// to each widget (taken here with `g_object_ref_sink`), so removing a widget
// from its box never destroys one the runtime is moving, and dropping that
// reference frees it.

var window: Ptr = null;
var closed = false;

pub const Backend = struct {
    pub fn stack(vertical: bool) View {
        const b = gtk.g_object_ref_sink(gtk.box_new(if (vertical) GTK_ORIENTATION_VERTICAL else GTK_ORIENTATION_HORIZONTAL, 8));
        if (vertical) gtk.widget_set_halign(b, GTK_ALIGN_START);
        return b;
    }

    pub fn label() View {
        const l = gtk.g_object_ref_sink(gtk.label_new(""));
        gtk.widget_set_halign(l, GTK_ALIGN_START);
        gtk.widget_set_valign(l, GTK_ALIGN_CENTER);
        return l;
    }

    pub fn button(n: u32) View {
        const b = gtk.g_object_ref_sink(gtk.button_new_with_label(""));
        _ = gtk.g_signal_connect_data(b, "clicked", @ptrCast(&clicked), @ptrFromInt(@as(usize, n) + 1), null, 0);
        return b;
    }

    pub fn insert(parent: View, child: View, _: usize, previous: View) void {
        gtk.box_insert_child_after(parent, child, previous);
    }

    pub fn remove(parent: View, child: View) void {
        gtk.box_remove(parent, child);
    }

    pub fn release(view: View) void {
        gtk.g_object_unref(view);
    }

    pub fn setLabel(view: View, text: []const u8) void {
        const z = cstr(text);
        defer rt.gpa.free(z);
        gtk.label_set_text(view, z);
    }

    pub fn setButton(view: View, text: []const u8) void {
        const z = cstr(text);
        defer rt.gpa.free(z);
        gtk.button_set_label(view, z);
    }

    pub fn buttonText(view: View) []const u8 {
        return std.mem.span(gtk.button_get_label(view) orelse "");
    }

    /// A click as a user makes it: `clicked`, the signal a button's click
    /// gesture emits on release, through GTK's signal system. (Keyboard
    /// activation emits it too, but only after a 250 ms animation.)
    pub fn click(view: View) void {
        gtk.g_signal_emit_by_name(view, "clicked");
    }

    pub fn dump() void {
        var child = gtk.widget_get_first_child(window);
        while (child != null) : (child = gtk.widget_get_next_sibling(child)) dumpWidget(child, 0);
    }

    /// Not yet: GTK paints a toplevel only to its surface. Take the
    /// screenshot from the display instead (with `ROC_NATIVE_STAY`).
    pub fn snapshot(_: [*:0]const u8) void {
        rt.die("ROC_NATIVE_SNAPSHOT is not supported with GTK; screenshot the display with ROC_NATIVE_STAY=1", .{});
    }

    pub fn quit() void {
        closed = true;
        gtk.g_main_context_wakeup(null);
    }
};

/// Print the tree as GTK holds it, reading each widget's own text.
fn dumpWidget(w: Ptr, depth: usize) void {
    const type_name = std.mem.span(gtk.g_type_name_from_instance(w));
    if (std.mem.eql(u8, type_name, "GtkButton")) {
        rt.dumpLine(depth, "button \"{s}\"", .{Backend.buttonText(w)});
    } else if (std.mem.eql(u8, type_name, "GtkLabel")) {
        rt.dumpLine(depth, "label \"{s}\"", .{std.mem.span(gtk.label_get_text(w) orelse "")});
    } else if (std.mem.eql(u8, type_name, "GtkBox")) {
        rt.dumpLine(depth, "{s}", .{if (gtk.orientable_get_orientation(w) == GTK_ORIENTATION_VERTICAL) "column" else "row"});
        var child = gtk.widget_get_first_child(w);
        while (child != null) : (child = gtk.widget_get_next_sibling(child)) dumpWidget(child, depth + 1);
    } else rt.dumpLine(depth, "{s}", .{type_name});
}

// ---------------------------------------------------------------------------
// Callbacks GTK makes.

/// `clicked`: the data is the button's node id plus one (never null).
fn clicked(_: Ptr, data: Ptr) callconv(.c) void {
    rt.press(@intCast(@intFromPtr(data) - 1));
}

fn closeRequest(_: Ptr, _: Ptr) callconv(.c) bool {
    closed = true;
    return false;
}

fn script(_: Ptr) callconv(.c) bool {
    rt.runScript();
    return false; // run once
}

// ---------------------------------------------------------------------------
// Process entry

fn cMain(_: c_int, _: [*]const [*:0]const u8) callconv(.c) c_int {
    load();
    gtk.init();

    window = gtk.window_new();
    gtk.window_set_title(window, "Roc Signals");
    gtk.window_set_default_size(window, 420, 160);
    _ = gtk.g_signal_connect_data(window, "close-request", @ptrCast(&closeRequest), null, null, 0);

    // The mount root (node 0) is a column that fills the window.
    const root = Backend.stack(true);
    gtk.widget_set_margin_start(root, 20);
    gtk.widget_set_margin_end(root, 20);
    gtk.widget_set_margin_top(root, 20);
    gtk.widget_set_margin_bottom(root, 20);
    gtk.window_set_child(window, root);
    rt.mount(root);

    gtk.window_present(window);
    if (rt.scripted()) _ = gtk.g_timeout_add(300, @ptrCast(&script), null);
    while (!closed) _ = gtk.g_main_context_iteration(null, true);
    return 0;
}

comptime {
    @export(&cMain, .{ .name = "main" });
}
