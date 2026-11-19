# Native desktop spike

An experiment, not part of the platform: the unchanged engine driving
native widgets on macOS (AppKit) and Linux (GTK 4). `design.md` lists a
native GUI host as a non-goal; this spike exists to measure what one would
take before proposing a change there.

- `platform/main-native.roc`: a second platform root over the same engine,
  with only mount, turns and teardown.
- `platform/Native.roc`: the widgets (`column`, `row`, `label`, `label_s`,
  `button`), ordinary engine elements in the `urn:roc-signals:native`
  namespace.
- `platform/host/native_runtime.zig`: the host and the command applier,
  shared by both systems. `native_mac.zig` and `native_gtk.zig` are each
  toolkit's widget operations and event loop; both load their toolkit with
  `dlopen`, so Roc's link needs no system UI libraries.

Only structural commands are drawn; keyed lists, attributes, text input and
effects are refused with a message.

## macOS (Apple silicon)

From `platform/`, with Zig 0.17.1:

```sh
zig build-lib -static host/native_mac.zig -target aarch64-macos -O ReleaseFast -fPIC -fcompiler-rt \
  -femit-bin=targets-native/arm64mac/libhost.a
```

Then, from the repository root:

```sh
roc build --opt=dev --target=arm64mac native/counter/main.roc --output=.build/native/counter
./.build/native/counter
```

## Linux (arm64, glibc, GTK 4)

From `platform/`, build the host. Then copy `crt1.o` and the `libc.so.6`
stub from Zig's glibc output into `targets-native/arm64glibc/`, naming the
stub `libc.so`. One way to find both files is to link any C program with
`zig build-exe -target aarch64-linux-gnu.2.39 -lc --verbose-link`.

```sh
zig build-lib -static host/native_gtk.zig -target aarch64-linux-gnu.2.39 -lc -O ReleaseFast -fPIC -fcompiler-rt \
  -femit-bin=targets-native/arm64glibc/libhost.a
```

Roc doesn't cross-compile glibc targets from macOS, so run `roc build` on
Linux (or in an arm64 container). The machine that runs the app needs
`libgtk-4-1`:

```sh
roc build --opt=dev --target=arm64glibc native/counter/main.roc --output=.build/native/counter-linux
./.build/native/counter-linux
```

## Self-test

`ROC_NATIVE_SCRIPT="+,+,-"` clicks the buttons with those titles through the
toolkit's own click path. It prints the widget tree the toolkit holds before
and after, then quits.

- `ROC_NATIVE_SNAPSHOT=out.pdf` also renders the window (macOS only).
- `ROC_NATIVE_STAY=1` keeps the window open, so you can take a screenshot
  from the display (on Linux, `xwd -root` under Xvfb).
